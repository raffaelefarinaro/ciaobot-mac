import XCTest

/// Locks the packaging contract that cannot be exercised in-process: the
/// bundle identity that WebKit stores, saved sign-in and notification
/// permission are tied to, and the fact that the distributable is ad-hoc
/// signed rather than Developer ID/notarized. These are pure text checks on
/// the repository; nothing is built, signed, launched, installed or fetched.
final class PackagingTests: XCTestCase {
    private static let expectedBundleIdentifier = "local.ciaobot.mac"

    func testNotarizedPackagingRequiresAppleVerification() throws {
        let text = try readScript("package-notarized.sh")
        XCTAssertTrue(text.contains("--options runtime --timestamp"))
        XCTAssertTrue(text.contains("notarytool submit"))
        XCTAssertTrue(text.contains("stapler staple"))
        XCTAssertTrue(text.contains("stapler validate"))
        XCTAssertTrue(text.contains("spctl --assess"))
        XCTAssertTrue(text.contains("codesign --verify --deep --strict"))
        XCTAssertFalse(text.contains("--password"))
    }

    func testBuildScriptKeepsTheStableBundleIdentifier() throws {
        let text = try readScript("build-app.sh")
        XCTAssertEqual(
            try plistValue(named: "CFBundleIdentifier", in: text),
            Self.expectedBundleIdentifier,
            "Changing CFBundleIdentifier moves WebKit stores, saved sign-in and notification permission. Keep it stable."
        )
    }

    func testBuildScriptWritesAPlausibleVersion() throws {
        let text = try readScript("build-app.sh")
        let version = try plistValue(named: "CFBundleShortVersionString", in: text)
        XCTAssertNotNil(
            version.range(of: #"^[0-9]+(\.[0-9]+){1,2}$"#, options: .regularExpression),
            "CFBundleShortVersionString must stay a dotted numeric version, got \(version)"
        )
        let build = try plistValue(named: "CFBundleVersion", in: text)
        XCTAssertNotNil(
            build.range(of: #"^[0-9]+$"#, options: .regularExpression),
            "CFBundleVersion must stay numeric, got \(build)"
        )
    }

    func testPackagingScriptSignsAdHocAndVerifiesDeepStrict() throws {
        let text = try readScript("package-app.sh")
        XCTAssertTrue(text.contains("codesign --force --sign -"), "the distributable must be ad-hoc signed")
        XCTAssertTrue(
            text.contains("codesign --verify --deep --strict"),
            "the script must verify the signature, including nested resources"
        )
        XCTAssertTrue(text.contains("zip -q -r -X -y"), "the archive must be reproducible, attribute-free and preserve symlinks")
        XCTAssertFalse(text.contains("Developer ID Application"))
        XCTAssertFalse(text.contains("Developer ID Installer"))
        XCTAssertFalse(text.contains("notarytool"))
        XCTAssertFalse(text.contains("stapler"))
        XCTAssertFalse(text.contains("altool"))
    }

    func testPackagingScriptDoesNotDefineASecondBundleIdentifier() throws {
        let text = try readScript("package-app.sh")
        XCTAssertFalse(
            text.contains("local.ciaobot"),
            "the bundle identifier must stay defined only in scripts/build-app.sh"
        )
        XCTAssertTrue(
            text.contains("CFBundleIdentifier"),
            "the script must read the identity from the built Info.plist"
        )
    }

    func testPackagingScriptNeverInstallsOrLaunchesTheApp() throws {
        let text = try readScript("package-app.sh")
        XCTAssertTrue(
            text.contains("refusing to write inside an Applications folder"),
            "packaging must refuse to replace an installed copy"
        )
        XCTAssertFalse(text.contains("\nopen "), "packaging must not launch the app")
        XCTAssertFalse(text.contains("launchctl"), "packaging must not register anything")
    }

    func testPackagingScriptDocumentsTheGatekeeperAndNotificationCaveats() throws {
        let text = try readScript("package-app.sh")
        XCTAssertTrue(text.contains("Gatekeeper"), "the operator must be told Gatekeeper still warns")
        XCTAssertTrue(
            text.contains("not exercised by this script"),
            "the script must say that notifications and login items stay unverified"
        )
    }

    func testPackagingScriptNeverOverwritesOrLeaksPrivatePaths() throws {
        let text = try readScript("package-app.sh")
        XCTAssertFalse(text.contains("--force       replace"), "there must be no force option")
        XCTAssertFalse(text.contains("rm -rf \"$bundle\""), "packaging must never delete a bundle")
        XCTAssertTrue(
            text.contains("refusing a non-empty --output directory"),
            "a non-empty output directory must be refused, not replaced"
        )
        XCTAssertTrue(
            text.contains("refusing an --output that contains the source app"),
            "an output directory that contains the source app must be refused"
        )
        XCTAssertTrue(text.contains("architectures=$architectures"), "the manifest must record the real architectures")
        XCTAssertFalse(text.contains("source_app="), "the public manifest must not record a local path")
    }

    func testReadmeStatesTheThinArchitectureAndTheSignedNotificationBuild() throws {
        let readme = try String(
            contentsOf: packageRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        XCTAssertTrue(readme.contains("not a universal binary"), "README must not imply a universal build")
        XCTAssertTrue(
            readme.contains("architectures=arm64") && readme.contains("Apple silicon"),
            "README must name the exact thin architecture and Apple silicon"
        )
        XCTAssertTrue(
            readme.contains("sealed, ad-hoc signed `Ciaobot.app` produced by `scripts/package-app.sh`"),
            "manual notification checks must use the sealed packaged app"
        )
        XCTAssertFalse(
            readme.contains("Use the assembled, signed `.build/Ciaobot.app`"),
            "the unsigned build output must not be presented as signed"
        )
    }

    func testPackagingScriptIsExecutable() throws {
        let url = scriptsDirectory.appendingPathComponent("package-app.sh")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: url.path),
            "scripts/package-app.sh must keep its executable bit"
        )
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var scriptsDirectory: URL {
        packageRoot.appendingPathComponent("scripts")
    }

    private func readScript(_ name: String) throws -> String {
        let url = scriptsDirectory.appendingPathComponent(name)
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            XCTFail("\(name) is not UTF-8")
            return ""
        }
        return text
    }

    /// Reads `<key>NAME</key><string>VALUE</string>` from the Info.plist heredoc
    /// in the build script without parsing the shell text as a plist.
    private func plistValue(named name: String, in text: String) throws -> String {
        let pattern = "<key>" + NSRegularExpression.escapedPattern(for: name) + "</key><string>([^<]*)</string>"
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text) else {
            XCTFail("scripts/build-app.sh has no <key>\(name)</key> value")
            return ""
        }
        return String(text[valueRange])
    }
}
