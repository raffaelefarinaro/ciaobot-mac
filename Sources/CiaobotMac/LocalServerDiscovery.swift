import Combine
import Foundation

/// The one address the connection screen may check on its own. It is a fixed
/// same-Mac candidate, not a search: there is no port loop, no Bonjour lookup,
/// and no process or lock inspection.
enum LocalServerCandidate {
    static let address = "http://127.0.0.1:8443"
    static let origin = Origin(address)
}

/// Whether the connection screen may start the candidate check by itself.
/// Automatic same-Mac discovery is a production convenience only: the debug
/// app used by the test suite must never contact the real candidate.
enum LocalServerDiscoveryPolicy {
    static func automaticallyProbes(isDebugBuild: Bool, testLaunchRequested: Bool) -> Bool {
        !isDebugBuild && !testLaunchRequested
    }

    static var automaticInThisBuild: Bool {
        #if DEBUG
        automaticallyProbes(isDebugBuild: true, testLaunchRequested: true)
        #else
        automaticallyProbes(isDebugBuild: false, testLaunchRequested: false)
        #endif
    }
}

/// A same-Mac hint for the connection screen. It asks the existing
/// credential-free `Probe` about one fixed candidate and reports only whether
/// the startup response shape came back. It does not identify the server or
/// its process, does not treat a startup identifier as authentication, and
/// never navigates or signs in. A result is a hint, not a connection decision.
@MainActor
final class LocalServerDiscovery: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case responded
        case notDetected
    }

    nonisolated static var defaultCandidate: Origin? { LocalServerCandidate.origin }

    @Published private(set) var status: Status = .idle

    private let candidate: Origin?
    private let transport: (Origin, @escaping (Bool) -> Void) -> Void
    /// Guards against a late response from a check that belonged to a screen
    /// that is no longer displayed, or to an older check on the same screen.
    private var generation = 0

    init(
        candidate: Origin? = LocalServerDiscovery.defaultCandidate,
        transport: @escaping (Origin, @escaping (Bool) -> Void) -> Void = { origin, completion in
            Probe().check(origin, completion: completion)
        }
    ) {
        self.candidate = candidate
        self.transport = transport
    }

    var isChecking: Bool { status == .checking }
    var address: String { candidate?.canonicalKey ?? LocalServerCandidate.address }
    var statusText: String { LocalServerDiscoveryCopy.text(for: status, address: address) }

    /// Starts one check. Returns false when there is no candidate or a check
    /// is already in flight, so a double click or a repeated Return cannot
    /// multiply the request.
    @discardableResult
    func refresh() -> Bool {
        guard let candidate, status != .checking else { return false }
        generation &+= 1
        let request = generation
        status = .checking
        transport(candidate) { [weak self] responded in
            guard let self, self.generation == request, self.status == .checking else { return }
            self.status = responded ? .responded : .notDetected
        }
        return true
    }

    /// The connection screen went away (or the selected server changed). A
    /// response that arrives afterwards must not update the new screen.
    func invalidate() {
        generation &+= 1
        status = .idle
    }
}

/// Copy for the same-Mac hint. The wording deliberately separates "something
/// answered this fixed address" from "this is the server you want" so a local
/// process, lock file, or startup identifier is never presented as identity.
enum LocalServerDiscoveryCopy {
    static let accessibilityLabel = "Local server status"
    static let hint = "Uses one credential-free request to 127.0.0.1:8443. It does not sign in, navigate, or check other ports."

    static func text(for status: LocalServerDiscovery.Status, address: String) -> String {
        switch status {
        case .idle:
            return "Local server check has not run. A response would not be proof of identity."
        case .checking:
            return "Checking for a local server…"
        case .responded:
            return "Local server responded at \(address). This only means the address returned the expected startup response; it is not proof of the server’s identity or who runs it."
        case .notDetected:
            return "No local server detected at \(address). This only means nothing answered the startup check; it is not proof about what is installed or running."
        }
    }
}
