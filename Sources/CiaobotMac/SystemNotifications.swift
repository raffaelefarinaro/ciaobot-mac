import Foundation
import UserNotifications

/// Only the default click opens a chat. Dismiss, clear, and any custom action
/// must never navigate.
enum NotificationResponsePolicy {
    static func target(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> ChatNotificationTarget? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              let chatID = userInfo["chat_id"] as? String,
              let origin = userInfo["origin"] as? String else { return nil }
        return ChatNotificationTarget(chatID: chatID, origin: origin)
    }
}

/// The real UserNotifications surface. `isAvailable` means only that this
/// process has a bundle identifier and a `.app` wrapper: the one condition
/// this client can establish before touching UserNotifications. It is not a
/// code-signature check. An unsigned or improperly provisioned bundle can
/// still be available here and then fail at the OS boundary; that failure is
/// preserved as a technical error, never folded into a user denial.
///
/// Nothing here requests permission except `requestAuthorization`, which the
/// controller calls only from the explicit menu action.
@MainActor
final class SystemNotificationPermissionClient: NSObject, NotificationPermissionClient, UNUserNotificationCenterDelegate {
    let isAvailable: Bool
    var onActivation: ((ChatNotificationTarget) -> Void)? {
        didSet {
            // A click that launched the app can be delivered before the
            // controller exists. Hold it until the handler is installed.
            guard let target = pendingActivation, let onActivation else { return }
            pendingActivation = nil
            DispatchQueue.main.async {
                onActivation(target)
            }
        }
    }

    private var notificationCenter: UNUserNotificationCenter?
    private var pendingActivation: ChatNotificationTarget?

    init(bundle: Bundle = .main) {
        // A debug executable run from `.build/debug` has no usable app bundle.
        // Treat it as unavailable rather than crashing in UserNotifications.
        self.isAvailable = bundle.bundleIdentifier != nil && bundle.bundleURL.pathExtension == "app"
        super.init()
    }

    func prepare() {
        guard isAvailable else { return }
        _ = resolvedCenter()
    }

    func authorizationStatus(completion: @escaping (ChatNotificationAuthorization) -> Void) {
        guard isAvailable else {
            completion(.unavailable)
            return
        }
        resolvedCenter().getNotificationSettings { settings in
            let status: ChatNotificationAuthorization
            switch settings.authorizationStatus {
            case .notDetermined:
                status = .notDetermined
            case .authorized, .provisional, .ephemeral:
                status = .authorized
            case .denied:
                status = .denied
            @unknown default:
                status = .unknown("macOS reported an unrecognized notification authorization status.")
            }
            Task { @MainActor in completion(status) }
        }
    }

    func requestAuthorization(completion: @escaping (ChatNotificationAuthorizationRequest) -> Void) {
        guard isAvailable else {
            completion(.unavailable)
            return
        }
        // `.alert` and `.badge` only. No provisional request and no sound: the
        // user asked for a visible completion notice, not a quiet or audible
        // subscription.
        resolvedCenter().requestAuthorization(options: [.alert, .badge]) { granted, error in
            let result: ChatNotificationAuthorizationRequest
            if let error {
                // A missing identity, an unsigned bundle, or a provisioning
                // failure arrives here. Preserve the exact message; it is not
                // a user denial.
                result = .failed(error.localizedDescription)
            } else {
                result = granted ? .granted : .denied
            }
            Task { @MainActor in completion(result) }
        }
    }

    func deliver(_ message: ChatNotificationMessage) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.threadIdentifier = "ciaobot.chat"
        content.userInfo = [
            "chat_id": message.target.chatID,
            "origin": message.target.origin,
        ]
        if #available(macOS 12.0, *) {
            content.interruptionLevel = .active
        }
        let request = UNNotificationRequest(
            identifier: message.identifier,
            content: content,
            trigger: nil
        )
        resolvedCenter().add(request) { error in
            // The title and body are user data. Log only the failure, never
            // the notification content.
            if let error {
                NSLog("Ciaobot notification delivery failed: %@", error.localizedDescription)
            }
        }
    }

    private func resolvedCenter() -> UNUserNotificationCenter {
        if let notificationCenter { return notificationCenter }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        notificationCenter = center
        return center
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .list])
        } else {
            completionHandler([.alert])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        guard let target = NotificationResponsePolicy.target(
            actionIdentifier: response.actionIdentifier,
            userInfo: info
        ) else {
            completionHandler()
            return
        }
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self else { return }
            if let onActivation = self.onActivation {
                onActivation(target)
            } else {
                self.pendingActivation = target
            }
        }
    }
}
