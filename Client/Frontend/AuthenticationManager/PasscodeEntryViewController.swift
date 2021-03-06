/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import SwiftKeychainWrapper

/// Presented to the to user when asking for their passcode to validate entry into a part of the app.
class PasscodeEntryViewController: BasePasscodeViewController {
    fileprivate let passcodeCompletion: ((Bool) -> Void)
    fileprivate var passcodePane: PasscodePane

    init(passcodeCompletion: @escaping ((Bool) -> Void)) {
        self.passcodeCompletion = passcodeCompletion
        let authInfo = KeychainWrapper.sharedAppContainerKeychain.authenticationInfo()
        passcodePane = PasscodePane(title: nil, passcodeSize: authInfo?.passcode?.count ?? 6)

        super.init()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = .AuthenticationEnterPasscodeTitle
        passcodePane.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(passcodePane)

        NSLayoutConstraint.activate([
            passcodePane.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            passcodePane.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            passcodePane.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            passcodePane.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        passcodePane.codeInputView.delegate = self

        // Don't show the keyboard or allow typing if we're locked out. Also display the error.
        if authenticationInfo?.isLocked() ?? false {
            displayLockoutError()
            passcodePane.codeInputView.isUserInteractionEnabled = false
        } else {
            passcodePane.codeInputView.becomeFirstResponder()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        if authenticationInfo?.isLocked() ?? false {
            passcodePane.codeInputView.isUserInteractionEnabled = false
            passcodePane.codeInputView.resignFirstResponder()
        } else {
             passcodePane.codeInputView.becomeFirstResponder()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.view.endEditing(true)
    }

    override func dismissAnimated() {
        super.dismissAnimated()
        passcodeCompletion(false)
    }
}

extension PasscodeEntryViewController: PasscodeInputViewDelegate {
    func passcodeInputView(_ inputView: PasscodeInputView, didFinishEnteringCode code: String) {
        if let passcode = authenticationInfo?.passcode, passcode == code {
            authenticationInfo?.recordValidation()
            KeychainWrapper.sharedAppContainerKeychain.setAuthenticationInfo(authenticationInfo)
            passcodeCompletion(true)
        } else {
            passcodePane.shakePasscode()
            failIncorrectPasscode(inputView)
            passcodePane.codeInputView.resetCode()

            // Store mutations on authentication info object
            KeychainWrapper.sharedAppContainerKeychain.setAuthenticationInfo(authenticationInfo)
        }
    }
}
