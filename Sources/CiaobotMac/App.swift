import SwiftUI
import WebKit
import AppKit

@main
struct CiaobotMacApp: App {
    var body: some Scene {
        WindowGroup("Ciaobot") { ConnectionView() }
            .defaultSize(width: 1100, height: 760)
    }
}

struct ConnectionView: View {
    @State private var address = "http://127.0.0.1:8443"
    @State private var origin: Origin?
    @State private var checking = false
    @State private var error: String?
    private let probe = Probe()

    var body: some View {
        Group {
            if let origin { WebWindow(origin: origin) }
            else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Connect to Ciaobot").font(.title.bold())
                    Text("Enter your server’s address. The local address is a candidate, not a verified server.")
                        .foregroundStyle(.secondary)
                    TextField("Server address", text: $address).textFieldStyle(.roundedBorder)
                        .onSubmit(connect).disabled(checking)
                    if let error { Text(error).foregroundStyle(.red) }
                    HStack {
                        Button(checking ? "Checking…" : "Connect", action: connect)
                            .keyboardShortcut(.defaultAction).disabled(checking)
                        if checking { ProgressView().controlSize(.small) }
                    }
                    Text("The connection check confirms the server’s response format, not its identity. Sign in only if you trust the address.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(32).frame(maxWidth: 520)
            }
        }.frame(minWidth: 480, minHeight: 320)
    }
    private func connect() {
        guard let candidate = Origin(address) else {
            error = "Enter an origin only. HTTP is allowed only for localhost, 127.0.0.1, or ::1; other hosts require HTTPS."
            return
        }
        error = nil
        checking = true
        probe.check(candidate) { ok in
            checking = false
            if ok { origin = candidate }
            else { error = "Could not verify the server’s startup response. Check the address and try again." }
        }
    }
}

struct WebWindow: NSViewRepresentable {
    let origin: Origin
    func makeCoordinator() -> Coordinator { Coordinator(origin: origin) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // A protocol-shaped response does not authenticate the server. Never
        // send cookies from earlier app sessions to the selected destination.
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: origin.url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let origin: Origin
        init(origin: Origin) { self.origin = origin }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            switch origin.navigation(url, userInitiated: action.navigationType == .linkActivated) {
            case .inWindow:
                if action.targetFrame == nil { webView.load(action.request); decisionHandler(.cancel) }
                else { decisionHandler(.allow) }
            case .external:
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            case .blocked: decisionHandler(.cancel)
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard let url = response.response.url, origin.navigation(url, userInitiated: false) == .inWindow else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
