package dnsext

import (
	"log"
	"runtime/debug"
	"time"
	_ "golang.org/x/mobile/bind"
)

var server *Server


func InitServer(listenIP4, listenIP6, doh string) int {
	var err error
	if server, err = NewServer(listenIP4, listenIP6, doh) ; err != nil {
		log.Printf("failed creating server: %v", err)
		return -1
	}

	return 0
}

func CloseIdleConnections() {
	if server == nil {
		return
	}
	server.CloseIdleConnections()
}

func ListenAndServe() {
	if server == nil {
		return
	}

	debug.SetGCPercent(10)

	go func() {
		for range time.NewTicker(5 * time.Second).C {
			debug.FreeOSMemory()
		}
	}()

	server.ListenAndServe()
}

func Shutdown() {
	if server == nil {
		return
	}

	server.Shutdown()
}

