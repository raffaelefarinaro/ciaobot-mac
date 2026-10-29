import XCTest
import Foundation
import WebKit
import Combine
import UserNotifications

@testable import CiaobotMac

/// Notification rows live in the Settings submenu, so this test searches the
/// tree instead of assuming a top-level row.
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

// MARK: - Doubles

@MainActor
private final class FakeNotificationClient: NotificationPermissionClient {
    var isAvailable = true
    var onActivation: ((ChatNotificationTarget) -> Void)?
    var authorization: ChatNotificationAuthorization = .notDetermined
    var grantsPermission = true
    var requestError: Error?
    var holdRequest = false
    private var pendingRequest: ((ChatNotificationAuthorizationRequest) -> Void)?

    private(set) var prepareCount = 0
    private(set) var statusCount = 0
    private(set) var requestCount = 0
    private(set) var delivered: [ChatNotificationMessage] = []

    func prepare() {
        prepareCount += 1
    }

    func authorizationStatus(completion: @escaping (ChatNotificationAuthorization) -> Void) {
        statusCount += 1
        completion(authorization)
    }

    func requestAuthorization(completion: @escaping (ChatNotificationAuthorizationRequest) -> Void) {
        requestCount += 1
        guard !holdRequest else {
            pendingRequest = completion
            return
        }
        completeRequest(completion)
    }

    func finishHeldRequest(granted: Bool) {
        guard let completion = pendingRequest else { return }
        pendingRequest = nil
        grantsPermission = granted
        completeRequest(completion)
    }

    private func completeRequest(_ completion: (ChatNotificationAuthorizationRequest) -> Void) {
        if let requestError {
            completion(.failed(requestError.localizedDescription))
            return
        }
        authorization = grantsPermission ? .authorized : .denied
        completion(grantsPermission ? .granted : .denied)
    }

    func deliver(_ message: ChatNotificationMessage) {
        delivered.append(message)
    }

    func activate(_ target: ChatNotificationTarget) {
        onActivation?(target)
    }
}

private final class MemoryNotificationPreference: NotificationPreferenceStoring {
    var isEnabled: Bool

    init(_ isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }
}

private final class NotificationFakeCookieProvider: ChatCookieProviding {
    var cookies: [HTTPCookie] = []
    private(set) var requestedURLs: [URL] = []

    func cookies(for url: URL, completion: @escaping ([HTTPCookie]) -> Void) {
        requestedURLs.append(url)
        completion(cookies)
    }
}

private final class NotificationFakeConnection: EventStreamConnection {
    private let onEvent: (ChatEvent) -> Void
    private let onClose: (EventStreamCloseReason) -> Void
    private(set) var cancelCount = 0

    init(onEvent: @escaping (ChatEvent) -> Void, onClose: @escaping (EventStreamCloseReason) -> Void) {
        self.onEvent = onEvent
        self.onClose = onClose
    }

    func emit(_ event: ChatEvent) {
        onEvent(event)
    }

    func close(_ reason: EventStreamCloseReason) {
        onClose(reason)
    }

    func cancel() {
        cancelCount += 1
    }
}

private final class NotificationFakeTransport: EventStreamTransport {
    struct Open {
        let origin: Origin
        let cookieHeader: String
        let connection: NotificationFakeConnection
    }

    private(set) var opens: [Open] = []
    var failOpen = false

    func open(
        origin: Origin,
        cookieHeader: String,
        onEvent: @escaping (ChatEvent) -> Void,
        onClose: @escaping (EventStreamCloseReason) -> Void
    ) -> EventStreamConnection? {
        guard !failOpen else { return nil }
        let connection = NotificationFakeConnection(onEvent: onEvent, onClose: onClose)
        opens.append(Open(origin: origin, cookieHeader: cookieHeader, connection: connection))
        return connection
    }
}

@MainActor
private final class NotificationFakeStatusItem: MenuBarStatusItem {
    var title: String?
    var image: NSImage?
    var toolTip: String?
    var menu: NSMenu?
    var isVisible = false

    func remove() {}
}

@MainActor
private final class NotificationFakeStatusItemFactory: StatusItemFactory {
    func makeStatusItem(length: CGFloat) -> MenuBarStatusItem {
        NotificationFakeStatusItem()
    }
}

@MainActor
private final class RecordingNotificationNavigationDelegate: NSObject, WKNavigationDelegate {
    private(set) var requestedURL: URL?

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        requestedURL = navigationAction.request.url
        decisionHandler(.cancel)
    }
}

// MARK: - Tests

@MainActor
final class ChatNotificationsTests: XCTestCase {
    private let origin = Origin("http://127.0.0.1:8443")!
    private let remote = Origin("https://example.com")!

    private func settle() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    @discardableResult
    private func waitUntilAsync(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func connectedStatus(_ origin: Origin) -> AppSessionStatus {
        let status = AppSessionStatus()
        status.reportConnected(origin, dataStore: WKWebsiteDataStore.nonPersistent())
        return status
    }

    private func makeCookie(
        name: String = "ciao_session",
        value: String = "secret",
        domain: String = "127.0.0.1",
        path: String = "/",
        secure: Bool = false
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]
        if secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }

    private func makeController(
        status: AppSessionStatus,
        client: FakeNotificationClient,
        preferences: MemoryNotificationPreference,
        provider: NotificationFakeCookieProvider,
        transport: NotificationFakeTransport,
        present: @escaping () -> Void = {},
        openChat: @escaping (String) -> Bool = { _ in true }
    ) -> ChatNotificationController {
        ChatNotificationController(
            status: status,
            permission: client,
            preferences: preferences,
            transport: transport,
            cookieProviderFactory: { _ in provider },
            presentWindow: present,
            openChat: openChat,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
    }

    // MARK: Opt-in and permission

    func testStartDoesNotPromptAndTheMenuClickIsTheOnlyPrompt() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        let preferences = MemoryNotificationPreference(false)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()

        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(client.prepareCount, 1, "The delegate is installed without prompting.")
        XCTAssertEqual(client.requestCount, 0, "Start must never request notification permission.")
        XCTAssertTrue(transport.opens.isEmpty, "No socket before an explicit opt-in.")
        XCTAssertFalse(preferences.isEnabled)

        controller.performMenuAction()
        await settle()

        XCTAssertEqual(client.requestCount, 1)
        XCTAssertEqual(controller.state, .on)
        XCTAssertTrue(preferences.isEnabled)
        XCTAssertEqual(transport.opens.count, 1)
        controller.stop()
    }

    func testASecondClickWhileThePermissionPromptIsPendingDoesNotPromptAgain() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.holdRequest = true
        let preferences = MemoryNotificationPreference(false)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        controller.performMenuAction()
        controller.performMenuAction()
        await settle()

        XCTAssertEqual(client.requestCount, 1, "Only the first explicit click may open the OS prompt.")
        XCTAssertEqual(controller.state, .off, "The state stays off until macOS answers.")
        XCTAssertTrue(transport.opens.isEmpty)

        client.finishHeldRequest(granted: true)
        await settle()
        XCTAssertEqual(controller.state, .on)
        XCTAssertTrue(preferences.isEnabled)
        controller.stop()
    }

    func testStartShowsBlockedWhenTheOSAlreadyDeniedPermission() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .denied
        let preferences = MemoryNotificationPreference(false)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()

        XCTAssertEqual(controller.state, .denied)
        XCTAssertEqual(client.requestCount, 0, "Reading the OS state must not prompt.")
        XCTAssertTrue(transport.opens.isEmpty)
        controller.stop()
    }

    func testDeniedPermissionLeavesNotificationsOffAndDoesNotRememberOptIn() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.grantsPermission = false
        let preferences = MemoryNotificationPreference(false)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        controller.performMenuAction()
        await settle()

        XCTAssertEqual(controller.state, .denied)
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertTrue(transport.opens.isEmpty)
        XCTAssertTrue(client.delivered.isEmpty)
        controller.stop()
    }

    func testAuthorizationRequestErrorIsPreservedAndNeverReportedAsDenied() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.requestError = NSError(
            domain: "CiaobotTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Notifications are not available for this application"]
        )
        let preferences = MemoryNotificationPreference(false)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        controller.performMenuAction()
        await settle()

        XCTAssertEqual(
            controller.state,
            .unavailable(.permissionRequestFailed("Notifications are not available for this application")),
            "A technical request failure is not a macOS denial."
        )
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertTrue(transport.opens.isEmpty)
        XCTAssertTrue(client.delivered.isEmpty)
        controller.stop()
    }

    func testRegistrationFailureSurvivesAMenuRefreshWithoutASecondPrompt() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.requestError = NSError(
            domain: "CiaobotTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Notifications are not available for this application"]
        )
        let preferences = MemoryNotificationPreference(false)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        controller.performMenuAction()
        await settle()
        let failure = ChatNotificationState.unavailable(
            .permissionRequestFailed("Notifications are not available for this application")
        )
        XCTAssertEqual(controller.state, failure)

        controller.refreshIfNeeded()
        await settle()

        XCTAssertEqual(controller.state, failure, "A menu refresh must not erase the technical error.")
        XCTAssertEqual(client.requestCount, 1, "Refreshing the menu never asks macOS again.")
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertTrue(transport.opens.isEmpty)
        controller.stop()
    }

    func testUnknownAuthorizationStatusIsUnavailableAndNotBlocked() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .unknown("A future macOS authorization state")
        let preferences = MemoryNotificationPreference(false)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()

        XCTAssertEqual(
            controller.state,
            .unavailable(.unknownAuthorization("A future macOS authorization state")),
            "An unrecognized status must not be shown as 'blocked by macOS'."
        )
        XCTAssertEqual(client.requestCount, 0)
        XCTAssertTrue(transport.opens.isEmpty)
        controller.stop()
    }

    func testRememberedOptInUsesExistingPermissionWithoutPrompting() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()

        XCTAssertEqual(client.requestCount, 0)
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(transport.opens.count, 1)
        controller.stop()
    }

    func testRememberedOptInWithoutPermissionNeedsANewClick() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .notDetermined
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()

        XCTAssertEqual(controller.state, .off)
        XCTAssertFalse(preferences.isEnabled, "A stored flag without permission is not consent for this launch.")
        XCTAssertEqual(client.requestCount, 0)
        XCTAssertTrue(transport.opens.isEmpty)
        controller.stop()
    }

    func testUnavailableClientNeverPromptsOrConnects() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.isAvailable = false
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()

        XCTAssertEqual(controller.state, .unavailable(.unbundled))
        XCTAssertEqual(client.requestCount, 0)
        XCTAssertEqual(client.statusCount, 0)
        XCTAssertTrue(transport.opens.isEmpty)
        controller.stop()
    }

    func testUnbundledProcessReportsUnavailableWithoutTouchingUserNotifications() {
        let client = SystemNotificationPermissionClient(bundle: Bundle(for: ChatNotificationsTests.self))
        XCTAssertFalse(client.isAvailable, "The test host is not a .app bundle.")
        client.prepare()

        var status: ChatNotificationAuthorization?
        client.authorizationStatus { status = $0 }
        XCTAssertEqual(status, .unavailable)

        var request: ChatNotificationAuthorizationRequest?
        client.requestAuthorization { request = $0 }
        XCTAssertEqual(request, .unavailable, "An unbundled process must fail closed without prompting.")
    }

    func testOnlyTheDefaultNotificationClickOpensAChat() {
        let userInfo: [AnyHashable: Any] = [
            "chat_id": "chat-1",
            "origin": origin.canonicalKey,
        ]
        XCTAssertEqual(
            NotificationResponsePolicy.target(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: userInfo
            ),
            ChatNotificationTarget(chatID: "chat-1", origin: origin.canonicalKey)
        )
        XCTAssertNil(
            NotificationResponsePolicy.target(
                actionIdentifier: UNNotificationDismissActionIdentifier,
                userInfo: userInfo
            ),
            "Dismiss must never navigate."
        )
        XCTAssertNil(
            NotificationResponsePolicy.target(
                actionIdentifier: "CUSTOM_ACTION",
                userInfo: userInfo
            ),
            "A custom action must never navigate."
        )
        XCTAssertNil(
            NotificationResponsePolicy.target(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: ["chat_id": "chat-1"]
            )
        )
    }

    // MARK: Socket authentication and lifecycle

    func testStreamStatusDescribesWaitingSignInConnectingAndRetry() async {
        let status = AppSessionStatus()
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(controller.streamStatus, .notConnected)

        status.reportConnected(origin, dataStore: WKWebsiteDataStore.nonPersistent())
        await settle()
        XCTAssertEqual(controller.streamStatus, .waitingForAuthentication)

        provider.cookies = [makeCookie()]
        controller.refreshIfNeeded()
        await settle()
        XCTAssertEqual(transport.opens.count, 1)
        XCTAssertEqual(controller.streamStatus, .connecting)

        transport.opens[0].connection.emit(.snapshot(activeChatIDs: []))
        XCTAssertEqual(controller.streamStatus, .ready)

        transport.opens[0].connection.close(.failed)
        await settle()
        XCTAssertEqual(controller.streamStatus, .retrying)

        status.reportDisconnected()
        await settle()
        XCTAssertEqual(controller.streamStatus, .notConnected)
        controller.stop()
    }

    func testSocketCloseReasonsMapToTruthfulMenuStates() async {
        let cases: [(EventStreamCloseReason, ChatNotificationStreamStatus)] = [
            (.unauthorized, .waitingForAuthentication),
            (.forbiddenOrigin, .originRejected),
            (.redirected, .redirected),
            (.authenticationRefused, .authenticationRefused),
            (.invalidMessage, .protocolError),
            (.ended, .retrying),
            (.failed, .retrying),
        ]

        for (reason, expected) in cases {
            let status = connectedStatus(origin)
            let client = FakeNotificationClient()
            client.authorization = .authorized
            let preferences = MemoryNotificationPreference(true)
            let provider = NotificationFakeCookieProvider()
            provider.cookies = [makeCookie()]
            let transport = NotificationFakeTransport()
            let controller = makeController(
                status: status,
                client: client,
                preferences: preferences,
                provider: provider,
                transport: transport
            )

            controller.start()
            await settle()
            XCTAssertEqual(transport.opens.count, 1, "Expected one socket before \(reason)")
            transport.opens[0].connection.close(reason)
            await settle()

            XCTAssertEqual(controller.streamStatus, expected, "Close reason \(reason) must be reported truthfully")
            XCTAssertEqual(
                transport.opens.count,
                1,
                "A terminal \(reason) must not be retried behind the user's back."
            )
            controller.stop()
        }
    }

    func testUnauthorizedCloseKeepsTheExplicitOptOutAndSignInRecovery() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        transport.opens[0].connection.close(.unauthorized)
        await settle()

        XCTAssertEqual(controller.streamStatus, .waitingForAuthentication)
        XCTAssertEqual(controller.state, .on)

        // The stream failure must not remove the user's explicit opt-out.
        controller.performMenuAction()
        await settle()
        XCTAssertEqual(controller.state, .off)
        XCTAssertFalse(preferences.isEnabled)
        controller.stop()
    }

    func testForbiddenAndRedirectedClosuresDoNotAutoRetry() async {
        for reason in [EventStreamCloseReason.forbiddenOrigin, .redirected] {
            let status = connectedStatus(origin)
            let client = FakeNotificationClient()
            client.authorization = .authorized
            let preferences = MemoryNotificationPreference(true)
            let provider = NotificationFakeCookieProvider()
            provider.cookies = [makeCookie()]
            let transport = NotificationFakeTransport()
            let controller = makeController(
                status: status,
                client: client,
                preferences: preferences,
                provider: provider,
                transport: transport
            )

            controller.start()
            await settle()
            transport.opens[0].connection.close(reason)
            await settle()
            XCTAssertEqual(transport.opens.count, 1, "\(reason) must not be silently retried.")

            // Opening the menu may retry once, but only the same selected origin.
            controller.refreshIfNeeded()
            await settle()
            XCTAssertEqual(transport.opens.count, 2)
            XCTAssertEqual(transport.opens[1].origin.canonicalKey, origin.canonicalKey)
            controller.stop()
        }
    }

    func testEnabledNotificationsWaitForAConnection() async {
        let status = AppSessionStatus()
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        XCTAssertEqual(controller.state, .on)
        XCTAssertTrue(transport.opens.isEmpty, "No socket before the app has a selected origin.")

        status.reportConnected(origin, dataStore: WKWebsiteDataStore.nonPersistent())
        await settle()
        XCTAssertEqual(transport.opens.count, 1)
        let connection = transport.opens[0].connection

        status.reportDisconnected()
        await settle()
        XCTAssertEqual(connection.cancelCount, 1)
        controller.stop()
    }

    func testNoSocketIsAttemptedWithoutAPerConnectionSessionCookie() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()

        XCTAssertEqual(controller.state, .on)
        XCTAssertTrue(transport.opens.isEmpty)
        XCTAssertEqual(provider.requestedURLs.first?.absoluteString, "ws://127.0.0.1:8443/ws/events")

        provider.cookies = [makeCookie()]
        controller.refreshIfNeeded()
        await settle()

        XCTAssertEqual(transport.opens.count, 1, "A later sign-in recovers without a new opt-in.")
        XCTAssertEqual(transport.opens[0].origin.canonicalKey, origin.canonicalKey)
        XCTAssertEqual(transport.opens[0].cookieHeader, "ciao_session=secret")
        controller.stop()
    }

    func testSocketCarriesOnlyTheExactSessionCookie() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [
            makeCookie(),
            makeCookie(name: "other", value: "not-a-credential"),
        ]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()

        let url = EventStreamEndpoint.url(origin: origin)!
        XCTAssertEqual(
            EventStreamEndpoint.cookieHeader(for: url, cookies: provider.cookies, now: Date(timeIntervalSince1970: 1_000_000)),
            "ciao_session=secret"
        )
        XCTAssertEqual(transport.opens.count, 1)
        XCTAssertEqual(transport.opens[0].cookieHeader, "ciao_session=secret")
        XCTAssertEqual(provider.requestedURLs, [EventStreamEndpoint.url(origin: origin)!])
        controller.stop()
    }

    func testDisconnectCancelsTheSocketAndDropsLateEvents() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        let connection = transport.opens[0].connection
        connection.emit(.snapshot(activeChatIDs: []))

        status.reportDisconnected()
        await settle()

        XCTAssertEqual(connection.cancelCount, 1)
        connection.emit(.resultReady(chatID: "chat-1", title: "Old", snippet: "Old answer"))
        XCTAssertTrue(client.delivered.isEmpty, "A stale connection cannot notify after disconnect.")
        controller.stop()
    }

    func testTurningNotificationsOffCancelsAndForgetsThePreference() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        let connection = transport.opens[0].connection

        controller.performMenuAction()
        await settle()

        XCTAssertEqual(controller.state, .off)
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertEqual(connection.cancelCount, 1)
        connection.emit(.snapshot(activeChatIDs: []))
        connection.emit(.resultReady(chatID: "chat-1", title: "Late", snippet: "Late"))
        XCTAssertTrue(client.delivered.isEmpty)
        controller.stop()
    }

    // MARK: Baseline, backlog and deduplication

    func testSnapshotIsABaselineAndEventsBeforeItNeverNotify() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        let connection = transport.opens[0].connection

        connection.emit(.resultReady(chatID: "chat-1", title: "Backlog", snippet: "Never announce this"))
        XCTAssertTrue(client.delivered.isEmpty, "No result before the snapshot is a live result.")

        connection.emit(.snapshot(activeChatIDs: ["chat-1"]))
        XCTAssertTrue(client.delivered.isEmpty, "The snapshot itself is never a banner.")

        connection.emit(.resultReady(chatID: "chat-1", title: "Fresh", snippet: "A real answer"))
        XCTAssertEqual(client.delivered.count, 1)
        XCTAssertEqual(client.delivered[0].title, "Fresh")
        controller.stop()
    }

    func testTheSameResultIsAnnouncedOnceAndANewTurnCanRepeatIt() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        let connection = transport.opens[0].connection
        connection.emit(.snapshot(activeChatIDs: []))

        let result = ChatEvent.resultReady(chatID: "chat-1", title: "Same", snippet: "Same")
        connection.emit(result)
        connection.emit(result)
        XCTAssertEqual(client.delivered.count, 1, "A duplicated event is not a second completion.")

        connection.emit(.streamingStarted(chatID: "chat-1"))
        connection.emit(result)
        XCTAssertEqual(client.delivered.count, 2, "A new turn may legitimately repeat the same text.")
        controller.stop()
    }

    func testMemoryPassLikeTitleIsNotHeuristicallySuppressed() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        let connection = transport.opens[0].connection
        connection.emit(.snapshot(activeChatIDs: []))
        // The event has no helper kind. A title-prefix heuristic would hide a
        // legitimate chat with this title, so the client does not guess.
        connection.emit(.resultReady(
            chatID: "chat-1",
            title: "Memory pass · Archived discussion",
            snippet: "Filed two notes"
        ))
        XCTAssertEqual(client.delivered.count, 1)
        controller.stop()
    }

    func testReconnectStartsANewBaselineAndOldGenerationCannotNotify() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        let first = transport.opens[0].connection
        first.emit(.snapshot(activeChatIDs: []))
        first.emit(.resultReady(chatID: "chat-1", title: "First", snippet: "Done"))
        XCTAssertEqual(client.delivered.count, 1)

        status.reportDisconnected()
        await settle()
        status.reportConnected(origin, dataStore: WKWebsiteDataStore.nonPersistent())
        await settle()

        XCTAssertEqual(transport.opens.count, 2)
        let second = transport.opens[1].connection

        // A late event from the previous socket must not notify.
        first.emit(.resultReady(chatID: "chat-2", title: "Stale", snippet: "Stale"))
        XCTAssertEqual(client.delivered.count, 1)

        // A reconnect's snapshot is a baseline: active streams are not backlog
        // banners, and a completion after it is fresh.
        second.emit(.snapshot(activeChatIDs: ["chat-2"]))
        XCTAssertEqual(client.delivered.count, 1)
        second.emit(.resultReady(chatID: "chat-2", title: "Fresh", snippet: "Done"))
        XCTAssertEqual(client.delivered.count, 2)
        controller.stop()
    }

    func testIdenticalResultAfterReconnectIsStillSuppressed() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        let result = ChatEvent.resultReady(chatID: "chat-1", title: "Same", snippet: "Same")
        transport.opens[0].connection.emit(.snapshot(activeChatIDs: []))
        transport.opens[0].connection.emit(result)
        XCTAssertEqual(client.delivered.count, 1)

        status.reportDisconnected()
        await settle()
        status.reportConnected(origin, dataStore: WKWebsiteDataStore.nonPersistent())
        await settle()
        XCTAssertEqual(transport.opens.count, 2)
        let second = transport.opens[1].connection
        second.emit(.snapshot(activeChatIDs: []))
        second.emit(result)
        XCTAssertEqual(client.delivered.count, 1, "A duplicate replayed after reconnect is not a new completion.")

        second.emit(.streamingStarted(chatID: "chat-1"))
        second.emit(result)
        XCTAssertEqual(client.delivered.count, 2, "A new turn clears the remembered result.")
        controller.stop()
    }

    func testPermissionResetStopsTheSocketAndRequiresANewClick() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        let connection = transport.opens[0].connection
        XCTAssertEqual(controller.state, .on)

        client.authorization = .notDetermined
        controller.refreshIfNeeded()
        await settle()

        XCTAssertEqual(controller.state, .off)
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertEqual(connection.cancelCount, 1)
        XCTAssertEqual(transport.opens.count, 1, "A reset permission must not start another socket.")
        controller.stop()
    }

    func testClosedSocketCanBeRetriedFromTheMenu() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        XCTAssertEqual(controller.state, .on)
        XCTAssertTrue(status.isConnected)
        XCTAssertNotNil(status.dataStore)
        XCTAssertEqual(provider.requestedURLs.count, 1)
        XCTAssertEqual(transport.opens.count, 1, "Expected an authenticated socket for the retry test.")
        guard let firstConnection = transport.opens.first?.connection else {
            XCTFail("No socket was opened")
            return
        }
        firstConnection.close(.failed)
        await settle()
        XCTAssertEqual(transport.opens.count, 1)

        controller.refreshIfNeeded()
        await settle()
        XCTAssertEqual(transport.opens.count, 2)
        controller.stop()
    }

    // MARK: Click handling

    func testNotificationClickOpensOnlyTheSameOriginAndASafeChatID() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        var presented = 0
        var opened: [String] = []
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport,
            present: { presented += 1 },
            openChat: { opened.append($0); return true }
        )

        controller.start()
        await settle()
        let connection = transport.opens[0].connection
        connection.emit(.snapshot(activeChatIDs: []))
        connection.emit(.resultReady(chatID: "chat-1", title: "Answer", snippet: "Done"))

        let target = try! XCTUnwrap(client.delivered.first?.target)
        XCTAssertEqual(target.origin, origin.canonicalKey)

        client.activate(target)
        XCTAssertEqual(presented, 1)
        XCTAssertEqual(opened, ["chat-1"])

        client.activate(ChatNotificationTarget(chatID: "chat-1", origin: remote.canonicalKey))
        XCTAssertEqual(presented, 2, "A valid click presents the window even when it needs to wait.")
        XCTAssertEqual(opened, ["chat-1"], "A notification from another origin must not navigate.")

        client.activate(ChatNotificationTarget(chatID: "../escape", origin: origin.canonicalKey))
        XCTAssertEqual(presented, 2, "An invalid target is refused before it can present or wait.")
        XCTAssertEqual(opened, ["chat-1"])

        status.reportDisconnected()
        await settle()
        client.activate(target)
        XCTAssertEqual(presented, 3)
        XCTAssertEqual(opened, ["chat-1"], "A click never signs in or reconnects.")
        XCTAssertFalse(status.isConnected)

        // A different origin must not consume the retained target.
        status.reportConnected(remote, dataStore: WKWebsiteDataStore.nonPersistent())
        await settle()
        XCTAssertEqual(opened, ["chat-1"])

        // The next manual connection to the exact origin opens the retained chat.
        status.reportConnected(origin, dataStore: WKWebsiteDataStore.nonPersistent())
        await settle()
        XCTAssertEqual(opened, ["chat-1", "chat-1"])
        controller.stop()
    }

    func testSessionQueuesAChosenChatAfterAnOriginChange() {
        let status = AppSessionStatus()
        status.reportConnected(remote)
        let wrong = WKWebView(frame: .zero, configuration: {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            return configuration
        }())
        status.attachWebView(wrong, for: remote)

        status.reportConnected(origin)
        XCTAssertTrue(status.openChat(chatID: "chat-1"))

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let delegate = RecordingNotificationNavigationDelegate()
        webView.navigationDelegate = delegate
        status.attachWebView(webView, for: origin)

        XCTAssertTrue(waitUntil(timeout: 2) { delegate.requestedURL != nil })
        XCTAssertEqual(delegate.requestedURL?.absoluteString, "http://127.0.0.1:8443/chat/chat-1")
    }

    func testColdLaunchClickWaitsForExactOriginAndWebViewAttach() async throws {
        let status = AppSessionStatus()
        let client = FakeNotificationClient()
        let preferences = MemoryNotificationPreference(false)
        let provider = NotificationFakeCookieProvider()
        let transport = NotificationFakeTransport()
        var presented = 0
        var opened: [String] = []
        var openResults: [Bool] = []
        let controller = ChatNotificationController(
            status: status,
            permission: client,
            preferences: preferences,
            transport: transport,
            cookieProviderFactory: { _ in provider },
            presentWindow: { presented += 1 },
            openChat: { chatID in
                let accepted = status.openChat(chatID: chatID)
                opened.append(chatID)
                openResults.append(accepted)
                return accepted
            },
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        controller.start()
        await settle()

        let target = ChatNotificationTarget(chatID: "chat-1", origin: origin.canonicalKey)
        client.activate(target)
        XCTAssertEqual(presented, 1, "A cold-launch click presents the window immediately.")
        XCTAssertFalse(status.isConnected)
        XCTAssertTrue(transport.opens.isEmpty, "A cold-launch click must not autoconnect or authenticate.")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let wrongWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        let wrongNavigation = RecordingNotificationNavigationDelegate()
        wrongWebView.navigationDelegate = wrongNavigation

        // A different origin is not the retained target and must not navigate.
        status.reportConnected(remote, dataStore: WKWebsiteDataStore.nonPersistent())
        await settle()
        status.attachWebView(wrongWebView, for: remote)
        XCTAssertFalse(
            waitUntil(timeout: 0.3) { wrongNavigation.requestedURL != nil },
            "A different origin must not open the retained chat."
        )

        // Connecting the exact origin only queues the navigation until the view attaches.
        status.reportConnected(origin, dataStore: WKWebsiteDataStore.nonPersistent())
        await settle()
        XCTAssertEqual(opened, ["chat-1"], "The retained target is applied only on the exact origin.")
        XCTAssertEqual(openResults, [true])
        XCTAssertNil(wrongNavigation.requestedURL, "The previous origin's view must never be navigated.")

        let exactConfiguration = WKWebViewConfiguration()
        exactConfiguration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: exactConfiguration)
        let navigation = RecordingNotificationNavigationDelegate()
        webView.navigationDelegate = navigation
        XCTAssertNil(navigation.requestedURL, "The chat waits for the matching web view to attach.")

        status.attachWebView(webView, for: origin)
        XCTAssertEqual(status.currentOrigin?.canonicalKey, origin.canonicalKey)
        let navigated = await waitUntilAsync(timeout: 2) { navigation.requestedURL != nil }
        XCTAssertTrue(navigated, "No navigation was requested after attach: \(String(describing: navigation.requestedURL))")
        XCTAssertEqual(navigation.requestedURL?.scheme, "http")
        XCTAssertEqual(navigation.requestedURL?.host, "127.0.0.1")
        XCTAssertEqual(navigation.requestedURL?.port, 8443)
        XCTAssertEqual(navigation.requestedURL?.path, "/chat/chat-1")
        XCTAssertEqual(presented, 1, "Waiting and attaching do not re-present the window.")
        XCTAssertTrue(transport.opens.isEmpty, "Notifications stayed off; no event-stream credentials were sent.")
        controller.stop()
    }

    func testDeliveredTextIsSanitizedAndCarriesOnlyChatAndOrigin() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        let connection = transport.opens[0].connection
        connection.emit(.snapshot(activeChatIDs: []))
        connection.emit(.resultReady(
            chatID: "chat-1",
            title: "Hello\nWorld\u{202E}",
            snippet: "Done\u{0007} now"
        ))

        let message = try! XCTUnwrap(client.delivered.first)
        XCTAssertEqual(message.title, "Hello World")
        XCTAssertEqual(message.body, "Done now")
        XCTAssertEqual(message.target, ChatNotificationTarget(chatID: "chat-1", origin: origin.canonicalKey))
        XCTAssertEqual(
            message.identifier,
            ChatNotificationController.notificationIdentifier(origin: origin.canonicalKey, chatID: "chat-1")
        )
        XCTAssertNotEqual(
            message.identifier,
            ChatNotificationController.notificationIdentifier(origin: remote.canonicalKey, chatID: "chat-1")
        )
        controller.stop()
    }

    func testIgnoredEventsDoNothing() async {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        client.authorization = .authorized
        let preferences = MemoryNotificationPreference(true)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )

        controller.start()
        await settle()
        let connection = transport.opens[0].connection
        connection.emit(.snapshot(activeChatIDs: []))
        connection.emit(.ignored)
        XCTAssertTrue(client.delivered.isEmpty)
        controller.stop()
    }

    func testMenuRowTogglesTheRealNotificationController() async throws {
        let status = connectedStatus(origin)
        let client = FakeNotificationClient()
        let preferences = MemoryNotificationPreference(false)
        let provider = NotificationFakeCookieProvider()
        provider.cookies = [makeCookie()]
        let transport = NotificationFakeTransport()
        let controller = makeController(
            status: status,
            client: client,
            preferences: preferences,
            provider: provider,
            transport: transport
        )
        let menuBar = MenuBarController(
            status: status,
            statusItemFactory: NotificationFakeStatusItemFactory(),
            openWindow: {},
            quit: {},
            notifications: controller
        )

        menuBar.start()
        controller.start()
        await settle()

        let offItem = try XCTUnwrap(menuBar.menu?.deepItem(withTitle: MenuBarController.notificationsOffTitle))
        menuBar.toggleNotifications(offItem)
        await settle()

        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(client.requestCount, 1)
        XCTAssertEqual(controller.streamStatus, .connecting)
        XCTAssertNotNil(menuBar.menu?.deepItem(withTitle: MenuBarController.notificationsConnectingTitle))
        XCTAssertEqual(transport.opens.count, 1)

        transport.opens[0].connection.emit(.snapshot(activeChatIDs: []))
        await settle()
        let onItem = try XCTUnwrap(menuBar.menu?.deepItem(withTitle: MenuBarController.notificationsOnTitle))
        XCTAssertEqual(onItem.state, .on)
        menuBar.stop()
    }
}
