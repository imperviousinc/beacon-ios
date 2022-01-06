/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import NetworkExtension

class DoHURLSetting: StringPrefSetting {
    let isChecked: () -> Bool

    init(prefs: Prefs, prefKey: String, defaultValue: String? = nil, placeholder: String, accessibilityIdentifier: String, isChecked: @escaping () -> Bool = { return false }, settingDidChange: ((String?) -> Void)? = nil) {
        self.isChecked = isChecked
        super.init(prefs: prefs,
                   prefKey: prefKey,
                   defaultValue: defaultValue,
                   placeholder: placeholder,
                   accessibilityIdentifier: accessibilityIdentifier,
                   settingIsValid: DoHURLSetting.isURLOrEmpty,
                   settingDidChange: settingDidChange)
        textField.keyboardType = .URL
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
    }

    override func prepareValidValue(userInput value: String?) -> String? {
        guard let value = value else {
            return nil
        }
        
        guard let url =  URIFixup.getURL(value) else {
            return nil
        }
        
        var comp = URLComponents(url: url, resolvingAgainstBaseURL: true)
        comp?.scheme = "https"
        if comp?.path ?? "" == "" {
            comp?.path = "/dns-query"
        }
      
        return comp?.string
    }

    override func onConfigureCell(_ cell: UITableViewCell) {
        super.onConfigureCell(cell)
        cell.accessoryType = isChecked() ? .checkmark : .none
        textField.textAlignment = .left
    }

    static func isURLOrEmpty(_ string: String?) -> Bool {
        guard let string = string, !string.isEmpty else {
            return true
        }
        guard let url = URL(string: string) else {
            return false
        }
        
        return url.scheme == "https"
    }
}

class EncryptedDNSViewController: SettingsTableViewController {
    /* variables for checkmark settings */
    let prefs: Prefs
    var currentChoice: String = ""
    var hasHomePage = false
    init(prefs: Prefs) {
        self.prefs = prefs
        super.init(style: .grouped)

        self.title = "Choose DNS Server"
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func generateSettings() -> [SettingSection] {
        self.currentChoice  = DNSAccessors.getSecureDNSOption(self.prefs)

        let onFinished = {
            self.prefs.setString(self.currentChoice, forKey: BeaconConstants.SecureDNSPrefKey)
            self.tableView.reloadData()
            EncryptedDNSTunnel.getManager() {m in
                guard let manager = m else {
                    return
                }
                
                if manager.connection.status == NEVPNStatus.connected {
                    EncryptedDNSTunnel.reloadSettings()
                }
            }
        }

        let defaultDoHServer = CheckmarkSetting(title: NSAttributedString(string: "Beacon"), subtitle: nil, accessibilityIdentifier: "BeaconDNSServer", isChecked: {return self.currentChoice == "Beacon"}, onChecked: {
            self.currentChoice = BeaconConstants.SecureDNSDefaultOption
            onFinished()
        })
        
       
        let customDoHServer = DoHURLSetting(prefs: prefs, prefKey: BeaconConstants.SecureDNSURLPrefKey, defaultValue: nil, placeholder: "https://server.example/dns-query", accessibilityIdentifier: "CustomDNSServer", isChecked: {return !defaultDoHServer.isChecked()}, settingDidChange: { (string) in
            self.currentChoice = BeaconConstants.SecureDNSCustomOption
            onFinished()
        })
        
        customDoHServer.textField.textAlignment = .natural

        let section = SettingSection(title: NSAttributedString(string: "DoH Server"), footerTitle: NSAttributedString(string: "Used for system DNS (if enabled) and for requesting DNSSEC chain. Restart the app for the setting to take effect."), children: [defaultDoHServer, customDoHServer])

        return [section]
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        NotificationCenter.default.post(name: .HomePanelPrefsChanged, object: nil)
        _ = EncryptedDNSTunnel.updateConnected()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.tableView.keyboardDismissMode = .onDrag
    }
}
