/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit
import Shared
import SnapKit

/* The layout for update view controller.

The whole is divided into two parts. Top container view and Bottom view.
Top container view sits above Sign Up button and its height spans all
the way from sign up button to top safe area. We then add [combined view]
that contains Image, Title and Description inside [Top container view]
to make it center in the top container view.
 
|----------------|----------[Top Container View]---------
|                |
|                |---------[Combined View]
|                |
|     Image      | [Top View]
|                |      -- Has title image view
|                |
|                | [Mid View]
|     Title      |      -- Has title
|                |      -- Description
|   Description  |
|                |---------[Combined View]
|                |
|----------------|----------[Top Container View]---------
|                |  Bottom View
|   [Next]       |      -- Bottom View
|                |
|                |
|                |
|----------------|

*/

class IntroScreenEthereumOnboardView: UIView, CardTheme {
    // Private vars
    private var fxTextThemeColour: UIColor {
        // For dark theme we want to show light colours and for light we want to show dark colours
        return theme == .dark ? .white : .black
    }
    private var fxBackgroundThemeColour: UIColor {
        return theme == .dark ? UIColor.Firefox.DarkGrey10 : .white
    }
    private lazy var titleImageView: UIImageView = {
        let imgView = UIImageView(image: #imageLiteral(resourceName: "tour-Sync"))
        imgView.contentMode = .scaleAspectFit
        return imgView
    }()
    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.text = "Access domains on Ethereum!"
        label.textColor = fxTextThemeColour
        label.font = UIFont.systemFont(ofSize: screenSize.height > 700 ? 24 : 18, weight: .semibold)
        label.textAlignment = .left
        label.numberOfLines = 0
        return label
    }()
    private lazy var descriptionLabel: UILabel = {
        let label = UILabel()
        label.text = "Forever domains are domains with no renewal fees, ever. They are deployed on Ethereum and unowned by anyone. Try opening impervious.forever"
        label.textColor = fxTextThemeColour
        label.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        label.textAlignment = .left
        label.numberOfLines = 0
        return label
    }()
    private lazy var descriptionLabel2: UILabel = {
        let label = UILabel()
        label.text = "Impervious allows you to access names on Etherem Name System too, try humbly.eth!"
        label.textColor = fxTextThemeColour
        label.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        label.textAlignment = .left
        label.numberOfLines = 0
        return label
    }()
    private var nextButton: UIButton = {
        let button = UIButton()
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        button.layer.cornerRadius = 10
        button.backgroundColor = UIColor.Photon.Blue50
        button.setTitle(Strings.IntroNextButtonTitle, for: .normal)
        button.accessibilityIdentifier = "signUpButtonSyncView"
        return button
    }()
    private lazy var startBrowsingButton: UIButton = {
        let button = UIButton()
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        button.backgroundColor = .clear
        button.setTitleColor(UIColor.Photon.Blue50, for: .normal)
        button.setTitle(Strings.StartBrowsingButtonTitle, for: .normal)
        button.titleLabel?.textAlignment = .center
        button.accessibilityIdentifier = "startBrowsingButtonSyncView"
        return button
    }()
    // Container and combined views
    private let topContainerView = UIView()
    private let combinedView = UIView()
    // Orientation independent screen size
    private let screenSize = DeviceInfo.screenSizeOrientationIndependent()
    // Closure delegates
    var onNext: (() -> Void)?
    var startBrowsing: (() -> Void)?
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        initialViewSetup()
        topContainerViewSetup()
        bottomViewSetup()
    }
    
    // MARK: Initializer
    private func initialViewSetup() {
        combinedView.addSubview(titleLabel)
        combinedView.addSubview(descriptionLabel)
        combinedView.addSubview(descriptionLabel2)
        combinedView.addSubview(titleImageView)
        topContainerView.addSubview(combinedView)
        addSubview(topContainerView)
        addSubview(nextButton)
    }
    
    // MARK: View setup
    private func topContainerViewSetup() {
        // Background colour setup
        backgroundColor = fxBackgroundThemeColour
        // Height constants
        let titleLabelHeight = screenSize.height > 700 ? 100 : 80
        let additionalSpaceHeight = screenSize.height > 700 ? 180 : 120
        let titleImageHeight = screenSize.height > 700 ? 200 : 150
        // Title label constraints
        titleLabel.snp.makeConstraints { make in
            make.left.right.equalToSuperview().inset(24)
            make.top.equalTo(titleImageView.snp.bottom)
            make.height.equalTo(titleLabelHeight)
        }

        // Description label constraints
        descriptionLabel.snp.makeConstraints { make in
            make.left.right.equalToSuperview().inset(24)
            make.top.equalTo(titleLabel.snp.bottom)
        }
        descriptionLabel2.snp.makeConstraints { make in
            make.left.right.equalToSuperview().inset(24)
            make.top.equalTo(descriptionLabel.snp.bottom).offset(20)
        }
        // Title image view constraints
        titleImageView.snp.makeConstraints { make in
            make.left.right.equalToSuperview()
            make.top.equalToSuperview()
            make.height.equalTo(titleImageHeight)
        }
        // Top container view constraints
        topContainerView.snp.makeConstraints { make in
            make.top.equalTo(safeArea.top)
            make.bottom.equalTo(nextButton.snp.top)
            make.left.right.equalToSuperview()
        }
        
        // Combined view constraints
        combinedView.snp.makeConstraints { make in
            make.height.equalTo(additionalSpaceHeight + titleLabelHeight + titleImageHeight)
            make.centerY.equalToSuperview()
            make.left.right.equalToSuperview()
        }
    }
    
    private func bottomViewSetup() {
        let buttonEdgeInset = 15
        let buttonHeight = 46
        
        nextButton.snp.makeConstraints { make in
            make.left.right.equalToSuperview().inset(buttonEdgeInset)
            // On large iPhone screens, bump this up from the bottom
            make.bottom.equalToSuperview().inset(screenSize.height > 700 ? 95 : 60)
            make.height.equalTo(buttonHeight)
        }
        
        nextButton.addTarget(self, action: #selector(nextAction), for: .touchUpInside)
    }
    
    // MARK: Button Actions
    @objc private func nextAction() {
        onNext?()
    }
    
    @objc private func startBrowsingAction() {
        startBrowsing?()
    }
}

