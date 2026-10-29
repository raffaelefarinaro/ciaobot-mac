import Foundation

/// One connection screen operation at a time. Connect can be started from the
/// button or from Return, so a boolean is not enough: forget and connect must
/// not overlap, and a late completion from one task must not clear the other.
enum ConnectionTask: Equatable {
    case idle
    case checking
    case forgetting
}

struct ConnectionTaskGate: Equatable {
    private(set) var task: ConnectionTask = .idle

    var isBusy: Bool { task != .idle }

    mutating func beginCheck() -> Bool {
        guard task == .idle else { return false }
        task = .checking
        return true
    }

    mutating func endCheck() {
        if task == .checking { task = .idle }
    }

    mutating func beginForget() -> Bool {
        guard task == .idle else { return false }
        task = .forgetting
        return true
    }

    mutating func endForget() {
        if task == .forgetting { task = .idle }
    }
}

/// Copy for the connection screen. Kept out of the SwiftUI view so the words
/// that describe a fail-closed state can be tested.
enum PersistentSignInCopy {
    static func explanation(origin: Origin?, persistentAvailable: Bool, registryAvailable: Bool) -> String {
        guard let origin else {
            return "Persistent sign-in applies only to HTTPS addresses on macOS 14 or later."
        }
        if !origin.usesTLS {
            return "Persistent sign-in is HTTPS-only. This address uses an in-memory store that is discarded when the app quits."
        }
        if !persistentAvailable {
            return "Persistent sign-in requires macOS 14 or later. This session stays in memory."
        }
        if !registryAvailable {
            return "The saved sign-in list on this Mac could not be used, so this session stays in memory. Persistent sign-in stays unavailable until the list is repaired. Do not delete it: it is the only record of the saved sign-ins this app can remove."
        }
        return "Stores this server’s sign-in in its own WebKit store, keyed by scheme, host, and port. Another address gets a separate store, and a saved session is used only when this option is on for the launch."
    }
}

/// Evidence that the connection's WKWebView is gone before its store is
/// erased. WebKit refuses to remove a store that a view still uses, so forget
/// must not claim the view was released unless the weak reference is actually
/// nil. The tracker holds the view weakly and polls the main queue.
@MainActor
final class SessionViewTracker {
    static let pollInterval: TimeInterval = 0.01

    private weak var view: AnyObject?

    var isReleased: Bool { view == nil }

    func attach(_ view: AnyObject) {
        self.view = view
    }

    func whenReleased(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        poll(deadline: Date().addingTimeInterval(timeout), completion: completion)
    }

    private func poll(deadline: Date, completion: @escaping (Bool) -> Void) {
        if view == nil {
            completion(true)
            return
        }
        if Date() >= deadline {
            completion(false)
            return
        }
        Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            self.poll(deadline: deadline, completion: completion)
        }
    }
}
