import XCTest
import Foundation

@testable import CiaobotMac

/// The connection screen's install offer and the rules for turning an install
/// outcome into a connection. Nothing here starts an install or touches the
/// network: the installer's fetch always throws and the probe is a stub.
@MainActor
final class NativeInstallFlowTests: XCTestCase {
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

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: UserDefaultsLastServerStore!
    private var registryURL: URL!

    override func setUp() {
        super.setUp()
        suiteName = "CiaobotMacTests.NativeInstallFlow.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = UserDefaultsLastServerStore(defaults: defaults)
        registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CiaobotMacTests-InstallRegistry-\(UUID().uuidString).json")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        if let registryURL { try? FileManager.default.removeItem(at: registryURL) }
        super.tearDown()
    }

    private func makeView(probe: ProbeChecking) -> ConnectionView {
        let signIn = SessionSignIn(
            registry: SessionStoreRegistry(fileURL: registryURL),
            eraser: NoopEraser(),
            persistentAvailable: false
        )
        // The fetch always throws, so no test can reach the real release.
        let installer = NativeInstaller(fetch: { _ in throw URLError(.notConnectedToInternet) })
        return ConnectionView(probe: probe, signIn: signIn, lastServer: store, installer: installer)
    }

    private func origin(_ raw: String) throws -> Origin {
        try XCTUnwrap(Origin(raw))
    }

    func testInstallIsOfferedOnlyWhenNothingIsFound() {
        XCTAssertTrue(NativeInstallOffer.isOffered(discovery: .notDetected, install: .idle))

        let notOffered: [LocalServerDiscovery.Status] = [
            .idle,
            .checking,
            .installedNotRunning(version: nil),
            .running(version: nil, ready: true, onThisMac: true),
            .startFailed(version: nil),
        ]
        for status in notOffered {
            XCTAssertFalse(
                NativeInstallOffer.isOffered(discovery: status, install: .idle),
                "Install was offered while discovery reported \(status)"
            )
        }
    }

    func testAFailedInstallCanBeRetriedAndARunningOneCannotBeRestarted() throws {
        let failed = NativeInstallState.failed(.installer(.serviceNotReady))
        let discoveries: [LocalServerDiscovery.Status] = [
            .idle, .notDetected, .running(version: nil, ready: true, onThisMac: true),
        ]
        for status in discoveries {
            XCTAssertTrue(
                NativeInstallOffer.isOffered(discovery: status, install: failed),
                "A failed install was not offered for retry while discovery reported \(status)"
            )
        }

        let wizard = try origin("http://127.0.0.1:8443")
        let service = try origin("http://127.0.0.1:8444")
        let active: [NativeInstallState] = [
            .downloading,
            .running(.install),
            .wizard(wizard),
            .cancelling,
            .succeeded(service),
        ]
        for state in active {
            XCTAssertFalse(
                NativeInstallOffer.isOffered(discovery: .notDetected, install: state),
                "Install was offered while the state was \(state)"
            )
        }
    }

    func testServiceReadyConnectsToTheServiceOriginAndRemembersIt() throws {
        let probe = StubProbe(responds: true)
        let view = makeView(probe: probe)

        view.handleInstallState(.succeeded(try origin("http://127.0.0.1:8444")))

        XCTAssertEqual(probe.checked.map(\.canonicalKey), ["http://127.0.0.1:8444"])
        XCTAssertEqual(store.savedOrigin?.canonicalKey, "http://127.0.0.1:8444")
    }

    func testNothingButServiceReadyConnects() throws {
        let states: [NativeInstallState] = [
            .wizard(try origin("http://127.0.0.1:8443")),
            .running(.activation),
            .cancelling,
            .failed(.installer(.activationRefused)),
            .failed(.checksumMismatch),
        ]
        for state in states {
            let probe = StubProbe(responds: true)
            let view = makeView(probe: probe)

            view.handleInstallState(state)

            XCTAssertTrue(probe.checked.isEmpty, "\(state) started a connection")
            XCTAssertNil(store.savedOrigin, "\(state) was remembered")
        }
    }

    func testAnUnverifiedServiceAfterInstallIsNotRemembered() throws {
        let probe = StubProbe(responds: false)
        let view = makeView(probe: probe)

        view.handleInstallState(.succeeded(try origin("http://127.0.0.1:8444")))

        XCTAssertEqual(probe.checked.count, 1)
        XCTAssertNil(store.savedOrigin, "An unverified service after install was remembered")
    }

    func testAfterInstallFailureCopyNamesTheServiceOrigin() throws {
        let service = try origin("http://127.0.0.1:8444")
        let text = NativeInstallFlowCopy.connectFailedAfterInstall(service)

        XCTAssertTrue(text.contains("http://127.0.0.1:8444"), "The copy does not name the service origin: \(text)")
        XCTAssertNotEqual(
            text,
            "Could not verify the server’s startup response. Check the address and try again.",
            "The after-install failure must not reuse the ordinary failure text"
        )
    }

    func testReadmeDocumentsTheCurrentInstallerPin() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readme = try String(
            contentsOf: packageRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )

        XCTAssertTrue(readme.contains(NativeInstallPin.current.sha256),
                      "README does not state the pinned installer digest")
        XCTAssertTrue(readme.contains("v\(NativeInstallPin.current.version)"),
                      "README does not name the pinned release tag")
        XCTAssertTrue(readme.contains("--native-install --events-fd 3"),
                      "README does not document the native install command")
        XCTAssertTrue(readme.contains("pick another port"),
                      "README does not explain the port failures")
        XCTAssertFalse(readme.contains("It does not install, manage, restart, or replace the server"),
                       "README still says the app never installs anything")
    }
}
