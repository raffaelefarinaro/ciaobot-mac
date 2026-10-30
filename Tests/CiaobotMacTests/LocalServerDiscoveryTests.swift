import XCTest
import Foundation

@testable import CiaobotMac

/// Same-Mac discovery is a hint on the connection screen, not a connection.
/// These tests keep it to one fixed candidate, one credential-free request per
/// check, and a response that never claims identity.
@MainActor
final class LocalServerDiscoveryTests: XCTestCase {
    private var requests: [Origin] = []
    private var completions: [(Bool) -> Void] = []

    private func makeDiscovery(candidate: String = "http://127.0.0.1:8443") -> LocalServerDiscovery {
        LocalServerDiscovery(candidate: Origin(candidate)) { [weak self] origin, completion in
            guard let self else { return }
            self.requests.append(origin)
            self.completions.append(completion)
        }
    }

    func testDefaultCandidateIsOnlyTheExplicitLoopbackAddress() {
        let candidate = LocalServerDiscovery.defaultCandidate
        XCTAssertEqual(candidate?.url.absoluteString, "http://127.0.0.1:8443")
        XCTAssertEqual(candidate?.canonicalKey, "http://127.0.0.1:8443")
        XCTAssertTrue(candidate?.isLoopback == true)
    }

    func testOneFixedCandidateIsProbedOncePerCheck() {
        let discovery = makeDiscovery()
        XCTAssertEqual(discovery.status, .idle)

        XCTAssertTrue(discovery.refresh())
        XCTAssertEqual(discovery.status, .checking)
        XCTAssertEqual(requests.map(\.canonicalKey), ["http://127.0.0.1:8443"],
                       "Discovery must probe exactly the fixed candidate, never a scanned port")
        XCTAssertEqual(requests.count, 1)
    }

    func testAResponseIsReportedAsRespondedOrNotDetected() {
        let discovery = makeDiscovery()

        XCTAssertTrue(discovery.refresh())
        completions[0](true)
        XCTAssertEqual(discovery.status, .responded)

        XCTAssertTrue(discovery.refresh())
        completions[1](false)
        XCTAssertEqual(discovery.status, .notDetected)
    }

    func testCheckCannotStartTwiceWhileOneIsInFlight() {
        let discovery = makeDiscovery()

        XCTAssertTrue(discovery.refresh())
        XCTAssertFalse(discovery.refresh(), "A second check started while the first was in flight")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(discovery.status, .checking)
    }

    func testAResponseAfterTheConnectionScreenDisappearsIsIgnored() {
        let discovery = makeDiscovery()

        XCTAssertTrue(discovery.refresh())
        discovery.invalidate()
        XCTAssertEqual(discovery.status, .idle)

        completions[0](true)
        XCTAssertEqual(discovery.status, .idle,
                       "A late response changed a screen that is no longer the connection screen")
    }

    func testAnOlderResponseCannotOverwriteANewerCheck() {
        let discovery = makeDiscovery()

        XCTAssertTrue(discovery.refresh())
        discovery.invalidate()
        XCTAssertTrue(discovery.refresh())

        completions[0](true)
        XCTAssertEqual(discovery.status, .checking,
                       "The first check's late response overwrote the newer check")

        completions[1](false)
        XCTAssertEqual(discovery.status, .notDetected)
    }

    func testCheckCanRunAgainAfterItFinishes() {
        let discovery = makeDiscovery()

        XCTAssertTrue(discovery.refresh())
        completions[0](false)
        XCTAssertTrue(discovery.refresh())
        XCTAssertEqual(requests.count, 2)
        completions[1](true)
        XCTAssertEqual(discovery.status, .responded)
    }

    func testCopyDistinguishesAResponseFromServerIdentity() {
        let address = "http://127.0.0.1:8443"
        let responded = LocalServerDiscoveryCopy.text(for: .responded, address: address)
        XCTAssertTrue(responded.contains("Local server responded"))
        XCTAssertTrue(responded.contains(address))
        let lowered = responded.lowercased()
        XCTAssertTrue(lowered.contains("not proof") || lowered.contains("does not identify"),
                      "The response text must not imply server identity: \(responded)")
        for claim in ["verified server", "authenticated", "signed in", "trusted server", "startup_id"] {
            XCTAssertFalse(lowered.contains(claim), "The response text makes an identity/auth claim: \(responded)")
        }

        let notDetected = LocalServerDiscoveryCopy.text(for: .notDetected, address: address)
        XCTAssertTrue(notDetected.contains("No local server detected"))
        XCTAssertTrue(notDetected.contains(address))
        XCTAssertTrue(notDetected.lowercased().contains("not proof") || notDetected.lowercased().contains("does not"),
                      "The absent text must not imply a negative identity claim: \(notDetected)")
    }

    func testCopyNeverExposesOrCallsOutAStartupIdentifier() {
        let address = "http://127.0.0.1:8443"
        for status in [LocalServerDiscovery.Status.idle, .checking, .responded, .notDetected] {
            let text = LocalServerDiscoveryCopy.text(for: status, address: address).lowercased()
            XCTAssertFalse(text.contains("startup id"), "\(status) copy mentions a startup identifier")
            XCTAssertFalse(text.contains("startup_id"), "\(status) copy mentions a startup identifier")
        }
    }

    func testCheckingCopyAndAccessibilityLabel() {
        XCTAssertEqual(LocalServerDiscoveryCopy.text(for: .checking, address: "http://127.0.0.1:8443"),
                       "Checking for a local server…")
        XCTAssertEqual(LocalServerDiscoveryCopy.accessibilityLabel, "Local server status")
        XCTAssertTrue(LocalServerDiscoveryCopy.hint.contains("127.0.0.1:8443"))
        XCTAssertTrue(LocalServerDiscoveryCopy.hint.contains("does not"))
    }

    func testAutomaticDiscoveryRunsOnlyInProductionAndNotForTestLaunches() {
        XCTAssertTrue(LocalServerDiscoveryPolicy.automaticallyProbes(isDebugBuild: false, testLaunchRequested: false),
                      "A production connection screen must be able to start the fixed candidate check")
        XCTAssertFalse(LocalServerDiscoveryPolicy.automaticallyProbes(isDebugBuild: true, testLaunchRequested: false),
                       "A debug build must not contact the real candidate by default")
        XCTAssertFalse(LocalServerDiscoveryPolicy.automaticallyProbes(isDebugBuild: false, testLaunchRequested: true),
                       "A test launch must not contact the real candidate")
        XCTAssertFalse(LocalServerDiscoveryPolicy.automaticallyProbes(isDebugBuild: true, testLaunchRequested: true))
    }

    func testShippedDefaultTracksTheBuildConfiguration() {
        #if DEBUG
        XCTAssertFalse(LocalServerDiscoveryPolicy.automaticInThisBuild,
                       "The debug app used by the test suite must not auto-contact 127.0.0.1:8443")
        #else
        XCTAssertTrue(LocalServerDiscoveryPolicy.automaticInThisBuild)
        #endif
    }

    func testShippedConnectionViewDefaultFollowsTheSamePolicy() {
        XCTAssertEqual(ConnectionView().automaticallyStartsDiscovery,
                       LocalServerDiscoveryPolicy.automaticInThisBuild)
    }

    func testNoCandidateMeansNoRequest() {
        var requestCount = 0
        let discovery = LocalServerDiscovery(candidate: nil) { _, _ in requestCount += 1 }

        XCTAssertFalse(discovery.refresh())
        XCTAssertEqual(discovery.status, .idle)
        XCTAssertEqual(requestCount, 0)
    }
}
