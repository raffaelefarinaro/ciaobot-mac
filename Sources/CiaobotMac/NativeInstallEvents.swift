import Foundation
import CryptoKit

extension Origin: Equatable {
    static func == (lhs: Origin, rhs: Origin) -> Bool { lhs.canonicalKey == rhs.canonicalKey }
}

/// The engine release the Mac client installs. The URL and digest pin one
/// installer script; nothing else is ever fetched or executed.
struct NativeInstallPin: Equatable {
    let version: String
    let url: URL
    let sha256: String          // lowercase hex

    /// The inherited descriptor the installer writes its events to.
    static let eventsFD: Int32 = 3

    static let current = NativeInstallPin(
        version: "1.8.1",
        url: URL(string: "https://github.com/raffaelefarinaro/ciaobot/releases/download/v1.8.1/install.sh")!,
        sha256: "df5a562bb99894f98d705a6223a5ed1ebef3b24dec44812619ae7e330773effb"
    )

    /// argv for posix_spawn, argv[0] included.
    func arguments(scriptPath: String, runID: UUID) -> [String] {
        [
            "/bin/sh", scriptPath,
            "--version", version,
            "--native-install",
            "--events-fd", String(Self.eventsFD),
            "--run-id", runID.uuidString.lowercased(),
        ]
    }

    /// Lowercase hex SHA-256 of `data`.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum NativeInstallPhase: String, CaseIterable {
    case preflight, bootstrap, download, install, wizard, activation, readiness
}

enum NativeInstallFailureCode: String, CaseIterable {
    case invalidArguments = "invalid_arguments"
    case existingInstall = "existing_install"
    case partialInstall = "partial_install"
    case unknownState = "unknown_state"
    case installInProgress = "install_in_progress"
    case downloadFailed = "download_failed"
    case verificationFailed = "verification_failed"
    case installFailed = "install_failed"
    case wizardFailed = "wizard_failed"
    case activationRefused = "activation_refused"
    case serviceNotReady = "service_not_ready"
    case cancelled
    case eventChannelFailed = "event_channel_failed"
    case internalError = "internal_error"
}

enum NativeInstallEvent: Equatable {
    case phase(NativeInstallPhase)
    case wizardReady(Origin)
    case setupSaved
    case serviceReady(Origin)
    case failed(NativeInstallFailureCode)

    var isTerminal: Bool {
        switch self {
        case .serviceReady, .failed: return true
        case .phase, .wizardReady, .setupSaved: return false
        }
    }
}

enum NativeInstallProtocolError: Error, Equatable {
    case lineTooLong, tooManyEvents, invalidUTF8, malformedJSON, wrongSchema, wrongRunID,
         nonIncreasingSequence, unknownType, phaseOutOfOrder, unexpectedEvent, invalidOrigin,
         unknownFailureCode, eventAfterTerminal, truncatedLine, missingTerminalEvent
}

/// Decodes the installer's NDJSON event stream. Every violation of the
/// contract is an error, and after the first error the decoder stays failed.
struct NativeInstallEventDecoder {
    static let maximumLineBytes = 1024   // including the newline
    static let maximumEvents = 32

    private let runID: String
    private let eventLimit: Int
    private var buffer = Data()
    private var eventCount = 0
    private var lastSeq: Int?
    private var lastPhaseIndex: Int?
    private var sawWizardReady = false
    private var sawSetupSaved = false
    private var error: NativeInstallProtocolError?
    private(set) var terminal: NativeInstallEvent?

    init(runID: String) {
        self.init(runID: runID, maximumEvents: Self.maximumEvents)
    }

    init(runID: String, maximumEvents: Int) {
        self.runID = runID
        self.eventLimit = maximumEvents
    }

    /// Appends bytes and returns every complete, valid event in order.
    mutating func feed(_ chunk: Data) throws -> [NativeInstallEvent] {
        if let error { throw error }
        do {
            buffer.append(chunk)
            var events: [NativeInstallEvent] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineLength = buffer.distance(from: buffer.startIndex, to: newline)
                guard lineLength + 1 <= Self.maximumLineBytes else { throw NativeInstallProtocolError.lineTooLong }
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                events.append(try decode(line))
            }
            // No newline left: the pending bytes must still fit a whole line.
            guard buffer.count < Self.maximumLineBytes else { throw NativeInstallProtocolError.lineTooLong }
            return events
        } catch let violation as NativeInstallProtocolError {
            error = violation
            throw violation
        }
    }

    /// Call at end of stream. A stream must end with a complete line and a
    /// terminal event.
    mutating func finish() throws {
        if let error { throw error }
        do {
            guard buffer.isEmpty else { throw NativeInstallProtocolError.truncatedLine }
            guard terminal != nil else { throw NativeInstallProtocolError.missingTerminalEvent }
        } catch let violation as NativeInstallProtocolError {
            error = violation
            throw violation
        }
    }

    private struct Wire: Decodable {
        let schema: Int
        let run_id: String
        let seq: Int
        let type: String
        let phase: String?
        let origin: String?
        let code: String?
    }

    private var currentPhase: NativeInstallPhase? {
        lastPhaseIndex.map { NativeInstallPhase.allCases[$0] }
    }

    private mutating func decode(_ line: Data) throws -> NativeInstallEvent {
        guard terminal == nil else { throw NativeInstallProtocolError.eventAfterTerminal }
        eventCount += 1
        guard eventCount <= eventLimit else { throw NativeInstallProtocolError.tooManyEvents }
        guard String(data: line, encoding: .utf8) != nil else { throw NativeInstallProtocolError.invalidUTF8 }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: line) else {
            throw NativeInstallProtocolError.malformedJSON
        }
        guard wire.schema == 1 else { throw NativeInstallProtocolError.wrongSchema }
        guard wire.run_id == runID else { throw NativeInstallProtocolError.wrongRunID }
        if let last = lastSeq, wire.seq <= last { throw NativeInstallProtocolError.nonIncreasingSequence }
        lastSeq = wire.seq

        switch wire.type {
        case "phase":
            guard let raw = wire.phase, let phase = NativeInstallPhase(rawValue: raw),
                  let index = NativeInstallPhase.allCases.firstIndex(of: phase) else {
                throw NativeInstallProtocolError.malformedJSON
            }
            if let last = lastPhaseIndex, index <= last { throw NativeInstallProtocolError.phaseOutOfOrder }
            lastPhaseIndex = index
            return .phase(phase)

        case "wizard_ready":
            guard currentPhase == .wizard, !sawWizardReady else { throw NativeInstallProtocolError.unexpectedEvent }
            guard let origin = Self.loopbackOrigin(wire.origin) else { throw NativeInstallProtocolError.invalidOrigin }
            sawWizardReady = true
            return .wizardReady(origin)

        case "setup_saved":
            guard sawWizardReady, !sawSetupSaved else { throw NativeInstallProtocolError.unexpectedEvent }
            sawSetupSaved = true
            return .setupSaved

        case "service_ready":
            guard currentPhase == .readiness else { throw NativeInstallProtocolError.unexpectedEvent }
            guard let origin = Self.loopbackOrigin(wire.origin) else { throw NativeInstallProtocolError.invalidOrigin }
            let event = NativeInstallEvent.serviceReady(origin)
            terminal = event
            return event

        case "failed":
            guard let raw = wire.code, let code = NativeInstallFailureCode(rawValue: raw) else {
                throw NativeInstallProtocolError.unknownFailureCode
            }
            let event = NativeInstallEvent.failed(code)
            terminal = event
            return event

        default:
            throw NativeInstallProtocolError.unknownType
        }
    }

    /// Only `http://127.0.0.1:<port>` with a real port is trusted. Hosts,
    /// paths, zero or leading-zero ports, and out-of-range ports are rejected.
    private static func loopbackOrigin(_ raw: String?) -> Origin? {
        guard let raw,
              raw.range(of: #"^http://127\.0\.0\.1:[1-9][0-9]{0,4}\z"#, options: .regularExpression) != nil,
              let port = raw.split(separator: ":").last.flatMap({ Int($0) }),
              (1...65535).contains(port),
              let origin = Origin(raw) else { return nil }
        return origin
    }
}

enum NativeInstallFailure: Equatable {
    case installer(NativeInstallFailureCode)   // a `failed` event
    case downloadFailed                        // client could not fetch install.sh
    case checksumMismatch                      // fetched bytes != pin sha256
    case launchFailed                          // temp dir/write/posix_spawn failed
    case protocolViolation(NativeInstallProtocolError)
    case cancelledBeforeLaunch
}

enum NativeInstallState: Equatable {
    case idle
    case downloading
    case verifying
    case running(NativeInstallPhase?)
    case wizard(Origin)        // the only state in which the wizard origin is trusted
    case cancelling            // SIGTERM sent; waiting for the terminal event / exit
    case succeeded(Origin)     // service_ready origin
    case failed(NativeInstallFailure)

    var wizardOrigin: Origin? {
        if case .wizard(let origin) = self { return origin }
        return nil
    }

    var isActive: Bool {
        switch self {
        case .downloading, .verifying, .running, .wizard, .cancelling: return true
        case .idle, .succeeded, .failed: return false
        }
    }
}

enum NativeInstallCopy {
    static func message(for failure: NativeInstallFailure) -> String {
        switch failure {
        case .installer(let code):
            switch code {
            case .invalidArguments:
                return "The installer could not start because its arguments were invalid. Update Ciaobot for Mac and try again."
            case .existingInstall:
                return "Ciaobot is already installed on this Mac. Connect to it or start it from this screen; this installer does not update or repair an existing installation."
            case .partialInstall:
                return "A partial Ciaobot installation was found on this Mac. Nothing was changed. Repair or remove it before installing again."
            case .unknownState:
                return "The state of an existing Ciaobot installation could not be determined. Nothing was changed. Check the installation before installing again."
            case .installInProgress:
                return "Another Ciaobot installation is already running. Wait for it to finish. If an earlier installation was interrupted, follow “Recovering a native-install lock” in the Ciaobot development guide; the lock is never removed automatically."
            case .downloadFailed:
                return "The installer could not download Ciaobot. Check your internet connection and try again."
            case .verificationFailed:
                return "The downloaded Ciaobot engine could not be verified, so nothing was installed. Try again later."
            case .installFailed:
                return "Ciaobot could not be installed. The installer log is at ~/Library/Logs/Ciaobot/native-install.log."
            case .wizardFailed:
                return "Setup could not start. Another program may be using 127.0.0.1:8443; quit it and try again."
            case .activationRefused:
                return "Ciaobot could not start on the port you chose. Pick another port and try again."
            case .serviceNotReady:
                return "Ciaobot did not become ready on the port you chose. Something else may be using it; pick another port and try again."
            case .cancelled:
                return "Installation was cancelled. A Ciaobot service that had already started was left running."
            case .eventChannelFailed:
                return "The installer could not report its progress. Check whether Ciaobot is installed before trying again."
            case .internalError:
                return "The installer hit an unexpected error. Check whether Ciaobot is installed before trying again."
            }
        case .downloadFailed:
            return "Could not download the Ciaobot installer. Check your internet connection and try again."
        case .checksumMismatch:
            return "The downloaded installer did not match the expected version, so it was not run. Try again later."
        case .launchFailed:
            return "The installer could not be started on this Mac. Nothing was installed."
        case .protocolViolation:
            return "The installer sent an unexpected progress report, so the installation was stopped. Check whether Ciaobot is installed before trying again."
        case .cancelledBeforeLaunch:
            return "Installation was cancelled before anything was installed."
        }
    }

    /// A short status line for the progress UI, or nil when no progress is shown.
    static func progress(for state: NativeInstallState) -> String? {
        switch state {
        case .downloading:
            return "Downloading the installer…"
        case .verifying:
            return "Verifying the installer…"
        case .running(let phase):
            guard let phase else { return "Starting the installer…" }
            switch phase {
            case .preflight: return "Checking this Mac…"
            case .bootstrap: return "Preparing tools…"
            case .download: return "Downloading Ciaobot…"
            case .install: return "Installing Ciaobot…"
            case .wizard: return "Starting setup…"
            case .activation: return "Starting Ciaobot…"
            case .readiness: return "Waiting for Ciaobot to be ready…"
            }
        case .wizard:
            return "Complete setup in the window below."
        case .cancelling:
            return "Cancelling…"
        case .idle, .succeeded, .failed:
            return nil
        }
    }
}
