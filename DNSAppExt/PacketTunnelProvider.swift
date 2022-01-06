//
//  PacketTunnelProvider.swift
//  DNSAppExt
//
//  Copyright © 2021 Beacon. All rights reserved.
//

import NetworkExtension
import DNSExt

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var tunnelStarted = false
    private var initialPathUpdate = false
    
    private var supportsIPv4 = true
    private var supportsIPv6 = true
    private var networkMonitor : NWPathMonitor?
    
    // Remove once min os is iOS 14+
    private let debugLegacyDNS = false
    
    private var dohURL = "https://hs.dnssec.dev/dns-query"
    private let workQueue = DispatchQueue(label: "BeaconWorkQueue")
    
    struct LocalAddresses {
        // Tunnel interface
        static let tunIPv4 = "192.0.2.30"
        static let tunIPv6 = "fdbd:bd:bd:bd::"
        
        // Routes in the local VPN
        // no traffic is sent to those addresses
        // for now. All other routes are excluded
        static let dnsIPv4 = "2001:db8:bd:bd::"
        static let dnsIPv6 = "192.0.2.36"
        
        // legacy DNS listening on loopback for < iOS 14+
        static let legacyDNSIPv4 = "127.0.0.1"
        static let legacyDNSIPv6 = "::1"
    }
    
    private func didReceivePathUpdate(path: Network.NWPath) {
        if !self.tunnelStarted {
            return
        }
        
        if initialPathUpdate {
            initialPathUpdate = false
            return
        }
        
        if path.status == .satisfied || path.status == .requiresConnection {
            if supportsIPv4 != path.supportsIPv4 || supportsIPv6 != path.supportsIPv6 {
                supportsIPv4 = path.supportsIPv4
                supportsIPv6 = path.supportsIPv6
                updateNetworkSettings (completionHandler: {_ in })
            }
            
            maybeResetLegacyIdleConns()
        }
    }
    
    func readDoHURL() -> String {
        guard let tunProto = self.protocolConfiguration as? NETunnelProviderProtocol,
              let config = tunProto.providerConfiguration,
              let url = config["dohURL"] as? String  else {
                  // fallback to default
                  return "https://hs.dnssec.dev/dns-query"
              }
        
        return url
    }
    
    func updateNetworkStatusSync() {
        let condition = NSCondition()
        
        condition.lock()
        defer { condition.unlock() }
        
        let netMonitor = NWPathMonitor()
        netMonitor.pathUpdateHandler = { [weak self] path in
            self?.supportsIPv6 = path.supportsIPv6
            self?.supportsIPv4 = path.supportsIPv4
            self?.initialPathUpdate = true
            condition.signal()
        }
        netMonitor.start(queue: workQueue)
        defer { netMonitor.cancel() }
        
        let timeout: TimeInterval = 0.5 // seconds
        if condition.wait(until: Date().addingTimeInterval(timeout)) {
            return
        }
        
        supportsIPv4 = true
        supportsIPv6 = true
    }
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        updateNetworkStatusSync()
        
        workQueue.async {
            self.dohURL = self.readDoHURL()
            
            if (self.tunnelStarted) {
                completionHandler(nil)
                return
            }
            
            self.maybeStartLegacyDNS()
            self.updateNetworkSettings(completionHandler: completionHandler)
            
            // Monitor network changes
            self.networkMonitor = NWPathMonitor()
            self.networkMonitor?.pathUpdateHandler = { [weak self] path in
                if !(self?.tunnelStarted ?? false) {
                    return
                }
                
                self?.didReceivePathUpdate(path: path)
            }
            self.networkMonitor?.start(queue: self.workQueue)
        }
    }
    
    func updateNetworkSettings(completionHandler: @escaping (Error?) -> Void) {
        let remoteAddress = supportsIPv6 ? "::1" : "127.0.0.1"
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        
        if #available(iOSApplicationExtension 14.0, *), !debugLegacyDNS {
            let doh = NEDNSOverHTTPSSettings()
            doh.serverURL = URL(string: self.dohURL)
            doh.matchDomains = [""]
            settings.dnsSettings = doh
        } else {
            // Fallback on earlier versions
            let legacyDNS = NEDNSSettings(servers: ["127.0.0.1", "::1"])
            legacyDNS.matchDomains = [""]
            settings.dnsSettings = legacyDNS
        }
        
        let ipv4 = NEIPv4Settings(addresses: [LocalAddresses.tunIPv4], subnetMasks: ["255.255.255.255"])
        let ipv6 = NEIPv6Settings(addresses: [LocalAddresses.tunIPv6], networkPrefixLengths: [128])
        
        // Exclude all routes from VPN
        ipv4.excludedRoutes = [NEIPv4Route.default()]
        ipv6.excludedRoutes = [NEIPv6Route.default()]
        
        // Include DNS routes only (not used for anything currently)
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: LocalAddresses.dnsIPv4, subnetMask: "255.255.255.255")]
        ipv6.includedRoutes = [NEIPv6Route(destinationAddress: LocalAddresses.dnsIPv6, networkPrefixLength: 128)]
        
        if supportsIPv4 {
            settings.ipv4Settings = ipv4
        }
        
        if supportsIPv6 {
            settings.ipv6Settings = ipv6
        }
        
        do {
            try setNetworkSettings(settings)
            tunnelStarted = true
            completionHandler(nil)
        } catch let error {
            completionHandler(error)
        }
    }
    
    private func setNetworkSettings(_ settings: NEPacketTunnelNetworkSettings) throws {
        var systemError: Error?
        let condition = NSCondition()
        
        condition.lock()
        defer { condition.unlock() }
        
        self.setTunnelNetworkSettings(settings) { error in
            systemError = error
            condition.signal()
        }
        
        // Call completionHandler after some timeout
        // based on: https://github.com/WireGuard/wireguard-apple/blob/master/Sources/WireGuardKit/WireGuardAdapter.swift#L314
        let timeout: TimeInterval = 6 // seconds
        if condition.wait(until: Date().addingTimeInterval(timeout)) {
            if let systemError = systemError {
                throw systemError
            }
        }
    }
    
    @objc func LegacyDNSListenAndServe() {
        DnsextListenAndServe()
        
        workQueue.async {
            if (!self.tunnelStarted) {
                return
            }
            
            exit(EXIT_FAILURE)
        }
    }
    
    func maybeStartLegacyDNS() {
        guard #available(iOSApplicationExtension 14.0, *), !debugLegacyDNS else {
            workQueue.async {
                DnsextInitServer("\(LocalAddresses.legacyDNSIPv4):53", "[\(LocalAddresses.legacyDNSIPv6)]:53", self.dohURL)
                
                let thread = Thread.init(target: self, selector: #selector(self.LegacyDNSListenAndServe), object: nil)
                thread.start()
            }
            return
        }
    }
    
    func maybeStopLegacyDNS() {
        guard #available(iOSApplicationExtension 14.0, *), !debugLegacyDNS else {
            DnsextShutdown()
            return
        }
    }
    
    func maybeResetLegacyIdleConns() {
        guard #available(iOSApplicationExtension 14.0, *), !debugLegacyDNS else {
            DnsextCloseIdleConnections()
            return
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        workQueue.async {
            self.tunnelStarted = false
            self.networkMonitor?.cancel()
            self.maybeStopLegacyDNS()
            completionHandler()
            
            // macoS bug see: https://developer.apple.com/forums/thread/84920
            // HACK: This is a filthy hack to work around Apple bug 32073323. Remove it when
            // they finally fix this upstream and the fix has been rolled out widely enough.
            exit(EXIT_SUCCESS)
        }
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let command = String.init(data: messageData, encoding: String.Encoding.utf8)!
        switch command {
        case "reloadSettings":
            workQueue.async {
                // update settings to reload protocolConfiguration
                self.updateNetworkSettings { _ in
                    // read doh url from proto config and save
                    self.dohURL = self.readDoHURL()
                    self.updateNetworkSettings { _ in }
                }
            }
        default:
            if let handler = completionHandler {
                handler(messageData)
            }
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    
    override func wake() {
        maybeResetLegacyIdleConns()
    }
}
