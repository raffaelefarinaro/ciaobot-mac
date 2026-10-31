import XCTest

/// Locks the packaging contract that cannot be exercised in-process: the
/// bundle identity that WebKit stores, saved sign-in and notification
/// permission are tied to, the fact that the ad-hoc distributable is not
/// Developer ID/notarized, and the release flow's two artifacts. Most checks
/// are pure text; the release-flow test runs the real
/// `scripts/package-notarized.sh` against a scratch repository and recording
/// doubles, so nothing is compiled, signed with a real identity, submitted to
/// Apple, launched, installed or fetched.
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

    /// Notarization must be able to run from an App Store Connect API key, with
    /// no keychain item and no interactive approval, while still accepting a
    /// keychain profile. A password must never enter the script.
    func testNotarizedPackagingSupportsAKeyFileWithoutAKeychainItem() throws {
        let text = try readScript("package-notarized.sh")
        XCTAssertTrue(text.contains("NOTARY_KEY_ID"), "the script must accept an App Store Connect key id")
        XCTAssertTrue(text.contains("NOTARY_ISSUER"), "the script must accept the issuer id")
        XCTAssertTrue(text.contains("AuthKey_$NOTARY_KEY_ID.p8"),
                      "the key path must default to the conventional private_keys location")
        XCTAssertTrue(text.contains("--key \"$notary_key\""), "the key file must be passed to notarytool")
        XCTAssertTrue(text.contains("NOTARY_PROFILE"), "a keychain profile must remain as a fallback")
        XCTAssertFalse(text.contains("-w "), "a password flag must never appear")
        XCTAssertFalse(text.contains("APPLE_ID"), "no Apple Account password path belongs in the script")
    }

    /// The disk image is the human download, so a release must build it from the
    /// same stapled bundle, notarize and staple it with the same authentication
    /// as the ZIP, and only then record its checksum. This runs the real
    /// package-notarized.sh in a scratch repository with recording doubles, so
    /// nothing is compiled, signed with a real identity, submitted to Apple or
    /// mounted for real.
    func testNotarizedPackagingAlsoBuildsAndStaplesADiskImage() throws {
        let fixture = try makeFakePackageRepository()

        let result = try runPackaging(fixture)

        XCTAssertEqual(result.status, 0, result.output)
        let output = try packageOutputDirectory(in: fixture)
        let dmg = output.appendingPathComponent("Ciaobot-0.1.2.dmg")
        let dmgChecksum = output.appendingPathComponent("Ciaobot-0.1.2.dmg.sha256")
        let zip = output.appendingPathComponent("Ciaobot-0.1.2-notarized.zip")
        XCTAssertTrue(fileManager.fileExists(atPath: zip.path), "the ZIP stays the Sparkle enclosure: \(result.output)")
        XCTAssertTrue(fileManager.fileExists(atPath: zip.path + ".sha256"), result.output)
        XCTAssertTrue(fileManager.fileExists(atPath: dmg.path), result.output)
        XCTAssertTrue(fileManager.fileExists(atPath: dmgChecksum.path), "the image checksum must be published")

        // The recorded checksum has to describe the bytes that would ship.
        let recorded = try String(contentsOf: dmgChecksum, encoding: .utf8)
        XCTAssertTrue(recorded.hasSuffix("Ciaobot-0.1.2.dmg\n"), recorded)
        let check = try run("/usr/bin/shasum", ["-a", "256", "-c", dmgChecksum.lastPathComponent], directory: output)
        XCTAssertEqual(check.status, 0, "the recorded image checksum must verify: \(check.output)")

        // Same authentication path, the image submitted on its own, then
        // stapled and validated — all after the ZIP, never before it.
        let xcrunCalls = try calls(in: fixture.xcrunLog)
        let submissions = xcrunCalls.filter { Array($0.prefix(2)) == ["notarytool", "submit"] }
        XCTAssertEqual(submissions.count, 2, "the ZIP and the DMG are submitted separately: \(submissions)")
        XCTAssertEqual((submissions[0][2] as NSString).pathExtension, "zip",
                       "the app is submitted as a ZIP: \(submissions[0])")
        XCTAssertEqual((submissions[1][2] as NSString).lastPathComponent, dmg.lastPathComponent)
        XCTAssertTrue(submissions[1].contains("--key"), "the image must use the same API key path: \(submissions[1])")
        XCTAssertTrue(submissions[1].contains(FakePackageRepository.keyID))

        func dmgTool(_ action: String) -> Int? {
            xcrunCalls.firstIndex {
                $0.count == 3 && $0[0] == "stapler" && $0[1] == action
                    && ($0[2] as NSString).lastPathComponent == dmg.lastPathComponent
            }
        }
        let imageSubmission = try XCTUnwrap(xcrunCalls.firstIndex(of: submissions[1]))
        let staple = try XCTUnwrap(dmgTool("staple"), "the image must be stapled: \(xcrunCalls)")
        let validate = try XCTUnwrap(dmgTool("validate"), "the stapled image must be validated: \(xcrunCalls)")
        XCTAssertLessThan(imageSubmission, staple, "only an accepted submission may be stapled")
        XCTAssertLessThan(staple, validate)

        // The image itself is signed with the release identity, with a secure
        // timestamp so Apple accepts it.
        let signedImages = try calls(in: fixture.codesignLog).filter { ($0.last ?? "").hasSuffix(".dmg") }
        let signedImage = try XCTUnwrap(signedImages.first, "the image must be signed")
        XCTAssertEqual(Array(signedImage.prefix(4)), ["--force", "--timestamp", "--sign", FakePackageRepository.identity])
        XCTAssertFalse(signedImage.contains("--deep"), "the image must not be signed with --deep")

        let create = try calls(in: fixture.hdiutilLog).first { $0.first == "create" }
        XCTAssertNotNil(create, "the image must be created by hdiutil: \(result.output)")
        let probe = try String(contentsOf: fixture.probe, encoding: .utf8)
        XCTAssertTrue(probe.contains("create-stage-app=yes"), probe)
        XCTAssertTrue(probe.contains("create-stage-link=/Applications"),
                      "the volume must offer the Applications symlink: \(probe)")

        let artifacts = Set(try fileManager.contentsOfDirectory(atPath: output.path))
        XCTAssertTrue(artifacts.isSuperset(of: [
            "Ciaobot.app", "verify", "Ciaobot-0.1.2-notarized.zip", "Ciaobot-0.1.2.dmg",
            "Ciaobot-0.1.2-notarized.zip.sha256", "Ciaobot-0.1.2.dmg.sha256",
        ]), "unexpected artifact set: \(artifacts)")
        XCTAssertFalse(artifacts.contains { $0.hasPrefix(".ciaobot-dmg.") },
                       "the image staging directory must be removed: \(artifacts)")
    }

    /// A checksum taken before notarization and stapling would never match the
    /// published image, because stapling adds the ticket to the file.
    func testDiskImageIsStapledAndValidatedBeforeItsChecksumIsWritten() throws {
        let text = try readScript("package-notarized.sh")
        let build = try XCTUnwrap(text.range(of: "scripts/make-dmg.sh"))
        let staple = try XCTUnwrap(text.range(of: "xcrun stapler staple \"$dmg\""))
        let validate = try XCTUnwrap(text.range(of: "xcrun stapler validate \"$dmg\""))
        let checksum = try XCTUnwrap(text.range(of: "shasum -a 256 \"$(basename -- \"$dmg\")\""))

        XCTAssertLessThan(build.lowerBound, staple.lowerBound, "the image must exist before it is stapled")
        XCTAssertLessThan(staple.lowerBound, validate.lowerBound, "a stapled image must be validated")
        XCTAssertLessThan(validate.lowerBound, checksum.lowerBound,
                          "the checksum must be taken after stapling, or it would describe different bytes")
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
            build, 6,
            "build 6 shipped as 0.1.5; never reuse or lower a published CFBundleVersion"
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

    /// The download is the image, and the reason for it has to be stated: a copy
    /// run from the download folder is translocated and cannot be updated.
    func testReadmeTellsPeopleToInstallFromTheImageBeforeLaunching() throws {
        let readme = try String(
            contentsOf: packageRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        XCTAssertTrue(readme.contains("Ciaobot-<version>.dmg"), "README must name the image download")
        XCTAssertTrue(readme.contains("drag **Ciaobot** into **Applications**"),
                      "README must describe the drag-to-Applications install")
        XCTAssertTrue(readme.contains("translocated"),
                      "README must name macOS App Translocation, not blame the app")
        XCTAssertTrue(readme.contains("location it was downloaded to"),
                      "README must quote the Sparkle refusal people actually see")
        XCTAssertTrue(readme.contains("Ciaobot-<version>-notarized.zip"),
                      "README must keep the ZIP as the Sparkle enclosure")
    }

    func testPackagingScriptIsExecutable() throws {
        let url = scriptsDirectory.appendingPathComponent("package-app.sh")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: url.path),
            "scripts/package-app.sh must keep its executable bit"
        )
    }

    // MARK: - Fake release repository

    /// A scratch checkout with the real release scripts, a stand-in bundle
    /// builder and recording doubles for the tools that need an identity, an
    /// Apple credential or a real disk image. The bundle builder is a stub on
    /// purpose: build-app.sh and Sparkle packaging have their own tests, and
    /// this fixture exists to exercise package-notarized.sh's artifact flow.
    private enum FakePackageRepository {
        static let identity = "Developer ID Application: Test Signer (AXBFS96Y9F)"
        static let keyID = "TESTKEY123"
        static let issuer = "00000000-0000-0000-0000-000000000000"
    }

    private struct PackageFixture {
        let repo: URL
        let tools: URL
        let tmp: URL
        let key: URL
        let probe: URL
        let xcrunLog: URL
        let codesignLog: URL
        let hdiutilLog: URL
        let hdiutilState: URL
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    private func makeFakePackageRepository() throws -> PackageFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ciaobot-release-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)

        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let scripts = repo.appendingPathComponent("scripts", isDirectory: true)
        try fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
        for name in ["package-notarized.sh", "make-dmg.sh", "sign-sparkle.sh"] {
            let destination = scripts.appendingPathComponent(name)
            try fileManager.copyItem(at: scriptsDirectory.appendingPathComponent(name), to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
        try writeExecutable(Self.stubBundleBuilder, at: scripts.appendingPathComponent("build-app.sh"))
        let release = repo.appendingPathComponent("release", isDirectory: true)
        try fileManager.createDirectory(at: release, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: packageRoot.appendingPathComponent("release/update-config.env"),
            to: release.appendingPathComponent("update-config.env")
        )

        let tools = root.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: tools, withIntermediateDirectories: true)
        try writeExecutable(Self.fakeCodesign, at: tools.appendingPathComponent("codesign"))
        try writeExecutable(Self.fakeXcrun, at: tools.appendingPathComponent("xcrun"))
        try writeExecutable("#!/bin/sh\nexit 0\n", at: tools.appendingPathComponent("spctl"))
        try writeExecutable(FakeHdiutil.script, at: tools.appendingPathComponent("hdiutil"))

        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        try fileManager.createDirectory(at: tmp, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("hdiutil-state", isDirectory: true)
        try fileManager.createDirectory(at: state, withIntermediateDirectories: true)
        let key = root.appendingPathComponent("AuthKey_\(FakePackageRepository.keyID).p8")
        try Data("fake App Store Connect key\n".utf8).write(to: key)

        return PackageFixture(
            repo: repo,
            tools: tools,
            tmp: tmp,
            key: key,
            probe: root.appendingPathComponent("hdiutil-probe.txt"),
            xcrunLog: root.appendingPathComponent("xcrun.log"),
            codesignLog: root.appendingPathComponent("codesign.log"),
            hdiutilLog: root.appendingPathComponent("hdiutil.log"),
            hdiutilState: state
        )
    }

    private func runPackaging(_ fixture: PackageFixture) throws -> (status: Int32, output: String) {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fixture.tools.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        // The script writes into a fresh mktemp directory; point it at the
        // scratch tree so the artifacts can be inspected.
        environment["TMPDIR"] = fixture.tmp.path
        environment["SIGNING_IDENTITY"] = FakePackageRepository.identity
        environment["NOTARY_KEY_ID"] = FakePackageRepository.keyID
        environment["NOTARY_ISSUER"] = FakePackageRepository.issuer
        environment["NOTARY_KEY"] = fixture.key.path
        environment["FAKE_CODESIGN_LOG"] = fixture.codesignLog.path
        environment["FAKE_XCRUN_LOG"] = fixture.xcrunLog.path
        environment["FAKE_HDIUTIL_LOG"] = fixture.hdiutilLog.path
        environment["FAKE_HDIUTIL_STATE"] = fixture.hdiutilState.path
        environment["FAKE_HDIUTIL_PROBE"] = fixture.probe.path
        return try run(
            "/bin/sh",
            [fixture.repo.appendingPathComponent("scripts/package-notarized.sh").path],
            environment: environment,
            directory: fixture.repo
        )
    }

    private func packageOutputDirectory(in fixture: PackageFixture) throws -> URL {
        let entries = try fileManager.contentsOfDirectory(at: fixture.tmp, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("ciaobot-notarized.") }
        XCTAssertEqual(entries.count, 1, "the run must create exactly one artifact directory: \(entries)")
        return try XCTUnwrap(entries.first)
    }

    private func calls(in log: URL) throws -> [[String]] {
        let text = try String(contentsOf: log, encoding: .utf8)
        return text.split(separator: "\n").map { line in
            line.split(separator: "|").map(String.init)
        }
    }

    private func writeExecutable(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static let stubBundleBuilder = """
    #!/bin/sh
    # Stand-in for scripts/build-app.sh: this fixture tests the release artifact
    # flow, which needs a bundle with the real identity, not a compiled app.
    set -eu
    bundle=.build/Ciaobot.app
    mkdir -p "$bundle/Contents/MacOS"
    printf '#!/bin/sh\\nexit 0\\n' > "$bundle/Contents/MacOS/CiaobotMac"
    chmod 755 "$bundle/Contents/MacOS/CiaobotMac"
    cat > "$bundle/Contents/Info.plist" <<'PLIST'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>CiaobotMac</string>
    <key>CFBundleIdentifier</key><string>local.ciaobot.mac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.2</string>
    <key>CFBundleVersion</key><string>4</string>
    </dict></plist>
    PLIST
    """

    private static let fakeCodesign = """
    #!/bin/sh
    [ -n "${FAKE_CODESIGN_LOG:-}" ] && {
        for argument in "$@"; do printf '%s|' "$argument"; done
        printf '\\n'
    } >> "$FAKE_CODESIGN_LOG"
    case "$*" in
        *--verify*) exit 0 ;;
    esac
    describe=
    for argument in "$@"; do
        case $argument in
            -d|--display|--verbose=4) describe=1 ;;
        esac
    done
    [ -n "$describe" ] || exit 0
    printf '%s\\n' 'Identifier=local.ciaobot.mac' >&2
    printf '%s\\n' 'Authority=Developer ID Application: Test Signer (AXBFS96Y9F)' >&2
    printf '%s\\n' 'TeamIdentifier=AXBFS96Y9F' >&2
    printf '%s\\n' 'flags=0x10002(runtime)' >&2
    exit 0
    """

    private static let fakeXcrun = """
    #!/bin/sh
    [ -n "${FAKE_XCRUN_LOG:-}" ] && {
        for argument in "$@"; do printf '%s|' "$argument"; done
        printf '\\n'
    } >> "$FAKE_XCRUN_LOG"
    case $1 in
        stapler) exit 0 ;;
        notarytool)
            # package-notarized.sh redirects this JSON into its result file.
            printf '%s\\n' '{"status":"Accepted","id":"fake-submission"}'
            exit 0
            ;;
    esac
    exit 1
    """

    // MARK: - Helpers

    private let fileManager = FileManager.default

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

    @discardableResult
    private func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        directory: URL? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory ?? packageRoot
        process.environment = environment.isEmpty
            ? ProcessInfo.processInfo.environment
            : environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
