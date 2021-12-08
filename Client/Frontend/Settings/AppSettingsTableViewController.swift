/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import Shared
import NetworkExtension

enum AppSettingsDeeplinkOption {
    case contentBlocker
    case customizeHomepage
}

/// App Settings Screen (triggered by tapping the 'Gear' in the Tab Tray Controller)
class AppSettingsTableViewController: SettingsTableViewController, FeatureFlagsProtocol {
    var deeplinkTo: AppSettingsDeeplinkOption?

    func enableDNSProgressDialog() -> UIAlertController {
            //create an alert controller
        let pending = UIAlertController(title: "Enabling DNS", message: "\n\n", preferredStyle: .alert)

            //create an activity indicator
            let indicator = UIActivityIndicatorView(frame: pending.view.bounds)
            indicator.autoresizingMask = [.flexibleWidth, .flexibleHeight]

            //add the activity indicator as a subview of the alert controller's view
            pending.view.addSubview(indicator)
            indicator.isUserInteractionEnabled = false
            indicator.startAnimating()

        self.present(pending, animated: true, completion: nil)

            return pending
    }
    
    var vpnManager : NEVPNManager?
    
    override func viewWillAppear(_ animated: Bool) {
        NotificationCenter.default.removeObserver(self,
                                                  name: .NEVPNStatusDidChange, object: vpnManager?.connection)
        
        DNSVPNConfiguration.getManager() { m in
            guard let manager = m else {
                return
            }
            
            self.vpnManager = manager
            NotificationCenter.default.addObserver(self, selector: #selector(self.vpnStatusChanged),
                                                   name: .NEVPNStatusDidChange, object: self.vpnManager?.connection)
        }
       
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        NotificationCenter.default.removeObserver(self,
                                                  name: .NEVPNStatusDidChange, object: self.vpnManager?.connection)
        self.vpnManager = nil
    }
    
    @objc func vpnStatusChanged() {
        guard let manager = self.vpnManager else {
                
                    DispatchQueue.main.async {
                        if DNSVPNConfiguration.status {
                            DNSVPNConfiguration.status = false
                        self.tableView.reloadData()
                        }
                    }
                
                return
            }
        DispatchQueue.main.async {
            let oldStatus = DNSVPNConfiguration.status
            DNSVPNConfiguration.status = DNSVPNConfiguration.connStatus(manager.connection.status)
            if oldStatus != DNSVPNConfiguration.status {
               
                    self.tableView.reloadData()
                }
            }
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        let variables = Experiments.shared.getVariables(featureId: .nimbusValidation)
        let title = variables.getText("settings-title") ?? .AppSettingsTitle
        let suffix = variables.getString("settings-title-punctuation") ?? ""

        navigationItem.title = "\(title)\(suffix)"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: .AppSettingsDone,
            style: .done,
            target: navigationController, action: #selector((navigationController as! ThemedNavigationController).done))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "AppSettingsTableViewController.navigationItem.leftBarButtonItem"

        tableView.accessibilityIdentifier = "AppSettingsTableViewController.tableView"

        // Refresh the user's FxA profile upon viewing settings. This will update their avatar,
        // display name, etc.
        ////profile.rustAccount.refreshProfile()

        checkForDeeplinkSetting()
    }

    private func checkForDeeplinkSetting() {
        guard let deeplink = deeplinkTo else { return }
        var viewController: SettingsTableViewController

        switch deeplink {
        case .contentBlocker:
            viewController = ContentBlockerSettingViewController(prefs: profile.prefs)
            viewController.tabManager = tabManager

        case .customizeHomepage:
            viewController = HomePageSettingViewController(prefs: profile.prefs)
        }

        viewController.profile = profile
        navigationController?.pushViewController(viewController, animated: false)
        // Add a done button from this view
        viewController.navigationItem.rightBarButtonItem = navigationItem.rightBarButtonItem
    }

    weak var dnsSetting : DNSVPNSetting?
    
    override func generateSettings() -> [SettingSection] {
        var settings = [SettingSection]()

        let prefs = profile.prefs
        
        let dnsSettingObj =  DNSVPNSetting(prefs:prefs, delegate: settingsDelegate, callback: {d in
           
        })
        dnsSetting = dnsSettingObj
        
        let encryptedDNSSettings: [Setting] = [
            DNSSetting(settings: self),
            dnsSettingObj,
       ]
       
        
        var generalSettings: [Setting] = [
            SearchSetting(settings: self),
           
            NewTabPageSetting(settings: self),
            HomeSetting(settings: self),
            OpenWithSetting(settings: self),
            ThemeSetting(settings: self),
            BoolSetting(prefs: prefs, prefKey: PrefsKeys.KeyBlockPopups, defaultValue: true,
                        titleText: .AppSettingsBlockPopups),
           ]

        generalSettings.insert(SiriPageSetting(settings: self), at: 5)

        if featureFlags.isFeatureActiveForBuild(.groupedTabs) || featureFlags.isFeatureActiveForBuild(.inactiveTabs) {
            generalSettings.insert(TabsSetting(), at: 3)
        }

    
        // There is nothing to show in the Customize section if we don't include the compact tab layout
        // setting on iPad. When more options are added that work on both device types, this logic can
        // be changed.

        generalSettings += [
            BoolSetting(prefs: prefs, prefKey: "showClipboardBar", defaultValue: false,
                        titleText: Strings.SettingsOfferClipboardBarTitle,
                        statusText: Strings.SettingsOfferClipboardBarStatus),
            BoolSetting(prefs: prefs, prefKey: PrefsKeys.ContextMenuShowLinkPreviews, defaultValue: true,
                        titleText: Strings.SettingsShowLinkPreviewsTitle,
                        statusText: Strings.SettingsShowLinkPreviewsStatus)
        ]

        // disable set as default Beacon doesn't have entitlement yet
        if #available(iOS 14.0, *), false {
            settings += [
                SettingSection(footerTitle: NSAttributedString(string: String.DefaultBrowserCardDescription), children: [DefaultBrowserSetting()])
            ]
        }
        settings += [ SettingSection(title: NSAttributedString(string: "Encrypted DNS"), children: encryptedDNSSettings)]
      
        settings += [ SettingSection(title: NSAttributedString(string: Strings.SettingsGeneralSectionTitle), children: generalSettings)]

        var privacySettings = [Setting]()
        privacySettings.append(LoginsSetting(settings: self, delegate: settingsDelegate))
        privacySettings.append(TouchIDPasscodeSetting(settings: self))

        privacySettings.append(ClearPrivateDataSetting(settings: self))

        privacySettings += [
            BoolSetting(prefs: prefs,
                prefKey: "settings.closePrivateTabs",
                defaultValue: false,
                titleText: .AppSettingsClosePrivateTabsTitle,
                statusText: .AppSettingsClosePrivateTabsDescription)
        ]

        privacySettings.append(ContentBlockerSetting(settings: self))

        privacySettings += [
            PrivacyPolicySetting()
        ]

        settings += [
            SettingSection(title: NSAttributedString(string: .AppSettingsPrivacyTitle), children: privacySettings),
            SettingSection(title: NSAttributedString(string: .AppSettingsSupport), children: [
                ShowIntroductionSetting(settings: self),
                SendFeedbackSetting(),
//                SendAnonymousUsageDataSetting(prefs: prefs, delegate: settingsDelegate),
//                OpenSupportPageSetting(delegate: settingsDelegate),
            ]),
            SettingSection(title: NSAttributedString(string: .AppSettingsAbout), children: [
                VersionSetting(settings: self),
                LicenseAndAcknowledgementsSetting(),
                YourRightsSetting(),
                ExportBrowserDataSetting(settings: self),
                ExportLogDataSetting(settings: self),
                DeleteExportedDataSetting(settings: self),
                ForceCrashSetting(settings: self),
                SlowTheDatabase(settings: self),
                ForgetSyncAuthStateDebugSetting(settings: self),
                SentryIDSetting(settings: self),
                ChangeToChinaSetting(settings: self),
                ShowEtpCoverSheet(settings: self),
                ToggleChronTabs(settings: self),
                TogglePullToRefresh(settings: self),
                ToggleInactiveTabs(settings: self),
                ExperimentsSettings(settings: self)
            ])]

        return settings
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let headerView = super.tableView(tableView, viewForHeaderInSection: section) as! ThemedTableSectionHeaderFooterView
        return headerView
    }
}
