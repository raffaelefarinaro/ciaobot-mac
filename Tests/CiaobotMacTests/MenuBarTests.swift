import XCTest
import AppKit
import Combine

@testable import CiaobotMac

/// Notification rows now live inside the Settings submenu, so a test that only
/// wants the row searches the whole tree. Composition tests separately assert
/// that the rows are not top-level and are not duplicated.
private extension NSMenu {
    func deepItem(withTitle title: String) -> NSMenuItem? {
        if let item = item(withTitle: title) { return item }
        for item in items {
            if let submenu = item.submenu,
               let found = submenu.deepItem(withTitle: title) {
                return found
            }
        }
        return nil
    }
}

/// A menu-bar item double. Controller tests never need a real `NSStatusBar`,
/// so they do not add an icon to the operator's menu bar. One adapter test at
/// the end creates and immediately removes a real item to prove that surface.
@MainActor
private final class FakeStatusItem: MenuBarStatusItem {
    var title: String?
    var image: NSImage?
    var toolTip: String?
    var menu: NSMenu?
    var isVisible = false
    private(set) var removeCount = 0

    func remove() {
        removeCount += 1
    }
}

@MainActor
private final class FakeStatusItemFactory: StatusItemFactory {
    private(set) var requestedLengths: [CGFloat] = []
    private(set) var items: [FakeStatusItem] = []

    func makeStatusItem(length: CGFloat) -> MenuBarStatusItem {
        requestedLengths.append(length)
        let item = FakeStatusItem()
        items.append(item)
        return item
    }
}

@MainActor
private final class SpyWindow: NSWindow {
    private(set) var orderFrontCount = 0

    override func makeKeyAndOrderFront(_ sender: Any?) {
        orderFrontCount += 1
    }
}

@MainActor
private final class FakeMainWindowPresenter: MainWindowPresenting {
    private(set) var presentCount = 0
    var result = true

    func present() -> Bool {
        presentCount += 1
        return result
    }
}

@MainActor
private final class FakeMenuBarController: MenuBarControlling {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

@MainActor
private final class FakeNotificationMenu: NotificationMenuProviding {
    let subject: CurrentValueSubject<ChatNotificationState, Never>
    let streamSubject: CurrentValueSubject<ChatNotificationStreamStatus, Never>
    private(set) var actionCount = 0
    private(set) var refreshCount = 0
    private(set) var stopCount = 0

    init(_ state: ChatNotificationState = .off, stream: ChatNotificationStreamStatus = .ready) {
        subject = CurrentValueSubject(state)
        streamSubject = CurrentValueSubject(stream)
    }

    var state: ChatNotificationState { subject.value }
    var statePublisher: AnyPublisher<ChatNotificationState, Never> { subject.eraseToAnyPublisher() }
    var streamStatus: ChatNotificationStreamStatus { streamSubject.value }
    var streamStatusPublisher: AnyPublisher<ChatNotificationStreamStatus, Never> {
        streamSubject.eraseToAnyPublisher()
    }

    func performMenuAction() { actionCount += 1 }
    func refreshIfNeeded() { refreshCount += 1 }
    func stop() { stopCount += 1 }
    func set(_ state: ChatNotificationState) { subject.send(state) }
    func setStream(_ status: ChatNotificationStreamStatus) { streamSubject.send(status) }
}

@MainActor
private final class FakeSystemSettings: SystemSettingsOpening {
    private(set) var notificationSettingsCount = 0
    private(set) var loginItemsSettingsCount = 0

    func openNotificationSettings() { notificationSettingsCount += 1 }
    func openLoginItemsSettings() { loginItemsSettingsCount += 1 }
}

@MainActor
final class MenuBarTests: XCTestCase {
    private let origin = Origin("http://127.0.0.1:8443")!

    // MARK: - Connection state

    func testConnectionStateStartsDisconnectedAndReportsTheCanonicalOrigin() {
        let status = AppSessionStatus()
        XCTAssertEqual(status.connection, .disconnected)
        XCTAssertFalse(status.isConnected)

        status.reportConnected(origin)
        XCTAssertEqual(status.connection, .connected("http://127.0.0.1:8443"))
        XCTAssertTrue(status.isConnected)

        status.reportDisconnected()
        XCTAssertEqual(status.connection, .disconnected)
        XCTAssertFalse(status.isConnected)
    }

    func testConnectionStateUsesTheExactOriginRatherThanTheProposedCandidate() {
        let otherPort = Origin("http://127.0.0.1:9443")!
        let https = Origin("https://example.com")!
        let status = AppSessionStatus()

        status.reportConnected(otherPort)
        XCTAssertEqual(status.connection, .connected("http://127.0.0.1:9443"))
        status.reportConnected(https)
        XCTAssertEqual(status.connection, .connected("https://example.com:443"))
    }

    // MARK: - Menu bar lifecycle

    func testStartCreatesOneMenuBarItemAndASecondStartIsIdempotent() throws {
        let factory = FakeStatusItemFactory()
        let controller = MenuBarController(
            status: AppSessionStatus(),
            statusItemFactory: factory,
            openWindow: {},
            quit: {}
        )

        controller.start()
        controller.start()

        XCTAssertEqual(factory.items.count, 1)
        XCTAssertEqual(
            factory.requestedLengths,
            [NSStatusItem.variableLength],
            "The tray item must fit the attention count beside the face."
        )
        let item = try XCTUnwrap(controller.statusItem as? FakeStatusItem)
        XCTAssertTrue(item === factory.items[0])
        XCTAssertTrue(item.isVisible)
        XCTAssertEqual(item.toolTip, MenuBarController.toolTip)
        XCTAssertTrue(item.menu === controller.menu)
        XCTAssertNotNil(controller.menu)
    }

    func testMenuItemUsesTheBundledTemplateArtwork() throws {
        let controller = MenuBarController(
            status: AppSessionStatus(),
            statusItemFactory: FakeStatusItemFactory(),
            image: AppAssets.menuBarImage,
            openWindow: {},
            quit: {}
        )
        controller.start()

        let item = try XCTUnwrap(controller.statusItem as? FakeStatusItem)
        let image = try XCTUnwrap(item.image, "The tray icon must be packaged with the client.")
        XCTAssertTrue(image.isTemplate, "A non-template image would not receive the macOS menu-bar tint.")
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }

    func testControllerForcesATemplateImageOfTheExpectedPointSize() throws {
        // Even an untemplated source image must never be drawn in its original
        // colours in the menu bar.
        let source = NSImage(size: NSSize(width: 40, height: 40))
        let controller = MenuBarController(
            status: AppSessionStatus(),
            statusItemFactory: FakeStatusItemFactory(),
            image: source,
            openWindow: {},
            quit: {}
        )
        controller.start()

        let item = try XCTUnwrap(controller.statusItem as? FakeStatusItem)
        let image = try XCTUnwrap(item.image)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertFalse(source.isTemplate, "The packaged image must not be mutated in place.")
        XCTAssertEqual(source.size, NSSize(width: 40, height: 40))
    }

    func testStartWithoutArtworkStillProducesAVisibleFallbackItem() throws {
        let controller = MenuBarController(
            status: AppSessionStatus(),
            statusItemFactory: FakeStatusItemFactory(),
            image: nil,
            openWindow: {},
            quit: {}
        )
        controller.start()

        let item = try XCTUnwrap(controller.statusItem as? FakeStatusItem)
        XCTAssertNil(item.image)
        XCTAssertEqual(item.title, MenuBarController.fallbackTitle)
        XCTAssertNotNil(item.menu)
    }

    /// Short-lived by design: this is the only test that touches the real
    /// `NSStatusBar`, and it removes the item before returning.
    func testSystemFactoryCreatesAButtonBackedItemThatCanBeRemoved() {
        let item = SystemStatusItemFactory().makeStatusItem(length: NSStatusItem.squareLength)
        defer { item.remove() }

        // Reading values back proves the status item exposes a real button,
        // which is where the controller installs the template artwork.
        item.title = "probe"
        XCTAssertEqual(item.title, "probe")
        item.toolTip = "Ciaobot"
        XCTAssertEqual(item.toolTip, "Ciaobot")

        let menu = NSMenu()
        item.menu = menu
        XCTAssertTrue(item.menu === menu)

        let image = NSImage(size: NSSize(width: 18, height: 18))
        item.image = image
        XCTAssertTrue(item.image === image)

        item.isVisible = true
        XCTAssertTrue(item.isVisible)
    }

    func testStopRemovesTheStatusItemAndCanBeStartedAgain() throws {
        let factory = FakeStatusItemFactory()
        let controller = MenuBarController(
            status: AppSessionStatus(),
            statusItemFactory: factory,
            openWindow: {},
            quit: {}
        )

        controller.start()
        let first = try XCTUnwrap(controller.statusItem as? FakeStatusItem)
        controller.stop()

        XCTAssertEqual(first.removeCount, 1)
        XCTAssertNil(controller.statusItem)
        XCTAssertNil(controller.menu)

        controller.start()
        XCTAssertEqual(factory.items.count, 2)
        let second = try XCTUnwrap(controller.statusItem as? FakeStatusItem)
        XCTAssertTrue(second === factory.items[1])
        XCTAssertEqual(second.removeCount, 0)
    }

    // MARK: - Menu contents and actions

    func testMenuContainsOnlyTheTruthfulStatusOpenAndQuit() throws {
        let controller = MenuBarController(
            status: AppSessionStatus(),
            statusItemFactory: FakeStatusItemFactory(),
            openWindow: {},
            quit: {}
        )
        controller.start()

        let menu = try XCTUnwrap(controller.menu)
        XCTAssertFalse(menu.autoenablesItems, "The static tray menu must keep its explicit enabled state.")
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), [
            MenuBarController.disconnectedTitle,
            MenuBarController.openTitle,
            MenuBarController.quitTitle,
        ])
        // No chat list, unread badge, notification or server lifecycle entry.
        XCTAssertEqual(menu.items.count, 5)

        let statusEntry = try XCTUnwrap(menu.items.first)
        XCTAssertFalse(statusEntry.isEnabled)
        XCTAssertNil(statusEntry.action)
    }

    func testOpenItemCallsOnlyTheOpenHandler() throws {
        var openCount = 0
        var quitCount = 0
        let controller = MenuBarController(
            status: AppSessionStatus(),
            statusItemFactory: FakeStatusItemFactory(),
            openWindow: { openCount += 1 },
            quit: { quitCount += 1 }
        )
        controller.start()

        let openItem = try XCTUnwrap(controller.menu?.item(withTitle: MenuBarController.openTitle))
        XCTAssertTrue(openItem.isEnabled)
        XCTAssertTrue(openItem.target === controller)
        XCTAssertEqual(openItem.action, #selector(MenuBarController.openCiaobot(_:)))

        controller.openCiaobot(openItem)

        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(quitCount, 0, "Opening the window must never quit the app.")
    }

    func testQuitItemCallsOnlyTheQuitHandler() throws {
        var openCount = 0
        var quitCount = 0
        let controller = MenuBarController(
            status: AppSessionStatus(),
            statusItemFactory: FakeStatusItemFactory(),
            openWindow: { openCount += 1 },
            quit: { quitCount += 1 }
        )
        controller.start()

        let quitItem = try XCTUnwrap(controller.menu?.item(withTitle: MenuBarController.quitTitle))
        XCTAssertTrue(quitItem.isEnabled)
        XCTAssertTrue(quitItem.target === controller)
        XCTAssertEqual(quitItem.action, #selector(MenuBarController.quitCiaobot(_:)))

        controller.quitCiaobot(quitItem)

        XCTAssertEqual(quitCount, 1)
        XCTAssertEqual(openCount, 0, "Quitting must not reopen the window.")
    }

    func testStatusTitleTracksTheConnectionAndStopsUpdatingAfterStop() throws {
        let status = AppSessionStatus()
        let controller = MenuBarController(
            status: status,
            statusItemFactory: FakeStatusItemFactory(),
            openWindow: {},
            quit: {}
        )
        controller.start()

        XCTAssertEqual(controller.statusTitle, MenuBarController.disconnectedTitle)

        status.reportConnected(origin)
        XCTAssertEqual(controller.statusTitle, "Connected to http://127.0.0.1:8443")

        status.reportDisconnected()
        XCTAssertEqual(controller.statusTitle, MenuBarController.disconnectedTitle)

        status.reportConnected(origin)
        controller.stop()
        XCTAssertNil(controller.statusTitle)
        // A late connection update after teardown must not resurrect the item.
        status.reportDisconnected()
        XCTAssertNil(controller.statusItem)
    }

    // MARK: - Reopening the window

    func testMainWindowPresenterActivatesAndReordersTheMainWindow() {
        let window = SpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.identifier = MainWindowPresenter.mainWindowIdentifier
        var activated = 0
        let presenter = MainWindowPresenter(
            windows: { [window] },
            activate: { activated += 1 }
        )

        XCTAssertTrue(presenter.present())
        XCTAssertEqual(activated, 1)
        XCTAssertEqual(window.orderFrontCount, 1)
    }

    func testMainWindowPresenterIgnoresOtherWindowsAndReportsAMissingMainWindow() {
        let child = NSWindow()
        child.identifier = NSUserInterfaceItemIdentifier("child")
        child.title = "Ciaobot"
        var activated = 0
        let presenter = MainWindowPresenter(
            windows: { [child] },
            activate: { activated += 1 }
        )

        XCTAssertFalse(presenter.present())
        XCTAssertEqual(activated, 1, "The app should still be activated when no window can be found.")
        XCTAssertNil(MainWindowPresenter.mainWindow(in: [child]))
    }

    func testApplicationLaunchStartsTheMenuBarAndOpenRoutesToThePresenter() {
        _ = NSApplication.shared
        let presenter = FakeMainWindowPresenter()
        let menuBar = FakeMenuBarController()
        var capturedOpen: (() -> Void)?
        let delegate = AppDelegate(
            session: AppSessionStatus(),
            presenter: presenter,
            makeMenuBar: { _, open, _ in
                capturedOpen = open
                return menuBar
            }
        )

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        XCTAssertEqual(menuBar.startCount, 1, "The menu bar must exist from app launch.")

        capturedOpen?()
        XCTAssertEqual(presenter.presentCount, 1, "Open Ciaobot must use the window presenter.")

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
        XCTAssertEqual(menuBar.stopCount, 1)
    }

    func testAppDelegateDoesNotTerminateWhenTheLastWindowCloses() {
        let delegate = AppDelegate(
            session: AppSessionStatus(),
            presenter: FakeMainWindowPresenter()
        )
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
                       "Closing the window must leave the tray app running.")
    }

    func testAppDelegateReopensOnlyWhenNoWindowIsVisible() {
        let presenter = FakeMainWindowPresenter()
        let delegate = AppDelegate(session: AppSessionStatus(), presenter: presenter)

        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(presenter.presentCount, 0, "A visible window must not be re-presented.")

        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(presenter.presentCount, 1)
    }

    // MARK: - Notification opt-in row

    func testNotificationRowOffersOptInAndOnlyTheClickActs() throws {
        let notifications = FakeNotificationMenu(.off)
        let controller = MenuBarController(
            status: AppSessionStatus(),
            statusItemFactory: FakeStatusItemFactory(),
            openWindow: {},
            quit: {},
            notifications: notifications
        )
        controller.start()

        let item = try XCTUnwrap(controller.menu?.deepItem(withTitle: MenuBarController.notificationsOffTitle))
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(item.target === controller)
        XCTAssertEqual(item.action, #selector(MenuBarController.toggleNotifications(_:)))
        XCTAssertEqual(notifications.actionCount, 0, "Showing the row must not request permission.")
        XCTAssertEqual(notifications.refreshCount, 0)

        controller.toggleNotifications(item)
        XCTAssertEqual(notifications.actionCount, 1)
    }

    func testNotificationRowShowsTheEnabledStateAndOffersToTurnOff() throws {
        let notifications = FakeNotificationMenu(.on)
        let controller = MenuBarController(
            status: AppSessionStatus(),
            statusItemFactory: FakeStatusItemFactory(),
            openWindow: {},
            quit: {},
            notifications: notifications
        )
        controller.start()

        let item = try XCTUnwrap(controller.menu?.deepItem(withTitle: MenuBarController.notificationsOnTitle))
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.state, .on)
        XCTAssertEqual(item.action, #selector(MenuBarController.toggleNotifications(_:)))

        controller.toggleNotifications(item)
        XCTAssertEqual(notifications.actionCount, 1)

        notifications.set(.off)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertNotNil(controller.menu?.deepItem(withTitle: MenuBarController.notificationsOffTitle))
        XCTAssertNil(controller.menu?.deepItem(withTitle: MenuBarController.notificationsOnTitle))
    }

    func testNotificationRowDoesNotSayOnUntilTheEventStreamIsReady() throws {
        for (stream, title) in [
            (ChatNotificationStreamStatus.notConnected, MenuBarController.notificationsWaitingTitle),
            (.waitingForAuthentication, MenuBarController.notificationsSignInTitle),
            (.connecting, MenuBarController.notificationsConnectingTitle),
            (.retrying, MenuBarController.notificationsRetryingTitle),
        ] {
            let notifications = FakeNotificationMenu(.on, stream: stream)
            let controller = MenuBarController(
                status: AppSessionStatus(),
                statusItemFactory: FakeStatusItemFactory(),
                openWindow: {},
                quit: {},
                notifications: notifications
            )
            controller.start()

            let item = try XCTUnwrap(controller.menu?.deepItem(withTitle: title))
            XCTAssertTrue(item.isEnabled, "The row must stay clickable so notifications can be turned off.")
            XCTAssertEqual(item.state, .on)
            XCTAssertNil(
                controller.menu?.deepItem(withTitle: MenuBarController.notificationsOnTitle),
                "A plain On row would claim an authenticated stream that is not ready."
            )
        }
    }

    func testNotificationRowBecomesPlainOnAfterTheSnapshot() throws {
        let notifications = FakeNotificationMenu(.on, stream: .connecting)
        let controller = MenuBarController(
            status: AppSessionStatus(),
            statusItemFactory: FakeStatusItemFactory(),
            openWindow: {},
            quit: {},
            notifications: notifications
        )
        controller.start()
        XCTAssertNotNil(controller.menu?.deepItem(withTitle: MenuBarController.notificationsConnectingTitle))

        notifications.setStream(.ready)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let ready = try XCTUnwrap(controller.menu?.deepItem(withTitle: MenuBarController.notificationsOnTitle))
        XCTAssertEqual(ready.state, .on)
    }

    func testBlockedNotificationRowOpensSettingsAndUnavailableRowStaysDisabled() throws {
        let blockedSettings = FakeSystemSettings()
        let blocked = FakeNotificationMenu(.denied)
        let blockedController = MenuBarController(
            status: AppSessionStatus(),
            statusItemFactory: FakeStatusItemFactory(),
            openWindow: {},
            quit: {},
            notifications: blocked,
            systemSettings: blockedSettings
        )
        blockedController.start()

        let blockedItem = try XCTUnwrap(
            blockedController.menu?.deepItem(withTitle: MenuBarController.notificationsBlockedTitle)
        )
        XCTAssertTrue(blockedItem.isEnabled)
        XCTAssertTrue(blockedItem.target === blockedController)
        XCTAssertEqual(blockedItem.action, #selector(MenuBarController.openNotificationSettings(_:)))

        blockedController.openNotificationSettings(blockedItem)
        XCTAssertEqual(blockedSettings.notificationSettingsCount, 1)
        XCTAssertEqual(blockedSettings.loginItemsSettingsCount, 0)

        let unavailable = FakeNotificationMenu(.unavailable(.unbundled))
        let unavailableController = MenuBarController(
            status: AppSessionStatus(),
            statusItemFactory: FakeStatusItemFactory(),
            openWindow: {},
            quit: {},
            notifications: unavailable,
            systemSettings: FakeSystemSettings()
        )
        unavailableController.start()

        let unavailableItem = try XCTUnwrap(
            unavailableController.menu?.deepItem(withTitle: MenuBarController.notificationsUnbundledTitle)
        )
        XCTAssertFalse(unavailableItem.isEnabled)
        XCTAssertNil(unavailableItem.action)
        XCTAssertTrue(unavailableItem.toolTip?.contains("bundled") == true)
    }

    func testMenuOpenRefreshesNotificationsWithoutAnActionAndStopEndsTheController() {
        let notifications = FakeNotificationMenu(.on)
        let controller = MenuBarController(
            status: AppSessionStatus(),
            statusItemFactory: FakeStatusItemFactory(),
            openWindow: {},
            quit: {},
            notifications: notifications
        )
        controller.start()

        let menu = controller.menu!
        controller.menuWillOpen(menu)
        XCTAssertEqual(notifications.refreshCount, 1)
        XCTAssertEqual(notifications.actionCount, 0, "Opening the menu must not opt in.")
        controller.menuDidClose(menu)

        controller.stop()
        XCTAssertEqual(notifications.stopCount, 1)
    }
}
