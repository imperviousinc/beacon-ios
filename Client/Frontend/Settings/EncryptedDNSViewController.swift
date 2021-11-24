/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import NetworkExtension

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
            self.prefs.setString(self.currentChoice, forKey: ImperviousConstants.SecureDNSPrefKey)
            self.tableView.reloadData()
            DNSVPNConfiguration.getManager() {m in
                guard let manager = m else {
                    return
                }
                
                if manager.connection.status == NEVPNStatus.connected {
                    DNSVPNConfiguration.restartVPN()
                }
            }
        }

        let defaultDoHServer = CheckmarkSetting(title: NSAttributedString(string: "Impervious"), subtitle: nil, accessibilityIdentifier: "ImperviousDNSServer", isChecked: {return self.currentChoice == "Impervious"}, onChecked: {
            self.currentChoice = ImperviousConstants.SecureDNSDefaultOption
            onFinished()
        })
        
       
        let customDoHServer = WebPageSetting(prefs: prefs, prefKey: ImperviousConstants.SecureDNSURLPrefKey, defaultValue: nil, placeholder: "https://server.example/dns-query", accessibilityIdentifier: "CustomDNSServer", isChecked: {return !defaultDoHServer.isChecked()}, settingDidChange: { (string) in
            self.currentChoice = ImperviousConstants.SecureDNSCustomOption
            onFinished()
        })
        
        customDoHServer.textField.textAlignment = .natural

        let section = SettingSection(title: NSAttributedString(string: "DoH Server"), footerTitle: NSAttributedString(string: "Used for system DNS (if enabled) and for requesting DNSSEC chain"), children: [defaultDoHServer, customDoHServer])

        return [section]
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        NotificationCenter.default.post(name: .HomePanelPrefsChanged, object: nil)
        _ = DNSVPNConfiguration.updateConnected()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.tableView.keyboardDismissMode = .onDrag
    }
}
