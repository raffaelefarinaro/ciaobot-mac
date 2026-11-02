import Combine
import XCTest
import Foundation

@testable import CiaobotMac

/// Runs the real spawn path against small POSIX shell installers. Only the
/// network fetch is replaced; the pin's digest is the fake script's digest.
@MainActor
final class NativeInstallerTests: XCTestCase {
    private var root: URL!
    private var temporaryRoot: URL!
    private var logURL: URL!
    private var history: [NativeInstallState] = []
    private var cancellables = Set<AnyCancellable>()
    private let runID = UUID(uuidString: "6F1C2A4E-9B7D-4C3A-8E5F-0A1B2C3D4E5F")!

    private let origin8443 = Origin("http://127.0.0.1:8443")!
    private let origin8444 = Origin("http://127.0.0.1:8444")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-installer-tests-\(UUID().uuidString)", isDirectory: true)
        temporaryRoot = root.appendingPathComponent("tmp", isDirectory: true)
        logURL = root.appendingPathComponent("logs/native-install.log")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        history = []
    }

    override func tearDownWithError() throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    /// Shell prelude every fake installer gets. It stores the run id from
    /// `--run-id` without consuming "$@", and defines `ev SEQ CONTENT` to
    /// write one event line on the inherited descriptor 3.
    private static let prelude = #"""
    #!/bin/sh
    RID=
    prev=
    for a in "$@"; do if [ "$prev" = "--run-id" ]; then RID="$a"; fi; prev="$a"; done
    emit() { printf '%s\n' "$1" >&3; }
    ev() { emit "{\"schema\":1,\"run_id\":\"$RID\",\"seq\":$1,$2}"; }

    """#

    private func makeScript(_ body: String) -> (Data, NativeInstallPin) {
        let data = Data((Self.prelude + body).utf8)
        let pin = NativeInstallPin(
            version: NativeInstallPin.current.version,
            url: NativeInstallPin.current.url,
            sha256: NativeInstallPin.sha256Hex(data)
        )
        return (data, pin)
    }

    private func makeInstaller(pin: NativeInstallPin, fetch: @escaping NativeInstallFetch) -> NativeInstaller {
        let id = runID
        let installer = NativeInstaller(
            pin: pin,
            fetch: fetch,
            makeRunID: { id },
            temporaryRoot: temporaryRoot,
            logURL: logURL
        )
        installer.$state
            .sink { [weak self] state in self?.history.append(state) }
            .store(in: &cancellables)
        return installer
    }

    private func fetchReturning(_ data: Data) -> NativeInstallFetch {
        { _ in data }
    }

    /// Waits on `installer.$state` until a state matches, failing the test on timeout.
    private func waitForState(
        _ installer: NativeInstaller,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping (NativeInstallState) -> Bool
    ) async {
        let reached = expectation(description: "installer state reached")
        reached.assertForOverFulfill = false
        let observer = installer.$state.sink { state in
            if predicate(state) { reached.fulfill() }
        }
        await fulfillment(of: [reached], timeout: timeout)
        observer.cancel()
        if !predicate(installer.state) {
            XCTFail("timed out waiting for state; last state was \(installer.state)", file: file, line: line)
        }
    }

    private func temporaryInstallerEntries() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)) ?? []
        return names.filter { $0.hasPrefix("ciaobot-native-install-") }
    }

    /// The run removes its private directory only after the child is reaped,
    /// so polling for that proves the run has finished.
    private func waitForTemporaryInstallerToClear(timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !temporaryInstallerEntries().isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(temporaryInstallerEntries(), [], "the installer run did not finish and clean up")
    }

    // MARK: Verification and download

    func testHashMismatchNeverRunsTheScript() async {
        let marker = root.appendingPathComponent("marker").path
        let (data, pin) = makeScript("touch '\(marker)'\nexit 0\n")
        let wrongPin = NativeInstallPin(
            version: pin.version,
            url: pin.url,
            sha256: String(repeating: "0", count: 64)
        )
        let installer = makeInstaller(pin: wrongPin, fetch: fetchReturning(data))

        installer.start()
        await waitForState(installer) { $0 == .failed(.checksumMismatch) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        XCTAssertEqual(temporaryInstallerEntries(), [])
    }

    func testDownloadErrorFails() async {
        let (_, pin) = makeScript("exit 0\n")
        let fetch: NativeInstallFetch = { _ in throw URLError(.notConnectedToInternet) }
        let installer = makeInstaller(pin: pin, fetch: fetch)

        installer.start()
        await waitForState(installer) { $0 == .failed(.downloadFailed) }
    }

    // MARK: Spawn contract and event handling

    func testSuccessfulRunPassesTheExactCommandAndReachesServiceReady() async throws {
        let argsFile = root.appendingPathComponent("args.txt").path
        let (data, pin) = makeScript(#"""
        printf '%s\n' "$0" "$@" > "\#(argsFile)"
        ev 1 '"type":"phase","phase":"preflight"'
        ev 2 '"type":"phase","phase":"bootstrap"'
        ev 3 '"type":"phase","phase":"download"'
        ev 4 '"type":"phase","phase":"install"'
        ev 5 '"type":"phase","phase":"wizard"'
        ev 6 '"type":"wizard_ready","origin":"http://127.0.0.1:8443"'
        ev 7 '"type":"setup_saved"'
        ev 8 '"type":"phase","phase":"activation"'
        ev 9 '"type":"phase","phase":"readiness"'
        ev 10 '"type":"service_ready","origin":"http://127.0.0.1:8444"'
        exit 0

        """#)
        let installer = makeInstaller(pin: pin, fetch: fetchReturning(data))

        installer.start()
        await waitForState(installer) { $0 == .succeeded(self.origin8444) }

        let written = try String(contentsOfFile: argsFile, encoding: .utf8)
        let lines = written.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        XCTAssertEqual(lines.count, 8)
        // lines[0] is $0, the script path; the rest is the argument tail.
        XCTAssertEqual(
            Array(pin.arguments(scriptPath: lines[0], runID: runID).dropFirst()),
            lines
        )
        XCTAssertEqual(lines.last, "6f1c2a4e-9b7d-4c3a-8e5f-0a1b2c3d4e5f")

        let wizardIndex = try XCTUnwrap(history.firstIndex(of: .wizard(origin8443)))
        XCTAssertTrue(history[wizardIndex...].contains(.running(.wizard)))
        await waitForTemporaryInstallerToClear()
    }

    func testFailedEventEndsTheRun() async {
        let (data, pin) = makeScript(#"""
        ev 1 '"type":"phase","phase":"preflight"'
        ev 2 '"type":"failed","code":"activation_refused"'
        exit 1

        """#)
        let installer = makeInstaller(pin: pin, fetch: fetchReturning(data))

        installer.start()
        await waitForState(installer) { $0 == .failed(.installer(.activationRefused)) }
    }

    func testExitWithoutTerminalEventIsAFailure() async {
        let (data, pin) = makeScript(#"""
        ev 1 '"type":"phase","phase":"preflight"'
        ev 2 '"type":"phase","phase":"bootstrap"'
        exit 0

        """#)
        let installer = makeInstaller(pin: pin, fetch: fetchReturning(data))

        installer.start()
        await waitForState(installer) { $0 == .failed(.protocolViolation(.missingTerminalEvent)) }
    }

    func testStdoutAndStderrAreNeverParsed() async throws {
        let (data, pin) = makeScript(#"""
        printf '%s\n' '{"schema":1,"run_id":"'"$RID"'","seq":1,"type":"service_ready","origin":"http://127.0.0.1:8444"}'
        printf '%s\n' '{"schema":1,"run_id":"'"$RID"'","seq":1,"type":"service_ready","origin":"http://127.0.0.1:8444"}' >&2
        ev 1 '"type":"failed","code":"internal_error"'
        exit 0

        """#)
        let installer = makeInstaller(pin: pin, fetch: fetchReturning(data))

        installer.start()
        await waitForState(installer) { $0 == .failed(.installer(.internalError)) }

        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains(#""type":"service_ready""#))
    }

    func testMalformedEventStopsAndTerminatesTheInstaller() async {
        let (data, pin) = makeScript(#"""
        emit 'not json'
        trap 'exit 0' TERM
        while :; do sleep 0.1; done

        """#)
        let installer = makeInstaller(pin: pin, fetch: fetchReturning(data))

        installer.start()
        await waitForState(installer) { $0 == .failed(.protocolViolation(.malformedJSON)) }
        // The child loops forever unless SIGTERM reaches it; the run only
        // cleans up after the child is reaped.
        await waitForTemporaryInstallerToClear()
    }

    func testOnlyTheEventDescriptorIsInherited() async {
        let openFDsFile = root.appendingPathComponent("open-fds.txt").path
        let (data, pin) = makeScript(#"""
        for n in 4 5 6 7 8 9; do if { true >&$n; } 2>/dev/null; then echo $n >> "\#(openFDsFile)"; fi; done
        ev 1 '"type":"failed","code":"internal_error"'
        exit 0

        """#)
        let installer = makeInstaller(pin: pin, fetch: fetchReturning(data))

        installer.start()
        await waitForState(installer) { $0 == .failed(.installer(.internalError)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: openFDsFile))
    }

    // MARK: Cancellation

    func testCancelBeforeLaunchStopsTheDownload() async throws {
        let marker = root.appendingPathComponent("marker").path
        let (data, pin) = makeScript("touch '\(marker)'\nexit 0\n")
        let slowFetch: NativeInstallFetch = { _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return data
        }
        let installer = makeInstaller(pin: pin, fetch: slowFetch)

        installer.start()
        await waitForState(installer) { $0 == .downloading }
        installer.cancel()
        XCTAssertEqual(installer.state, .failed(.cancelledBeforeLaunch))

        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testCancelWhileTheWizardIsOpenRevokesItAndReportsCancelled() async {
        let (data, pin) = makeScript(#"""
        on_term() { ev 20 '"type":"failed","code":"cancelled"'; exit 1; }
        trap on_term TERM
        ev 1 '"type":"phase","phase":"preflight"'
        ev 2 '"type":"phase","phase":"wizard"'
        ev 3 '"type":"wizard_ready","origin":"http://127.0.0.1:8443"'
        while :; do sleep 0.1; done

        """#)
        let installer = makeInstaller(pin: pin, fetch: fetchReturning(data))

        installer.start()
        await waitForState(installer) { $0.wizardOrigin != nil }

        let mark = history.count
        installer.cancel()
        XCTAssertEqual(installer.state, .cancelling)
        XCTAssertNil(installer.state.wizardOrigin)

        await waitForState(installer) { $0 == .failed(.installer(.cancelled)) }
        XCTAssertFalse(history[mark...].contains { $0.wizardOrigin != nil })
    }

    func testServiceReadyWinsARaceWithCancel() async {
        let (data, pin) = makeScript(#"""
        on_term() { ev 10 '"type":"service_ready","origin":"http://127.0.0.1:8444"'; exit 0; }
        trap on_term TERM
        ev 1 '"type":"phase","phase":"readiness"'
        while :; do sleep 0.1; done

        """#)
        let installer = makeInstaller(pin: pin, fetch: fetchReturning(data))

        installer.start()
        await waitForState(installer) { $0 == .running(.readiness) }
        installer.cancel()
        await waitForState(installer) { $0 == .succeeded(self.origin8444) }
    }

    // MARK: Lifecycle

    func testStartIsIgnoredWhileARunIsActive() async throws {
        let startsFile = root.appendingPathComponent("starts.txt").path
        let (data, pin) = makeScript(#"""
        on_term() { ev 2 '"type":"failed","code":"cancelled"'; exit 1; }
        trap on_term TERM
        printf 'start\n' >> "\#(startsFile)"
        ev 1 '"type":"phase","phase":"preflight"'
        while :; do sleep 0.1; done

        """#)
        let installer = makeInstaller(pin: pin, fetch: fetchReturning(data))

        installer.start()
        await waitForState(installer) { $0 == .running(.preflight) }
        installer.start()
        try await Task.sleep(nanoseconds: 500_000_000)

        let starts = try String(contentsOfFile: startsFile, encoding: .utf8)
        XCTAssertEqual(starts.split(separator: "\n").count, 1)

        installer.cancel()
        await waitForState(installer) { $0 == .failed(.installer(.cancelled)) }
    }

    func testTemporaryInstallerIsRemovedAfterTheRun() async {
        let (data, pin) = makeScript(#"""
        ev 1 '"type":"phase","phase":"preflight"'
        ev 2 '"type":"failed","code":"invalid_arguments"'
        exit 1

        """#)
        let installer = makeInstaller(pin: pin, fetch: fetchReturning(data))

        installer.start()
        await waitForState(installer) { $0 == .failed(.installer(.invalidArguments)) }
        await waitForTemporaryInstallerToClear()
    }
}
