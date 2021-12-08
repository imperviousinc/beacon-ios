/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared
import UIKit
import Storage
import SDWebImage
import XCGLogger
import SyncTelemetry

private let log = Logger.browserLogger

// MARK: -  UX

struct FirefoxHomeUX {
    static let highlightCellHeight: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 250 : 200
    static let jumpBackInCellHeight: CGFloat = 112
    static let recentlySavedCellHeight: CGFloat = 136
    static let sectionInsetsForSizeClass = UXSizeClasses(compact: 0, regular: 101, other: 15)
    static let numberOfItemsPerRowForSizeClassIpad = UXSizeClasses(compact: 3, regular: 4, other: 2)
    static let spacingBetweenSections: CGFloat = 24
    static let SectionInsetsForIpad: CGFloat = 101
    static let MinimumInsets: CGFloat = 15
    static let LibraryShortcutsHeight: CGFloat = 90
    static let LibraryShortcutsMaxWidth: CGFloat = 375
    static let customizeHomeHeight: CGFloat = 144
    static let hnsHeaderHeight: CGFloat = 45
}

struct FxHomeAccessibilityIdentifiers {
    struct MoreButtons {
        static let recentlySaved = "recentlySavedSectionMoreButton"
        static let jumpBackIn = "jumpBackInSectionMoreButton"
    }

    struct SectionTitles {
        static let jumpBackIn = "jumpBackInTitle"
        static let recentlySaved = "jumpBackInTitle"
        static let pocket = "pocketTitle"
        static let library = "libraryTitle"
        static let topSites = "topSitesTitle"
    }
}

struct FxHomeDevStrings {
    struct GestureRecognizers {
        static let dismissOverlay = "dismissOverlay"
    }
}


/*
 Size classes are the way Apple requires us to specify our UI.
 Split view on iPad can make a landscape app appear with the demensions of an iPhone app
 Use UXSizeClasses to specify things like offsets/itemsizes with respect to size classes
 For a primer on size classes https://useyourloaf.com/blog/size-classes/
 */
struct UXSizeClasses {
    var compact: CGFloat
    var regular: CGFloat
    var unspecified: CGFloat

    init(compact: CGFloat, regular: CGFloat, other: CGFloat) {
        self.compact = compact
        self.regular = regular
        self.unspecified = other
    }

    subscript(sizeClass: UIUserInterfaceSizeClass) -> CGFloat {
        switch sizeClass {
            case .compact:
                return self.compact
            case .regular:
                return self.regular
            case .unspecified:
                return self.unspecified
            @unknown default:
                fatalError()
        }

    }
}

// MARK: - Home Panel

protocol HomePanelDelegate: AnyObject {
    func homePanelDidRequestToOpenInNewTab(_ url: URL, isPrivate: Bool)
    func homePanel(didSelectURL url: URL, visitType: VisitType, isGoogleTopSite: Bool)
    func homePanelDidRequestToOpenLibrary(panel: LibraryPanelType)
    func homePanelDidRequestToOpenTabTray(withFocusedTab tabToFocus: Tab?)
    func homePanelDidRequestToCustomizeHomeSettings()
}

protocol HomePanel: Themeable {
    var homePanelDelegate: HomePanelDelegate? { get set }
}

enum HomePanelType: Int {
    case topSites = 0

    var internalUrl: URL {
        let aboutUrl: URL! = URL(string: "\(InternalURL.baseUrl)/\(AboutHomeHandler.path)")
        return URL(string: "#panel=\(self.rawValue)", relativeTo: aboutUrl)!
    }
}

protocol HomePanelContextMenu {
    func getSiteDetails(for indexPath: IndexPath) -> Site?
    func getContextMenuActions(for site: Site, with indexPath: IndexPath) -> [PhotonActionSheetItem]?
    func presentContextMenu(for indexPath: IndexPath)
    func presentContextMenu(for site: Site, with indexPath: IndexPath, completionHandler: @escaping () -> PhotonActionSheet?)
}

extension HomePanelContextMenu {
    func presentContextMenu(for indexPath: IndexPath) {
        guard let site = getSiteDetails(for: indexPath) else { return }

        presentContextMenu(for: site, with: indexPath, completionHandler: {
            return self.contextMenu(for: site, with: indexPath)
        })
    }

    func contextMenu(for site: Site, with indexPath: IndexPath) -> PhotonActionSheet? {
        guard let actions = self.getContextMenuActions(for: site, with: indexPath) else { return nil }

        let contextMenu = PhotonActionSheet(site: site, actions: actions)
        contextMenu.modalPresentationStyle = .overFullScreen
        contextMenu.modalTransitionStyle = .crossDissolve

        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()

        return contextMenu
    }

    func getDefaultContextMenuActions(for site: Site, homePanelDelegate: HomePanelDelegate?) -> [PhotonActionSheetItem]? {
        guard let siteURL = URL(string: site.url) else { return nil }

        let openInNewTabAction = PhotonActionSheetItem(title: Strings.OpenInNewTabContextMenuTitle, iconString: "quick_action_new_tab") { _, _ in
            homePanelDelegate?.homePanelDidRequestToOpenInNewTab(siteURL, isPrivate: false)
        }

        let openInNewPrivateTabAction = PhotonActionSheetItem(title: Strings.OpenInNewPrivateTabContextMenuTitle, iconString: "quick_action_new_private_tab") { _, _ in
            homePanelDelegate?.homePanelDidRequestToOpenInNewTab(siteURL, isPrivate: true)
        }

        return [openInNewTabAction, openInNewPrivateTabAction]
    }
}

// MARK: - HomeVC

class FirefoxHomeViewController: UICollectionViewController, HomePanel, FeatureFlagsProtocol {
    weak var homePanelDelegate: HomePanelDelegate?
    weak var libraryPanelDelegate: LibraryPanelDelegate?
    fileprivate let profile: Profile
    fileprivate let pocketAPI = Pocket()
    fileprivate let flowLayout = UICollectionViewFlowLayout()
    fileprivate let experiments: NimbusApi
    fileprivate var hasSentPocketSectionEvent = false
    fileprivate var hasSentJumpBackInSectionEvent = false
    var recentlySavedViewModel = FirefoxHomeRecentlySavedViewModel()
    var jumpBackInViewModel = FirefoxHomeJumpBackInViewModel()
    
    var hnsStatusTimer : Timer?
    var hnsBlockHeight = 0
    var hnsPoolSize = 0
    var hnsActivePeers = 0
    var lastHnsBlockHeight = 0
    var lastHnsPoolSize = 0
    var lastHnsActivePeers = 0

    fileprivate lazy var topSitesManager: ASHorizontalScrollCellManager = {
        let manager = ASHorizontalScrollCellManager()
        return manager
    }()

    fileprivate lazy var longPressRecognizer: UILongPressGestureRecognizer = {
        return UILongPressGestureRecognizer(target: self, action: #selector(longPress))
    }()

    private var tapGestureRecognizer: UITapGestureRecognizer {
        let dismissOverlay = UITapGestureRecognizer(target: self, action: #selector(dismissOverlayMode))
        dismissOverlay.name = FxHomeDevStrings.GestureRecognizers.dismissOverlay
        dismissOverlay.cancelsTouchesInView = false

        return dismissOverlay
    }

    // Not used for displaying. Only used for calculating layout.
    lazy var topSiteCell: ASHorizontalScrollCell = {
        let customCell = ASHorizontalScrollCell(frame: CGRect(width: self.view.frame.size.width, height: 0))
        customCell.delegate = self.topSitesManager
        return customCell
    }()
    lazy var defaultBrowserCard: DefaultBrowserCard = .build { card in
        card.backgroundColor = UIColor.theme.homePanel.topSitesBackground
    }

    var pocketStories: [PocketStory] = []
    var hasRecentBookmarks = false
    var hasReadingListitems = false
    var currentTab: Tab? {
        let tabManager = BrowserViewController.foregroundBVC().tabManager
        return tabManager.selectedTab
    }

    lazy var homescreen = experiments.withVariables(featureId: .homescreen, sendExposureEvent: false) {
        Homescreen(variables: $0)
    }

    // MARK: - Section availability variables
    var isTopSitesSectionEnabled: Bool {
        homescreen.sectionsEnabled[.topSites] == true
    }

    var isYourLibrarySectionEnabled: Bool {
        UIDevice.current.userInterfaceIdiom != .pad &&
            homescreen.sectionsEnabled[.libraryShortcuts] == true
    }

    var isJumpBackInSectionEnabled: Bool {
        guard featureFlags.isFeatureActiveForBuild(.jumpBackIn),
              homescreen.sectionsEnabled[.topSites] == true,
              featureFlags.userPreferenceFor(.jumpBackIn) == UserFeaturePreference.enabled
        else { return false }

        let tabManager = BrowserViewController.foregroundBVC().tabManager
        return !(tabManager.selectedTab?.isPrivate ?? false)
            && !tabManager.recentlyAccessedNormalTabs.isEmpty
}

    var isRecentlySavedSectionEnabled: Bool {
        guard featureFlags.isFeatureActiveForBuild(.recentlySaved),
              homescreen.sectionsEnabled[.recentlySaved] == true,
              featureFlags.userPreferenceFor(.recentlySaved) == UserFeaturePreference.enabled
        else { return false }

        return hasRecentBookmarks || hasReadingListitems
    }

    var isPocketSectionEnabled: Bool {
        // For Pocket, the user preference check returns a user preference if it exists in
        // UserDefaults, and, if it does not, it will return a default preference based on
        // a (nimbus pocket section enabled && Pocket.isLocaleSupported) check
        guard featureFlags.isFeatureActiveForBuild(.pocket),
              featureFlags.userPreferenceFor(.pocket) == UserFeaturePreference.enabled
        else { return false }

        return true
    }

    // MARK: - Initializers
    init(profile: Profile, experiments: NimbusApi = Experiments.shared) {
        self.profile = profile
        self.experiments = experiments
        super.init(collectionViewLayout: flowLayout)
        collectionView?.delegate = self
        collectionView?.dataSource = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        collectionView?.addGestureRecognizer(longPressRecognizer)
        currentTab?.lastKnownUrl?.absoluteString.hasPrefix("internal://") ?? false ? collectionView?.addGestureRecognizer(tapGestureRecognizer) : nil

        let refreshEvents: [Notification.Name] = [.DynamicFontChanged, .HomePanelPrefsChanged, .DisplayThemeChanged]
        refreshEvents.forEach { NotificationCenter.default.addObserver(self, selector: #selector(reload), name: $0, object: nil) }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()

        Section.allCases.forEach { collectionView.register($0.cellType, forCellWithReuseIdentifier: $0.cellIdentifier) }
        self.collectionView?.register(ASHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "Header")
        collectionView?.keyboardDismissMode = .onDrag
        collectionView?.backgroundColor = .clear
        
        // disable default browser for now Beacon doesn't have the entitlement yet
        if #available(iOS 14.0, *), !UserDefaults.standard.bool(forKey: "DidDismissDefaultBrowserCard"), false {
            self.view.addSubview(defaultBrowserCard)
            NSLayoutConstraint.activate([
                defaultBrowserCard.topAnchor.constraint(equalTo: view.topAnchor),
                defaultBrowserCard.bottomAnchor.constraint(equalTo: collectionView.topAnchor),
                defaultBrowserCard.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                defaultBrowserCard.widthAnchor.constraint(equalToConstant: 380),

                collectionView.topAnchor.constraint(equalTo: defaultBrowserCard.bottomAnchor),
                collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])

            defaultBrowserCard.dismissClosure = {
                self.dismissDefaultBrowserCard()
            }
        }
        self.view.backgroundColor = UIColor.theme.homePanel.topSitesBackground
        self.profile.panelDataObservers.activityStream.delegate = self

        applyTheme()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadAll()
    }

    @objc func updateStatusView() {

        hnsBlockHeight = HandshakeCtx?.height() ?? 0
        hnsPoolSize = HandshakeCtx?.peerCount() ?? -1
        hnsActivePeers = HandshakeCtx?.activePeerCount() ?? -1
        
        if hnsBlockHeight != lastHnsBlockHeight || hnsPoolSize != lastHnsPoolSize || hnsActivePeers != lastHnsActivePeers {
            self.collectionView.reloadItems(at: [IndexPath(row: 0, section: 0)])
        }
        
        lastHnsBlockHeight = hnsBlockHeight
        lastHnsPoolSize = hnsPoolSize
        lastHnsActivePeers = hnsActivePeers
       
    }
    
    override func viewDidAppear(_ animated: Bool) {
        experiments.recordExposureEvent(featureId: .homescreen)
        super.viewDidAppear(animated)
        
        updateStatusView()
        self.hnsStatusTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateStatusView), userInfo: nil, repeats: true)
        
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.hnsStatusTimer?.invalidate()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: {context in
            //The AS context menu does not behave correctly. Dismiss it when rotating.
            if let _ = self.presentedViewController as? PhotonActionSheet {
                self.presentedViewController?.dismiss(animated: true, completion: nil)
            }
            self.collectionViewLayout.invalidateLayout()
            self.collectionView?.reloadData()
        }, completion: { _ in
            // Workaround: label positions are not correct without additional reload
            self.collectionView?.reloadData()
        })
    }

    // MARK: - Helpers
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        self.topSitesManager.currentTraits = self.traitCollection
        applyTheme()
    }

    public func dismissDefaultBrowserCard() {
        self.defaultBrowserCard.removeFromSuperview()
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    @objc func reload(notification: Notification) {
        reloadAll()
    }

    func applyTheme() {
        defaultBrowserCard.applyTheme()
        self.view.backgroundColor = UIColor.theme.homePanel.topSitesBackground
        topSiteCell.collectionView.reloadData()
        if let collectionView = self.collectionView, collectionView.numberOfSections > 0, collectionView.numberOfItems(inSection: 0) > 0 {
            collectionView.reloadData()
        }
    }

    func scrollToTop(animated: Bool = false) {
        collectionView?.setContentOffset(.zero, animated: animated)
    }

    override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        currentTab?.lastKnownUrl?.absoluteString.hasPrefix("internal://") ?? false ? BrowserViewController.foregroundBVC().urlBar.leaveOverlayMode() : nil
    }

    @objc func dismissOverlayMode() {
        BrowserViewController.foregroundBVC().urlBar.leaveOverlayMode()
        if let gestureRecognizers = collectionView.gestureRecognizers {
            for (index, gesture) in gestureRecognizers.enumerated() {
                if gesture.name == FxHomeDevStrings.GestureRecognizers.dismissOverlay {
                    collectionView.gestureRecognizers?.remove(at: index)
                }
            }
        }
    }

    func configureItemsForRecentlySaved() {
        profile.places.getRecentBookmarks(limit: 5).uponQueue(.main) { [weak self] result in
            self?.hasRecentBookmarks = false

            if let bookmarks = result.successValue,
               !bookmarks.isEmpty,
               !RecentItemsHelper.filterStaleItems(recentItems: bookmarks, since: Date()).isEmpty {
                self?.hasRecentBookmarks = true

                TelemetryWrapper.recordEvent(category: .action,
                                             method: .view,
                                             object: .firefoxHomepage,
                                             value: .recentlySavedBookmarkItemView,
                                             extras: [TelemetryWrapper.EventObject.recentlySavedBookmarkImpressions.rawValue: bookmarks.count])
            }

            self?.collectionView.reloadData()
        }

        if let readingList = profile.readingList.getAvailableRecords().value.successValue?.prefix(RecentlySavedCollectionCellUX.readingListItemsLimit) {
            var readingListItems = Array(readingList)
            readingListItems = RecentItemsHelper.filterStaleItems(recentItems: readingListItems,
                                                                       since: Date()) as! [ReadingListItem]
            self.hasReadingListitems = !readingListItems.isEmpty

            TelemetryWrapper.recordEvent(category: .action,
                                         method: .view,
                                         object: .firefoxHomepage,
                                         value: .recentlySavedBookmarkItemView,
                                         extras: [TelemetryWrapper.EventObject.recentlySavedReadingItemImpressions.rawValue: readingListItems.count])

            self.collectionView.reloadData()
        }

    }

}

// MARK: -  Section Management

extension FirefoxHomeViewController {
    
    

    enum Section: Int, CaseIterable {
        case hnsInfo
        case topSites
        case libraryShortcuts
        case jumpBackIn
        case recentlySaved
        case pocket
        case customizeHome
        

        var title: String? {
            switch self {
            case .pocket: return Strings.ASPocketTitle2
            case .jumpBackIn: return String.FirefoxHomeJumpBackInSectionTitle
            case .recentlySaved: return Strings.RecentlySavedSectionTitle
            case .topSites: return Strings.ASShortcutsTitle
            case .libraryShortcuts: return Strings.AppMenuLibraryTitleString
            case .customizeHome: return nil
            case .hnsInfo: return "Status"
            }
        }

        var headerHeight: CGSize {
            return CGSize(width: 50, height: self == .hnsInfo ? 60 : 40)
        }

        var headerImage: UIImage? {
            switch self {
            case .pocket: return UIImage.templateImageNamed("menu-pocket")
            case .topSites: return UIImage.templateImageNamed("menu-panel-TopSites")
            case .libraryShortcuts: return UIImage.templateImageNamed("menu-library")
            case .hnsInfo: return UIImage.templateImageNamed("")
            default : return nil
            }
        }

        var footerHeight: CGSize {
            switch self {
            case .pocket, .jumpBackIn, .recentlySaved, .customizeHome: return .zero
            case .topSites, .libraryShortcuts, .hnsInfo: return CGSize(width: 50, height: 5)
            }
        }

        func cellHeight(_ traits: UITraitCollection, width: CGFloat) -> CGFloat {
            switch self {
            case .pocket: return FirefoxHomeUX.highlightCellHeight
            case .jumpBackIn: return FirefoxHomeUX.jumpBackInCellHeight
            case .recentlySaved: return FirefoxHomeUX.recentlySavedCellHeight
            case .topSites: return 0 //calculated dynamically
            case .libraryShortcuts: return FirefoxHomeUX.LibraryShortcutsHeight
            case .customizeHome: return FirefoxHomeUX.customizeHomeHeight
            case .hnsInfo: return FirefoxHomeUX.hnsHeaderHeight
            }
        }

        /*
         There are edge cases to handle when calculating section insets
        - An iPhone 7+ is considered regular width when in landscape
        - An iPad in 66% split view is still considered regular width
         */
        func sectionInsets(_ traits: UITraitCollection, frameWidth: CGFloat) -> CGFloat {
            var currentTraits = traits
            if (traits.horizontalSizeClass == .regular && UIScreen.main.bounds.size.width != frameWidth) || UIDevice.current.userInterfaceIdiom == .phone {
                currentTraits = UITraitCollection(horizontalSizeClass: .compact)
            }
            var insets = FirefoxHomeUX.sectionInsetsForSizeClass[currentTraits.horizontalSizeClass]
            let window = UIApplication.shared.keyWindow
            let safeAreaInsets = window?.safeAreaInsets.left ?? 0
            insets += FirefoxHomeUX.MinimumInsets + safeAreaInsets
            return insets
        }

        func numberOfItemsForRow(_ traits: UITraitCollection) -> CGFloat {
            switch self {
            case .pocket:
                var numItems: CGFloat = FirefoxHomeUX.numberOfItemsPerRowForSizeClassIpad[traits.horizontalSizeClass]
                if UIApplication.shared.statusBarOrientation.isPortrait {
                    numItems = numItems - 1
                }
                if traits.horizontalSizeClass == .compact && UIApplication.shared.statusBarOrientation.isLandscape {
                    numItems = numItems - 1
                }

                return numItems
            case .topSites, .libraryShortcuts, .jumpBackIn, .recentlySaved, .customizeHome, .hnsInfo:
                return 1
            }
        }

        func cellSize(for traits: UITraitCollection, frameWidth: CGFloat) -> CGSize {
            let height = cellHeight(traits, width: frameWidth)
            let inset = sectionInsets(traits, frameWidth: frameWidth) * 2

            switch self {
            case .pocket:
                let numItems = numberOfItemsForRow(traits)
                return CGSize(width: floor(((frameWidth - inset) - (FirefoxHomeUX.MinimumInsets * (numItems - 1))) / numItems), height: height)
            case .topSites, .libraryShortcuts, .jumpBackIn, .recentlySaved, .customizeHome, .hnsInfo:
                return CGSize(width: frameWidth - inset, height: height)
            }
        }

        var headerView: UIView? {
            let view = ASHeaderView()
            view.title = title
            return view
        }

        var cellIdentifier: String {
            switch self {
            case .topSites: return "TopSiteCell"
            case .pocket: return "PocketCell"
            case .jumpBackIn: return "JumpBackInCell"
            case .recentlySaved: return "RecentlySavedCell"
            case .libraryShortcuts: return  "LibraryShortcutsCell"
            case .customizeHome: return "CustomizeHomeCell"
            case .hnsInfo: return "HandshakeInfoCell"
            }
        }

        var cellType: UICollectionViewCell.Type {
            switch self {
            case .topSites: return ASHorizontalScrollCell.self
            case .pocket: return FirefoxHomeHighlightCell.self
            case .jumpBackIn: return FxHomeJumpBackInCollectionCell.self
            case .recentlySaved: return FxHomeRecentlySavedCollectionCell.self
            case .libraryShortcuts: return ASLibraryCell.self
            case .customizeHome: return FxHomeCustomizeHomeView.self
            case .hnsInfo: return HNSHomeHeaderView.self
            }
        }

        init(at indexPath: IndexPath) {
            self.init(rawValue: indexPath.section)!
        }

        init(_ section: Int) {
            self.init(rawValue: section)!
        }
    }
}

// MARK: -  CollectionView Delegate

extension FirefoxHomeViewController: UICollectionViewDelegateFlowLayout {

    override func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        switch kind {
        case UICollectionView.elementKindSectionHeader:
            let view = collectionView.dequeueReusableSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "Header", for: indexPath) as! ASHeaderView
            let title = Section(indexPath.section).title
            view.title = title
            view.firstHeader = false

            switch Section(indexPath.section) {
            case .pocket:
                // tracking pocket section shown
                if !hasSentPocketSectionEvent {
                    TelemetryWrapper.recordEvent(category: .action, method: .view, object: .pocketSectionImpression, value: nil, extras: nil)
                    hasSentPocketSectionEvent = true
                }
                view.moreButton.isHidden = false
                view.moreButton.setTitle(Strings.PocketMoreStoriesText, for: .normal)
                view.moreButton.addTarget(self, action: #selector(showMorePocketStories), for: .touchUpInside)
                view.titleLabel.accessibilityIdentifier = FxHomeAccessibilityIdentifiers.SectionTitles.pocket
                return view
            case .jumpBackIn:
                if !hasSentJumpBackInSectionEvent
                    && isJumpBackInSectionEnabled
                    && !(jumpBackInViewModel.jumpList.itemsToDisplay == 0) {
                    TelemetryWrapper.recordEvent(category: .action, method: .view, object: .jumpBackInImpressions, value: nil, extras: nil)
                    hasSentJumpBackInSectionEvent = true
                }
                view.moreButton.isHidden = false
                view.moreButton.setTitle(Strings.RecentlySavedShowAllText, for: .normal)
                view.moreButton.addTarget(self, action: #selector(openTabTray), for: .touchUpInside)
                view.moreButton.accessibilityIdentifier = FxHomeAccessibilityIdentifiers.MoreButtons.jumpBackIn
                view.titleLabel.accessibilityIdentifier = FxHomeAccessibilityIdentifiers.SectionTitles.jumpBackIn
                return view
            case .recentlySaved:
                view.moreButton.isHidden = false
                view.moreButton.setTitle(Strings.RecentlySavedShowAllText, for: .normal)
                view.moreButton.addTarget(self, action: #selector(openBookmarks), for: .touchUpInside)
                view.moreButton.accessibilityIdentifier = FxHomeAccessibilityIdentifiers.MoreButtons.recentlySaved
                view.titleLabel.accessibilityIdentifier = FxHomeAccessibilityIdentifiers.SectionTitles.recentlySaved
                return view
            case .topSites:
                view.titleLabel.accessibilityIdentifier = FxHomeAccessibilityIdentifiers.SectionTitles.topSites
                view.moreButton.isHidden = true
                return view
            case .libraryShortcuts:
                view.moreButton.isHidden = true
                view.titleLabel.accessibilityIdentifier = FxHomeAccessibilityIdentifiers.SectionTitles.library
                return view
            case .customizeHome:
                view.moreButton.isHidden = true
                return view
            case .hnsInfo:
                view.moreButton.isHidden = true
                view.titleLabel.accessibilityIdentifier = "HNSHomeTitle"
                view.firstHeader = true
                return view
        }
        default:
            return UICollectionReusableView()
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        self.longPressRecognizer.isEnabled = false
        selectItemAtIndex(indexPath.item, inSection: Section(indexPath.section))
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        var cellSize = Section(indexPath.section).cellSize(for: self.traitCollection, frameWidth: self.view.frame.width)

        switch Section(indexPath.section) {
        case .topSites:
            // Create a temporary cell so we can calculate the height.
            let layout = topSiteCell.collectionView.collectionViewLayout as! HorizontalFlowLayout
            let estimatedLayout = layout.calculateLayout(for: CGSize(width: cellSize.width, height: 0))
            return CGSize(width: cellSize.width, height: estimatedLayout.size.height)
        case .recentlySaved:
            if recentlySavedViewModel.recentItems.count > 8, UIDevice.current.userInterfaceIdiom == .pad {
                cellSize.height *= 3
                return cellSize
            } else if recentlySavedViewModel.recentItems.count > 4, UIDevice.current.userInterfaceIdiom == .pad {
                cellSize.height *= 2
                return cellSize
            }
            return cellSize
        case .jumpBackIn:
            if jumpBackInViewModel.layoutVariables.scrollDirection == .horizontal {
                if jumpBackInViewModel.jumpList.itemsToDisplay > 2 {
                    cellSize.height *= 2
                }
            } else if jumpBackInViewModel.layoutVariables.scrollDirection == .vertical {
                cellSize.height *= CGFloat(jumpBackInViewModel.jumpList.itemsToDisplay)
            }
            return cellSize
        case .pocket:
            return cellSize
        case .libraryShortcuts:
            let width = min(FirefoxHomeUX.LibraryShortcutsMaxWidth, cellSize.width)
            return CGSize(width: width, height: cellSize.height)
        case .customizeHome:
            return cellSize
        case .hnsInfo:
            return cellSize
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        switch Section(section) {
        case .pocket:
            return pocketStories.isEmpty ? .zero : Section(section).headerHeight
        case .topSites:
            return isTopSitesSectionEnabled ? Section(section).headerHeight : .zero
        case .libraryShortcuts:
            return isYourLibrarySectionEnabled ? Section(section).headerHeight : .zero
        case .jumpBackIn:
            return isJumpBackInSectionEnabled ? Section(section).headerHeight : .zero
        case .recentlySaved:
            return isRecentlySavedSectionEnabled ? Section(section).headerHeight : .zero
        case .hnsInfo:
            return Section(section).headerHeight
        case .customizeHome:
            return .zero
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForFooterInSection section: Int) -> CGSize {
        return .zero
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat {
        return 0
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        let insets = Section(section).sectionInsets(self.traitCollection, frameWidth: self.view.frame.width)
        return UIEdgeInsets(top: 0, left: insets, bottom: FirefoxHomeUX.spacingBetweenSections, right: insets)
    }

    fileprivate func showSiteWithURLHandler(_ url: URL, isGoogleTopSite: Bool = false) {
        let visitType = VisitType.bookmark
        homePanelDelegate?.homePanel(didSelectURL: url, visitType: visitType, isGoogleTopSite: isGoogleTopSite)
    }
}

// MARK: - CollectionView Data Source

extension FirefoxHomeViewController {

    override func numberOfSections(in collectionView: UICollectionView) -> Int {
        return Section.allCases.count
    }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        var numItems: CGFloat = FirefoxHomeUX.numberOfItemsPerRowForSizeClassIpad[self.traitCollection.horizontalSizeClass]
        if UIApplication.shared.statusBarOrientation.isPortrait {
            numItems = numItems - 1
        }
        if self.traitCollection.horizontalSizeClass == .compact && UIApplication.shared.statusBarOrientation.isLandscape {
            numItems = numItems - 1
        }

        switch Section(section) {
        case .topSites:
            return isTopSitesSectionEnabled && !topSitesManager.content.isEmpty ? 1 : 0
        case .pocket:
            // There should always be a full row of pocket stories (numItems) otherwise don't show them
            return pocketStories.count
        case .jumpBackIn:
            return isJumpBackInSectionEnabled ? 1 : 0
        case .recentlySaved:
            return isRecentlySavedSectionEnabled ? 1 : 0
        case .libraryShortcuts:
            return isYourLibrarySectionEnabled ? 1 : 0
        case .customizeHome, .hnsInfo:
            return 1
        }
    }

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let identifier = Section(indexPath.section).cellIdentifier
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: identifier, for: indexPath)

        switch Section(indexPath.section) {
        case .topSites:
            return configureTopSitesCell(cell, forIndexPath: indexPath)
        case .pocket:
            return configurePocketItemCell(cell, forIndexPath: indexPath)
        case .jumpBackIn:
            return configureJumpBackInCell(cell, forIndexPath: indexPath)
        case .recentlySaved:
            return configureRecentlySavedCell(cell, forIndexPath: indexPath)
        case .libraryShortcuts:
            return configureLibraryShortcutsCell(cell, forIndexPath: indexPath)
        case .customizeHome:
            return configureCustomizeHomeCell(cell, forIndexPath: indexPath)
        case .hnsInfo:
            return configureHNSHomeCell(cell, forIndexPath: indexPath)
        }
    }

    func configureLibraryShortcutsCell(_ cell: UICollectionViewCell, forIndexPath indexPath: IndexPath) -> UICollectionViewCell {
        let libraryCell = cell as! ASLibraryCell
        let targets = [#selector(openBookmarks), #selector(openHistory), #selector(openDownloads), #selector(openReadingList)]
        libraryCell.libraryButtons.map({ $0.button }).zip(targets).forEach { (button, selector) in
            button.removeTarget(nil, action: nil, for: .allEvents)
            button.addTarget(self, action: selector, for: .touchUpInside)
        }
        libraryCell.applyTheme()

        return cell
    }

    func configureTopSitesCell(_ cell: UICollectionViewCell, forIndexPath indexPath: IndexPath) -> UICollectionViewCell {
        let topSiteCell = cell as! ASHorizontalScrollCell
        topSiteCell.delegate = self.topSitesManager
        topSiteCell.setNeedsLayout()
        topSiteCell.collectionView.reloadData()

        return cell
    }

    func configurePocketItemCell(_ cell: UICollectionViewCell, forIndexPath indexPath: IndexPath) -> UICollectionViewCell {
        let pocketStory = pocketStories[indexPath.row]
        let pocketItemCell = cell as! FirefoxHomeHighlightCell
        pocketItemCell.configureWithPocketStory(pocketStory)

        return pocketItemCell
    }

    private func configureRecentlySavedCell(_ cell: UICollectionViewCell, forIndexPath indexPath: IndexPath) -> UICollectionViewCell {
        let recentlySavedCell = cell as! FxHomeRecentlySavedCollectionCell
        recentlySavedCell.homePanelDelegate = homePanelDelegate
        recentlySavedCell.libraryPanelDelegate = libraryPanelDelegate
        recentlySavedCell.profile = profile
        recentlySavedCell.collectionView.reloadData()
        recentlySavedCell.setNeedsLayout()
        recentlySavedCell.viewModel = recentlySavedViewModel

        return recentlySavedCell
    }

    private func configureJumpBackInCell(_ cell: UICollectionViewCell, forIndexPath indexPath: IndexPath) -> UICollectionViewCell {
        let jumpBackInCell = cell as! FxHomeJumpBackInCollectionCell
        jumpBackInCell.profile = profile

        jumpBackInViewModel.onTapGroup = { [weak self] tab in
            self?.homePanelDelegate?.homePanelDidRequestToOpenTabTray(withFocusedTab: tab)
        }

        jumpBackInCell.viewModel = jumpBackInViewModel
        jumpBackInCell.collectionView.reloadData()
        jumpBackInCell.setNeedsLayout()

        return jumpBackInCell
    }

    private func configureCustomizeHomeCell(_ cell: UICollectionViewCell, forIndexPath indexPath: IndexPath) -> UICollectionViewCell {
        let customizeHomeCell = cell as! FxHomeCustomizeHomeView
        customizeHomeCell.goToSettingsButton.addTarget(self, action: #selector(openCustomizeHomeSettings), for: .touchUpInside)
        customizeHomeCell.setNeedsLayout()

        return customizeHomeCell
    }
    
    private func configureHNSHomeCell(_ cell: UICollectionViewCell, forIndexPath indexPath: IndexPath) -> UICollectionViewCell {
        let customizeHomeCell = cell as! HNSHomeHeaderView
      
        customizeHomeCell.blockHeightLabel.text = "Block height #\(hnsBlockHeight)"
        customizeHomeCell.poolSizeLabel.text = "Pool: size: \(hnsPoolSize) active: \(hnsActivePeers)"
        customizeHomeCell.setNeedsLayout()
        
        return customizeHomeCell
    }
}

// MARK: - Data Management

extension FirefoxHomeViewController: DataObserverDelegate {

    // Reloads both highlights and top sites data from their respective caches. Does not invalidate the cache.
    // See ActivityStreamDataObserver for invalidation logic.
    func reloadAll() {
        // If the pocket stories are not availible for the Locale the PocketAPI will return nil
        // So it is okay if the default here is true

        self.configureItemsForRecentlySaved()

        TopSitesHandler.getTopSites(profile: profile).uponQueue(.main) { [weak self] result in
            guard let self = self else { return }

            // If there is no pending cache update and highlights are empty. Show the onboarding screen
            self.collectionView?.reloadData()

            self.topSitesManager.currentTraits = self.view.traitCollection

            let numRows = max(self.profile.prefs.intForKey(PrefsKeys.NumberOfTopSiteRows) ?? TopSitesRowCountSettingsController.defaultNumberOfRows, 1)

            let maxItems = Int(numRows) * self.topSitesManager.numberOfHorizontalItems()

            var sites = Array(result.prefix(maxItems))

            // Check if all result items are pinned site
            var pinnedSites = 0
            result.forEach {
                if let _ = $0 as? PinnedSite {
                    pinnedSites += 1
                }
            }
            // Special case: Adding Google topsite
            let googleTopSite = GoogleTopSiteHelper(prefs: self.profile.prefs)
            if !googleTopSite.isHidden, let gSite = googleTopSite.suggestedSiteData() {
                // Once Google top site is added, we don't remove unless it's explicitly unpinned
                // Add it when pinned websites are less than max pinned sites
                if googleTopSite.hasAdded || pinnedSites < maxItems {
                    sites.insert(gSite, at: 0)
                    // Purge unwated websites from the end of list
                    if sites.count > maxItems {
                        sites.removeLast(sites.count - maxItems)
                    }
                    googleTopSite.hasAdded = true
                }
            }
            self.topSitesManager.content = sites
            self.topSitesManager.urlPressedHandler = { [unowned self] site, indexPath in
                self.longPressRecognizer.isEnabled = false
                guard let url = site.url.asURL else { return }
                let isGoogleTopSiteUrl = url.absoluteString == GoogleTopSiteConstants.usUrl || url.absoluteString == GoogleTopSiteConstants.rowUrl
                self.topSiteTracking(site: site, position: indexPath.item)
                self.showSiteWithURLHandler(url as URL, isGoogleTopSite: isGoogleTopSiteUrl)
            }

            self.getPocketSites().uponQueue(.main) { _ in
                if !self.pocketStories.isEmpty {
                    self.collectionView?.reloadData()
                }
            }
            // Refresh the AS data in the background so we'll have fresh data next time we show.
            self.profile.panelDataObservers.activityStream.refreshIfNeeded(forceTopSites: false)
        }
    }

    func topSiteTracking(site: Site, position: Int) {
        let topSitePositionKey = TelemetryWrapper.EventExtraKey.topSitePosition.rawValue
        let topSiteTileTypeKey = TelemetryWrapper.EventExtraKey.topSiteTileType.rawValue
        let isPinnedAndGoogle = site is PinnedSite && site.guid == GoogleTopSiteConstants.googleGUID
        let isPinnedOnly = site is PinnedSite
        let isSuggestedSite = site is SuggestedSite
        let type = isPinnedAndGoogle ? "google" : isPinnedOnly ? "user-added" : isSuggestedSite ? "suggested" : "history-based"
        TelemetryWrapper.recordEvent(category: .action, method: .tap, object: .topSiteTile, value: nil, extras: [topSitePositionKey : "\(position)", topSiteTileTypeKey: type])
    }

    func getPocketSites() -> Success {

        guard isPocketSectionEnabled else {
            self.pocketStories = []
            return succeed()
        }

        return pocketAPI.globalFeed(items: 10).bindQueue(.main) { pStory in
            self.pocketStories = pStory
            return succeed()
        }
    }

    @objc func showMorePocketStories() {
        showSiteWithURLHandler(Pocket.MoreStoriesURL)
    }

    // Invoked by the ActivityStreamDataObserver when highlights/top sites invalidation is complete.
    func didInvalidateDataSources(refresh forced: Bool, topSitesRefreshed: Bool) {
        // Do not reload panel unless we're currently showing the highlight intro or if we
        // force-reloaded the highlights or top sites. This should prevent reloading the
        // panel after we've invalidated in the background on the first load.
        if forced {
            reloadAll()
        }
    }

    func hideURLFromTopSites(_ site: Site) {
        guard let host = site.tileURL.normalizedHost else { return }

        let url = site.tileURL.absoluteString
        // if the default top sites contains the siteurl. also wipe it from default suggested sites.
        if !defaultTopSites().filter({ $0.url == url }).isEmpty {
            deleteTileForSuggestedSite(url)
        }
        profile.history.removeHostFromTopSites(host).uponQueue(.main) { result in
            guard result.isSuccess else { return }
            self.profile.panelDataObservers.activityStream.refreshIfNeeded(forceTopSites: true)
        }
    }

    func pinTopSite(_ site: Site) {
        profile.history.addPinnedTopSite(site).uponQueue(.main) { result in
            guard result.isSuccess else { return }
            self.profile.panelDataObservers.activityStream.refreshIfNeeded(forceTopSites: true)
        }
    }

    func removePinTopSite(_ site: Site) {
        // Special Case: Hide google top site
        if site.guid == GoogleTopSiteConstants.googleGUID {
            let gTopSite = GoogleTopSiteHelper(prefs: self.profile.prefs)
            gTopSite.isHidden = true
        }

        profile.history.removeFromPinnedTopSites(site).uponQueue(.main) { result in
            guard result.isSuccess else { return }
            self.profile.panelDataObservers.activityStream.refreshIfNeeded(forceTopSites: true)
        }
    }

    fileprivate func deleteTileForSuggestedSite(_ siteURL: String) {
        var deletedSuggestedSites = profile.prefs.arrayForKey(TopSitesHandler.DefaultSuggestedSitesKey) as? [String] ?? []
        deletedSuggestedSites.append(siteURL)
        profile.prefs.setObject(deletedSuggestedSites, forKey: TopSitesHandler.DefaultSuggestedSitesKey)
    }

    func defaultTopSites() -> [Site] {
        let suggested = SuggestedSites.asArray()
        let deleted = profile.prefs.arrayForKey(TopSitesHandler.DefaultSuggestedSitesKey) as? [String] ?? []
        return suggested.filter({ deleted.firstIndex(of: $0.url) == .none })
    }

    @objc fileprivate func longPress(_ longPressGestureRecognizer: UILongPressGestureRecognizer) {
        guard longPressGestureRecognizer.state == .began else { return }

        let point = longPressGestureRecognizer.location(in: self.collectionView)
        guard let indexPath = self.collectionView?.indexPathForItem(at: point) else { return }

        switch Section(indexPath.section) {
        case .pocket:
            presentContextMenu(for: indexPath)
        case .topSites:
            let topSiteCell = self.collectionView?.cellForItem(at: indexPath) as! ASHorizontalScrollCell
            let pointInTopSite = longPressGestureRecognizer.location(in: topSiteCell.collectionView)
            guard let topSiteIndexPath = topSiteCell.collectionView.indexPathForItem(at: pointInTopSite) else { return }
            presentContextMenu(for: topSiteIndexPath)
        case .libraryShortcuts, .jumpBackIn, .recentlySaved, .customizeHome, .hnsInfo:
            return
        }
    }

    fileprivate func fetchBookmarkStatus(for site: Site, completionHandler: @escaping () -> Void) {
        profile.places.isBookmarked(url: site.url).uponQueue(.main) { result in
            let isBookmarked = result.successValue ?? false
            site.setBookmarked(isBookmarked)
            completionHandler()
        }
    }

    func selectItemAtIndex(_ index: Int, inSection section: Section) {
        var site: Site? = nil
        switch section {
        case .pocket:
            site = Site(url: pocketStories[index].url.absoluteString, title: pocketStories[index].title)
            let key = TelemetryWrapper.EventExtraKey.pocketTilePosition.rawValue
            TelemetryWrapper.recordEvent(category: .action, method: .tap, object: .pocketStory, value: nil, extras: [key : "\(index)"])
        case .topSites, .libraryShortcuts, .jumpBackIn, .recentlySaved, .customizeHome, .hnsInfo:
            return
        }

        if let site = site {
            showSiteWithURLHandler(URL(string: site.url)!)
        }
    }
}

// MARK: - Actions Handling

extension FirefoxHomeViewController {
    @objc func openTabTray(_ sender: UIButton) {
        if sender.accessibilityIdentifier == FxHomeAccessibilityIdentifiers.MoreButtons.jumpBackIn {
            TelemetryWrapper.recordEvent(category: .action,
                                         method: .tap,
                                         object: .firefoxHomepage,
                                         value: .jumpBackInSectionShowAll)
        }
        homePanelDelegate?.homePanelDidRequestToOpenTabTray(withFocusedTab: nil)
    }

    @objc func openBookmarks(_ sender: UIButton) {
        homePanelDelegate?.homePanelDidRequestToOpenLibrary(panel: .bookmarks)

        if sender.accessibilityIdentifier == FxHomeAccessibilityIdentifiers.MoreButtons.recentlySaved {
            TelemetryWrapper.recordEvent(category: .action,
                                              method: .tap,
                                              object: .firefoxHomepage,
                                              value: .recentlySavedSectionShowAll)
        } else {
            TelemetryWrapper.recordEvent(category: .action,
                                         method: .tap,
                                         object: .firefoxHomepage,
                                         value: .yourLibrarySection,
                                         extras: [TelemetryWrapper.EventObject.libraryPanel.rawValue: TelemetryWrapper.EventValue.bookmarksPanel.rawValue])
        }
    }

    @objc func openHistory() {
        homePanelDelegate?.homePanelDidRequestToOpenLibrary(panel: .history)
        TelemetryWrapper.recordEvent(category: .action,
                                     method: .tap,
                                     object: .firefoxHomepage,
                                     value: .yourLibrarySection,
                                     extras: [TelemetryWrapper.EventObject.libraryPanel.rawValue: TelemetryWrapper.EventValue.historyPanel.rawValue])
    }

    @objc func openReadingList() {
        homePanelDelegate?.homePanelDidRequestToOpenLibrary(panel: .readingList)
        TelemetryWrapper.recordEvent(category: .action,
                                     method: .tap,
                                     object: .firefoxHomepage,
                                     value: .yourLibrarySection,
                                     extras: [TelemetryWrapper.EventObject.libraryPanel.rawValue: TelemetryWrapper.EventValue.readingListPanel.rawValue])
    }

    @objc func openDownloads() {
        homePanelDelegate?.homePanelDidRequestToOpenLibrary(panel: .downloads)
        TelemetryWrapper.recordEvent(category: .action,
                                     method: .tap,
                                     object: .firefoxHomepage,
                                     value: .yourLibrarySection,
                                     extras: [TelemetryWrapper.EventObject.libraryPanel.rawValue: TelemetryWrapper.EventValue.downloadsPanel.rawValue])
    }

    @objc func openCustomizeHomeSettings() {
        homePanelDelegate?.homePanelDidRequestToCustomizeHomeSettings()
        TelemetryWrapper.recordEvent(category: .action,
                                     method: .tap,
                                     object: .firefoxHomepage,
                                     value: .customizeHomepageButton)
    }
}

// MARK: - Context Menu

extension FirefoxHomeViewController: HomePanelContextMenu {
    func presentContextMenu(for site: Site, with indexPath: IndexPath, completionHandler: @escaping () -> PhotonActionSheet?) {

        fetchBookmarkStatus(for: site) {
            guard let contextMenu = completionHandler() else { return }
            self.present(contextMenu, animated: true, completion: nil)
        }
    }

    func getSiteDetails(for indexPath: IndexPath) -> Site? {
        switch Section(indexPath.section) {
        case .pocket:
            return Site(url: pocketStories[indexPath.row].url.absoluteString, title: pocketStories[indexPath.row].title)
        case .topSites:
            return topSitesManager.content[indexPath.item]
        case .libraryShortcuts, .jumpBackIn, .recentlySaved, .customizeHome, .hnsInfo:
            return nil
        }
    }

    func getContextMenuActions(for site: Site, with indexPath: IndexPath) -> [PhotonActionSheetItem]? {
        guard let siteURL = URL(string: site.url) else { return nil }
        var sourceView: UIView?

        switch Section(indexPath.section) {
        case .topSites:
            if let topSiteCell = self.collectionView?.cellForItem(at: IndexPath(row: 0, section: 0)) as? ASHorizontalScrollCell {
                sourceView = topSiteCell.collectionView.cellForItem(at: indexPath)
            }
        case .pocket:
            sourceView = self.collectionView?.cellForItem(at: indexPath)
        case .libraryShortcuts, .jumpBackIn, .recentlySaved, .customizeHome, .hnsInfo:
            return nil
        }

        let openInNewTabAction = PhotonActionSheetItem(title: Strings.OpenInNewTabContextMenuTitle, iconString: "quick_action_new_tab") { _, _ in
            self.homePanelDelegate?.homePanelDidRequestToOpenInNewTab(siteURL, isPrivate: false)
            if Section(indexPath.section) == .pocket {
                TelemetryWrapper.recordEvent(category: .action, method: .tap, object: .pocketStory)
            }
        }

        let openInNewPrivateTabAction = PhotonActionSheetItem(title: Strings.OpenInNewPrivateTabContextMenuTitle, iconString: "quick_action_new_private_tab") { _, _ in
            self.homePanelDelegate?.homePanelDidRequestToOpenInNewTab(siteURL, isPrivate: true)
        }

        let bookmarkAction: PhotonActionSheetItem
        if site.bookmarked ?? false {
            bookmarkAction = PhotonActionSheetItem(title: Strings.RemoveBookmarkContextMenuTitle, iconString: "action_bookmark_remove", handler: { _, _ in
                self.profile.places.deleteBookmarksWithURL(url: site.url) >>== {
                    self.profile.panelDataObservers.activityStream.refreshIfNeeded(forceTopSites: false)
                    site.setBookmarked(false)
                }

                TelemetryWrapper.recordEvent(category: .action, method: .delete, object: .bookmark, value: .activityStream)
            })
        } else {
            bookmarkAction = PhotonActionSheetItem(title: Strings.BookmarkContextMenuTitle, iconString: "action_bookmark", handler: { _, _ in
                let shareItem = ShareItem(url: site.url, title: site.title, favicon: site.icon)
                _ = self.profile.places.createBookmark(parentGUID: BookmarkRoots.MobileFolderGUID, url: shareItem.url, title: shareItem.title)

                var userData = [QuickActions.TabURLKey: shareItem.url]
                if let title = shareItem.title {
                    userData[QuickActions.TabTitleKey] = title
                }
                QuickActions.sharedInstance.addDynamicApplicationShortcutItemOfType(.openLastBookmark,
                                                                                    withUserData: userData,
                                                                                    toApplication: .shared)
                site.setBookmarked(true)
                self.profile.panelDataObservers.activityStream.refreshIfNeeded(forceTopSites: true)
                TelemetryWrapper.recordEvent(category: .action, method: .add, object: .bookmark, value: .activityStream)
            })
        }

        let shareAction = PhotonActionSheetItem(title: Strings.ShareContextMenuTitle, iconString: "action_share", handler: { _, _ in
            let helper = ShareExtensionHelper(url: siteURL, tab: nil)
            let controller = helper.createActivityViewController { (_, _) in }
            if UIDevice.current.userInterfaceIdiom == .pad, let popoverController = controller.popoverPresentationController {
                let cellRect = sourceView?.frame ?? .zero
                let cellFrameInSuperview = self.collectionView?.convert(cellRect, to: self.collectionView) ?? .zero

                popoverController.sourceView = sourceView
                popoverController.sourceRect = CGRect(origin: CGPoint(x: cellFrameInSuperview.size.width/2, y: cellFrameInSuperview.height/2), size: .zero)
                popoverController.permittedArrowDirections = [.up, .down, .left]
                popoverController.delegate = self
            }
            self.present(controller, animated: true, completion: nil)
        })

        let removeTopSiteAction = PhotonActionSheetItem(title: Strings.RemoveContextMenuTitle, iconString: "action_remove", handler: { _, _ in
            self.hideURLFromTopSites(site)
        })

        let pinTopSite = PhotonActionSheetItem(title: Strings.AddToShortcutsActionTitle, iconString: "action_pin", handler: { _, _ in
            self.pinTopSite(site)
        })

        let removePinTopSite = PhotonActionSheetItem(title: Strings.RemoveFromShortcutsActionTitle, iconString: "action_unpin", handler: { _, _ in
            self.removePinTopSite(site)
        })

        let topSiteActions: [PhotonActionSheetItem]
        if let _ = site as? PinnedSite {
            topSiteActions = [removePinTopSite]
        } else {
            topSiteActions = [pinTopSite, removeTopSiteAction]
        }

        var actions = [openInNewTabAction, openInNewPrivateTabAction, bookmarkAction, shareAction]

        switch Section(indexPath.section) {
        case .pocket, .libraryShortcuts, .jumpBackIn, .recentlySaved, .customizeHome, .hnsInfo: break
        case .topSites: actions.append(contentsOf: topSiteActions)
        }

        return actions
    }
}

// MARK: - Popover Presentation Delegate

extension FirefoxHomeViewController: UIPopoverPresentationControllerDelegate {

    // Dismiss the popover if the device is being rotated.
    // This is used by the Share UIActivityViewController action sheet on iPad
    func popoverPresentationController(_ popoverPresentationController: UIPopoverPresentationController, willRepositionPopoverTo rect: UnsafeMutablePointer<CGRect>, in view: AutoreleasingUnsafeMutablePointer<UIView>) {
        popoverPresentationController.presentedViewController.dismiss(animated: false, completion: nil)
    }
}
