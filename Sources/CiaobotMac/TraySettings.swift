import AppKit
import ServiceManagement

/// Which explicit action failed. A failed stop must be retried as a stop, not
/// silently turned into an enable on the next click.
enum LoginItemOperation: Equatable {
    case register
    case unregister
}

/// The truthful state of the macOS login item. `requiresApproval` is not
/// success: the app has been registered but macOS has not started it at login
/// yet. `unavailable` and `failed` carry the exact reason shown to the user.
enum LoginItemState: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case unavailable(String)
    case failed(operation: LoginItemOperation, reason: String)
}

/// The login-item surface behind the tray row. Tests inject a double so no
/// test ever registers the operator's Mac as a login item. Registration is
/// only ever reached from an explicit menu click.
@MainActor
protocol LoginItemControlling: AnyObject {
    var state: LoginItemState { get }
    func refresh()
    func register() throws
    func unregister() throws
}

/// `SMAppService.mainApp` plus the bundle guard. A bare `swift build`
/// executable is not a login-item-capable app, so it reports a fixed reason
/// without touching ServiceManagement. Nothing here registers at launch.
@MainActor
final class SystemLoginItem: LoginItemControlling {
    static let bareExecutableReason =
        "Start at Login requires the bundled Ciaobot.app. A bare debug executable cannot register itself as a login item."
    static let notFoundReason =
        "macOS could not find this app as a login item. Move Ciaobot.app to Applications, then try again."

    private let isAvailable: Bool
    private(set) var state: LoginItemState

    init(bundle: Bundle = .main) {
        let available = bundle.bundleIdentifier != nil && bundle.bundleURL.pathExtension == "app"
        self.isAvailable = available
        self.state = available ? .notRegistered : .unavailable(Self.bareExecutableReason)
        if available {
            refresh()
        }
    }

    func refresh() {
        guard isAvailable else { return }
        state = Self.state(for: SMAppService.mainApp.status)
    }

    func register() throws {
        guard isAvailable else {
            throw LoginItemError.unavailable(Self.bareExecutableReason)
        }
        do {
            try SMAppService.mainApp.register()
        } catch {
            refresh()
            // Keep a real status such as `.requiresApproval` or `.enabled`.
            // Only an unchanged not-registered state becomes a failed action.
            if state == .notRegistered {
                state = .failed(operation: .register, reason: Self.message(for: error))
            }
            throw error
        }
        refresh()
    }

    func unregister() throws {
        guard isAvailable else {
            throw LoginItemError.unavailable(Self.bareExecutableReason)
        }
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            refresh()
            // Preserve the OS result. If the app is still enabled, the failed
            // action was a stop and must stay a stop for retry. If macOS now
            // reports notRegistered, the stop actually took effect.
            if state == .enabled {
                state = .failed(operation: .unregister, reason: Self.message(for: error))
            }
            throw error
        }
        refresh()
    }

    /// Pure mapping, so tests can prove every macOS status without asking the
    /// operating system to change this Mac's login items.
    static func state(for status: SMAppService.Status) -> LoginItemState {
        switch status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .unavailable(notFoundReason)
        @unknown default:
            return .unavailable("macOS reported an unknown login-item status.")
        }
    }

    static func message(for error: Error) -> String {
        "macOS could not change the login item: \(error.localizedDescription)"
    }
}

enum LoginItemError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        }
    }
}

/// The persisted Dock preference. The menu-bar item is independent of the
/// activation policy, so hiding the Dock icon leaves the tray icon in place.
@MainActor
protocol DockIconControlling: AnyObject {
    var hidesDockIcon: Bool { get }
    func setHidesDockIcon(_ hidden: Bool)
    /// Apply the saved choice at launch. It never changes the saved value.
    func applyPersistedPreference()
    /// Open needs a regular app so its window can become key. The tray item is
    /// not part of the Dock and stays visible.
    func prepareForWindowPresentation()
    /// Return to the saved policy after the main window closes.
    func windowDidClose()
}

protocol DockIconPreferenceStoring: AnyObject {
    var hidesDockIcon: Bool { get set }
}

final class UserDefaultsDockIconPreferenceStore: DockIconPreferenceStoring {
    static let defaultKey = "CiaobotHideDockIcon"

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = UserDefaultsDockIconPreferenceStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    var hidesDockIcon: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}

@MainActor
protocol ActivationPolicyApplying: AnyObject {
    var currentPolicy: NSApplication.ActivationPolicy { get }
    func setPolicy(_ policy: NSApplication.ActivationPolicy)
}

@MainActor
final class ApplicationActivationPolicy: ActivationPolicyApplying {
    var currentPolicy: NSApplication.ActivationPolicy { NSApp.activationPolicy() }

    func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
}

@MainActor
final class DockIconController: DockIconControlling {
    private let preferences: DockIconPreferenceStoring
    private let policy: ActivationPolicyApplying
    private let mainWindowIsOpen: () -> Bool

    init(
        preferences: DockIconPreferenceStoring = UserDefaultsDockIconPreferenceStore(),
        policy: ActivationPolicyApplying? = nil,
        mainWindowIsOpen: (@MainActor () -> Bool)? = nil
    ) {
        self.preferences = preferences
        self.policy = policy ?? ApplicationActivationPolicy()
        self.mainWindowIsOpen = mainWindowIsOpen ?? Self.systemMainWindowIsOpen
    }

    var hidesDockIcon: Bool { preferences.hidesDockIcon }

    func setHidesDockIcon(_ hidden: Bool) {
        preferences.hidesDockIcon = hidden
        guard hidden else {
            // Turning the preference off must show the Dock icon now, even if
            // the window is closed.
            policy.setPolicy(.regular)
            return
        }
        applyPersistedPreference()
    }

    func applyPersistedPreference() {
        guard hidesDockIcon else { return }
        // The saved choice only hides the Dock while the main window is
        // closed. An open window stays a regular app so it can be key.
        policy.setPolicy(mainWindowIsOpen() ? .regular : .accessory)
    }

    func prepareForWindowPresentation() {
        policy.setPolicy(.regular)
    }

    func windowDidClose() {
        guard hidesDockIcon else { return }
        // `willClose` still reports the window as visible, so do not consult
        // `mainWindowIsOpen` here: the window is closing right now.
        policy.setPolicy(.accessory)
    }

    private static func systemMainWindowIsOpen() -> Bool {
        NSApp.windows.contains {
            $0.identifier == MainWindowPresenter.mainWindowIdentifier && $0.isVisible
        }
    }
}

/// Fixed, app-owned destinations for macOS Settings. A server, page, or chat
/// never supplies these URLs. The notification link is used only when macOS
/// itself is blocking notifications; it is never offered for a missing sign-in
/// or a missing server connection.
@MainActor
protocol SystemSettingsOpening: AnyObject {
    func openNotificationSettings()
    func openLoginItemsSettings()
}

@MainActor
final class WorkspaceSystemSettings: SystemSettingsOpening {
    static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    )!
    static let loginItemsSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    )!

    private let open: (URL) -> Void

    init(open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.open = open
    }

    func openNotificationSettings() {
        open(Self.notificationSettingsURL)
    }

    func openLoginItemsSettings() {
        open(Self.loginItemsSettingsURL)
    }
}

/// The one action behind the tray's "Change Connected Host" item. It presents
/// the client window and, only after that presentation is confirmed, asks its
/// existing connection screen to take over; it never contacts, restarts, or
/// reconfigures the separately installed server. A failed presentation is
/// reported by the presenter and this action does nothing else, so the change
/// request cannot be silently dropped. The connection screen clears the
/// previous sign-in consent itself, so a new host still requires a fresh,
/// explicit opt-in.
@MainActor
enum ConnectionMenuActions {
    static func changeConnectedHost(present: @escaping () -> Bool) -> () -> Void {
        return {
            guard present() else { return }
            NotificationCenter.default.post(name: .ciaobotChangeServer, object: nil)
        }
    }
}
