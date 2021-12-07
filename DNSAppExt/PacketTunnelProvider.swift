//
//  PacketTunnelProvider.swift
//  DNSAppExt
//
//  Copyright © 2021 Beacon. All rights reserved.
//

import NetworkExtension
import DNSExt

class PacketTunnelProvider: NEPacketTunnelProvider {
    var tunnelStarted = false
    var dohURL = "https://hs.dnssec.dev/dns-query"
    
    private let workQueue = DispatchQueue(label: "BeaconWorkQueue")
    
    @objc func ListenAndServe() {
        DnsextListenAndServe()
        workQueue.async {
            if (!self.tunnelStarted) {
                exit(EXIT_SUCCESS)
            }
            
            exit(EXIT_FAILURE)
        }
    }
    
    private func didReceivePathUpdate(path: Network.NWPath) {
        if tunnelStarted {
            if path.status == .satisfied || path.status == .requiresConnection {
                reactivateTunnel()
            }
        }
    }
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        workQueue.async {
            if (self.tunnelStarted) {
                completionHandler(nil)
                return
            }
            
            let networkMonitor = NWPathMonitor()
            networkMonitor.pathUpdateHandler = { [weak self] path in
                self?.didReceivePathUpdate(path: path)
            }
            networkMonitor.start(queue: self.workQueue)
            
            self.tunnelStarted = true
            
            if let opts = options, let secureOpt = opts["SecureDNSURL"] {
                self.dohURL = secureOpt as! String
            }
            
            
            DnsextInitServer("127.0.0.1:53", "[::1]:53", self.dohURL)
            
            let thread = Thread.init(target: self, selector: #selector(self.ListenAndServe), object: nil)
            thread.start()
            self.saveNetworkSettings(completionHandler: completionHandler)
            
        }
    }
    
    func saveNetworkSettings(completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1280
        
        let dnsSettings = NEDNSSettings(servers: ["127.0.0.1", "::1"])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        
        let condition = NSCondition()
        var saveErr : Error?
        
        condition.lock()
        defer { condition.unlock() }
        
        
        self.setTunnelNetworkSettings(settings) { error in
            saveErr = error
            condition.signal()
        }
        
        // Sometimes setTunnelNetworkSettings callback never
        // gets called we should call completionHandler after
        // some timeout either way
        // based on: https://github.com/WireGuard/wireguard-apple/blob/master/Sources/WireGuardKit/WireGuardAdapter.swift#L314
        let timeout: TimeInterval = 5 // seconds
        if condition.wait(until: Date().addingTimeInterval(timeout)) {
              completionHandler(saveErr)
        } else {
            // timeout continue anyway
            completionHandler(nil)
        }
    }
    
    func reactivateTunnel() {
        workQueue.async {
           DnsextCloseIdleConnections()
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        tunnelStarted = false
        DnsextShutdown()
        
        completionHandler()
        exit(EXIT_SUCCESS)
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let handler = completionHandler {
            handler(messageData)
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    
    override func wake() {
        reactivateTunnel()
    }
}
