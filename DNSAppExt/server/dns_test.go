package dnsext

import (
	"bufio"
	"github.com/miekg/dns"
	"log"
	"os"
	"strings"
	"testing"
	"time"
)

func TestServer_ListenAndServe(t *testing.T) {
	InitServer("127.0.0.1:5451", "https://hns.dnssec.dev/dns-query")
	ListenAndServe()
}

func TestNewServer(t *testing.T) {
	InitServer("127.0.0.1:5450", "https://hns.dnssec.dev/dns-query")
	go ListenAndServe()

	time.Sleep(1 * time.Second)

	f, err := os.OpenFile("testdata/10million-query", os.O_RDONLY, 0644)
	if err != nil {
		t.Fatalf("err make sure query test file is available: %v", err)
		return
	}

	c := dns.Client{}
	sc := bufio.NewScanner(f)
	count := 200
	for sc.Scan() {
		count--
		if count < 0 {
			break
		}
		parts := strings.Fields(sc.Text())
		if len(parts) != 2 {
			continue
		}

		strType := strings.TrimSpace(parts[1])
		qtype, ok := dns.StringToType[strType]
		if !ok {
			continue
		}

		msg := &dns.Msg{}
		msg.SetQuestion(strings.TrimSpace(parts[0]), qtype)
		msg.SetEdns0(4096, true)
		msg.AuthenticatedData = true
		r, _, err := c.Exchange(msg, "127.0.0.1:5450")
		if err != nil {
			log.Printf("failed querying %s %s: %v", msg.Question[0].Name, strType, err)
			continue
		}
		log.Printf("success querying %s %s: answers: %d, rcode: %s", r.Question[0].Name, strType, len(msg.Answer), dns.RcodeToString[r.Rcode])
	}
}
