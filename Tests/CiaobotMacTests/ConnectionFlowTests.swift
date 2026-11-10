import XCTest
import Combine
import Foundation
import WebKit
import SwiftUI
import AppKit

@testable import CiaobotMac

/// Connect and forget share one screen and one stored sign-in. They must never
/// overlap, including when Return starts a connect while a forget is running.
final class ConnectionTaskGateTests: XCTestCase {
    func testReturnCannotStartAProbeWhileForgetIsRunning() {
        var gate = ConnectionTaskGate()
        XCTAssertTrue(gate.beginForget())
        XCTAssertTrue(gate.isBusy)
        XCTAssertFalse(gate.beginCheck(), "Return started a probe while forget was running")
        XCTAssertEqual(gate.task, .forgetting)
    }

    func testForgetCannotStartWhileAProbeIsRunning() {
        var gate = ConnectionTaskGate()
        XCTAssertTrue(gate.beginCheck())
        XCTAssertFalse(gate.beginForget(), "Forget started while the probe was still running")
        XCTAssertEqual(gate.task, .checking)
    }

    func testARepeatedConnectCannotStartTwice() {
        var gate = ConnectionTaskGate()
        XCTAssertTrue(gate.beginCheck())
        XCTAssertFalse(gate.beginCheck())
        XCTAssertFalse(gate.beginForget())
    }

    func testTheGateReopensOnlyForTheMatchingCompletion() {
        var gate = ConnectionTaskGate()
        XCTAssertTrue(gate.beginCheck())
        gate.endForget()
        XCTAssertEqual(gate.task, .checking, "A foreign completion must not clear the current task")

        gate.endCheck()
        XCTAssertEqual(gate.task, .idle)
        XCTAssertTrue(gate.beginForget())
        gate.endCheck()
        XCTAssertEqual(gate.task, .forgetting)
        gate.endForget()
        XCTAssertEqual(gate.task, .idle)
    }

    func testBothOperationsAreAvailableAgainAfterCompletion() {
        var gate = ConnectionTaskGate()
        XCTAssertTrue(gate.beginCheck())
        gate.endCheck()
        XCTAssertTrue(gate.beginForget())
        gate.endForget()
        XCTAssertTrue(gate.beginCheck())
    }
}

final class PersistentSignInCopyTests: XCTestCase {
    private let https = Origin("https://example.com")!
    private let http = Origin("http://127.0.0.1:8443")!

    func testEveryExplanationSaysWhatIsMissing() {
        XCTAssertTrue(PersistentSignInCopy.explanation(origin: nil, persistentAvailable: true, registryAvailable: true).contains("HTTPS"))
        XCTAssertTrue(PersistentSignInCopy.explanation(origin: http, persistentAvailable: true, registryAvailable: true).contains("HTTPS-only"))
        XCTAssertTrue(PersistentSignInCopy.explanation(origin: https, persistentAvailable: false, registryAvailable: true).contains("macOS 14"))
        XCTAssertTrue(PersistentSignInCopy.explanation(origin: https, persistentAvailable: true, registryAvailable: false).contains("saved sign-in list"))
        XCTAssertTrue(PersistentSignInCopy.explanation(origin: https, persistentAvailable: true, registryAvailable: true).contains("WebKit store"))
    }

    func testCorruptRegistryCopyDoesNotSuggestDeletingTheOnlyRecord() {
        let explanation = PersistentSignInCopy.explanation(origin: https, persistentAvailable: true, registryAvailable: false)
        let fallback = SessionStorageFallback.registryUnavailable.userMessage

        for text in [explanation, fallback] {
            let lowered = text.lowercased()
            XCTAssertFalse(lowered.contains("delete it to"), "Copy suggests deleting the only mapping record: \(text)")
            XCTAssertFalse(lowered.contains("remove it to"), "Copy suggests removing the only mapping record: \(text)")
            XCTAssertFalse(lowered.contains("delete the file"), "Copy suggests deleting the only mapping record: \(text)")
            XCTAssertFalse(lowered.contains("remove the file"), "Copy suggests removing the only mapping record: \(text)")
            XCTAssertTrue(lowered.contains("do not delete") || lowered.contains("lose the record") || lowered.contains("only record"),
                          "Copy does not warn that the list is the only record: \(text)")
        }
    }

    func testHealthyCopyDoesNotPromiseCrossPortCookieIsolation() {
        let text = PersistentSignInCopy.explanation(origin: https, persistentAvailable: true, registryAvailable: true)
        XCTAssertFalse(text.lowercased().contains("different port"),
                       "The UI must not promise isolation from subresources on another port: \(text)")
        XCTAssertFalse(text.lowercased().contains("never shared"),
                       "The UI must not promise absolute cookie isolation: \(text)")
    }
}

/// Persistence may only start on where it can actually work: an HTTPS origin
/// with persistent stores available. Everywhere else stays off even when the
/// stored explicit choice says otherwise, because the choice cannot create a
/// store the system will not provide.
final class PersistentSignInDefaultTests: XCTestCase {
    private let https = Origin("https://example.com")!
    private let http = Origin("http://127.0.0.1:8443")!

    func testPersistentSignInDefaultsOnForHTTPSWhenAvailable() {
        let enabled = PersistentSignInDefault.isEnabled(
            origin: https,
            persistentAvailable: true,
            explicitChoice: nil
        )

        XCTAssertTrue(enabled, "An HTTPS origin with persistent stores should arrive opted in")
    }

    func testPersistentSignInDefaultsOffForHTTPSWithoutPersistentStores() {
        let enabled = PersistentSignInDefault.isEnabled(
            origin: https,
            persistentAvailable: false,
            explicitChoice: nil
        )

        XCTAssertFalse(enabled, "macOS 13 has no named WebKit stores, so the default must stay off")
    }

    func testPersistentSignInDefaultsOffForPlainHTTP() {
        let enabled = PersistentSignInDefault.isEnabled(
            origin: http,
            persistentAvailable: true,
            explicitChoice: nil
        )

        XCTAssertFalse(enabled, "HTTP always uses an in-memory store, so the default must stay off")
    }

    func testExplicitChoiceWinsOverTheDefault() {
        XCTAssertFalse(PersistentSignInDefault.isEnabled(
            origin: https,
            persistentAvailable: true,
            explicitChoice: false
        ), "Turning persistence off for an HTTPS origin must be honoured")

        XCTAssertTrue(PersistentSignInDefault.isEnabled(
            origin: https,
            persistentAvailable: true,
            explicitChoice: true
        ), "An explicit opt-in for an HTTPS origin must be honoured")
    }

    func testExplicitChoiceCannotEnablePersistenceWhereItIsImpossible() {
        XCTAssertFalse(PersistentSignInDefault.isEnabled(
            origin: https,
            persistentAvailable: false,
            explicitChoice: true
        ), "No stored choice may enable persistence on a system without named stores")

        XCTAssertFalse(PersistentSignInDefault.isEnabled(
            origin: http,
            persistentAvailable: true,
            explicitChoice: true
        ), "No stored choice may enable persistence for an HTTP origin")

        XCTAssertFalse(PersistentSignInDefault.isEnabled(
            origin: nil,
            persistentAvailable: true,
            explicitChoice: true
        ), "No stored choice may enable persistence before an address is entered")
    }
}

final class OriginSignInChoiceTests: XCTestCase {
    func testConsentIsScopedToCanonicalOriginAndCapturedForAsyncProbe() throws {
        let originA = try XCTUnwrap(Origin("https://a.example:443"))
        let originB = try XCTUnwrap(Origin("https://b.example:443"))
        let explicitOff = OriginSignInChoice(origin: originA, isEnabled: false)
        let explicitOn = OriginSignInChoice(origin: originA, isEnabled: true)

        XCTAssertEqual(explicitOff.value(for: originA), false)
        XCTAssertNil(explicitOff.value(for: originB), "A different HTTPS origin inherited explicit consent")
        XCTAssertNil(explicitOn.value(for: try XCTUnwrap(Origin("http://127.0.0.1:8443"))),
                     "Loopback inherited explicit consent")
    }
}

/// Only a connection that actually answered is remembered, and a remembered
/// origin always comes back prefilled. The probe is injected so the test never
/// contacts anything.
@MainActor
final class ConnectionRememberingTests: XCTestCase {
    private final class StubProbe: ProbeChecking {
        private let responds: Bool
        private(set) var checked: [Origin] = []

        init(responds: Bool) {
            self.responds = responds
        }

        func check(_ origin: Origin, completion: @escaping (Bool) -> Void) {
            checked.append(origin)
            completion(responds)
        }
    }

    private final class NoopEraser: WebsiteDataStoreErasing {
        func remove(identifier: UUID, completion: @escaping (Error?) -> Void) {
            completion(nil)
        }
    }

    @MainActor
    private final class FakeHostStore: HostListStoring {
        private(set) var added: [Origin] = []
        var hosts: [HostRecord] = []

        func add(_ origin: Origin) {
            added.append(origin)
            let record = HostRecord(origin: origin.canonicalKey,
                                    label: HostRecord.defaultLabel(for: origin.canonicalKey))
            if !hosts.contains(record) { hosts.append(record) }
        }

        func remove(_ origin: Origin) {
            hosts.removeAll { $0.origin == origin.canonicalKey }
        }

        func rename(_ origin: Origin, label: String) {
            guard let index = hosts.firstIndex(where: { $0.origin == origin.canonicalKey }) else { return }
            hosts[index].label = label
        }
    }

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: UserDefaultsLastServerStore!
    private var hostStore: FakeHostStore!
    private var registryURL: URL!

    override func setUp() {
        super.setUp()
        suiteName = "CiaobotMacTests.ConnectionRemembering.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = UserDefaultsLastServerStore(defaults: defaults)
        hostStore = FakeHostStore()
        registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CiaobotMacTests-Registry-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("registry.json")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        hostStore = nil
        if let registryURL { try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent()) }
        super.tearDown()
    }

    private func makeView(probe: ProbeChecking) -> ConnectionView {
        let signIn = SessionSignIn(
            registry: SessionStoreRegistry(fileURL: registryURL),
            eraser: NoopEraser(),
            persistentAvailable: false
        )
        return ConnectionView(probe: probe, signIn: signIn, lastServer: store, hostStore: hostStore)
    }

    private final class DeferredProbe: ProbeChecking {
        var checked: [Origin] = []
        var completions: [(Bool) -> Void] = []
        func check(_ origin: Origin, completion: @escaping (Bool) -> Void) {
            checked.append(origin)
            completions.append(completion)
        }
        func finish(_ result: Bool) { completions.removeFirst()(result) }
    }

    private final class WindowCapture { var arguments: MainWindowArguments? }

    private func flush() {
        let rendered = expectation(description: "SwiftUI update")
        DispatchQueue.main.async { rendered.fulfill() }
        wait(for: [rendered], timeout: 2)
    }

    private func waitUntil(_ description: String, _ condition: @escaping () -> Bool) {
        let predicate = NSPredicate { _, _ in condition() }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        expectation.expectationDescription = description
        wait(for: [expectation], timeout: 3)
    }

    private func host(_ presentation: ConnectionPresentation, probe: ProbeChecking,
                      target: Origin? = nil, signIn: SessionSignIn? = nil,
                      capture: WindowCapture = WindowCapture()) -> NSWindow {
        let signIn = signIn ?? SessionSignIn(registry: SessionStoreRegistry(fileURL: registryURL), eraser: NoopEraser(), persistentAvailable: true)
        let policy = ConnectionLaunchPolicy(initialAddress: presentation.address, autoConnectTarget: target, isTestLaunch: false, diagnostic: nil)
        let view = ConnectionView(probe: probe, signIn: signIn, autoDiscovery: false, lastServer: store, hostStore: hostStore,
                                  mainWindow: { args in capture.arguments = args; return AnyView(Text("Connected")) },
                                  launchPolicy: policy, presentation: presentation)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        flush()
        return window
    }

    private func close(_ window: NSWindow) { window.close(); window.contentView = nil }

    func testFailedAutomaticRemoteProbeOpensDisclosureOnce() throws {
        let target = try XCTUnwrap(Origin("https://remote.example:8443"))
        let state = ConnectionPresentation(initialAddress: target.url.absoluteString)
        let probe = DeferredProbe()
        let window = host(state, probe: probe, target: target)
        defer { close(window) }
        XCTAssertFalse(state.remoteControlsExpanded)
        XCTAssertEqual(probe.checked.map(\.canonicalKey), [target.canonicalKey])
        probe.finish(false)
        flush()
        XCTAssertTrue(state.remoteControlsExpanded)
        XCTAssertEqual(Origin(state.address)?.canonicalKey, target.canonicalKey)
        XCTAssertNotNil(state.error)
        state.address = target.url.absoluteString + "/"
        flush()
        XCTAssertEqual(probe.checked.count, 1)
    }

    func testChangeServerAfterRemoteConnectionRestoresConnectedRemoteDraft() throws {
        let state = ConnectionPresentation(initialAddress: "https://a.example")
        let probe = DeferredProbe()
        let capture = WindowCapture()
        let window = host(state, probe: probe, capture: capture)
        defer { close(window) }
        state.consentAction?(false)
        state.connectAction?()
        state.address = "https://b.example"
        probe.finish(true)
        flush()
        XCTAssertEqual(capture.arguments?.origin.canonicalKey, "https://a.example:443")
        NotificationCenter.default.post(name: .ciaobotChangeServer, object: nil)
        flush()
        XCTAssertEqual(Origin(state.address)?.canonicalKey, "https://a.example:443")
        XCTAssertNil(state.keepSignedInChoice)
    }

    func testMainWindowFailuresRouteByConnectionFlow() throws {
        let state = ConnectionPresentation(initialAddress: "https://remote.example")
        let probe = DeferredProbe()
        let capture = WindowCapture()
        let window = host(state, probe: probe, capture: capture)
        defer { close(window) }
        state.connectAction?(); probe.finish(true); flush()
        try XCTUnwrap(capture.arguments).onFailure("remote failed")
        flush()
        XCTAssertTrue(state.remoteControlsExpanded)
        XCTAssertEqual(state.error, "remote failed")
        state.remoteControlsExpanded = false
        let local = try XCTUnwrap(Origin("http://127.0.0.1:8444"))
        state.localConnectAction?(local); probe.finish(true); flush()
        try XCTUnwrap(capture.arguments).onFailure("local failed")
        flush()
        XCTAssertFalse(state.remoteControlsExpanded)
        XCTAssertEqual(state.localError, "local failed")
        XCTAssertEqual(state.failedLocalTarget?.canonicalKey, local.canonicalKey)
        state.retryAction?()
        XCTAssertEqual(probe.checked.last?.canonicalKey, local.canonicalKey)
        probe.finish(false)
        XCTAssertNotNil(state.localError)
    }

    func testConsentIsScopedToCanonicalOriginAndCapturedForAsyncProbe() throws {
        let state = ConnectionPresentation(initialAddress: "https://a.example")
        let probe = DeferredProbe()
        let capture = WindowCapture()
        let window = host(state, probe: probe, capture: capture)
        defer { close(window) }
        state.consentAction?(false)
        state.address = "https://b.example"; flush()
        state.connectAction?(); probe.finish(true)
        waitUntil("B connects") { capture.arguments?.origin.canonicalKey == "https://b.example:443" }
        guard case .persistent = try XCTUnwrap(capture.arguments).storage else { return XCTFail("B did not use its HTTPS default: \(String(describing: state.storageNotice)), choice \(String(describing: state.keepSignedInChoice))") }
        NotificationCenter.default.post(name: .ciaobotChangeServer, object: nil); flush()
        state.address = "https://a.example"; flush()
        state.consentAction?(true)
        state.localConnectAction?(try XCTUnwrap(Origin("http://127.0.0.1:8444")))
        probe.finish(true)
        waitUntil("local connects") { capture.arguments?.origin.canonicalKey == "http://127.0.0.1:8444" }
        XCTAssertEqual(capture.arguments?.storage, .ephemeral)
        NotificationCenter.default.post(name: .ciaobotChangeServer, object: nil); flush()
        state.address = "https://a.example"; flush()
        state.consentAction?(false)
        state.connectAction?()
        state.address = "https://b.example"; flush()
        probe.finish(true)
        waitUntil("A connects") { capture.arguments?.origin.canonicalKey == "https://a.example:443" }
        XCTAssertEqual(capture.arguments?.origin.canonicalKey, "https://a.example:443")
        XCTAssertEqual(capture.arguments?.storage, .ephemeral)
        XCTAssertNil(state.storageNotice)
        close(window)

        let changedRegistry = SessionStoreRegistry(fileURL: registryURL)
        let signIn = SessionSignIn(registry: changedRegistry, eraser: NoopEraser(), persistentAvailable: true)
        let nextState = ConnectionPresentation(initialAddress: "https://fallback.example")
        let nextProbe = DeferredProbe()
        let nextCapture = WindowCapture()
        let nextWindow = host(nextState, probe: nextProbe, signIn: signIn, capture: nextCapture)
        defer { close(nextWindow) }
        nextState.consentAction?(true)
        nextState.connectAction?()
        try Data("changed elsewhere".utf8).write(to: registryURL)
        nextState.address = "https://other.example"
        flush()
        nextProbe.finish(true)
        waitUntil("fallback renders") { nextCapture.arguments != nil }
        XCTAssertEqual(nextCapture.arguments?.origin.canonicalKey, "https://fallback.example:443")
        XCTAssertEqual(nextCapture.arguments?.storage, .ephemeral)
        XCTAssertEqual(nextState.storageNotice, SessionStorageFallback.registryChangedElsewhere.userMessage)
    }

    func testInvalidDebugLaunchDiagnosticVisibleWhileDisclosureCollapsed() throws {
        #if DEBUG
        final class SpyLastServer: LastServerStoring {
            var reads = 0
            var savedOrigin: Origin? { reads += 1; return nil }
            func remember(_ origin: Origin) { XCTFail("unexpected write") }
            func clear() { XCTFail("unexpected clear") }
        }
        let oldOrigin = getenv("CIAOBOT_MAC_TEST_ORIGIN").map { String(cString: $0) }
        let oldAuto = getenv("CIAOBOT_MAC_TEST_AUTOCONNECT").map { String(cString: $0) }
        defer {
            if let oldOrigin { setenv("CIAOBOT_MAC_TEST_ORIGIN", oldOrigin, 1) } else { unsetenv("CIAOBOT_MAC_TEST_ORIGIN") }
            if let oldAuto { setenv("CIAOBOT_MAC_TEST_AUTOCONNECT", oldAuto, 1) } else { unsetenv("CIAOBOT_MAC_TEST_AUTOCONNECT") }
        }
        unsetenv("CIAOBOT_MAC_TEST_ORIGIN"); setenv("CIAOBOT_MAC_TEST_AUTOCONNECT", "1", 1)
        let spy = SpyLastServer()
        let probe = DeferredProbe()
        let state = ConnectionPresentation(initialAddress: "")
        let signIn = SessionSignIn(registry: SessionStoreRegistry(fileURL: registryURL), eraser: NoopEraser(), persistentAvailable: false)
        let view = ConnectionView(probe: probe, signIn: signIn, autoDiscovery: false, lastServer: spy, hostStore: hostStore,
                                  mainWindow: { _ in AnyView(Text("Connected")) }, presentation: state)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view); window.orderFront(nil); flush()
        defer { close(window) }
        XCTAssertEqual(spy.reads, 0)
        XCTAssertTrue(probe.checked.isEmpty)
        XCTAssertEqual(view.launchAddress, "")
        XCTAssertFalse(state.remoteControlsExpanded)
        XCTAssertEqual(state.launchDiagnostic, "Test mode requires CIAOBOT_MAC_TEST_ORIGIN set to a loopback origin; nothing was contacted.")
        #endif
    }

    func testASuccessfulConnectionRemembersItsOrigin() {
        let probe = StubProbe(responds: true)
        let view = makeView(probe: probe)

        view.connect()

        XCTAssertEqual(probe.checked.count, 1, "The connection screen did not probe exactly once")
        XCTAssertEqual(store.savedOrigin?.canonicalKey, "http://127.0.0.1:8443")
        XCTAssertEqual(hostStore.added.map(\.canonicalKey), ["http://127.0.0.1:8443"],
                       "A successful connection was not recorded in the saved host list")
    }

    func testAFailedConnectionDoesNotRememberTheAddress() {
        let probe = StubProbe(responds: false)
        let view = makeView(probe: probe)

        view.connect()

        XCTAssertEqual(probe.checked.count, 1)
        XCTAssertNil(store.savedOrigin, "A failed attempt was stored as the launch target")
        XCTAssertTrue(hostStore.added.isEmpty, "A failed probe was recorded in the saved host list")
    }

    func testAFailedConnectionLeavesThePreviouslySavedOriginAlone() throws {
        let previous = try XCTUnwrap(Origin("https://remote.example:8443"))
        store.remember(previous)
        let view = makeView(probe: StubProbe(responds: false))

        view.connect()

        XCTAssertEqual(store.savedOrigin?.canonicalKey, previous.canonicalKey)
    }

    func testARememberedOriginPrefillsTheField() throws {
        let saved = try XCTUnwrap(Origin("https://remote.example:8443"))
        store.remember(saved)

        let view = makeView(probe: StubProbe(responds: false))

        XCTAssertEqual(view.launchAddress, saved.url.absoluteString)
    }

    func testNoSavedOriginPrefillsTheLocalCandidate() {
        let view = makeView(probe: StubProbe(responds: false))

        XCTAssertEqual(view.launchAddress, "http://127.0.0.1:8443")
    }
}

@MainActor
final class SessionViewTrackerTests: XCTestCase {
    func testNothingAttachedCountsAsReleased() {
        let tracker = SessionViewTracker()
        var result: Bool?
        tracker.whenReleased(timeout: 1) { result = $0 }
        XCTAssertEqual(result, true, "With no tracked view, forget must not wait")
    }

    func testTrackerWaitsUntilTheTrackedViewIsDeallocated() {
        let tracker = SessionViewTracker()
        var view: NSObject? = NSObject()
        tracker.attach(view!)

        var result: Bool?
        let reported = expectation(description: "release reported")
        tracker.whenReleased(timeout: 5) { ok in
            result = ok
            reported.fulfill()
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertNil(result, "The tracker reported release while the view was still strongly held")
        XCTAssertFalse(tracker.isReleased)

        view = nil
        wait(for: [reported], timeout: 5)
        XCTAssertEqual(result, true)
        XCTAssertTrue(tracker.isReleased)
    }

    func testTrackerTimesOutWhileTheViewIsHeld() {
        let tracker = SessionViewTracker()
        let view = NSObject()
        tracker.attach(view)

        var result: Bool?
        let reported = expectation(description: "tracker timed out")
        tracker.whenReleased(timeout: 0.1) { ok in
            result = ok
            reported.fulfill()
        }

        wait(for: [reported], timeout: 2)
        XCTAssertEqual(result, false, "A view that never releases must not be reported as released")
        withExtendedLifetime(view) {}
    }
}

/// A second host has no session object, so the chat models read a fixed origin
/// and store instead. The session has to keep working as the same context, and
/// its publisher has to fire only after the stored connection it describes.
@MainActor
final class ConnectionFlowTests: XCTestCase {
    func testStaticHostContextReportsItsFixedOriginAndStore() throws {
        let origin = try XCTUnwrap(Origin("https://fixed.example:8443"))
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let context = StaticHostContext(origin: origin, dataStore: dataStore)

        XCTAssertTrue(context.isConnected)
        XCTAssertEqual(context.currentOrigin?.canonicalKey, origin.canonicalKey)
        XCTAssertTrue(context.dataStore === dataStore, "The context must report exactly the store it was given")

        var emissions = 0
        let subscription = context.connectionPublisher.sink { emissions += 1 }
        XCTAssertEqual(emissions, 1, "A fixed host replays its connection once on subscribe")

        let settled = expectation(description: "no repeat emission")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(emissions, 1, "A fixed host must not publish a second connection")

        subscription.cancel()
    }

    func testSessionAsContextPublishesAfterTheStoredConnection() throws {
        let status = AppSessionStatus()
        let context: ConnectionContext = status
        let origin = try XCTUnwrap(Origin("https://remote.example:8443"))

        var observed: Origin?
        let subscription = context.connectionPublisher.sink {
            observed = context.currentOrigin
        }
        XCTAssertNil(observed, "Nothing is connected before the first report")

        status.reportConnected(origin)

        XCTAssertEqual(observed?.canonicalKey, origin.canonicalKey,
                       "Subscribers read currentOrigin after the published connection has settled")
        XCTAssertTrue(context.isConnected)

        subscription.cancel()
    }

    // MARK: Port recovery

    func testOnlyAPortFailureOffersPortRecovery() {
        XCTAssertTrue(NativeInstallPortRecovery.isRecoverable(.installer(.activationRefused)))
        XCTAssertTrue(NativeInstallPortRecovery.isRecoverable(.installer(.serviceNotReady)))

        let downloadFailures: [NativeInstallFailure] = [
            .offline, .timedOut, .httpStatus(500),
            .oversized(bytes: 2_000_000, limit: 1_048_576),
            .insecureConnection, .other,
        ].map { NativeInstallFailure.downloadFailed($0) }
        let others: [NativeInstallFailure] =
            NativeInstallFailureCode.allCases
                .filter { $0 != .activationRefused && $0 != .serviceNotReady }
                .map { .installer($0) }
            + downloadFailures
            + [.checksumMismatch, .launchFailed, .cancelledBeforeLaunch, .releaseUnverified, .repairUnavailable]
            + [.protocolViolation(.missingTerminalEvent)]
        for failure in others {
            XCTAssertFalse(NativeInstallPortRecovery.isRecoverable(failure), "\(failure) must not offer port recovery")
        }
    }

    func testPortTextMustBeAPlainPort() {
        XCTAssertEqual(NativeInstallPortRecovery.port(" 8555 "), 8555)
        XCTAssertEqual(NativeInstallPortRecovery.port("1"), 1)
        XCTAssertEqual(NativeInstallPortRecovery.port("65535"), 65535)

        for text in ["", "0", "65536", "abc", "84 43", "-1"] {
            XCTAssertNil(NativeInstallPortRecovery.port(text), text)
        }
    }

    func testAFailedInstallIsClearedOnlyWhenDiscoveryFindsARunningEngine() {
        let origin = Origin("http://127.0.0.1:8443")!
        let running = LocalServerDiscovery.Status.running(version: "1.9.0", ready: true, onThisMac: true)
        let failures: [NativeInstallFailure] = [
            .installer(.activationRefused), .installer(.serviceNotReady),
            .downloadFailed(.other), .cancelledBeforeLaunch,
        ]
        for failure in failures {
            XCTAssertTrue(NativeInstallFailureReset.shouldReset(install: .failed(failure), discovery: running),
                          "\(failure) must clear once the engine is running")
        }

        let notRunning: [LocalServerDiscovery.Status] = [
            .idle, .checking, .installedNotRunning(version: nil), .starting,
            .startFailed(version: nil), .notDetected,
        ]
        for status in notRunning {
            XCTAssertFalse(NativeInstallFailureReset.shouldReset(install: .failed(.installer(.activationRefused)), discovery: status),
                           "\(status) must not clear a failed install")
        }

        let notFailed: [NativeInstallState] = [
            .idle, .succeeded(origin), .downloading, .verifying, .running(nil), .cancelling,
        ]
        for state in notFailed {
            XCTAssertFalse(NativeInstallFailureReset.shouldReset(install: state, discovery: running),
                           "\(state) is not a failed install")
        }
    }
}
