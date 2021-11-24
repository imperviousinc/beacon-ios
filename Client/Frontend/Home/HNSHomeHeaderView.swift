/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

fileprivate struct HomeViewUX {
    static let settingsButtonHeight: CGFloat = 36
    static let settingsButtonWidth: CGFloat = 328
    static let settingsButtonTopAnchorSpace: CGFloat = 5
}

class HNSHomeHeaderView: UICollectionViewCell, CardTheme {

    var mainView = UIStackView()

    private var fxTextThemeColour: UIColor {
        // For dark theme we want to show light colours and for light we want to show dark colours
        return theme == .dark ? .white : .black
    }
    
    // MARK: - UI Elements
    let blockHeightLabel: UILabel = .build { button in
        button.text = "Block Height #500"
        button.font = .systemFont(ofSize: 15, weight: .regular)
        button.accessibilityIdentifier = "HNSHomeHeaderBlockHeight"
    }
    let poolSizeLabel: UILabel = .build { button in
        button.text = "Pool (size: 20, active: 5)"
        button.font = .systemFont(ofSize: 15, weight: .regular)
        button.accessibilityIdentifier = "HNSHomeHeaderPoolSize"
    }

    // MARK: - Initializers
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Setup
    func setupView() {
        addSubview(mainView)
        mainView.distribution = .equalSpacing
        mainView.axis = .vertical
        mainView.snp.makeConstraints { make in
            make.edges.equalTo(self)
        }
        blockHeightLabel.textColor = fxTextThemeColour
        poolSizeLabel.textColor = fxTextThemeColour
        
        mainView.addArrangedSubview(blockHeightLabel)
        mainView.addArrangedSubview(poolSizeLabel)
    }
}

