package dnsext

import (
	"context"
	"errors"
	"fmt"
	"github.com/hashicorp/golang-lru"
	"github.com/miekg/dns"
	"hash/fnv"
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

var (
	minTTL = 1 * time.Minute
	maxTTL = 6 * time.Hour
)

type Server struct {
	http  http.Client
	url   *url.URL
	dns   dns.Client
	cache *lru.Cache
	addr  string

	ipv4Loopback *dns.Server
	ipv6Loopback *dns.Server
}

type cacheEntry struct {
	msg    *dns.Msg
	expire time.Time
}

func NewServer(listenAddr string, dohServer string) (s *Server, err error) {
	s = &Server{
		http: http.Client{},
		dns:  dns.Client{},
		addr: listenAddr,
		ipv4Loopback: &dns.Server{
			Addr:         "127.0.0.1:53",
			Net:          "udp",
			ReadTimeout:  10 * time.Second,
			WriteTimeout: 10 * time.Second,
		},
		ipv6Loopback: &dns.Server{
			Addr:         "[::1]:53",
			Net:          "udp",
			ReadTimeout:  10 * time.Second,
			WriteTimeout: 10 * time.Second,
		},
	}
	s.http.Transport = dohTransport

	s.ipv4Loopback.Handler = s.handleDnsRequest()
	s.ipv6Loopback.Handler = s.handleDnsRequest()
	s.http.Timeout = time.Second * 6

	if s.url, err = url.Parse(dohServer); err != nil {
		return nil, err
	}

	if s.cache, err = lru.New(100); err != nil {
		return nil, fmt.Errorf("failed cache init: %v", err)
	}

	return s, nil
}

func hash(qname string, qtype uint16) uint64 {
	h := fnv.New64()
	h.Write([]byte{byte(qtype >> 8)})
	h.Write([]byte{byte(qtype)})
	h.Write([]byte(qname))
	return h.Sum64()
}

func (s *Server) exchangeWithCache(ctx context.Context, req *dns.Msg) (*dns.Msg, error) {
	if len(req.Question) != 1 {
		return nil, fmt.Errorf("bad question")
	}
	req.Question[0].Name = dns.CanonicalName(req.Question[0].Name)

	key := hash(req.Question[0].Name, req.Question[0].Qtype)
	if val, ok := s.cache.Get(key); ok {
		r := val.(*cacheEntry)
		if time.Now().Before(r.expire) {
			ttl := uint32(r.expire.Sub(time.Now()).Seconds())
			for _, rr := range r.msg.Answer {
				rr.Header().Ttl = ttl
			}

			// check for collisions
			if strings.EqualFold(req.Question[0].Name, r.msg.Question[0].Name) {
				return r.msg, nil
			}
		}
		s.cache.Remove(key)
	}

	r, _, err := s.exchange(ctx, req)
	if err != nil {
		return nil, err
	}

	if r.Rcode == dns.RcodeServerFailure {
		return r, nil
	}

	// clear extra section
	r.Extra = nil
	ttl := getMinTTL(r)
	s.cache.Add(key, &cacheEntry{
		msg:    r,
		expire: time.Now().Add(ttl),
	})

	return r, nil
}

func (s *Server) exchange(ctx context.Context, msg *dns.Msg) (re *dns.Msg, rtt time.Duration, err error) {
	re, rtt, err = s.dns.ExchangeWithConn(msg, &dns.Conn{Conn: &dohConn{
		endpoint: s.url,
		http:     &s.http,
		ctx:      ctx,
	}})

	if err == nil {
		if re.Truncated {
			err = errors.New("response truncated")
		}
	}

	return
}

// getMinTTL get the ttl for dns msg
// borrowed from coredns: https://github.com/coredns/coredns/blob/master/plugin/pkg/dnsutil/ttl.go
func getMinTTL(m *dns.Msg) time.Duration {
	// No records or OPT is the only record, return a short ttl as a fail safe.
	if len(m.Answer)+len(m.Ns) == 0 &&
		(len(m.Extra) == 0 || (len(m.Extra) == 1 && m.Extra[0].Header().Rrtype == dns.TypeOPT)) {
		return minTTL
	}

	minTTL := maxTTL
	for _, r := range m.Answer {
		if r.Header().Ttl < uint32(minTTL.Seconds()) {
			minTTL = time.Duration(r.Header().Ttl) * time.Second
		}
	}
	for _, r := range m.Ns {
		if r.Header().Ttl < uint32(minTTL.Seconds()) {
			minTTL = time.Duration(r.Header().Ttl) * time.Second
		}
	}

	for _, r := range m.Extra {
		if r.Header().Rrtype == dns.TypeOPT {
			// OPT records use TTL field for extended rcode and flags
			continue
		}
		if r.Header().Ttl < uint32(minTTL.Seconds()) {
			minTTL = time.Duration(r.Header().Ttl) * time.Second
		}
	}
	return minTTL
}

func answerHINFO(msg *dns.Msg, hinfoStr string) {
	// we can't use Rcode Servfail or Refused here
	// iOS will fallback to system resolver which
	// leaks DNS queries
	msg.Rcode = dns.RcodeSuccess

	// limit length in case the device's resolver
	// doesn't like it
	if len(hinfoStr) > 200 {
		hinfoStr = hinfoStr[:200]
	}
	var name string
	if len(msg.Question) > 0 {
		name = msg.Question[0].Name
	}
	rr := &dns.HINFO{
		Hdr: dns.RR_Header{
			Name:   name,
			Rrtype: dns.TypeHINFO,
			Class:  dns.ClassINET,
			Ttl:    1,
		},
		Cpu: hinfoStr,
		Os:  "Impervious Resolver",
	}

	msg.Ns = append(msg.Ns, rr)
}

func (s *Server) handleDnsRequest() dns.HandlerFunc {
	return func(w dns.ResponseWriter, req *dns.Msg) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		resp, err := s.exchangeWithCache(ctx, req)

		// if there's an error and we haven't reached the ctx timeout yet
		// keep retrying. This is useful if user switched from Wifi to cellular
		// The lookup may work again after it connects
		if err != nil {
		RetryLoop:
			for {
				select {
				case <-ctx.Done():
					break RetryLoop
				default:
					resp, err = s.exchangeWithCache(ctx, req)
					if err == nil {
						break RetryLoop
					}
				}
			}
		}

		if err != nil {
			log.Printf("lookup error: %v", err)
			msg := &dns.Msg{}
			msg.SetReply(req)

			// embed error using HINFO for debugging similar to dnscryptproxy
			hinfoStr := fmt.Sprintf("lookup error: %v", err)
			answerHINFO(msg, hinfoStr)
			w.WriteMsg(msg)
			return
		}
		rcode := resp.Rcode
		if rcode == dns.RcodeServerFailure || rcode == dns.RcodeRefused {
			hinfoStr := fmt.Sprintf("lookup failed: %s (code: %d)", dns.RcodeToString[rcode], rcode)
			msg := &dns.Msg{}
			msg.SetReply(req)

			answerHINFO(msg, hinfoStr)
			w.WriteMsg(msg)
			return
		}

		resp.SetReply(req)
		resp.Rcode = rcode
		w.WriteMsg(resp)
	}
}

func (s *Server) ListenAndServe() {
	log.Printf("starting listening")
	// attempt to find & cache DoH address
	host, _, err := net.SplitHostPort(s.url.Host)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err == nil {
		go addrRes.lookupDialAddrList(ctx, host)
	}

	go func() {
		s.ipv6Loopback.ListenAndServe()
		s.Shutdown()
	}()

	err = s.ipv4Loopback.ListenAndServe()
	if err != nil {
		log.Printf("udp server listen and serve error: %v", err)
	}

}


func (s *Server) CloseIdleConnections() {
	if s != nil {
		s.http.CloseIdleConnections()
	}
}

func (s *Server) Shutdown() {
	go s.ipv6Loopback.Shutdown()
	s.ipv4Loopback.Shutdown()
}
