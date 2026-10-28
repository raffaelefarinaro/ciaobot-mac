import XCTest
@testable import CiaobotMac

final class PolicyTests: XCTestCase {
    func testOrigins() {
        for value in ["http://localhost:8443", "http://127.0.0.1", "http://[::1]:8443", "https://192.168.1.2", "https://Example.COM"] { XCTAssertNotNil(Origin(value), value) }
        for value in ["http://192.168.1.2", "http://localhost.evil", "https://user:pass@example.com", "https://example.com/", "https://example.com/a", "https://example.com?x=1", "https://example.com#x", "https://example.com:", "https://example.com:0", "garbage"] { XCTAssertNil(Origin(value), value) }
    }
    func testNavigation() {
        let origin = Origin("https://Example.com")!
        XCTAssertEqual(origin.navigation(URL(string: "https://example.COM:443/chat")!, userInitiated: false), .inWindow)
        XCTAssertEqual(origin.navigation(URL(string: "https://example.com:444/chat")!, userInitiated: true), .external)
        XCTAssertEqual(origin.navigation(URL(string: "http://example.com/")!, userInitiated: true), .blocked)
        XCTAssertEqual(origin.navigation(URL(string: "https://elsewhere.com")!, userInitiated: false), .blocked)
        XCTAssertEqual(origin.navigation(URL(string: "mailto:a@example.com")!, userInitiated: true), .external)
        XCTAssertEqual(origin.navigation(URL(string: "file:///etc/passwd")!, userInitiated: true), .blocked)
        XCTAssertEqual(origin.navigation(URL(string: "https://u:p@example.com")!, userInitiated: true), .blocked)
        XCTAssertNotEqual(Origin("http://localhost:8443")!.navigation(URL(string: "http://127.0.0.1:8443")!, userInitiated: false), .inWindow)
    }
    func testProbeResponse() {
        XCTAssertTrue(Probe.valid(status: 200, data: Data(#"{"startup_id":"abc"}"#.utf8)))
        for body in [#"{"startup_id":""}"#, #"{"startup_id":"  "}"#, #"{"startup_id":1}"#, "[]", "oops"] { XCTAssertFalse(Probe.valid(status: 200, data: Data(body.utf8))) }
        XCTAssertFalse(Probe.valid(status: 302, data: Data(#"{"startup_id":"abc"}"#.utf8)))
        XCTAssertFalse(Probe.valid(status: 401, data: Data(#"{"startup_id":"abc"}"#.utf8)))
    }
}

final class HostValidationTests: XCTestCase {
    func testValidHosts() {
        for host in ["example.com", "a-b.example", "localhost", "127.0.0.1", "[::1]", "[2001:db8::1]"] {
            XCTAssertNotNil(Origin("https://\(host)"), host)
        }
    }
    func testInvalidHosts() {
        for host in ["-", ".", "example.com..", "-foo.example", "foo-.example", "foo..example", "a_b.example", "999.1.1.1", "[:::1]"] {
            XCTAssertNil(Origin("https://\(host)"), host)
        }
    }
}
