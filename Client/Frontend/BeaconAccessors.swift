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
    public static let PrivacyPolicy = "https://impervious.com/browser/privacy"
    public static let TermsOfUse = "https://impervious.com/browser/terms-of-use"
}

class EncryptedDNSTunnel {
    static var connected = false
    
    static func updateConnected() -> Bool {
        getManager() { m in
            guard let manager = m else {
                connected = false
                return
            }
  
            connected = manager.connection.status == .connected
        }
        
        return connected
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
        getManager() { m in
            do {
                try m?.connection.startVPNTunnel()
            } catch   {
                print("failed starting VPN")
            }
        }
    }
   
    static func reloadSettings() {
        getManager() { m in
            guard let manager = m else {
                enableVPN()
                return
            }
            
            if manager.connection.status != .connected {
                return
            }
            
            manager.protocolConfiguration = createProtoConfig()
            manager.saveToPreferences { err in
                let session = manager.connection as? NETunnelProviderSession
                try? session?.sendProviderMessage("reloadSettings".data(using: String.Encoding.utf8)!)
            }
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
  
    private static func createProtoConfig() -> NETunnelProviderProtocol {
        let protoConfig = NETunnelProviderProtocol()
        protoConfig.providerBundleIdentifier = (Bundle.main.bundleIdentifier ?? "com.impervious.ios.browser") + ".DNSAppExt"
        protoConfig.serverAddress = "Beacon DNS"
        protoConfig.providerConfiguration = ["dohURL": getDoHURL()]
        return protoConfig
    }
    
    static func enableVPNWithUserConfirmation(_ handler : ((Bool) -> Void)?) -> UIAlertController {
        var vpnAlert = UIAlertController(title: "Beacon will add a VPN", message: "VPN is needed to set up custom DNS settings for your device. The VPN is local and no traffic will be routed through any servers. We do not collect any data when you use this profile.", preferredStyle: UIAlertController.Style.alert)
        
        vpnAlert.addAction(UIAlertAction(title: "Ok", style: .default, handler: { _ in
            if let handler = handler {
                handler(true)
            }
            enableVPN()
        }))
        
        vpnAlert.addAction(UIAlertAction(title: "Privacy policy", style: .default, handler: { _ in
            if let handler = handler {
                handler(false)
            }
            if let url = URL(string: BeaconConstants.PrivacyPolicy) {
                UIApplication.shared.open(url)
            }
        }))
        
        vpnAlert.addAction(UIAlertAction(title: "Cancel", style: .default, handler: { _ in
            if let handler = handler {
                handler(false)
            }
        }))
        
        return vpnAlert
    }
    
    static func enableVPN() {
        connected = true
        getManager() { m in
            guard let manager = m else {
                let manager = NETunnelProviderManager()
                let protoConfig = createProtoConfig()
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
