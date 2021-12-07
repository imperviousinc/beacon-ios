//
//  BeaconAccessors.swift
//  Client
//
//  Copyright © 2021 Beacon. All rights reserved.
//
import Shared
import Foundation
import NetworkExtension

class BeaconConstants {
    public static let SecureDNSPrefKey = "ImpSecureDNSPref"
    public static let SecureDNSURLPrefKey = "ImpSecureDNSURLPref"
    public static let SecureDNSDefaultOption = "Beacon"
    public static let SecureDNSCustomOption = "Custom"
    public static let SecureDNSDisabled = "Disabled"
    public static let SecureDNSDefaultURL = "https://hs.dnssec.dev/dns-query"
}

class DNSVPNConfiguration {
    static var status = false
    
    static func initObserver() {
        
    }
    
    static func updateConnected() -> Bool {
        getManager() { m in
            guard let manager = m else {
                status = false
                return
            }
            
            let state = manager.connection.status
            status = connStatus(state)
        }
        
       
        return status
    }
    
    static func getDoHURL() -> String {
        var url = BeaconConstants.SecureDNSDefaultURL
        let choice = NSUserDefaultsPrefs(prefix: "profile").stringForKey(BeaconConstants.SecureDNSPrefKey)
        if choice == "Custom" {
            url = NSUserDefaultsPrefs(prefix: "profile").stringForKey(BeaconConstants.SecureDNSURLPrefKey) ?? BeaconConstants.SecureDNSDefaultURL
        }
        return url
    }
    
    static func startVPN() {
        var url = BeaconConstants.SecureDNSDefaultURL
        let choice = NSUserDefaultsPrefs(prefix: "profile").stringForKey(BeaconConstants.SecureDNSPrefKey)
        if choice == "Custom" {
            url = NSUserDefaultsPrefs(prefix: "profile").stringForKey(BeaconConstants.SecureDNSURLPrefKey) ?? BeaconConstants.SecureDNSDefaultURL
        }
        
        getManager() { m in
            do {
                try m?.connection.startVPNTunnel(options: ["SecureDNSURL": url as NSObject])
                print("vpn: starting tunnel with url: \(url)")
            } catch   {
                print("failed starting")
            }
        }
    }
    
    static func restartVPN() {
        stopVPN()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            startVPN()
        }
    }
    
    static func stopVPN() {
        getManager() { m in
            guard let manager = m else {
                return
            }
            manager.isOnDemandEnabled = false
            manager.saveToPreferences() { (error) -> Void in
                manager.connection.stopVPNTunnel()
            }
           
        }
    }
    
    static func getManager(_ m : @escaping ((NEVPNManager?) -> Void))  {
        NETunnelProviderManager.loadAllFromPreferences() { (managers, error) in
            if let managers = managers, managers.count > 0 {
                m(managers[0])
            } else {
                m(nil)
            }
        }
    }
    
    static func connStatus(_ s : NEVPNStatus) -> Bool {
        return s == NEVPNStatus.connected
    }
    

    static func enableVPN() {
        status = true
        getManager() { m in
            guard let manager = m else {
                let manager = NETunnelProviderManager()
                let protoConfig = NETunnelProviderProtocol()
                protoConfig.providerBundleIdentifier = (Bundle.main.bundleIdentifier ?? "com.impervious.ios.browser") + ".DNSAppExt"
                protoConfig.serverAddress = "Beacon DNS"
                protoConfig.providerConfiguration = ["l": 1]
                let connectRule = NEOnDemandRuleConnect()
                manager.onDemandRules = [connectRule]
                manager.localizedDescription = "Beacon DNS"
                manager.protocolConfiguration = protoConfig
                manager.isEnabled = true
                manager.isOnDemandEnabled = true
                manager.saveToPreferences() { (error) -> Void in
                
                    self.startVPN()
                    
                }
                return
            }
            
            if !manager.isEnabled || !manager.isOnDemandEnabled {
                manager.isEnabled = true
                manager.isOnDemandEnabled = true
                manager.saveToPreferences() { (error) -> Void in
                    self.startVPN()
                }
                return
            }
            
            self.startVPN()
        }
    }
}

class DNSAccessors {
    static func getSecureDNSOption(_ prefs: Prefs) -> String {
        return prefs.stringForKey(BeaconConstants.SecureDNSPrefKey) ?? BeaconConstants.SecureDNSDefaultOption
    }
    
    static func getDoHServer(_ prefs: Prefs) -> String {
        let opt = prefs.stringForKey(BeaconConstants.SecureDNSPrefKey) ?? BeaconConstants.SecureDNSDefaultOption
        if opt == BeaconConstants.SecureDNSDefaultOption {
            return BeaconConstants.SecureDNSDefaultURL
        }
        
        return prefs.stringForKey(BeaconConstants.SecureDNSURLPrefKey) ?? BeaconConstants.SecureDNSDefaultURL

    }
}
