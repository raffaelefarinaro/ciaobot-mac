import XCTest
import Foundation

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
