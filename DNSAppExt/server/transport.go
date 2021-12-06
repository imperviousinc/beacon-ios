package dnsext

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"github.com/miekg/dns"
	"golang.org/x/sync/errgroup"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

var mobileTransport = &MobileTransport{
	tr: internalTransport,
}

type MobileTransport struct {
	tr *http.Transport
	sync.RWMutex
}

func (m *MobileTransport) CloseIdleConnections() {
	m.RLock()
	m.tr.CloseIdleConnections()
	m.RUnlock()
}


func (m *MobileTransport) CloseAllConnections() {
	m.CloseIdleConnections()

	m.Lock()
	m.tr = m.tr.Clone()
	m.Unlock()
}

func (m *MobileTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	m.RLock()
	tr := m.tr
	m.RUnlock()

	if tr == nil {
		return nil, errors.New("no http transport available")
	}

	return tr.RoundTrip(req)
}

var (
	// if net.LookupHost fails
	// use the following servers to find DoH address
	bootstrapAddresses = []string{
		"[2606:4700:4700::1111]",
		"1.1.1.1",
		"[2620:fe::fe]",
		"9.9.9.9",
	}
)

type addrList struct {
	host   string
	addrs  []net.IP
	expire time.Time

	tlsClient *dns.Client
	udpClient *dns.Client

	sync.RWMutex
}


var (
	dialer = &net.Dialer{
		Timeout: 5 * time.Second,
	}

	addrRes = newAddrList()

	internalTransport = &http.Transport{
		ForceAttemptHTTP2: true,
		MaxIdleConnsPerHost: 30,
		TLSHandshakeTimeout: 10*time.Second,
		ExpectContinueTimeout: 10*time.Second,
		MaxResponseHeaderBytes: 4096,
		DialTLSContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}

			host = strings.ToLower(host)
			ips, err := addrRes.lookupDialAddrList(ctx, host)
			if err != nil {
				return nil, fmt.Errorf("no such host")
			}

			var lastErr error
			for _, ip := range ips {
				if ip.To4() == nil {
					addr = "[" + ip.String() + "]"
				} else {
					addr = ip.String()
				}

				tlsDialer := tls.Dialer{
					NetDialer: dialer,
					Config: &tls.Config{
						ServerName: host,
						MinVersion: tls.VersionTLS13,
						NextProtos: []string{"h2"},
					},
				}

				conn, err := tlsDialer.DialContext(ctx, network, addr+":"+port)
				if err != nil {
					lastErr = err
					continue
				}
				return conn, nil
			}
			return nil, lastErr
		},
	}
)

func newAddrList() *addrList {
	a := &addrList{
		tlsClient: &dns.Client{
			Net:            "tcp-tls",
			SingleInflight: true,
		},
		udpClient: &dns.Client{
			Net:            "udp",
			SingleInflight: true,
		},
	}
	return a
}

func (a *addrList) lookupIPv(ctx context.Context, host, server string, ip4, tls bool) ([]dns.RR, error) {
	msg := new(dns.Msg)
	if ip4 {
		msg.SetQuestion(dns.Fqdn(host), dns.TypeA)
	} else {
		msg.SetQuestion(dns.Fqdn(host), dns.TypeAAAA)
	}
	var res *dns.Msg
	var err error

	if tls {
		res, _, err = a.tlsClient.ExchangeContext(ctx, msg, server+":853")
	} else {
		res, _, err = a.udpClient.ExchangeContext(ctx, msg, server+":53")
	}

	if err != nil {
		return nil, err
	}
	if res.Truncated {
		return nil, fmt.Errorf("truncated")
	}
	if res.Rcode != dns.RcodeSuccess {
		if res.Rcode == dns.RcodeNameError {
			return nil, nil
		}
		return nil, fmt.Errorf("failed got rcode: %d", res.Rcode)
	}
	return res.Answer, nil
}

func (a *addrList) lookupIP(ctx context.Context, host string, tryOS, tryTLS bool) ([]net.IP, time.Time, error) {
	if tryOS {
		ips, err := net.LookupIP(host)

		if err == nil && len(ips) > 0 {
			for _, ip := range ips {
				// only accept if addr isn't 0.0.0.0
				if !ip.IsUnspecified() {
					return ips, time.Now().Add(time.Minute), nil
				}
			}
		}
	}

	tryWithServer := func(ctx context.Context, server string, tls bool) (ip4, ip6 []net.IP, exp time.Time, err error) {
		g, ctx := errgroup.WithContext(ctx)

		var ttl1, ttl2 uint32
		g.Go(func() error {
			rrs, err := a.lookupIPv(ctx, host, server, true, true)
			if err != nil {
				return err
			}
			for _, rr := range rrs {
				if rr.Header().Rrtype == dns.TypeA {
					ttl1 = rr.Header().Ttl
					a4 := rr.(*dns.A)
					ip4 = append(ip4, a4.A)
				}
			}
			return nil
		})

		g.Go(func() error {
			rrs, err := a.lookupIPv(ctx, host, server, false, true)
			if err != nil {
				return err
			}
			for _, rr := range rrs {
				if rr.Header().Rrtype == dns.TypeAAAA {
					ttl2 = rr.Header().Ttl
					a6 := rr.(*dns.AAAA)
					ip6 = append(ip6, a6.AAAA)
				}
			}
			return nil
		})

		err = g.Wait()
		if ttl2 < ttl1 {
			ttl1 = ttl2
		}

		exp = time.Now().Add(time.Duration(ttl1) * time.Second)
		return
	}

	// fallback
	var lastErr error
	for _, server := range bootstrapAddresses {
		select {
		case <-ctx.Done():
			return nil, time.Time{}, fmt.Errorf("lookup failed context deadline exceeded")
		default:
			ip4, ip6, ttl, err := tryWithServer(ctx, server, tryTLS)
			if err != nil {
				lastErr = err
				continue
			}
			log.Printf("found address using server: %s", server)
			return mixAddrs(ip4, ip6), ttl, nil
		}
	}

	return nil, time.Time{}, lastErr
}

func mixAddrs(ip4, ip6 []net.IP) []net.IP {
	var addrs []net.IP
	// A/AAAA usually have the same length
	// prefer ipv6
	var addr1 = ip6
	var addr2 = ip4

	if len(ip4) < len(ip6) {
		addr1 = ip4
		addr2 = ip6
	}

	for idx, ip := range addr1 {
		addrs = append(addrs, ip)
		addrs = append(addrs, addr2[idx])
	}

	for i := len(addr1); i < len(addr2); i++ {
		addrs = append(addrs, addr2[i])
	}

	return addrs
}

func (a *addrList) getCachedAddrs(host string) []net.IP {
	a.RLock()
	defer a.RUnlock()

	if len(a.addrs) == 0 || a.host != host {
		return nil
	}
	if time.Now().After(a.expire) {
		return nil
	}

	return a.addrs
}

func (a *addrList) lookupDialAddrList(ctx context.Context, host string) ([]net.IP, error) {
	if ip := net.ParseIP(host) ; ip != nil {
		return []net.IP{ip}, nil
	}

	if addrs := a.getCachedAddrs(host); len(addrs) > 0 {
		return addrs, nil
	}

	// try lookup with Dns over TLS max 1 second
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	ips, exp, err := a.lookupIP(ctx, host, false, true)
	cancel()

	if err != nil {
		// try with OS or without TLS
		ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		ips, exp, err = a.lookupIP(ctx, host, true, false)
		cancel()

		if err != nil {
			return nil, err
		}
	}

	a.Lock()
	a.expire = exp
	a.host = host
	a.addrs = ips
	a.Unlock()

	log.Printf("fetched resolver ip addresses: %v", ips)

	return ips, nil
}
