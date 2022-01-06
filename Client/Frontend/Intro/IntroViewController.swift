/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit
import Shared

class IntroViewController: UIViewController, OnViewDismissable {
    var onViewDismissed: (() -> Void)? = nil
    var timer:Timer?

    // private var
    // Private views
    private lazy var welcomeCard: IntroScreenWelcomeView = {
        let welcomeCardView = IntroScreenWelcomeView()
        welcomeCardView.translatesAutoresizingMaskIntoConstraints = false
        welcomeCardView.clipsToBounds = true
        return welcomeCardView
    }()
    private lazy var handshakeCard: IntroScreenHandshakeOnboardView = {
        let handshakeCardView = IntroScreenHandshakeOnboardView()
        handshakeCardView.translatesAutoresizingMaskIntoConstraints = false
        handshakeCardView.clipsToBounds = true
        return handshakeCardView
    }()
    private lazy var ethereumCard: IntroScreenEthereumOnboardView = {
        let ethereumCardView = IntroScreenEthereumOnboardView()
        ethereumCardView.translatesAutoresizingMaskIntoConstraints = false
        ethereumCardView.clipsToBounds = true
        return ethereumCardView
    }()
    private lazy var syncCard: IntroScreenSyncView = {
        let syncCardView = IntroScreenSyncView()
        syncCardView.translatesAutoresizingMaskIntoConstraints = false
        syncCardView.clipsToBounds = true
        
        return syncCardView
    }()
    private lazy var enableDNSCard: IntroScreenEnableDNSView = {
        let enableDNSCardView = IntroScreenEnableDNSView()
        enableDNSCardView.translatesAutoresizingMaskIntoConstraints = false
        enableDNSCardView.clipsToBounds = true
        return enableDNSCardView
    }()
    // Closure delegate
    var didFinishClosure: ((IntroViewController, FxAPageType?) -> Void)?
    
    // MARK: Initializer
    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        initialViewSetup()
       
    }
    
    @objc func updateProgressView() {
        let p = HandshakeCtx?.progress() ?? 0
        let height = HandshakeCtx?.height() ?? 0
        syncCard.updateProgress(progress: p, height: Int64(height))
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.timer = Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: #selector(updateProgressView), userInfo: nil, repeats: true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onViewDismissed?()
        onViewDismissed = nil
        self.timer?.invalidate()
    }
    
    // MARK: View setup
    private func initialViewSetup() {
        setupIntroView()
    }
    
    //onboarding intro view
    private func setupIntroView() {
        // Initialize
        view.addSubview(enableDNSCard)
        view.addSubview(syncCard)
        view.addSubview(ethereumCard)
        view.addSubview(handshakeCard)
        view.addSubview(welcomeCard)
        
        // Constraints
        setupWelcomeCard()
        setupHandshakeCard()
        setupEthereumCard()
        setupSyncCard()
        setupEnableDNSCard()
    }
    
    private func hideSyncCard() {
        UIView.animate(withDuration: 0.3, animations: {
            self.syncCard.alpha = 0
        }) { _ in
            self.syncCard.isHidden = true
        }
    }
    
    private func setupSyncCard() {
        NSLayoutConstraint.activate([
            syncCard.topAnchor.constraint(equalTo: view.topAnchor),
            syncCard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            syncCard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            syncCard.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        // Buton action closures
        // Next button action
        syncCard.onNext = {
            self.hideSyncCard()
        }
        // Close button action
//        syncCard.closeClosure = {
//            self.didFinishClosure?(self, nil)
//        }
//        // Sign in button closure
//        syncCard.signInClosure = {
//            self.didFinishClosure?(self, .emailLoginFlow)
//        }
//        // Sign up button closure
//        syncCard.signUpClosure = {
//            self.didFinishClosure?(self, .emailLoginFlow)
//        }
    }
    
    private func setupWelcomeCard() {
        NSLayoutConstraint.activate([
            welcomeCard.topAnchor.constraint(equalTo: view.topAnchor),
            welcomeCard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            welcomeCard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            welcomeCard.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        // Buton action closures
        // Next button action
        welcomeCard.nextClosure = {
            UIView.animate(withDuration: 0.3, animations: {
                self.welcomeCard.alpha = 0
            }) { _ in
                self.welcomeCard.isHidden = true
                TelemetryWrapper.recordEvent(category: .action, method: .view, object: .syncScreenView)
            }
        }
        // Close button action
        welcomeCard.closeClosure = {
            self.didFinishClosure?(self, nil)
        }
        // Sign in button closure
        welcomeCard.signInClosure = {
            self.didFinishClosure?(self, .emailLoginFlow)
        }
        // Sign up button closure
        welcomeCard.signUpClosure = {
            self.didFinishClosure?(self, .emailLoginFlow)
        }
    }
    
    private func setupHandshakeCard() {
        NSLayoutConstraint.activate([
            handshakeCard.topAnchor.constraint(equalTo: view.topAnchor),
            handshakeCard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            handshakeCard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            handshakeCard.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        // Start browsing button action
        handshakeCard.startBrowsing = {
            self.didFinishClosure?(self, nil)
        }
        // Sign-up browsing button action
        handshakeCard.onNext = {
            UIView.animate(withDuration: 0.3, animations: {
                self.handshakeCard.alpha = 0
            }) { _ in
                self.handshakeCard.isHidden = true
            }
        }
    }
    
    private func setupEnableDNSCard() {
        NSLayoutConstraint.activate([
            enableDNSCard.topAnchor.constraint(equalTo: view.topAnchor),
            enableDNSCard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            enableDNSCard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            enableDNSCard.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        // Start browsing button action
        enableDNSCard.startBrowsing = {
            self.didFinishClosure?(self, nil)
        }
        // enable HNS resolver
        enableDNSCard.onEnableHNSResolver = {
            let confirm = EncryptedDNSTunnel.enableVPNWithUserConfirmation({ confirmed in
                if confirmed {
                    self.didFinishClosure?(self, nil)
                }
            })
            self.present(confirm, animated: true, completion: nil)
        }
    }
    
    private func setupEthereumCard() {
        NSLayoutConstraint.activate([
            ethereumCard.topAnchor.constraint(equalTo: view.topAnchor),
            ethereumCard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ethereumCard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ethereumCard.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        // Start browsing button action
        ethereumCard.startBrowsing = {
            self.didFinishClosure?(self, nil)
        }
        // Next -> sync view
        ethereumCard.onNext = {
            UIView.animate(withDuration: 0.3, animations: {
                self.ethereumCard.alpha = 0
            }) { _ in
                self.ethereumCard.isHidden = true
            }
            
            // Skip sync card if already synced
            guard let ctx = HandshakeCtx else {
                return
            }
            if ctx.progress() > 0.98 {
                self.hideSyncCard()
            }
        }
    }
}

// MARK: UIViewController setup
extension IntroViewController {
    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var shouldAutorotate: Bool {
        return false
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        // This actually does the right thing on iPad where the modally
        // presented version happily rotates with the iPad orientation.
        return .portrait
    }
}
