import Foundation
import Darwin

enum NavigationDecision { case inWindow, external, blocked }

struct Origin {
    let url: URL
    private let scheme: String
    private let host: String
    private let port: Int

    init?(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.percentEncodedPath.isEmpty, components.query == nil, components.fragment == nil,
              !text.hasSuffix(":"), let url = components.url,
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        let plainHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard Self.validHost(plainHost), scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(plainHost) else { return nil }
        self.url = url
        self.scheme = scheme
        self.host = plainHost
        self.port = components.port ?? (scheme == "https" ? 443 : 80)
    }

    private static func validHost(_ host: String) -> Bool {
        var ipv6 = in6_addr()
        if host.contains(":") { return host.withCString { inet_pton(AF_INET6, $0, &ipv6) == 1 } }
        if host.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) {
            var ipv4 = in_addr()
            return host.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 }
        }
        guard host.utf8.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }

    func navigation(_ url: URL, userInitiated: Bool) -> NavigationDecision {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let targetScheme = parts.scheme?.lowercased(), parts.user == nil, parts.password == nil else { return .blocked }
        if targetScheme == "mailto" { return userInitiated ? .external : .blocked }
        guard ["http", "https"].contains(targetScheme), let targetHost = parts.host?.lowercased(), !targetHost.isEmpty,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return .blocked }
        let targetPort = parts.port ?? (targetScheme == "https" ? 443 : 80)
        if targetScheme == scheme && targetHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == host && targetPort == port { return .inWindow }
        if scheme == "https" && targetScheme == "http" { return .blocked }
        return userInitiated ? .external : .blocked
    }
}
