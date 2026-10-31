import SwiftUI
import AppKit
import Combine
import WebKit

@main
struct CiaobotMacApp: App {
    // AppKit owns the menu-bar item and the reopen path; SwiftUI keeps the
    // single Window scene. The same session object feeds both.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single Window (not a WindowGroup) keeps the client to one native
        // main window and removes File > New Window from the menu.
        Window("Ciaobot", id: "main") { ConnectionView(session: appDelegate.session) }
            .defaultSize(width: 1100, height: 760)
            .commands {
                CommandGroup(after: .newItem) {
                    Button("Change Server…") {
                        NotificationCenter.default.post(name: .ciaobotChangeServer, object: nil)
                    }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                }
            }
    }
}

extension Notification.Name {
    static let ciaobotChangeServer = Notification.Name("CiaobotChangeServer")
}

#if DEBUG
/// Test-only launch controls. They are compiled out of release builds and
/// fail closed: an origin is honoured only when it is an explicit loopback
/// origin, and auto-connect never falls back to the proposed live address.
enum TestLaunch {
    static func origin(environment: [String: String] = ProcessInfo.processInfo.environment) -> Origin? {
        guard let raw = environment["CIAOBOT_MAC_TEST_ORIGIN"],
              let origin = Origin(raw), origin.isLoopback else { return nil }
        return origin
    }

    static func autoConnectRequested(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["CIAOBOT_MAC_TEST_AUTOCONNECT"] == "1"
    }

    static func autoConnect(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        autoConnectRequested(environment: environment) && origin(environment: environment) != nil
    }

    /// The initial field value. A requested test launch with a missing or
    /// non-loopback origin gets an empty field, never the proposed live
    /// address, so a stray Return cannot contact it.
    static func initialAddress(defaultAddress: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let origin = origin(environment: environment) { return origin.url.absoluteString }
        if autoConnectRequested(environment: environment) { return "" }
        return defaultAddress
    }
}
#endif

@MainActor
struct ConnectionView: View {
    private static let defaultAddress = "http://127.0.0.1:8443"

    @State private var address: String
    @State private var origin: Origin?
    @State private var storage: SessionStorage = .ephemeral
    @State private var dataStore: WKWebsiteDataStore?
    @State private var storageNotice: String?
    @State private var keepSignedInChoice: Bool?
    @State private var tasks = ConnectionTaskGate()
    @State private var error: String?
    @State private var forgetMessage: String?
    @State private var didAutoConnect = false
    @State private var viewTracker = SessionViewTracker()
    @StateObject private var discovery: LocalServerDiscovery
    private let probe: ProbeChecking
    private let signIn: SessionSignIn
    private let session: AppSessionStatus?
    private let autoConnectTarget: Origin?
    private let autoDiscovery: Bool
    private let lastServer: LastServerStoring
    private var checking: Bool { tasks.task == .checking }
    private var forgetting: Bool { tasks.task == .forgetting }

    /// The shipped default only. Exposed so a test can prove the view used by
    /// the app matches the build policy without rendering it.
    var automaticallyStartsDiscovery: Bool { autoDiscovery }

    /// The value the address field starts with. Exposed so a test can prove a
    /// saved origin is prefilled without rendering the view.
    let launchAddress: String

    init(
        probe: ProbeChecking = Probe(),
        signIn: SessionSignIn? = nil,
        discovery: LocalServerDiscovery? = nil,
        autoDiscovery: Bool = LocalServerDiscoveryPolicy.automaticInThisBuild,
        session: AppSessionStatus? = nil,
        lastServer: LastServerStoring = UserDefaultsLastServerStore()
    ) {
        self.probe = probe
        self.signIn = signIn ?? .live
        self.autoDiscovery = autoDiscovery
        self.session = session
        self.lastServer = lastServer
        _discovery = StateObject(wrappedValue: discovery ?? LocalServerDiscovery())
        #if DEBUG
        let testOrigin = TestLaunch.origin()
        let testLaunchRequested = TestLaunch.autoConnectRequested()
        // Any test launch — an addressed one, or one that only asked to
        // auto-connect — wins over the saved origin. Nothing in the store may
        // turn a test launch into a connection.
        let isTestLaunch = testOrigin != nil || testLaunchRequested
        // A test launch does not even read the saved value, so it cannot be
        // influenced by (or mutate) the operator's real defaults.
        let savedOrigin = isTestLaunch ? nil : lastServer.savedOrigin
        let initialAddress = isTestLaunch
            ? TestLaunch.initialAddress(defaultAddress: Self.defaultAddress)
            : ConnectionLaunch.initialAddress(saved: savedOrigin, defaultAddress: Self.defaultAddress)
        let autoConnectTarget: Origin?
        if isTestLaunch {
            autoConnectTarget = TestLaunch.autoConnect() ? testOrigin : nil
        } else {
            autoConnectTarget = ConnectionLaunch.autoConnectOrigin(
                saved: savedOrigin,
                isTestLaunch: false,
                isDebugBuild: true
            )
        }
        let testError = testLaunchRequested && testOrigin == nil
            ? "Test mode requires CIAOBOT_MAC_TEST_ORIGIN set to a loopback origin; nothing was contacted."
            : nil
        #else
        let savedOrigin = lastServer.savedOrigin
        let initialAddress = ConnectionLaunch.initialAddress(saved: savedOrigin, defaultAddress: Self.defaultAddress)
        let autoConnectTarget = ConnectionLaunch.autoConnectOrigin(
            saved: savedOrigin,
            isTestLaunch: false,
            isDebugBuild: false
        )
        let testError: String? = nil
        #endif
        self.autoConnectTarget = autoConnectTarget
        self.launchAddress = initialAddress
        _address = State(initialValue: initialAddress)
        _error = State(initialValue: testError)
    }

    var body: some View {
        Group {
            if let origin {
                // A fallback is reported where the session actually lives: the
                // connection screen is already gone once the probe succeeds.
                VStack(spacing: 0) {
                    if let storageNotice {
                        Text(storageNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    WebWindow(
                        origin: origin,
                        storage: storage,
                        websiteDataStore: dataStore,
                        onFailure: { message in
                            self.origin = nil
                            self.storage = .ephemeral
                            self.dataStore = nil
                            self.storageNotice = nil
                            self.error = message
                            self.session?.reportDisconnected()
                        },
                        viewTracker: viewTracker,
                        onWebViewReady: { view in
                            self.session?.attachWebView(view, for: origin)
                        }
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        if let face = AppAssets.faceImage {
                            Image(nsImage: face)
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                                // Decorative: the title already names the app.
                                .accessibilityHidden(true)
                        }
                        Text("Connect to Ciaobot").font(.title.bold())
                    }
                    Text("Enter your server’s address. The local address is a candidate, not a verified server.")
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if discovery.isChecking {
                            ProgressView().controlSize(.small)
                                .accessibilityHidden(true)
                        }
                        Text(discovery.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(LocalServerDiscoveryCopy.accessibilityLabel)
                            .accessibilityValue(discovery.statusText)
                        Spacer(minLength: 8)
                        Button(discovery.status == .idle ? "Check for Local Server" : "Check Again") {
                            discovery.refresh()
                        }
                        .disabled(discovery.isChecking || tasks.isBusy)
                        .accessibilityHint(LocalServerDiscoveryCopy.hint)
                    }
                    TextField("Server address", text: $address).textFieldStyle(.roundedBorder)
                        .onSubmit(connect).disabled(tasks.isBusy)
                    Toggle("Keep me signed in on this Mac", isOn: Binding(
                        get: { keepSignedIn },
                        set: { keepSignedInChoice = $0 }
                    ))
                        .disabled(!persistentOptionAvailable || tasks.isBusy)
                    Text(persistenceExplanation)
                        .font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                    if let candidate = addressOrigin, signIn.hasSavedSignIn(for: candidate) {
                        Button(forgetting ? "Forgetting…" : "Forget saved sign-in") { forget() }
                            .disabled(tasks.isBusy)
                    }
                    if let forgetMessage {
                        Text(forgetMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(checking ? "Checking…" : "Connect", action: connect)
                            .keyboardShortcut(.defaultAction).disabled(tasks.isBusy)
                        if checking { ProgressView().controlSize(.small) }
                    }
                    Text("The connection check confirms the server’s response format, not its identity. Sign in only if you trust the address.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(32).frame(maxWidth: 520)
                    .onAppear { startAutomaticDiscovery() }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .onAppear {
            // A fresh connection screen is disconnected. Do not clear a live
            // connection when SwiftUI merely re-shows the existing window.
            if origin == nil { session?.reportDisconnected() }
            guard let target = autoConnectTarget, !didAutoConnect else { return }
            didAutoConnect = true
            address = target.url.absoluteString
            connect(to: target)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ciaobotChangeServer)) { _ in
            guard origin != nil else { return }
            address = origin?.url.absoluteString ?? address
            discovery.invalidate()
            origin = nil
            storage = .ephemeral
            dataStore = nil
            storageNotice = nil
            // Consent belongs to one connection. A different server must be
            // opted in again (or use the default) rather than inheriting the
            // previous choice.
            keepSignedInChoice = nil
            error = nil
            forgetMessage = nil
            session?.reportDisconnected()
            startAutomaticDiscovery()
        }
        // Editing the address to another server is a different connection
        // too. Clear the click so the new address starts from the default
        // instead of inheriting consent given for an earlier host.
        .onChange(of: addressOrigin?.canonicalKey) { _ in
            keepSignedInChoice = nil
        }
    }

    /// Automatic same-Mac discovery starts only on the connection screen and
    /// only in production. Debug builds and test launches leave it to an
    /// explicit click so the test suite never contacts the real candidate.
    private func startAutomaticDiscovery() {
        guard autoDiscovery, origin == nil else { return }
        discovery.refresh()
    }

    private var addressOrigin: Origin? { Origin(address) }

    /// Persistence starts on where it can work. `canPersistSignIn` includes a
    /// usable registry, so an HTTPS address on a Mac with a broken mapping
    /// file stays off and the toggle stays disabled. An explicit click is
    /// stored separately and wins for this address only.
    private var keepSignedIn: Bool {
        PersistentSignInDefault.isEnabled(
            origin: addressOrigin,
            persistentAvailable: signIn.canPersistSignIn,
            explicitChoice: keepSignedInChoice
        )
    }

    private var persistentOptionAvailable: Bool {
        guard let candidate = addressOrigin else { return false }
        return candidate.usesTLS && signIn.canPersistSignIn
    }

    private var persistenceExplanation: String {
        PersistentSignInCopy.explanation(
            origin: addressOrigin,
            persistentAvailable: signIn.persistentAvailable,
            registryAvailable: signIn.registry.isAvailable
        )
    }

    private func forget() {
        guard let candidate = addressOrigin, tasks.beginForget() else { return }
        forgetMessage = nil
        // WebKit refuses to remove a store that a view still uses. The tracker
        // only reports release when the WKWebView weak reference is actually
        // nil; if that never happens, forget is not attempted and nothing is
        // claimed to have been released.
        viewTracker.whenReleased(timeout: 2) { released in
            guard released else {
                self.tasks.endForget()
                self.forgetMessage = "The session view has not finished closing. Try Forget again in a moment."
                return
            }
            self.signIn.forget(origin: candidate, releaseWebViews: { $0() }) { result in
                self.tasks.endForget()
                switch result {
                case .success:
                    self.storage = .ephemeral
                    self.forgetMessage = "Saved sign-in removed for \(candidate.canonicalKey)."
                case .failure(.registryUnavailable):
                    self.forgetMessage = "Could not use the saved sign-in list. Persistent sign-in is disabled."
                case .failure(.registryChangedElsewhere):
                    self.forgetMessage = "Another copy of the app changed the saved sign-in list. Restart Ciaobot to reload it before forgetting."
                case .failure(.storeStillPresent):
                    self.forgetMessage = "Could not remove the saved sign-in. Nothing was forgotten; try again."
                case .failure(.mappingNotSaved):
                    self.forgetMessage = "WebKit reported the saved sign-in store removed, but its record could not be updated. This session stays in memory; try again or restart Ciaobot to finish."
                }
            }
        }
    }

    /// Internal so the connection outcome — and therefore the remembered
    /// origin — can be tested without rendering the view.
    func connect() {
        guard !tasks.isBusy else { return }
        guard let candidate = Origin(address) else {
            error = "Enter only an origin, such as https://example.com:8443. Do not include a path, query, fragment, or credentials. HTTP is allowed only for localhost, 127.0.0.1, or ::1; other hosts require HTTPS."
            return
        }
        connect(to: candidate)
    }

    private func connect(to candidate: Origin) {
        guard tasks.beginCheck() else { return }
        error = nil
        storageNotice = nil
        probe.check(candidate) { ok in
            self.tasks.endCheck()
            if ok {
                // Only a connection that actually answered is remembered. A
                // typo, an unreachable host, or a hostile address never
                // becomes the startup target.
                self.lastServer.remember(candidate)
                // The connection screen is about to disappear. A discovery
                // response that is still in flight must not update the screen
                // that replaces it.
                self.discovery.invalidate()
                // Resolve the store only after the probe succeeds, so a typo
                // cannot create a persistent mapping or empty store. If the
                // user opted in but cannot get a persistent store, say so
                // instead of silently using memory only.
                self.storage = self.signIn.storage(for: candidate, keepSignedIn: self.keepSignedIn)
                self.storageNotice = self.signIn.fallback(for: candidate, keepSignedIn: self.keepSignedIn)?.userMessage
                // Create the one store this connection uses. The web view and
                // the menu-bar chat feed share it; no second nonpersistent
                // store and never the default shared store.
                let store = WebKitSessionStores.make(self.storage)
                self.dataStore = store
                self.origin = candidate
                // The probe verified the protocol shape, not an identity or a
                // signed-in session. The menu bar says only this much.
                self.session?.reportConnected(candidate, dataStore: store)
            } else {
                self.error = "Could not verify the server’s startup response. Check the address and try again."
                self.session?.reportDisconnected()
            }
        }
    }
}
