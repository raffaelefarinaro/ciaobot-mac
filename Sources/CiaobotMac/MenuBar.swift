import AppKit
import Combine

/// The menu-bar item surface the controller needs. Tests use a double so they
/// never add an icon to the operator's real menu bar.
@MainActor
protocol MenuBarStatusItem: AnyObject {
    var title: String? { get set }
    var image: NSImage? { get set }
    var toolTip: String? { get set }
    var menu: NSMenu? { get set }
    var isVisible: Bool { get set }
    func remove()
}

protocol StatusItemFactory {
    @MainActor func makeStatusItem(length: CGFloat) -> MenuBarStatusItem
}

@MainActor
private final class SystemMenuBarStatusItem: MenuBarStatusItem {
    private let item: NSStatusItem

    init(_ item: NSStatusItem) {
        self.item = item
        // Keep the face on the left and the attention count on the right. The
        // status item is variable length so the digits are never clipped.
        item.button?.imagePosition = .imageLeading
    }

    var title: String? {
        get { item.button?.title }
        set { item.button?.title = newValue ?? "" }
    }

    var image: NSImage? {
        get { item.button?.image }
        set { item.button?.image = newValue }
    }

    var toolTip: String? {
        get { item.button?.toolTip }
        set { item.button?.toolTip = newValue }
    }

    var menu: NSMenu? {
        get { item.menu }
        set { item.menu = newValue }
    }

    var isVisible: Bool {
        get { item.isVisible }
        set { item.isVisible = newValue }
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }
}

struct SystemStatusItemFactory: StatusItemFactory {
    func makeStatusItem(length: CGFloat) -> MenuBarStatusItem {
        SystemMenuBarStatusItem(NSStatusBar.system.statusItem(withLength: length))
    }
}

/// The lifecycle surface `AppDelegate` needs, so launch can be tested without
/// creating a real status item.
@MainActor
protocol MenuBarControlling: AnyObject {
    func start()
    func stop()
}

/// Bounds and cleans untrusted server text before it reaches AppKit. Chat
/// titles and workspace names are data from the selected server, not trusted
/// menu structure: line breaks, control/format characters, bidi overrides, and
/// invisible separators are removed so a title cannot forge another menu row
/// or reorder its neighbours.
enum MenuTextSanitizer {
    static func sanitize(_ raw: String, limit: Int, fallback: String) -> String {
        var output = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in raw.unicodeScalars {
            let category = scalar.properties.generalCategory
            if category == .format { continue }
            if category == .spaceSeparator || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace {
                    output.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            if category == .control || category == .lineSeparator || category == .paragraphSeparator || category == .surrogate {
                continue
            }
            output.append(scalar)
            lastWasSpace = false
        }
        let cleaned = String(output).trimmingCharacters(in: .whitespacesAndNewlines)
        // Bound the scalar count as well as the grapheme count. A single
        // grapheme can contain thousands of combining marks, so a character
        // limit alone would still let an untrusted title carry a large string.
        let maxScalars = max(1, limit * 8)
        let scalarBounded: String
        if cleaned.unicodeScalars.count > maxScalars {
            var view = String.UnicodeScalarView()
            for scalar in cleaned.unicodeScalars.prefix(maxScalars) {
                view.append(scalar)
            }
            scalarBounded = String(view)
        } else {
            scalarBounded = cleaned
        }
        let base = scalarBounded.isEmpty ? fallback : scalarBounded
        let clipped = clip(base, limit: limit)
        return clipped.isEmpty ? fallback : clipped
    }

    static func clip(_ text: String, limit: Int) -> String {
        let bounded = max(1, limit)
        guard text.count > bounded else { return text }
        let end = text.index(text.startIndex, offsetBy: bounded - 1)
        return String(text[..<end]) + "…"
    }
}

/// A deliberately small status item: the connection fact, an attention badge,
/// a truthful chat list from the selected server, Open, one compact Settings
/// submenu (which owns the notification state and every recovery action), and
/// Quit. It never owns the server, never quits the server, and never invents
/// chats, counts, or lifecycle state.
@MainActor
final class MenuBarController: NSObject, MenuBarControlling, NSMenuDelegate {
    static let openTitle = "Open Ciaobot"
    static let quitTitle = "Quit Ciaobot"
    static let disconnectedTitle = "Not connected"
    static let connectedTitlePrefix = "Connected to "
    static let toolTip = "Ciaobot"
    static let loadingChatsTitle = "Loading chats…"
    static let noChatsTitle = "No open chats"
    static let noRelevantChatsTitle = "No unread or needs-you chats"
    static let notSignedInTitle = "Sign in to see chats"
    static let chatsUnavailableTitle = "Chat list unavailable"
    static let noAttentionTitle = "No chats need attention"
    static let notificationsOffTitle = "Turn On Chat Notifications…"
    static let notificationsOnTitle = "Chat Notifications On"
    static let settingsTitle = "Settings"
    static let notificationsWaitingTitle = "Notifications on — connect to a server"
    static let notificationsSignInTitle = "Notifications on — sign in to receive"
    static let notificationsConnectingTitle = "Notifications on — connecting…"
    static let notificationsRetryingTitle = "Notifications on — reconnecting…"
    static let notificationsAuthenticationRefusedTitle = "Notifications on — server refused app authentication"
    static let notificationsOriginRejectedTitle = "Notifications on — server rejected this app's origin"
    static let notificationsRedirectedTitle = "Notifications on — event stream redirected; not followed"
    static let notificationsProtocolErrorTitle = "Notifications on — unexpected server event"
    static let notificationsBlockedTitle = "Notifications blocked by macOS — Open Settings…"
    static let notificationsDeliveryOffTitle = "Notifications allowed but turned off in macOS — Open Settings…"
    static let notificationsUnbundledTitle = "Notifications unavailable — bare executable; use Ciaobot.app"
    static let notificationsPermissionRequestFailedTitle = "Notifications unavailable — registration failed; use signed Ciaobot.app"
    static let notificationsUnknownAuthorizationTitle = "Notifications unavailable — unknown macOS permission state"
    static let signInForNotificationsTitle = "Open Ciaobot to Sign In…"
    static let connectForNotificationsTitle = "Connect in Ciaobot…"
    static let checkServerForNotificationsTitle = "Open Ciaobot to Check the Server…"
    static let loginItemTitle = "Start at Login"
    static let loginItemApprovalTitle = "Start at Login — Approval Needed…"
    static let loginItemUnavailableTitle = "Start at Login Unavailable"
    static let loginItemFailedTitle = "Start at Login Failed"
    static let loginItemRemoveFailedTitle = "Start at Login — Stop Failed"
    static let hideDockIconTitle = "Hide Dock Icon"
    static let changeHostTitle = "Change Connected Host…"
    static let updatesUnavailableTitle = "Updates unavailable"
    static let checkForUpdatesTitle = "Check for Updates…"
    /// Says exactly what restarts: this Mac client. The Ciaobot engine and the
    /// web app it serves are separate processes and stay running.
    static let checkForUpdatesToolTip = "Download and install a verified Ciaobot update. An automatic update restarts this Mac client only; the Ciaobot engine and the web app keep running."
    /// A visible label if the bundled template is missing. It is not a status
    /// claim and the item still carries the same limited menu.
    static let fallbackTitle = "C"

    private let status: AppSessionStatus
    private let statusItemFactory: StatusItemFactory
    private let sourceImage: NSImage?
    private let openWindow: () -> Void
    private let quit: () -> Void
    private let chatList: ChatListProviding?
    /// The Dock badge reads the same snapshot as the status-bar badge; it is
    /// optional so a test never touches the real Dock tile.
    private let dockBadge: DockBadgeApplying?
    private let openChatHandler: ((String) -> Bool)?
    private let chatUnavailableHandler: (String) -> Void
    private let notifications: NotificationMenuProviding?
    private let activity: ChatActivityProviding?
    private let loginItem: LoginItemControlling?
    private let dockIcon: DockIconControlling?
    private let systemSettings: SystemSettingsOpening?
    /// How a diagnostic Start at Login row explains itself. Tests inject a
    /// recorder so no test shows a modal alert.
    private let loginItemExplanation: (LoginItemUnavailability, (() -> Void)?) -> Void
    private let changeHost: (() -> Void)?
    private let updates: ClientUpdateControlling?
    private let now: () -> Date
    private var subscription: AnyCancellable?
    private var chatStateSubscription: AnyCancellable?
    private var activityStateSubscription: AnyCancellable?
    private var notificationStateSubscription: AnyCancellable?
    private var notificationStreamSubscription: AnyCancellable?
    private var statusEntry: NSMenuItem?
    private var menuIsOpen = false
    private var needsChatRebuild = false
    /// The origin whose attention count the current badge came from. It lets a
    /// connection sink that re-reports the same origin keep the number, while a
    /// genuine origin switch clears it before the deferred rebuild.
    private var badgeOrigin: String?

    private(set) var statusItem: MenuBarStatusItem?
    private(set) var menu: NSMenu?

    init(
        status: AppSessionStatus,
        statusItemFactory: StatusItemFactory = SystemStatusItemFactory(),
        image: NSImage? = AppAssets.menuBarImage,
        openWindow: @escaping () -> Void,
        quit: @escaping () -> Void,
        chatList: ChatListProviding? = nil,
        dockBadge: DockBadgeApplying? = nil,
        openChat: ((String) -> Bool)? = nil,
        chatUnavailable: ((String) -> Void)? = nil,
        notifications: NotificationMenuProviding? = nil,
        activity: ChatActivityProviding? = nil,
        loginItem: LoginItemControlling? = nil,
        dockIcon: DockIconControlling? = nil,
        systemSettings: SystemSettingsOpening? = nil,
        loginItemExplanation: ((LoginItemUnavailability, (() -> Void)?) -> Void)? = nil,
        changeHost: (() -> Void)? = nil,
        updates: ClientUpdateControlling? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.status = status
        self.statusItemFactory = statusItemFactory
        self.sourceImage = image
        self.openWindow = openWindow
        self.quit = quit
        self.chatList = chatList
        self.dockBadge = dockBadge
        self.openChatHandler = openChat
        self.chatUnavailableHandler = chatUnavailable ?? Self.presentChatUnavailable
        self.notifications = notifications
        self.activity = activity
        self.loginItem = loginItem
        self.dockIcon = dockIcon
        self.systemSettings = systemSettings
        self.loginItemExplanation = loginItemExplanation ?? Self.presentLoginItemUnavailable
        self.changeHost = changeHost
        self.updates = updates
        self.now = now
        super.init()
    }

    /// A chat can stop being openable between building the menu and clicking
    /// it (a disconnect/switch race). Never leave that click silent.
    private static func presentChatUnavailable(_ chatID: String) {
        let alert = NSAlert()
        alert.messageText = "Could not open the chat"
        alert.informativeText = "Ciaobot is not ready to open that chat. Reconnect if the server changed, then try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func start() {
        guard statusItem == nil else { return }

        let item = statusItemFactory.makeStatusItem(length: NSStatusItem.variableLength)
        if let sourceImage, let template = sourceImage.copy() as? NSImage {
            // The legacy face is black-plus-alpha. Marking it as a template is
            // what makes macOS draw it in the correct light/dark menu-bar tint.
            template.isTemplate = true
            template.size = AppAssets.menuBarImagePointSize
            item.image = template
            item.title = ""
        } else {
            item.image = nil
            item.title = Self.fallbackTitle
        }
        item.toolTip = Self.toolTip

        let menu = NSMenu()
        // The menu is entirely app-managed: keep explicit enabled state
        // instead of letting AppKit re-validate every row.
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        item.isVisible = true

        statusItem = item
        self.menu = menu
        rebuildMenu()

        subscription = status.$connection.sink { [weak self] connection in
            self?.statusChanged(connection)
        }
        chatStateSubscription = chatList?.statePublisher.sink { [weak self] _ in
            // `@Published` sends before the new value is stored. Rebuild on the
            // next main-loop turn so the menu and tooltip read the settled
            // state instead of the previous snapshot.
            DispatchQueue.main.async { self?.chatStateChanged() }
        }
        activityStateSubscription = activity?.statePublisher.sink { [weak self] _ in
            // `@Published` sends before the new value is stored. Rebuild on the
            // next main-loop turn so the row reads the settled state.
            DispatchQueue.main.async { self?.chatStateChanged() }
        }
        notificationStateSubscription = notifications?.statePublisher.sink { [weak self] _ in
            // `@Published` sends before the new value is stored. Rebuild on the
            // next main-loop turn so the row reads the settled state.
            DispatchQueue.main.async { self?.chatStateChanged() }
        }
        notificationStreamSubscription = notifications?.streamStatusPublisher.sink { [weak self] _ in
            DispatchQueue.main.async { self?.chatStateChanged() }
        }
        chatList?.start()
        activity?.start()
        updateToolTip()
    }

    func stop() {
        notificationStreamSubscription?.cancel()
        notificationStreamSubscription = nil
        notificationStateSubscription?.cancel()
        notificationStateSubscription = nil
        activityStateSubscription?.cancel()
        activityStateSubscription = nil
        chatStateSubscription?.cancel()
        chatStateSubscription = nil
        chatList?.stop()
        activity?.stop()
        notifications?.stop()
        subscription?.cancel()
        subscription = nil
        statusItem?.remove()
        statusItem = nil
        menu = nil
        statusEntry = nil
        menuIsOpen = false
        needsChatRebuild = false
        badgeOrigin = nil
    }

    /// Exposed for tests and for the menu item itself; reading it is the only
    /// way the status line is produced.
    var statusTitle: String? { statusEntry?.title }

    static func statusTitle(for connection: AppSessionStatus.Connection) -> String {
        switch connection {
        case .disconnected:
            return disconnectedTitle
        case .connected(let origin):
            return connectedTitlePrefix + origin
        }
    }

    /// The endpoint's attention count, attributed to the server. The payload
    /// only covers unread and `needs_input`; Home also files failed turns, board
    /// tasks, and memory passes that this endpoint does not send. The wording
    /// therefore never claims to be a complete homepage status count.
    static func attentionTitle(_ count: Int) -> String {
        guard count > 0 else { return noAttentionTitle }
        return count == 1
            ? "1 chat needs attention on the server"
            : "\(count) chats need attention on the server"
    }

    /// The compact status-bar badge. It is empty for a zero, negative, or
    /// unknown count, so the face never carries a number the server did not
    /// stand behind. A count is already deduplicated by the server contract
    /// and by `ChatListPayload.decode`; working chats are not added to it.
    /// It shares `DockBadgeTitle` with the Dock badge, so both surfaces apply
    /// exactly the same rule; only the empty-string spelling differs.
    static func attentionBadgeTitle(_ count: Int?) -> String {
        DockBadgeTitle.label(for: count) ?? ""
    }

    static func notificationTitle(
        for state: ChatNotificationState,
        streamStatus: ChatNotificationStreamStatus
    ) -> String {
        switch state {
        case .off:
            return notificationsOffTitle
        case .on:
            switch streamStatus {
            case .ready: return notificationsOnTitle
            case .notConnected: return notificationsWaitingTitle
            case .waitingForAuthentication: return notificationsSignInTitle
            case .connecting: return notificationsConnectingTitle
            case .retrying: return notificationsRetryingTitle
            case .authenticationRefused: return notificationsAuthenticationRefusedTitle
            case .originRejected: return notificationsOriginRejectedTitle
            case .redirected: return notificationsRedirectedTitle
            case .protocolError: return notificationsProtocolErrorTitle
            }
        case .denied:
            return notificationsBlockedTitle
        case .deliveryOff:
            return notificationsDeliveryOffTitle
        case .unavailable(let reason):
            switch reason {
            case .unbundled:
                return notificationsUnbundledTitle
            case .permissionRequestFailed:
                return notificationsPermissionRequestFailedTitle
            case .unknownAuthorization:
                return notificationsUnknownAuthorizationTitle
            }
        }
    }

    static func notificationToolTip(
        for state: ChatNotificationState,
        streamStatus: ChatNotificationStreamStatus
    ) -> String {
        switch state {
        case .off:
            return "Ask macOS for permission and show a banner when a chat finishes."
        case .on:
            switch streamStatus {
            case .ready:
                return "Chat completion banners are on. Click the status row to turn them off on this Mac."
            case .notConnected:
                return "Notifications are on. Connect to a server in the Ciaobot window to start them. The status row still turns notifications off."
            case .waitingForAuthentication:
                return "Notifications are on, but the authenticated event stream needs a signed-in session. Sign in on the server in the Ciaobot window, then open this menu again. The status row still turns notifications off."
            case .connecting:
                return "Notifications are on. The authenticated event stream is connecting. The status row turns them off."
            case .retrying:
                return "Notifications are on. The event stream closed and is reconnecting. The status row turns them off."
            case .authenticationRefused:
                return "The server refused this app's TLS, proxy, or client authentication, so no event stream is active. The client did not send another credential or retry automatically. Check the server in Ciaobot; the status row still turns notifications off."
            case .originRejected:
                return "The server rejected the exact Origin this app supplied, so no event stream is active. The client did not retry automatically. Check the selected server in Ciaobot; the status row still turns notifications off."
            case .redirected:
                return "The event stream redirected. The client did not follow it and did not carry the session cookie to the new target. Check the selected server in Ciaobot; the status row still turns notifications off."
            case .protocolError:
                return "The server sent an event this client cannot decode. The client did not retry automatically. Check the server in Ciaobot; the status row still turns notifications off."
            }
        case .denied:
            return "macOS is blocking notifications for Ciaobot. Open System Settings > Notifications, select Ciaobot, allow banners, then open this menu again. Focus must also be off; Ciaobot cannot detect Focus."
        case .deliveryOff:
            return "macOS allows Ciaobot to notify you, but both its banners and its Notification Center entries are turned off, so nothing would appear. Open System Settings > Notifications, select Ciaobot, allow banners, then open this menu again. Focus must also be off; Ciaobot cannot detect Focus."
        case .unavailable(let reason):
            switch reason {
            case .unbundled:
                return "This process is not a bundled .app and has no notification identity. Use the built, bundled Ciaobot.app; System Settings cannot add an identity to this process."
            case .permissionRequestFailed(let detail):
                return "macOS could not register this build for notifications: \(sanitizedNoticeDetail(detail)). The client cannot tell from here whether the build is unsigned; use the signed Ciaobot.app. System Settings cannot add a notification identity."
            case .unknownAuthorization(let detail):
                return "macOS returned an unrecognized notification permission state: \(sanitizedNoticeDetail(detail)). Open Ciaobot again; if it persists, use the signed Ciaobot.app."
            }
        }
    }

    static func notificationRecoveryTitle(for streamStatus: ChatNotificationStreamStatus) -> String? {
        switch streamStatus {
        case .notConnected:
            return connectForNotificationsTitle
        case .waitingForAuthentication:
            return signInForNotificationsTitle
        case .authenticationRefused, .originRejected, .redirected, .protocolError:
            return checkServerForNotificationsTitle
        case .ready, .connecting, .retrying:
            return nil
        }
    }

    static func notificationRecoveryToolTip(for streamStatus: ChatNotificationStreamStatus) -> String? {
        switch streamStatus {
        case .notConnected:
            return "Open Ciaobot and connect to a server. This only opens the app; it never changes the notification opt-in."
        case .waitingForAuthentication:
            return "Open Ciaobot and sign in on the server. This only opens the app; it never changes the notification opt-in."
        case .authenticationRefused, .originRejected, .redirected, .protocolError:
            return "Open Ciaobot to check the selected server. This only opens the app; it never follows a redirect or retries with a credential."
        case .ready, .connecting, .retrying:
            return nil
        }
    }

    private static func sanitizedNoticeDetail(_ detail: String) -> String {
        MenuTextSanitizer.sanitize(detail, limit: 240, fallback: "no further detail")
    }

    /// A Home-style row title: the server's sanitized title plus its compact
    /// relative activity unit. The row's glyph already carries the tier, so the
    /// title does not repeat the state. A missing or invalid timestamp adds no
    /// time rather than inventing "now".
    static func chatRowTitle(_ row: TrayChatRow) -> String {
        let title = MenuTextSanitizer.sanitize(row.chat.title, limit: 96, fallback: "Untitled chat")
        guard let time = row.relativeTime else { return title }
        return "\(title) · \(time)"
    }

    private func statusChanged(_ connection: AppSessionStatus.Connection) {
        statusEntry?.title = Self.statusTitle(for: connection)
        // `@Published` sends before the stored connection is updated. A genuine
        // disconnect or origin switch clears the badge from the emitted fact
        // now, so the previous origin's count cannot survive even one frame. A
        // re-report of the same origin keeps it until the deferred rebuild.
        let keepsBadge: Bool
        if case .connected(let origin) = connection {
            keepsBadge = badgeOrigin == origin
        } else {
            keepsBadge = false
        }
        if !keepsBadge { clearBadge() }
        updateToolTip()
        if menuIsOpen {
            // A connection change invalidates every chat row on screen. Close
            // the tracking session so the deferred rebuild cannot leave the
            // previous origin's rows visible.
            needsChatRebuild = true
            menu?.cancelTracking()
        }
        // `@Published` sends before the stored property is updated, so the
        // definitive rebuild happens on the next main-loop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.menuIsOpen {
                self.needsChatRebuild = true
            } else {
                self.rebuildMenu()
            }
        }
    }

    private func chatStateChanged() {
        updateToolTip()
        updateBadge()
        if menuIsOpen {
            needsChatRebuild = true
        } else {
            rebuildMenu()
        }
    }

    /// The only source of the status-bar number and the Dock badge is the
    /// server's validated `attention_count` for the selected origin.
    /// `displayState` refuses a snapshot from another origin, and a nil/zero
    /// count paints no number on either surface.
    private func updateBadge() {
        guard status.isConnected,
              let origin = status.currentOrigin?.canonicalKey,
              let chatList,
              case .loaded(let snapshot) = displayState(chatList.state) else {
            clearBadge()
            return
        }
        setBadge(snapshot.attentionCount, origin: origin)
    }

    private func clearBadge() {
        badgeOrigin = nil
        applyBadge(nil)
    }

    /// One count drives both attention surfaces: the status-bar digits and the
    /// Dock tile. There is no second fetch, timer, or count.
    private func setBadge(_ attentionCount: Int?, origin: String) {
        badgeOrigin = origin
        applyBadge(attentionCount)
    }

    private func applyBadge(_ attentionCount: Int?) {
        guard let statusItem else { return }
        dockBadge?.setBadgeLabel(DockBadgeTitle.label(for: attentionCount))
        let badge = Self.attentionBadgeTitle(attentionCount)
        if statusItem.image != nil {
            statusItem.title = badge
        } else {
            // A missing artwork asset still leaves a visible mark; keep it
            // beside the count rather than letting the badge erase it.
            statusItem.title = badge.isEmpty
                ? Self.fallbackTitle
                : "\(Self.fallbackTitle) \(badge)"
        }
    }

    private func updateToolTip() {
        guard status.isConnected, let chatList else {
            statusItem?.toolTip = Self.toolTip
            return
        }
        guard case .loaded(let snapshot) = displayState(chatList.state) else {
            statusItem?.toolTip = Self.toolTip
            return
        }
        var parts: [String] = []
        if let count = snapshot.attentionCount, count > 0 {
            parts.append(Self.attentionTitle(count))
        }
        let workingCount = TrayChatList.sections(
            snapshot: snapshot,
            activity: activity?.state,
            now: now()
        ).flatMap(\.rows).filter(\.working).count
        if workingCount > 0 {
            parts.append(workingCount == 1 ? "1 working" : "\(workingCount) working")
        }
        statusItem?.toolTip = parts.isEmpty
            ? Self.toolTip
            : "\(Self.toolTip) — \(parts.joined(separator: ", "))"
    }

    private func rebuildMenu() {
        guard let menu else { return }
        needsChatRebuild = false
        menu.removeAllItems()

        let entry = NSMenuItem(
            title: Self.statusTitle(for: status.connection),
            action: nil,
            keyEquivalent: ""
        )
        entry.isEnabled = false
        menu.addItem(entry)
        statusEntry = entry

        menu.addItem(.separator())

        var addedChatSection = false
        if status.isConnected, let chatList {
            addedChatSection = appendChatSection(to: menu, state: displayState(chatList.state))
        }
        if addedChatSection {
            menu.addItem(.separator())
        }

        let open = NSMenuItem(
            title: Self.openTitle,
            action: #selector(openCiaobot(_:)),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        if hasSettingsControls {
            menu.addItem(.separator())
            menu.addItem(settingsItem())
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: Self.quitTitle,
            action: #selector(quitCiaobot(_:)),
            keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)

        // The rebuilt rows and the status item read the same settled snapshot.
        updateToolTip()
        updateBadge()
    }

    private var hasSettingsControls: Bool {
        notifications != nil || loginItem != nil || dockIcon != nil || changeHost != nil || updates != nil
    }

    /// The secondary controls live in one submenu instead of competing with
    /// the chats and the primary Open action. The notification state row and
    /// its recovery row are settings, not a top-level chat-list row: they share
    /// the same submenu as the other controls. Nothing here acts on build:
    /// opening the submenu only exposes the same explicit-click rows.
    private func settingsItem() -> NSMenuItem {
        let item = NSMenuItem(title: Self.settingsTitle, action: nil, keyEquivalent: "")
        item.isEnabled = true

        let submenu = NSMenu(title: Self.settingsTitle)
        submenu.autoenablesItems = false

        var notificationItems: [NSMenuItem] = []
        if let notifications {
            // The status row always owns the explicit enable/disable action.
            // When a sign-in or server check is the next safe step, a second
            // focused row offers it, so the recovery never replaces the
            // user's ability to turn notifications off.
            notificationItems.append(notificationItem(
                for: notifications.state,
                streamStatus: notifications.streamStatus
            ))
            if let recovery = notificationRecoveryItem(
                for: notifications.state,
                streamStatus: notifications.streamStatus
            ) {
                notificationItems.append(recovery)
            }
        }

        var otherItems: [NSMenuItem] = []
        if let loginItem {
            otherItems.append(loginItemItem(loginItem))
        }
        if let dockIcon {
            otherItems.append(dockIconItem(dockIcon))
        }
        if changeHost != nil {
            otherItems.append(changeHostItem())
        }
        otherItems.append(updatesItem())

        for notification in notificationItems {
            submenu.addItem(notification)
        }
        // One separator only where two real groups meet. This keeps a
        // notifications-only Settings submenu free of a leading, trailing, or
        // doubled separator.
        if !notificationItems.isEmpty, !otherItems.isEmpty {
            submenu.addItem(.separator())
        }
        for other in otherItems {
            submenu.addItem(other)
        }
        item.submenu = submenu
        return item
    }

    /// Never shows a loaded snapshot from a different origin, even for the
    /// instant before the model notices a switch.
    private func displayState(_ state: ChatListState) -> ChatListState {
        guard let origin = status.currentOrigin?.canonicalKey else { return .disconnected }
        switch state {
        case .disconnected:
            return .loading
        case .loaded(let snapshot) where snapshot.origin != origin:
            return .loading
        default:
            return state
        }
    }

    private func appendChatSection(to menu: NSMenu, state: ChatListState) -> Bool {
        switch state {
        case .disconnected:
            return false
        case .loading:
            menu.addItem(disabledItem(Self.loadingChatsTitle))
            return true
        case .unavailable(.notSignedIn):
            menu.addItem(disabledItem(Self.notSignedInTitle))
            return true
        case .unavailable:
            menu.addItem(disabledItem(Self.chatsUnavailableTitle))
            return true
        case .loaded(let snapshot):
            guard !snapshot.chats.isEmpty else {
                menu.addItem(disabledItem(Self.noChatsTitle))
                return true
            }

            let activityState = activity?.state
            let sections = TrayChatList.sections(
                snapshot: snapshot,
                activity: activityState,
                now: now()
            )
            let workingIsKnown = activityState?.isLive(for: snapshot.origin) ?? false

            if sections.isEmpty {
                if let count = snapshot.attentionCount, count > 0 {
                    // The returned page has no flagged row to show, but the
                    // endpoint still reports attention. Never contradict the
                    // status-bar badge with "No chats need attention".
                    menu.addItem(disabledItem(Self.attentionTitle(count)))
                } else {
                    // With a live working feed, "nothing needs attention" is a
                    // claim we can stand behind. Without one, only the unread
                    // and needs-you facts are known, so the row says exactly
                    // that and the working-status note explains what is
                    // missing.
                    menu.addItem(disabledItem(
                        workingIsKnown ? Self.noAttentionTitle : Self.noRelevantChatsTitle
                    ))
                }
                if let note = activityState?.note(for: snapshot.origin) {
                    menu.addItem(disabledItem(note))
                }
                return true
            }

            // The status-bar badge already carries the count. The tier is
            // carried by each row's glyph, so repeating it as a header (and
            // repeating the count above the list) adds rows without adding a
            // fact. Home's tier order is preserved by `TrayChatList.sections`.
            for section in sections {
                for row in section.rows {
                    menu.addItem(chatItem(row))
                }
            }
            if let note = activityState?.note(for: snapshot.origin) {
                menu.addItem(.separator())
                menu.addItem(disabledItem(note))
            }
            return true
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func chatItem(_ row: TrayChatRow) -> NSMenuItem {
        let item = NSMenuItem(
            title: Self.chatRowTitle(row),
            action: #selector(openChat(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = row.chat.chatID
        item.isEnabled = openChatHandler != nil && ChatLink.isValidChatID(row.chat.chatID)
        item.image = TrayChatGlyph.image(for: row.tier)
        let title = MenuTextSanitizer.sanitize(row.chat.title, limit: 120, fallback: "Untitled chat")
        let workspace = MenuTextSanitizer.sanitize(row.chat.workspace, limit: 48, fallback: "")
        var tooltip = row.tier.statusPhrase
        if row.working, row.tier != .working {
            tooltip += " · working"
        }
        tooltip += workspace.isEmpty ? " · \(title)" : " · Open in \(workspace)"
        item.toolTip = tooltip
        return item
    }

    /// The one status row. Its title names the state; the exact technical
    /// detail and the recovery guidance live in its tooltip. The click is the
    /// explicit enable/disable action (opt-in when off, opt-out when on), or
    /// the fixed macOS Settings link only when macOS actually reported denial
    /// or this app's visible delivery channels are all disabled.
    /// Unavailable states stay disabled because no app action can create a
    /// notification identity that macOS does not have.
    private func notificationItem(
        for state: ChatNotificationState,
        streamStatus: ChatNotificationStreamStatus
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: Self.notificationTitle(for: state, streamStatus: streamStatus),
            action: nil,
            keyEquivalent: ""
        )
        item.toolTip = Self.notificationToolTip(for: state, streamStatus: streamStatus)
        switch state {
        case .off, .on:
            item.action = #selector(toggleNotifications(_:))
            item.target = self
            item.isEnabled = true
            if state == .on { item.state = .on }
        case .denied, .deliveryOff:
            item.action = #selector(openNotificationSettings(_:))
            item.target = self
            item.isEnabled = systemSettings != nil
        case .unavailable:
            item.isEnabled = false
        }
        return item
    }

    /// A separate row only when opening Ciaobot is the next safe step. Keeping
    /// it separate is what lets the status row above stay the explicit
    /// enable/disable control in every `.on` state.
    private func notificationRecoveryItem(
        for state: ChatNotificationState,
        streamStatus: ChatNotificationStreamStatus
    ) -> NSMenuItem? {
        guard state == .on,
              let title = Self.notificationRecoveryTitle(for: streamStatus),
              let toolTip = Self.notificationRecoveryToolTip(for: streamStatus) else { return nil }
        let item = NSMenuItem(
            title: title,
            action: #selector(openCiaobotForNotifications(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = true
        item.toolTip = toolTip
        return item
    }

    private func loginItemItem(_ loginItem: LoginItemControlling) -> NSMenuItem {
        let item: NSMenuItem
        switch loginItem.state {
        case .enabled:
            item = NSMenuItem(
                title: Self.loginItemTitle,
                action: #selector(toggleLoginItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = true
            item.state = .on
            item.toolTip = "Ciaobot opens at login. Click to stop opening it automatically."
        case .notRegistered:
            item = NSMenuItem(
                title: Self.loginItemTitle,
                action: #selector(toggleLoginItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = true
            item.toolTip = "Open Ciaobot at login. macOS may ask you to approve it in Login Items."
        case .requiresApproval:
            item = NSMenuItem(
                title: Self.loginItemApprovalTitle,
                action: #selector(toggleLoginItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = systemSettings != nil
            item.toolTip = "Ciaobot is registered, but macOS has not approved it. Open System Settings > General > Login Items and allow Ciaobot."
        case .unavailable(let unavailability):
            // A diagnosed cause becomes a clickable explanation with the one
            // next step. A state the app cannot diagnose keeps the generic
            // disabled row and its raw reason. Neither path registers.
            let cause = unavailability.cause
            item = NSMenuItem(
                title: cause.map(LoginItemUnavailableCopy.title(for:)) ?? Self.loginItemUnavailableTitle,
                action: cause == nil ? nil : #selector(explainLoginItemUnavailable(_:)),
                keyEquivalent: ""
            )
            item.target = cause == nil ? nil : self
            item.isEnabled = cause != nil
            item.toolTip = unavailability.reason
        case .failed(let operation, let reason):
            item = NSMenuItem(
                title: operation == .unregister
                    ? Self.loginItemRemoveFailedTitle
                    : Self.loginItemFailedTitle,
                action: #selector(toggleLoginItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = true
            item.toolTip = reason
        }
        return item
    }

    private func dockIconItem(_ dockIcon: DockIconControlling) -> NSMenuItem {
        let item = NSMenuItem(
            title: Self.hideDockIconTitle,
            action: #selector(toggleDockIcon(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = true
        item.state = dockIcon.hidesDockIcon ? .on : .off
        item.toolTip = "Hide the Dock icon while the main window is closed, but keep the Ciaobot menu-bar tray item. Opening the window restores the Dock icon until the window closes."
        return item
    }

    private func changeHostItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: Self.changeHostTitle,
            action: status.isConnected ? #selector(changeConnectedHost(_:)) : nil,
            keyEquivalent: ""
        )
        item.target = status.isConnected ? self : nil
        item.isEnabled = status.isConnected
        item.toolTip = status.isConnected
            ? "Return to the connection screen without contacting or restarting the server. Sign-in consent is asked again for the new host."
            : "Connect to a server first."
        return item
    }

    /// Two truthful shapes: a real check when this build has a started updater,
    /// or the disabled row that names why it cannot. The row never starts the
    /// updater and never claims a check it cannot perform.
    private func updatesItem() -> NSMenuItem {
        guard let updates else {
            let item = NSMenuItem(title: Self.updatesUnavailableTitle, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = "This build has no updater. Ciaobot for Mac does not download or install updates; use a new app build when one is available."
            return item
        }
        if let reason = updates.unavailableReason {
            let item = NSMenuItem(title: Self.updatesUnavailableTitle, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = "\(reason) Ciaobot for Mac does not download or install updates in this build; use a new app build when one is available."
            return item
        }
        let item = NSMenuItem(
            title: Self.checkForUpdatesTitle,
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = self
        // Sparkle reports when a check or a download is already running.
        item.isEnabled = updates.canCheckForUpdates
        item.toolTip = Self.checkForUpdatesToolTip
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        needsChatRebuild = false
        // Re-read the OS login-item state without registering anything.
        loginItem?.refresh()
        rebuildMenu()
        chatList?.refreshIfNeeded()
        activity?.refreshIfNeeded()
        notifications?.refreshIfNeeded()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if needsChatRebuild {
            rebuildMenu()
        }
    }

    @objc func openCiaobot(_ sender: Any?) {
        openWindow()
    }

    @objc func toggleNotifications(_ sender: Any?) {
        notifications?.performMenuAction()
    }

    @objc func openNotificationSettings(_ sender: Any?) {
        // Only a macOS-side block is a Settings problem: a permission denial or
        // an allowed permission whose visible delivery channels are all off.
        // A missing sign-in or connection is handled by opening the app
        // instead, and an unavailable process cannot be fixed in Settings at
        // all.
        guard let state = notifications?.state,
              state == .denied || state == .deliveryOff else { return }
        systemSettings?.openNotificationSettings()
    }

    @objc func openCiaobotForNotifications(_ sender: Any?) {
        openWindow()
    }

    /// Explicit opt-in or opt-out. `.requiresApproval` is not success, so it
    /// opens Login Items instead of silently registering again. Registration
    /// never happens at launch or when the menu merely opens.
    @objc func toggleLoginItem(_ sender: Any?) {
        guard let loginItem else { return }
        switch loginItem.state {
        case .enabled:
            try? loginItem.unregister()
        case .requiresApproval:
            systemSettings?.openLoginItemsSettings()
        case .notRegistered:
            try? loginItem.register()
        case .failed(let operation, _):
            switch operation {
            case .register:
                try? loginItem.register()
            case .unregister:
                try? loginItem.unregister()
            }
        case .unavailable:
            break
        }
        // `register`/`unregister` leave `state` at the OS result or at the
        // exact failure. A follow-up refresh here would erase a failure that
        // the user must see. Opening the menu refreshes the OS state later.
        rebuildMenu()
    }

    /// The click on a diagnosed unavailable row. It only explains: it never
    /// registers or unregisters, and it never claims Start at Login is on. The
    /// Login Items pane is offered only for a cause that Settings can settle,
    /// and only inside the alert as its own button.
    @objc func explainLoginItemUnavailable(_ sender: Any?) {
        guard let loginItem,
              case .unavailable(let unavailability) = loginItem.state,
              let cause = unavailability.cause else { return }
        let settingsAction: (() -> Void)? =
            systemSettings != nil && LoginItemUnavailableCopy.offersLoginItemsSettings(for: cause)
            ? { [systemSettings] in systemSettings?.openLoginItemsSettings() }
            : nil
        loginItemExplanation(unavailability, settingsAction)
    }

    /// The native explanation behind a diagnostic row. Tests inject the same
    /// closure shape, so no test ever shows a modal alert.
    static func presentLoginItemUnavailable(
        _ unavailability: LoginItemUnavailability,
        openLoginItemsSettings: (() -> Void)?
    ) {
        guard let cause = unavailability.cause else { return }
        let alert = NSAlert()
        alert.messageText = LoginItemUnavailableCopy.title(for: cause)
        alert.informativeText = unavailability.reason
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if openLoginItemsSettings != nil {
            alert.addButton(withTitle: "Open Login Items Settings…")
        }
        if alert.runModal() == .alertSecondButtonReturn {
            openLoginItemsSettings?()
        }
    }

    @objc func toggleDockIcon(_ sender: Any?) {
        guard let dockIcon else { return }
        dockIcon.setHidesDockIcon(!dockIcon.hidesDockIcon)
        rebuildMenu()
    }

    @objc func changeConnectedHost(_ sender: Any?) {
        changeHost?()
    }

    /// The only path that asks Sparkle to check. Opening the menu never does,
    /// and a disabled or unavailable row forwards nothing even if AppKit sends
    /// the action anyway.
    @objc func checkForUpdates(_ sender: Any?) {
        guard let updates, updates.unavailableReason == nil, updates.canCheckForUpdates else { return }
        updates.checkForUpdates()
        // The click may have started a session; the next open reads the real
        // availability again.
        rebuildMenu()
    }

    @objc func openChat(_ sender: NSMenuItem) {
        guard let chatID = sender.representedObject as? String,
              let openChatHandler else { return }
        openWindow()
        if !openChatHandler(chatID) {
            chatUnavailableHandler(chatID)
        }
    }

    /// `NSApp.terminate` stops this process only; the client has no server
    /// lifecycle call and the separately installed server keeps running.
    @objc func quitCiaobot(_ sender: Any?) {
        quit()
    }
}
