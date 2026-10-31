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

    /// Sparkle compares `CFBundleVersion` as an integer, so a published build
    /// number may never be reused or lowered. Pinning one exact version here
    /// would make every release fail CI; the floor is raised only when a build
    /// is actually published.
    func testUpdaterReleaseUsesANewBuildNumber() throws {
        let text = try readScript("build-app.sh")
        let version = try plistValue(named: "CFBundleShortVersionString", in: text)
        XCTAssertNotNil(
            version.range(of: #"^0\.[0-9]+"#, options: .regularExpression),
            "the updater preview line stays in 0.x, got \(version)"
        )
        let build = try XCTUnwrap(Int(try plistValue(named: "CFBundleVersion", in: text)))
        XCTAssertGreaterThanOrEqual(
            build, 4,
            "build 4 shipped as 0.1.3; never reuse or lower a published CFBundleVersion"
        )
    }

    /// Every Sparkle key is emitted from the committed public config, and only
    /// inside the `CIAOBOT_RELEASE_UPDATES=1` branch. A default local build must
    /// therefore have no feed and no key, which is what keeps it inert.
    func testReleaseBuildEmitsEveryUpdaterKeyOnlyBehindTheReleaseFlag() throws {
        let text = try readScript("build-app.sh")
        let config = try readUpdateConfig()

        XCTAssertEqual(config["UPDATE_FEED_URL"],
                       "https://github.com/raffaelefarinaro/ciaobot-mac/releases/download/updates/appcast.xml")
        XCTAssertEqual(config["UPDATE_PUBLIC_ED_KEY"], "uLLvdsFBrO33Zb9zLZ+m/ZUun3D9vUf+9t1ufoa2guM=")
        XCTAssertEqual(config["UPDATE_MIN_SYSTEM_VERSION"], "13.0")

        let guardIndex = try XCTUnwrap(text.range(of: "CIAOBOT_RELEASE_UPDATES"))
        let heredocIndex = try XCTUnwrap(text.range(of: "cat > \"$bundle/Contents/Info.plist\""))
        let expectedKeys = [
            "SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks",
            "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates",
            "SUScheduledCheckInterval", "SUVerifyUpdateBeforeExtraction",
            "SURequireSignedFeed", "SUEnableSystemProfiling",
        ]
        for key in expectedKeys {
            let range = try XCTUnwrap(
                text.range(of: "<key>\(key)</key>"),
                "scripts/build-app.sh never emits \(key)"
            )
            XCTAssertGreaterThan(range.lowerBound, guardIndex.lowerBound,
                                 "\(key) must be gated behind CIAOBOT_RELEASE_UPDATES")
            XCTAssertLessThan(range.lowerBound, heredocIndex.lowerBound,
                              "\(key) must be built into the plist by the release branch")
        }
        XCTAssertTrue(text.contains("update_plist=\n"),
                      "the plist fragment must be initialised empty")
        XCTAssertTrue(text.contains("if [ \"${CIAOBOT_RELEASE_UPDATES:-0}\" = \"1\" ]; then"),
                      "the keys are written only behind the release flag")
        XCTAssertTrue(text.contains("<key>SUFeedURL</key><string>$UPDATE_FEED_URL</string>"),
                      "the feed must come from the public config, never a hardcoded secret")
        XCTAssertTrue(text.contains("<key>SUPublicEDKey</key><string>$UPDATE_PUBLIC_ED_KEY</string>"))
        XCTAssertTrue(text.contains("$update_plist\n</dict></plist>"),
                      "the default plist template must interpolate the fragment instead of embedding keys")
        XCTAssertFalse(text.contains("SUPublicEDKey</key><string>uLL"), "the key is read from the config")
    }

    func testDefaultBuildEmitsNoUpdaterConfiguration() throws {
        let text = try readScript("build-app.sh")
        // The default path is the plist template with an empty fragment: no
        // feed, no key, no scheduled checks.
        XCTAssertTrue(text.contains("update_plist=\n"),
                      "the updater plist fragment must be initialised empty")
        XCTAssertTrue(text.contains("<key>SUEnableAutomaticChecks</key><true/>"),
                      "automatic checks belong to the flagged fragment")
        let template = try XCTUnwrap(text.range(of: "cat > \"$bundle/Contents/Info.plist\""))
        let templateText = String(text[template.lowerBound...])
        XCTAssertFalse(templateText.contains("<key>SUFeedURL</key><string>https://"),
                       "the template must not hardcode a feed")
        XCTAssertFalse(templateText.contains("<key>SUPublicEDKey</key><string>"),
                       "the template must not hardcode a key")
    }

    /// The config is public and stays public: only the feed, the public key and
    /// the minimum system version may live in it.
    func testPublicUpdateConfigCarriesNoPrivateMaterial() throws {
        let config = try readUpdateConfig()
        XCTAssertEqual(Set(config.keys),
                       ["UPDATE_FEED_URL", "UPDATE_PUBLIC_ED_KEY", "UPDATE_MIN_SYSTEM_VERSION", "UPDATE_TEAM_ID"])
        // The public team identifier is printed by `codesign -d` on every
        // signed copy. scripts/make-appcast.sh refuses an archive another team
        // signed, so a silent change here would reject this project's releases.
        XCTAssertEqual(config["UPDATE_TEAM_ID"], "AXBFS96Y9F")

        let text = try String(
            contentsOf: packageRoot.appendingPathComponent("release/update-config.env"),
            encoding: .utf8
        )
        let valueLines = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        for forbidden in ["PRIVATE", "BEGIN", "password", "PASSWORD", "secret", "SECRET", "token", "TOKEN"] {
            for line in valueLines {
                XCTAssertFalse(line.contains(forbidden), "release/update-config.env must not carry \(forbidden)")
            }
        }
        // Sparkle's private EdDSA key is a 128-character base64 string; the
        // public key is 44 characters and the feed URL stays well below.
        for line in valueLines {
            XCTAssertLessThan(line.count, 120, "a committed line looks like private key material: \(line.count) characters")
        }
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

    /// Reads the committed public update config as `KEY=value` pairs. It is a
    /// sourced shell file of plain assignments plus comments.
    private func readUpdateConfig() throws -> [String: String] {
        let url = packageRoot.appendingPathComponent("release/update-config.env")
        let text = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator])
            var value = String(trimmed[trimmed.index(after: separator)...])
            if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
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
