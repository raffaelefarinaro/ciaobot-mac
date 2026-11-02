import CryptoKit
import XCTest
import Foundation

@testable import CiaobotMac

final class NativeInstallEventsTests: XCTestCase {
    private let testRunID = "6f1c2a4e-9b7d-4c3a-8e5f-0a1b2c3d4e5f"

    /// One compact JSON object followed by a newline. `schema` defaults to 1
    /// and `run_id` to the test run id; the caller supplies `seq` and `type`.
    private func line(_ fields: [String: Any], runID: String? = nil) -> Data {
        var object: [String: Any] = ["schema": 1, "run_id": runID ?? testRunID]
        for (key, value) in fields { object[key] = value }
        let json = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return json + Data("\n".utf8)
    }

    private func phaseLine(_ seq: Int, _ phase: String) -> Data {
        line(["seq": seq, "type": "phase", "phase": phase])
    }

    private var recordedSuccessfulRun: Data {
        var stream = Data()
        stream.append(phaseLine(1, "preflight"))
        stream.append(phaseLine(2, "bootstrap"))
        stream.append(phaseLine(3, "download"))
        stream.append(phaseLine(4, "install"))
        stream.append(phaseLine(5, "wizard"))
        stream.append(line(["seq": 6, "type": "wizard_ready", "origin": "http://127.0.0.1:8443"]))
        stream.append(line(["seq": 7, "type": "setup_saved"]))
        stream.append(phaseLine(8, "activation"))
        stream.append(phaseLine(9, "readiness"))
        stream.append(line(["seq": 10, "type": "service_ready", "origin": "http://127.0.0.1:8444"]))
        return stream
    }

    private let recordedEvents: [NativeInstallEvent] = [
        .phase(.preflight),
        .phase(.bootstrap),
        .phase(.download),
        .phase(.install),
        .phase(.wizard),
        .wizardReady(Origin("http://127.0.0.1:8443")!),
        .setupSaved,
        .phase(.activation),
        .phase(.readiness),
        .serviceReady(Origin("http://127.0.0.1:8444")!),
    ]

    private func decoder() -> NativeInstallEventDecoder {
        NativeInstallEventDecoder(runID: testRunID)
    }

    // MARK: Pin and arguments

    func testPinMatchesTheEngineContract() {
        XCTAssertEqual(NativeInstallPin.current.version, "1.8.1")
        XCTAssertEqual(
            NativeInstallPin.current.url.absoluteString,
            "https://github.com/raffaelefarinaro/ciaobot/releases/download/v1.8.1/install.sh"
        )
        XCTAssertEqual(
            NativeInstallPin.current.sha256,
            "df5a562bb99894f98d705a6223a5ed1ebef3b24dec44812619ae7e330773effb"
        )
        XCTAssertEqual(NativeInstallPin.eventsFD, 3)
    }

    func testArgumentsAreTheNativeInstallCommand() {
        let runID = UUID(uuidString: "6F1C2A4E-9B7D-4C3A-8E5F-0A1B2C3D4E5F")!
        XCTAssertEqual(
            NativeInstallPin.current.arguments(scriptPath: "/tmp/run/install.sh", runID: runID),
            [
                "/bin/sh", "/tmp/run/install.sh",
                "--version", "1.8.1",
                "--native-install",
                "--events-fd", "3",
                "--run-id", "6f1c2a4e-9b7d-4c3a-8e5f-0a1b2c3d4e5f",
            ]
        )
    }

    func testSha256HexMatchesAKnownVector() {
        XCTAssertEqual(
            NativeInstallPin.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    // MARK: Decoding

    func testDecodesTheRecordedSuccessfulRun() throws {
        var decoder = decoder()
        XCTAssertEqual(try decoder.feed(recordedSuccessfulRun), recordedEvents)
        XCTAssertEqual(decoder.terminal, .serviceReady(Origin("http://127.0.0.1:8444")!))
        XCTAssertNoThrow(try decoder.finish())
    }

    func testDecodesEventsSplitAcrossArbitraryChunks() throws {
        var decoder = decoder()
        var events: [NativeInstallEvent] = []
        for byte in recordedSuccessfulRun {
            events += try decoder.feed(Data([byte]))
        }
        XCTAssertEqual(events, recordedEvents)
        XCTAssertNoThrow(try decoder.finish())
    }

    func testAcceptsSequenceGaps() throws {
        var decoder = decoder()
        let events = try decoder.feed(phaseLine(1, "preflight") + phaseLine(5, "bootstrap") + phaseLine(9, "download"))
        XCTAssertEqual(events, [.phase(.preflight), .phase(.bootstrap), .phase(.download)])
    }

    func testRejectsRepeatedOrDecreasingSequence() {
        var repeated = decoder()
        XCTAssertThrowsError(try repeated.feed(phaseLine(1, "preflight") + phaseLine(1, "bootstrap"))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .nonIncreasingSequence)
        }

        var decreasing = decoder()
        XCTAssertThrowsError(try decreasing.feed(phaseLine(5, "preflight") + phaseLine(3, "bootstrap"))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .nonIncreasingSequence)
        }
    }

    func testRejectsWrongRunIDAndSchema() {
        var wrongRun = decoder()
        XCTAssertThrowsError(try wrongRun.feed(line(["seq": 1, "type": "phase", "phase": "preflight"], runID: "00000000-0000-4000-8000-000000000000"))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .wrongRunID)
        }

        var wrongSchema = decoder()
        XCTAssertThrowsError(try wrongSchema.feed(line(["schema": 2, "seq": 1, "type": "phase", "phase": "preflight"]))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .wrongSchema)
        }
    }

    func testLineLimitIsTenTwentyFourBytesIncludingNewline() throws {
        let prefix = #"{"schema":1,"run_id":"\#(testRunID)","seq":1,"type":"phase","phase":"preflight","pad":""#
        let suffix = #""}"#
        let baseLength = prefix.utf8.count + suffix.utf8.count

        let paddingForExactLimit = String(repeating: "x", count: 1024 - 1 - baseLength)
        let exact = Data((prefix + paddingForExactLimit + suffix).utf8) + Data("\n".utf8)
        XCTAssertEqual(exact.count, 1024)
        var acceptingDecoder = decoder()
        XCTAssertEqual(try acceptingDecoder.feed(exact), [.phase(.preflight)])

        let paddingOneOver = String(repeating: "x", count: 1024 - baseLength)
        let oneOver = Data((prefix + paddingOneOver + suffix).utf8) + Data("\n".utf8)
        XCTAssertEqual(oneOver.count, 1025)
        var rejectingDecoder = decoder()
        XCTAssertThrowsError(try rejectingDecoder.feed(oneOver)) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .lineTooLong)
        }

        var noNewlineDecoder = decoder()
        XCTAssertThrowsError(try noNewlineDecoder.feed(Data(repeating: UInt8(ascii: "x"), count: 1024))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .lineTooLong)
        }
    }

    func testRejectsMoreThanThirtyTwoEvents() {
        XCTAssertEqual(NativeInstallEventDecoder.maximumEvents, 32)

        var decoder = NativeInstallEventDecoder(runID: testRunID, maximumEvents: 2)
        XCTAssertThrowsError(
            try decoder.feed(phaseLine(1, "preflight") + phaseLine(2, "bootstrap") + phaseLine(3, "download"))
        ) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .tooManyEvents)
        }
    }

    func testPhasesMustBeInOrderAndUnique() {
        var reordered = decoder()
        XCTAssertThrowsError(try reordered.feed(phaseLine(1, "wizard") + phaseLine(2, "install"))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .phaseOutOfOrder)
        }

        var repeated = decoder()
        XCTAssertThrowsError(try repeated.feed(phaseLine(1, "preflight") + phaseLine(2, "preflight"))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .phaseOutOfOrder)
        }

        var skipping = decoder()
        XCTAssertNoThrow(try skipping.feed(phaseLine(1, "preflight") + phaseLine(2, "install")))
    }

    func testWizardReadyNeedsTheWizardPhase() {
        var decoder = decoder()
        XCTAssertThrowsError(
            try decoder.feed(phaseLine(1, "install") + line(["seq": 2, "type": "wizard_ready", "origin": "http://127.0.0.1:8443"]))
        ) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .unexpectedEvent)
        }
    }

    func testSetupSavedNeedsWizardReady() {
        var decoder = decoder()
        XCTAssertThrowsError(try decoder.feed(phaseLine(1, "wizard") + line(["seq": 2, "type": "setup_saved"]))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .unexpectedEvent)
        }
    }

    func testServiceReadyNeedsTheReadinessPhase() {
        var decoder = decoder()
        XCTAssertThrowsError(
            try decoder.feed(phaseLine(1, "activation") + line(["seq": 2, "type": "service_ready", "origin": "http://127.0.0.1:8444"]))
        ) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .unexpectedEvent)
        }
    }

    func testRejectsNonLoopbackOrigins() {
        let origins = [
            "https://127.0.0.1:8443",
            "http://localhost:8443",
            "http://[::1]:8443",
            "http://127.0.0.1",
            "http://127.0.0.1:8443/",
            "http://127.0.0.1:0",
            "http://127.0.0.1:70000",
            "http://127.0.0.1:08443",
            "http://10.0.0.1:8443",
            "http://127.0.0.1:8443/path",
        ]
        for origin in origins {
            var decoder = decoder()
            XCTAssertThrowsError(
                try decoder.feed(phaseLine(1, "wizard") + line(["seq": 2, "type": "wizard_ready", "origin": origin])),
                origin
            ) {
                XCTAssertEqual($0 as? NativeInstallProtocolError, .invalidOrigin, origin)
            }
        }
    }

    func testDecodesEveryFailureCode() throws {
        let rawCodes = [
            "invalid_arguments", "existing_install", "partial_install", "unknown_state",
            "install_in_progress", "download_failed", "verification_failed", "install_failed",
            "wizard_failed", "activation_refused", "service_not_ready", "cancelled",
            "event_channel_failed", "internal_error",
        ]
        XCTAssertEqual(NativeInstallFailureCode.allCases.map(\.rawValue).sorted(), rawCodes.sorted())

        for code in NativeInstallFailureCode.allCases {
            var decoder = decoder()
            XCTAssertEqual(
                try decoder.feed(line(["seq": 1, "type": "failed", "code": code.rawValue])),
                [.failed(code)]
            )
            XCTAssertEqual(decoder.terminal, .failed(code))
        }
    }

    func testRejectsUnknownTypeAndFailureCode() {
        var unknownType = decoder()
        XCTAssertThrowsError(try unknownType.feed(line(["seq": 1, "type": "celebrate"]))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .unknownType)
        }

        var unknownCode = decoder()
        XCTAssertThrowsError(try unknownCode.feed(line(["seq": 1, "type": "failed", "code": "on_fire"]))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .unknownFailureCode)
        }
    }

    func testRejectsInvalidUTF8AndMalformedJSON() {
        var invalidUTF8 = decoder()
        XCTAssertThrowsError(try invalidUTF8.feed(Data([0xFF, 0x0A]))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .invalidUTF8)
        }

        var missingFields = decoder()
        XCTAssertThrowsError(try missingFields.feed(Data(#"{"schema":1}"#.utf8) + Data("\n".utf8))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .malformedJSON)
        }

        var boolSeq = decoder()
        let boolSeqLine = #"{"schema":1,"run_id":"\#(testRunID)","seq":true,"type":"setup_saved"}"#
        XCTAssertThrowsError(try boolSeq.feed(Data(boolSeqLine.utf8) + Data("\n".utf8))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .malformedJSON)
        }
    }

    func testRejectsAnEventAfterTheTerminalEvent() throws {
        var decoder = decoder()
        XCTAssertEqual(try decoder.feed(line(["seq": 1, "type": "failed", "code": "cancelled"])), [.failed(.cancelled)])
        XCTAssertThrowsError(try decoder.feed(phaseLine(2, "preflight"))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .eventAfterTerminal)
        }
    }

    func testFinishRequiresATerminalEventAndACompleteLine() throws {
        var noTerminal = decoder()
        _ = try noTerminal.feed(phaseLine(1, "preflight") + phaseLine(2, "bootstrap"))
        XCTAssertThrowsError(try noTerminal.finish()) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .missingTerminalEvent)
        }

        var truncated = decoder()
        _ = try truncated.feed(line(["seq": 1, "type": "failed", "code": "internal_error"]) + Data(#"{"sch"#.utf8))
        XCTAssertThrowsError(try truncated.finish()) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .truncatedLine)
        }
    }

    func testDecoderStaysFailedAfterAViolation() {
        var decoder = decoder()
        XCTAssertThrowsError(try decoder.feed(Data("not json\n".utf8))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .malformedJSON)
        }
        XCTAssertThrowsError(try decoder.feed(phaseLine(1, "preflight"))) {
            XCTAssertEqual($0 as? NativeInstallProtocolError, .malformedJSON)
        }
    }

    // MARK: States and copy

    func testEveryFailureHasItsOwnMessage() {
        let failures: [NativeInstallFailure] =
            NativeInstallFailureCode.allCases.map { .installer($0) }
            + [.downloadFailed, .checksumMismatch, .launchFailed, .cancelledBeforeLaunch, .releaseUnverified]
            + [.protocolViolation(.missingTerminalEvent)]
        let messages = failures.map { NativeInstallCopy.message(for: $0) }

        XCTAssertEqual(messages.count, 20)
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(messages).count, messages.count)
    }

    func testPortFailuresTellTheUserToPickAnotherPort() {
        let portFailures: [NativeInstallFailure] = [.installer(.activationRefused), .installer(.serviceNotReady)]
        let others: [NativeInstallFailure] =
            NativeInstallFailureCode.allCases.filter { $0 != .activationRefused && $0 != .serviceNotReady }.map { .installer($0) }
            + [.downloadFailed, .checksumMismatch, .launchFailed, .cancelledBeforeLaunch, .protocolViolation(.missingTerminalEvent)]

        for failure in portFailures {
            XCTAssertTrue(NativeInstallCopy.message(for: failure).lowercased().contains("pick another port"))
        }
        for failure in others {
            XCTAssertFalse(NativeInstallCopy.message(for: failure).lowercased().contains("pick another port"))
        }
    }

    func testLockAndCancelCopyNeverPromiseCleanup() {
        let lock = NativeInstallCopy.message(for: .installer(.installInProgress))
        XCTAssertTrue(lock.contains("Recovering a native-install lock"))
        XCTAssertTrue(lock.contains("never removed automatically"))

        let cancelled = NativeInstallCopy.message(for: .installer(.cancelled))
        XCTAssertTrue(cancelled.contains("left running"))
    }

    func testOnlyTheWizardStateTrustsAnOrigin() {
        let origin = Origin("http://127.0.0.1:8443")!
        XCTAssertEqual(NativeInstallState.wizard(origin).wizardOrigin, origin)
        let untrusted: [NativeInstallState] = [
            .idle, .downloading, .verifying, .running(nil), .running(.wizard),
            .cancelling, .succeeded(origin), .failed(.cancelledBeforeLaunch),
        ]
        for state in untrusted {
            XCTAssertNil(state.wizardOrigin)
        }

        let active: [NativeInstallState] = [.downloading, .verifying, .running(nil), .running(.wizard), .wizard(origin), .cancelling]
        let inactive: [NativeInstallState] = [.idle, .succeeded(origin), .failed(.cancelledBeforeLaunch)]
        XCTAssertTrue(active.allSatisfy(\.isActive))
        XCTAssertTrue(inactive.allSatisfy { !$0.isActive })
    }
}
