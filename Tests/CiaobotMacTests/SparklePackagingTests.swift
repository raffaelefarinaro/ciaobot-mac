import XCTest

/// Exercises the Sparkle packaging contract without launching the app: the
/// exact pinned dependency, architecture selection, symlink/executable
/// preservation, nested signing order, ad-hoc archive extraction, and the
/// absence of `--deep` signing. Fixtures and fake signing tools live in a
/// unique scratch directory; nothing touches an installed app, the operator's
/// `.build` output, the network, or a server.
final class SparklePackagingTests: XCTestCase {
    private var scratch: URL!
    private let fileManager = FileManager.default
    private static let sparkleVersion = "2.10.1"
    private static let sparkleRevision = "ab7d71291238df6e0492143b120c9b696a35f603"

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ciaobot-sparkle-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? fileManager.removeItem(at: scratch) }
    }

    // MARK: - Dependency pin

    func testPackagePinsSparkleExactlyAndResolvesTheExpectedRevision() throws {
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            manifest.contains(#".package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")"#),
            "Sparkle must stay an exact 2.10.1 dependency, not a branch or range"
        )
        XCTAssertTrue(
            manifest.contains(#".product(name: "Sparkle", package: "Sparkle")"#),
            "the executable target must link the Sparkle product"
        )
        XCTAssertTrue(
            manifest.contains("@executable_path/../Frameworks"),
            "the executable needs an executable-relative framework runpath"
        )

        let data = try Data(contentsOf: packageRoot.appendingPathComponent("Package.resolved"))
        let resolved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Package.resolved is not JSON"
        )
        let pins = try XCTUnwrap(resolved["pins"] as? [[String: Any]])
        let sparkle = try XCTUnwrap(pins.first { ($0["identity"] as? String) == "sparkle" })
        XCTAssertEqual(sparkle["location"] as? String, "https://github.com/sparkle-project/Sparkle")
        let state = try XCTUnwrap(sparkle["state"] as? [String: Any])
        XCTAssertEqual(state["version"] as? String, Self.sparkleVersion)
        XCTAssertEqual(state["revision"] as? String, Self.sparkleRevision)
    }

    // MARK: - Framework selection and copy

    func testInstallsTheResolvedFrameworkWithSymlinksAndExecutables() throws {
        let xcframework = try resolvedSparkleXCFramework()
        let frameworks = scratch.appendingPathComponent("Install/Ciaobot.app/Contents/Frameworks", isDirectory: true)

        let result = try run(
            "/bin/sh",
            [installScript.path, xcframework.path, try hostArchitecture(), frameworks.path]
        )
        XCTAssertEqual(result.status, 0, result.output)

        let framework = frameworks.appendingPathComponent("Sparkle.framework")
        for link in ["Autoupdate", "Headers", "Modules", "PrivateHeaders", "Resources",
                     "Sparkle", "Updater.app", "XPCServices", "Versions/Current"] {
            let attributes = try fileManager.attributesOfItem(atPath: framework.appendingPathComponent(link).path)
            XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink,
                           "\(link) must stay a symbolic link, not a copy")
        }
        XCTAssertTrue(
            fileManager.isExecutableFile(
                atPath: framework.appendingPathComponent("Versions/B/Sparkle").path
            ),
            "the framework binary must stay executable"
        )
        for helper in [
            "Versions/B/Autoupdate",
            "Versions/B/Updater.app/Contents/MacOS/Updater",
            "Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
            "Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
        ] {
            XCTAssertTrue(
                fileManager.isExecutableFile(atPath: framework.appendingPathComponent(helper).path),
                "\(helper) must stay executable"
            )
        }
    }

    func testRefusesTwoMacOSLibrariesClaimingTheSameArchitecture() throws {
        let xcframework = try makeXCFramework(slices: [
            (id: "macos-a", platform: "macos", architectures: ["arm64"]),
            (id: "macos-b", platform: "macos", architectures: ["arm64"]),
        ])
        let frameworks = scratch.appendingPathComponent("Ambiguous/Ciaobot.app/Contents/Frameworks", isDirectory: true)

        let result = try run(
            "/bin/sh",
            [installScript.path, xcframework.path, "arm64", frameworks.path]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("ambiguous"), result.output)
        XCTAssertFalse(fileManager.fileExists(atPath: frameworks.appendingPathComponent("Sparkle.framework").path))
    }

    func testRefusesWhenNoMacOSSliceSupportsTheArchitecture() throws {
        let xcframework = try makeXCFramework(slices: [
            (id: "ios-arm64", platform: "ios", architectures: ["arm64"]),
            (id: "macos-x86_64", platform: "macos", architectures: ["x86_64"]),
        ])
        let frameworks = scratch.appendingPathComponent("Missing/Ciaobot.app/Contents/Frameworks", isDirectory: true)

        let result = try run(
            "/bin/sh",
            [installScript.path, xcframework.path, "arm64", frameworks.path]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("no macOS Sparkle slice supports arm64"), result.output)
    }

    func testIgnoresANonMacOSSliceForTheSameArchitecture() throws {
        let xcframework = try makeXCFramework(slices: [
            (id: "ios-arm64", platform: "ios", architectures: ["arm64"]),
            (id: "macos-arm64", platform: "macos", architectures: ["arm64", "x86_64"]),
        ])
        let frameworks = scratch.appendingPathComponent("Ignores/Ciaobot.app/Contents/Frameworks", isDirectory: true)

        let result = try run(
            "/bin/sh",
            [installScript.path, xcframework.path, "arm64", frameworks.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(
            fileManager.fileExists(atPath: frameworks.appendingPathComponent("Sparkle.framework/Versions/B/Sparkle").path)
        )
    }

    func testLinkedExecutableLoadsTheEmbeddedFrameworkAtRuntime() throws {
        let xcframework = try resolvedSparkleXCFramework()
        let frameworks = scratch.appendingPathComponent("Runtime/Ciaobot.app/Contents/Frameworks", isDirectory: true)
        let installed = try run(
            "/bin/sh",
            [installScript.path, xcframework.path, try hostArchitecture(), frameworks.path]
        )
        XCTAssertEqual(installed.status, 0, installed.output)

        let source = scratch.appendingPathComponent("Probe.swift")
        try Data("import Sparkle\nprint(SPUUpdater.self)\n".utf8).write(to: source)
        let binary = frameworks
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Contents/MacOS/Probe")
        try fileManager.createDirectory(
            at: binary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let swiftc = try run("/usr/bin/xcrun", ["--find", "swiftc"])
        XCTAssertEqual(swiftc.status, 0, swiftc.output)
        let compilation = try run(
            swiftc.output.trimmingCharacters(in: .whitespacesAndNewlines),
            [
                "-F", frameworks.path,
                "-framework", "Sparkle",
                "-Xlinker", "-rpath",
                "-Xlinker", "@executable_path/../Frameworks",
                "-o", binary.path,
                source.path,
            ]
        )
        XCTAssertEqual(compilation.status, 0, compilation.output)

        let linkage = try run("/usr/bin/otool", ["-L", binary.path])
        XCTAssertEqual(linkage.status, 0, linkage.output)
        XCTAssertTrue(
            linkage.output.contains("@rpath/Sparkle.framework/Versions/B/Sparkle"),
            "the probe must link Sparkle by @rpath, got:\n\(linkage.output)"
        )

        // Loading Sparkle is the only runtime action. No updater is created and
        // no feed, network request, or window is involved.
        let launch = try run(binary.path, [])
        XCTAssertEqual(launch.status, 0, launch.output)
        XCTAssertTrue(launch.output.contains("SPUUpdater"), launch.output)
    }

    // MARK: - Nested signing

    func testAdHocSignerOrdersHelpersInsideOutAndNeverUsesDeep() throws {
        let framework = try makeFrameworkFixture()
        let fakeBin = scratch.appendingPathComponent("bin", isDirectory: true)
        let log = scratch.appendingPathComponent("codesign.log")
        try makeFakeCodesign(in: fakeBin)

        let result = try run(
            "/bin/sh",
            [signScript.path, "--adhoc", framework.path],
            environment: fakeEnvironment(log: log, bin: fakeBin)
        )
        XCTAssertEqual(result.status, 0, result.output)

        let signed = try signedPaths(in: log)
        XCTAssertEqual(signed.count, 5, "expected four helpers and the framework:\n\(signed)")
        let expected = [
            "Installer.xpc",
            "Downloader.xpc",
            "Autoupdate",
            "Updater.app",
            framework.lastPathComponent,
        ]
        XCTAssertEqual(signed.map { ($0 as NSString).lastPathComponent }, expected)

        let logText = try String(contentsOf: log, encoding: .utf8)
        XCTAssertFalse(logText.contains("--deep"), "--deep must never be used to sign Sparkle")
        XCTAssertTrue(logText.contains("--sign|-|--timestamp=none|"), logText)
        XCTAssertFalse(logText.contains("--options|runtime"), "ad-hoc local packaging must not enable the hardened runtime")
    }

    func testDistributionSignerUsesRuntimeTimestampAndKeepsDownloaderEntitlements() throws {
        let framework = try makeFrameworkFixture()
        let fakeBin = scratch.appendingPathComponent("bin", isDirectory: true)
        let log = scratch.appendingPathComponent("codesign.log")
        try makeFakeCodesign(in: fakeBin)
        let identity = "Developer ID Application: Example Person (TEAMID)"

        let result = try run(
            "/bin/sh",
            [signScript.path, "--distribution", identity, framework.path],
            environment: fakeEnvironment(log: log, bin: fakeBin)
        )
        XCTAssertEqual(result.status, 0, result.output)

        let logText = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logText.contains("--sign|\(identity)|--options|runtime|--timestamp"), logText)
        let downloaderSignature = try XCTUnwrap(
            logText.split(separator: "\n").first { $0.contains("--preserve-metadata=entitlements") },
            "Downloader.xpc must keep Sparkle's entitlements when re-signed:\n\(logText)"
        )
        XCTAssertTrue(downloaderSignature.contains("Downloader.xpc"), String(downloaderSignature))
        XCTAssertFalse(logText.contains("--deep"), "--deep must never be used to sign Sparkle")
    }

    func testDistributionSignerRefusesGetTaskAllowOnANestedHelper() throws {
        let framework = try makeFrameworkFixture()
        let fakeBin = scratch.appendingPathComponent("bin", isDirectory: true)
        let log = scratch.appendingPathComponent("codesign.log")
        try makeFakeCodesign(in: fakeBin)
        let downloader = framework.appendingPathComponent("Versions/B/XPCServices/Downloader.xpc")
        let resolvedDownloader = try realPath(of: downloader)

        let result = try run(
            "/bin/sh",
            [signScript.path, "--distribution", "Developer ID Application: Example (TEAMID)", framework.path],
            environment: fakeEnvironment(
                log: log,
                bin: fakeBin,
                extra: ["FAKE_GET_TASK_ALLOW_PATH": resolvedDownloader]
            )
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("get-task-allow"), result.output)
        XCTAssertTrue(result.output.contains("Downloader.xpc"), result.output)
    }

    /// A helper replaced by a symlink to a bundle outside the copied framework
    /// must be refused before codesign is invoked, so the external bundle is
    /// never signed or rewritten.
    func testSignerRejectsHelperSymlinkOutsideFrameworkBeforeSigning() throws {
        let framework = try makeFrameworkFixture()
        let external = try makeExternalXPCBundle(named: "Installer.xpc")
        let installer = framework.appendingPathComponent("Versions/B/XPCServices/Installer.xpc")
        try fileManager.removeItem(at: installer)
        try fileManager.createSymbolicLink(atPath: installer.path, withDestinationPath: external.bundle.path)
        let sentinelBefore = try Data(contentsOf: external.sentinel)

        let fakeBin = scratch.appendingPathComponent("bin", isDirectory: true)
        let log = scratch.appendingPathComponent("codesign.log")
        try makeFakeCodesign(in: fakeBin)
        let result = try run(
            "/bin/sh",
            [signScript.path, "--adhoc", framework.path],
            environment: fakeEnvironment(log: log, bin: fakeBin)
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("symbolic"), result.output)
        XCTAssertTrue(result.output.contains("Installer.xpc"), result.output)
        XCTAssertFalse(
            fileManager.fileExists(atPath: log.path),
            "codesign must not run before the framework layout is validated"
        )
        XCTAssertEqual(try Data(contentsOf: external.sentinel), sentinelBefore)
        XCTAssertTrue(fileManager.fileExists(atPath: external.bundle.path))
    }

    /// Versions/B itself is a symlink to an external directory: nothing under
    /// the framework root may be signed through it.
    func testSignerRejectsVersionsBundleSymlinkOutsideFrameworkBeforeSigning() throws {
        let framework = try makeFrameworkFixture()
        let external = scratch.appendingPathComponent("External-B", isDirectory: true)
        try fileManager.createDirectory(at: external, withIntermediateDirectories: true)
        try fileManager.moveItem(
            at: framework.appendingPathComponent("Versions/B"),
            to: external.appendingPathComponent("B")
        )
        try fileManager.createSymbolicLink(
            atPath: framework.appendingPathComponent("Versions/B").path,
            withDestinationPath: external.appendingPathComponent("B").path
        )
        let sentinel = external.appendingPathComponent("B/sentinel.txt")
        try Data("external versions\n".utf8).write(to: sentinel)

        let fakeBin = scratch.appendingPathComponent("bin", isDirectory: true)
        let log = scratch.appendingPathComponent("codesign.log")
        try makeFakeCodesign(in: fakeBin)
        let result = try run(
            "/bin/sh",
            [signScript.path, "--adhoc", framework.path],
            environment: fakeEnvironment(log: log, bin: fakeBin)
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("symlink") || result.output.contains("symbolic"), result.output)
        XCTAssertFalse(fileManager.fileExists(atPath: log.path), "codesign must not run")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "external versions\n")
    }

    /// Any symlink outside Sparkle's documented framework layout is refused,
    /// even when the script would not otherwise sign through it.
    func testSignerRejectsUnexpectedFrameworkSymlinkBeforeSigning() throws {
        let framework = try makeFrameworkFixture()
        let external = scratch.appendingPathComponent("External-Evil", isDirectory: true)
        try fileManager.createDirectory(at: external, withIntermediateDirectories: true)
        let sentinel = external.appendingPathComponent("sentinel.txt")
        try Data("outside\n".utf8).write(to: sentinel)
        try fileManager.createSymbolicLink(
            atPath: framework.appendingPathComponent("Unexpected").path,
            withDestinationPath: external.path
        )

        let fakeBin = scratch.appendingPathComponent("bin", isDirectory: true)
        let log = scratch.appendingPathComponent("codesign.log")
        try makeFakeCodesign(in: fakeBin)
        let result = try run(
            "/bin/sh",
            [signScript.path, "--adhoc", framework.path],
            environment: fakeEnvironment(log: log, bin: fakeBin)
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("unexpected"), result.output)
        XCTAssertFalse(fileManager.fileExists(atPath: log.path), "codesign must not run")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "outside\n")
    }

    /// The app's Contents/Frameworks directory is an enclosing component; a
    /// symlinked one must be refused before the framework is inspected.
    func testSignerRejectsSymlinkedFrameworksAncestorBeforeSigning() throws {
        let framework = try makeFrameworkFixture()
        let bundle = framework
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let external = scratch.appendingPathComponent("External-Frameworks", isDirectory: true)
        let externalFramework = external.appendingPathComponent("Sparkle.framework", isDirectory: true)
        try fileManager.createDirectory(at: externalFramework, withIntermediateDirectories: true)
        let sentinel = externalFramework.appendingPathComponent("sentinel.txt")
        try Data("outside frameworks\n".utf8).write(to: sentinel)
        try fileManager.removeItem(at: frameworks)
        try fileManager.createSymbolicLink(atPath: frameworks.path, withDestinationPath: external.path)

        let fakeBin = scratch.appendingPathComponent("bin", isDirectory: true)
        let log = scratch.appendingPathComponent("codesign.log")
        try makeFakeCodesign(in: fakeBin)
        let result = try run(
            "/bin/sh",
            [signScript.path, "--adhoc", framework.path],
            environment: fakeEnvironment(log: log, bin: fakeBin)
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("symlink"), result.output)
        XCTAssertFalse(fileManager.fileExists(atPath: log.path), "codesign must not run")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "outside frameworks\n")
    }

    // MARK: - Safe framework replacement

    func testSafeRemovalRefusesSymlinkedFrameworksDirectoryAndPreservesSentinel() throws {
        let repo = try makeOwnedRepository()
        let bundle = repo.appendingPathComponent(".build/Ciaobot.app", isDirectory: true)
        let external = scratch.appendingPathComponent("External-Frameworks", isDirectory: true)
        let externalFramework = external.appendingPathComponent("Sparkle.framework", isDirectory: true)
        try fileManager.createDirectory(at: externalFramework, withIntermediateDirectories: true)
        let sentinel = externalFramework.appendingPathComponent("sentinel.txt")
        try Data("keep external\n".utf8).write(to: sentinel)
        try fileManager.createDirectory(
            at: bundle.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            atPath: bundle.appendingPathComponent("Contents/Frameworks").path,
            withDestinationPath: external.path
        )
        let before = try Data(contentsOf: sentinel)

        let result = try run("/bin/sh", [copiedRemoveScript(in: repo).path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("symlink"), result.output)
        XCTAssertEqual(try Data(contentsOf: sentinel), before)
        XCTAssertTrue(fileManager.fileExists(atPath: externalFramework.path))
    }

    func testSafeRemovalRefusesSymlinkedFrameworkBundleAndPreservesSentinel() throws {
        let repo = try makeOwnedRepository()
        let bundle = repo.appendingPathComponent(".build/Ciaobot.app", isDirectory: true)
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        try fileManager.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let externalFramework = scratch.appendingPathComponent("External-Sparkle.framework", isDirectory: true)
        try fileManager.createDirectory(at: externalFramework, withIntermediateDirectories: true)
        let sentinel = externalFramework.appendingPathComponent("sentinel.txt")
        try Data("keep external framework\n".utf8).write(to: sentinel)
        try fileManager.createSymbolicLink(
            atPath: frameworks.appendingPathComponent("Sparkle.framework").path,
            withDestinationPath: externalFramework.path
        )
        let before = try Data(contentsOf: sentinel)

        let result = try run("/bin/sh", [copiedRemoveScript(in: repo).path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("symlink"), result.output)
        XCTAssertEqual(try Data(contentsOf: sentinel), before)
        XCTAssertTrue(fileManager.fileExists(atPath: externalFramework.path))
    }

    func testSafeRemovalRefusesSymlinkedBuildAncestor() throws {
        let repo = try makeOwnedRepository(createBuildDirectory: false)
        let externalBuild = scratch.appendingPathComponent("External-Build", isDirectory: true)
        let externalBundle = externalBuild.appendingPathComponent("Ciaobot.app", isDirectory: true)
        let externalFramework = externalBundle.appendingPathComponent("Contents/Frameworks/Sparkle.framework", isDirectory: true)
        try fileManager.createDirectory(at: externalFramework, withIntermediateDirectories: true)
        let sentinel = externalFramework.appendingPathComponent("sentinel.txt")
        try Data("keep external build\n".utf8).write(to: sentinel)
        try fileManager.createSymbolicLink(
            atPath: repo.appendingPathComponent(".build").path,
            withDestinationPath: externalBuild.path
        )
        let before = try Data(contentsOf: sentinel)

        let result = try run("/bin/sh", [copiedRemoveScript(in: repo).path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("symlink"), result.output)
        XCTAssertEqual(try Data(contentsOf: sentinel), before)
        XCTAssertTrue(fileManager.fileExists(atPath: externalFramework.path))
    }

    /// A correctly shaped Sparkle directory that this build did not create has
    /// no ownership marker and must never be recursively removed.
    func testSafeRemovalRejectsCorrectlyShapedUnownedFramework() throws {
        let repo = try makeOwnedRepository()
        let bundle = repo.appendingPathComponent(".build/Ciaobot.app", isDirectory: true)
        let framework = bundle.appendingPathComponent("Contents/Frameworks/Sparkle.framework", isDirectory: true)
        try makeFrameworkLayout(at: framework)
        let sentinel = framework.appendingPathComponent("sentinel.txt")
        try Data("unowned sentinel\n".utf8).write(to: sentinel)

        let result = try run("/bin/sh", [copiedRemoveScript(in: repo).path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("ownership"), result.output)
        XCTAssertTrue(fileManager.fileExists(atPath: framework.path))
        XCTAssertEqual(
            try String(contentsOf: sentinel, encoding: .utf8),
            "unowned sentinel\n"
        )
    }

    /// The installer writes the ownership evidence; removal deletes the
    /// framework and evidence together so a repeated build can install again.
    func testOwnedFrameworkCanBeReplacedRepeatedly() throws {
        let repo = try makeOwnedRepository()
        let bundle = repo.appendingPathComponent(".build/Ciaobot.app", isDirectory: true)
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let xcframework = try makeXCFramework(slices: [
            (id: "macos-host", platform: "macos", architectures: [try hostArchitecture()]),
        ])
        let marker = repo.appendingPathComponent(".build/.ciaobot-sparkle-owned")

        let first = try run(
            "/bin/sh",
            [installScript.path, xcframework.path, try hostArchitecture(), frameworks.path]
        )
        XCTAssertEqual(first.status, 0, first.output)
        XCTAssertTrue(fileManager.fileExists(atPath: marker.path))
        XCTAssertTrue(
            fileManager.fileExists(atPath: frameworks.appendingPathComponent("Sparkle.framework").path)
        )

        let removed = try run("/bin/sh", [copiedRemoveScript(in: repo).path])
        XCTAssertEqual(removed.status, 0, removed.output)
        XCTAssertTrue(removed.output.contains("Removing owned framework"), removed.output)
        XCTAssertFalse(fileManager.fileExists(atPath: frameworks.appendingPathComponent("Sparkle.framework").path))
        XCTAssertFalse(fileManager.fileExists(atPath: marker.path), "removal must not leave stale ownership evidence")

        let second = try run(
            "/bin/sh",
            [installScript.path, xcframework.path, try hostArchitecture(), frameworks.path]
        )
        XCTAssertEqual(second.status, 0, second.output)
        XCTAssertTrue(fileManager.fileExists(atPath: marker.path))
        XCTAssertTrue(
            fileManager.fileExists(atPath: frameworks.appendingPathComponent("Sparkle.framework").path)
        )

        // A second install without removal must refuse, and must not overwrite
        // the marker already in that directory.
        let markerBefore = try Data(contentsOf: marker)
        let third = try run(
            "/bin/sh",
            [installScript.path, xcframework.path, try hostArchitecture(), frameworks.path]
        )
        XCTAssertNotEqual(third.status, 0, third.output)
        XCTAssertTrue(third.output.contains("refusing to replace"), third.output)
        XCTAssertEqual(try Data(contentsOf: marker), markerBefore)
    }

    /// An existing marker must never be overwritten, even when no framework is
    /// present in that directory.
    func testInstallRefusesToOverwriteExistingOwnershipMarker() throws {
        let repo = try makeOwnedRepository()
        let bundle = repo.appendingPathComponent(".build/Ciaobot.app", isDirectory: true)
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let xcframework = try makeXCFramework(slices: [
            (id: "macos-host", platform: "macos", architectures: [try hostArchitecture()]),
        ])
        let marker = repo.appendingPathComponent(".build/.ciaobot-sparkle-owned")
        let foreign = "foreign marker\n"
        try Data(foreign.utf8).write(to: marker)

        let result = try run(
            "/bin/sh",
            [installScript.path, xcframework.path, try hostArchitecture(), frameworks.path]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("ownership marker"), result.output)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), foreign)
        XCTAssertFalse(
            fileManager.fileExists(atPath: frameworks.appendingPathComponent("Sparkle.framework").path)
        )
    }

    // MARK: - Ad-hoc packaging

    func testPackagingSignsAndExtractsAnAppWithSparkle() throws {
        let xcframework = try resolvedSparkleXCFramework()
        let app = scratch.appendingPathComponent("Build/Ciaobot.app", isDirectory: true)
        let frameworks = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        try makeApp(at: app)
        try fileManager.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let installed = try run(
            "/bin/sh",
            [installScript.path, xcframework.path, try hostArchitecture(), frameworks.path]
        )
        XCTAssertEqual(installed.status, 0, installed.output)

        let output = scratch.appendingPathComponent("out", isDirectory: true)
        let packaged = try run(
            "/bin/sh",
            [packageScript.path, "--no-build", "--app", app.path, "--output", output.path]
        )
        XCTAssertEqual(packaged.status, 0, packaged.output)

        let archive = output.appendingPathComponent("Ciaobot-1.2.3-adhoc.zip")
        let extracted = scratch.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        let unzip = try run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
        XCTAssertEqual(unzip.status, 0, unzip.output)

        let extractedFramework = extracted.appendingPathComponent(
            "Ciaobot.app/Contents/Frameworks/Sparkle.framework"
        )
        XCTAssertTrue(
            fileManager.fileExists(atPath: extractedFramework.appendingPathComponent("Versions/B/Sparkle").path)
        )
        for link in ["Sparkle", "Resources", "Updater.app", "XPCServices", "Versions/Current"] {
            let attributes = try fileManager.attributesOfItem(
                atPath: extractedFramework.appendingPathComponent(link).path
            )
            XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink,
                           "the archive dereferenced Sparkle/\(link)")
        }
        let verified = try run(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", "--verbose=2", extracted.appendingPathComponent("Ciaobot.app").path]
        )
        XCTAssertEqual(verified.status, 0, verified.output)
        let nested = try run(
            "/usr/bin/codesign",
            ["--verify", "--strict", "--verbose=2", extractedFramework.path]
        )
        XCTAssertEqual(nested.status, 0, nested.output)
    }

    // MARK: - Script contracts

    func testBuildScriptSelectsTheFrameworkAndVerifiesLinkage() throws {
        let text = try readScript("build-app.sh")
        XCTAssertTrue(text.contains("scripts/install-sparkle-framework.sh"), text)
        XCTAssertTrue(text.contains("scripts/remove-owned-framework.sh"), text)
        XCTAssertFalse(
            text.contains("remove-owned-framework.sh \"$PWD\""),
            "the removal helper must anchor to its own checkout, not a caller path"
        )
        XCTAssertFalse(
            text.contains("rm -rf \"$frameworks/Sparkle.framework\""),
            "build-app must not recursively remove the framework without an ownership check"
        )
        XCTAssertTrue(text.contains("ambigu"), "an ambiguous Sparkle artifact must fail the build")
        XCTAssertTrue(text.contains("@rpath/Sparkle.framework/Versions/B/Sparkle"), text)
        XCTAssertTrue(text.contains("@executable_path/../Frameworks"), text)
        XCTAssertTrue(text.contains("otool -l"), text)
    }

    func testNotarizedPackagingSignsSparkleBeforeTheApp() throws {
        let text = try readScript("package-notarized.sh")
        let sparkle = try XCTUnwrap(text.range(of: "scripts/sign-sparkle.sh --distribution"))
        let app = try XCTUnwrap(
            text.range(of: "codesign --force --options runtime --timestamp --sign \"$SIGNING_IDENTITY\" \"$bundle\"")
        )
        XCTAssertLessThan(sparkle.lowerBound, app.lowerBound)
        XCTAssertTrue(text.contains("codesign --verify --deep --strict"))
    }

    func testPackagingScriptSignsSparkleBeforeTheAppAndPreservesSymlinks() throws {
        let text = try readScript("package-app.sh")
        let sparkle = try XCTUnwrap(text.range(of: "scripts/sign-sparkle.sh --adhoc"))
        let app = try XCTUnwrap(text.range(of: "codesign --force --sign - --timestamp=none \"$bundle\""))
        XCTAssertLessThan(sparkle.lowerBound, app.lowerBound)
        XCTAssertTrue(text.contains("zip -q -r -X -y"), "the archive must store Sparkle symlinks as links")
        XCTAssertTrue(text.contains("the archive dereferenced Sparkle"))
    }

    func testSparkleScriptsAreExecutable() throws {
        for name in ["install-sparkle-framework.sh", "sign-sparkle.sh", "remove-owned-framework.sh"] {
            let url = scriptsDirectory.appendingPathComponent(name)
            XCTAssertTrue(
                fileManager.isExecutableFile(atPath: url.path),
                "scripts/\(name) is invoked directly and must keep its executable bit"
            )
        }
    }

    func testRemovalAnchorsItsOwnCheckoutAndUsesInstallerOwnershipMarker() throws {
        let remove = try readScript("remove-owned-framework.sh")
        XCTAssertTrue(
            remove.contains(#"script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"#),
            "the removal helper must derive the checkout from its own location"
        )
        XCTAssertFalse(remove.contains("repo_root=$1"), "the checkout root must never come from a caller")
        let install = try readScript("install-sparkle-framework.sh")
        let marker = "ciaobot-build-owned-sparkle-framework-v1"
        XCTAssertTrue(remove.contains(marker), remove)
        XCTAssertTrue(install.contains(marker), install)
        XCTAssertTrue(install.contains(".ciaobot-sparkle-owned"), install)
    }

    // MARK: - Fixtures

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var scriptsDirectory: URL {
        packageRoot.appendingPathComponent("scripts")
    }

    private var installScript: URL {
        scriptsDirectory.appendingPathComponent("install-sparkle-framework.sh")
    }

    private var signScript: URL {
        scriptsDirectory.appendingPathComponent("sign-sparkle.sh")
    }

    private var packageScript: URL {
        scriptsDirectory.appendingPathComponent("package-app.sh")
    }

    private var removeScript: URL {
        scriptsDirectory.appendingPathComponent("remove-owned-framework.sh")
    }

    private func hostArchitecture() throws -> String {
        let result = try run("/usr/bin/uname", ["-m"])
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readScript(_ name: String) throws -> String {
        try String(
            contentsOf: scriptsDirectory.appendingPathComponent(name),
            encoding: .utf8
        )
    }

    /// Finds SwiftPM's resolved binary artifact. `swift test` itself resolves
    /// the package, so a missing artifact means the dependency was removed.
    private func resolvedSparkleXCFramework() throws -> URL {
        let artifacts = packageRoot.appendingPathComponent(".build/artifacts")
        guard let enumerator = fileManager.enumerator(
            at: artifacts,
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("no .build/artifacts; SwiftPM did not resolve Sparkle")
            throw CocoaError(.fileNoSuchFile)
        }
        for case let url as URL in enumerator where url.lastPathComponent == "Sparkle.xcframework" {
            return url
        }
        XCTFail("no Sparkle.xcframework under .build/artifacts")
        throw CocoaError(.fileNoSuchFile)
    }

    /// Creates a minimal xcframework whose slices have the layout the install
    /// helper validates: versioned framework, executable binary, nested tools.
    private func makeXCFramework(
        slices: [(id: String, platform: String, architectures: [String])]
    ) throws -> URL {
        let root = scratch.appendingPathComponent("Sparkle.xcframework", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var libraries: [[String: Any]] = []
        for slice in slices {
            let framework = root
                .appendingPathComponent(slice.id)
                .appendingPathComponent("Sparkle.framework")
            try makeFrameworkLayout(at: framework)
            libraries.append([
                "LibraryIdentifier": slice.id,
                "LibraryPath": "Sparkle.framework",
                "BinaryPath": "Sparkle.framework/Versions/B/Sparkle",
                "SupportedPlatform": slice.platform,
                "SupportedArchitectures": slice.architectures,
            ])
        }
        let info: [String: Any] = [
            "AvailableLibraries": libraries,
            "CFBundlePackageType": "XFWK",
            "XCFrameworkFormatVersion": "1.0",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent("Info.plist"))
        return root
    }

    /// Framework fixture used by both selection and signing tests. It lives in
    /// the exact app layout the signer validates: Contents/Frameworks.
    private func makeFrameworkFixture() throws -> URL {
        let framework = scratch
            .appendingPathComponent("Signing/Ciaobot.app/Contents/Frameworks/Sparkle.framework", isDirectory: true)
        try makeFrameworkLayout(at: framework)
        return framework
    }

    /// External bundle used to prove a symlink target is never signed.
    private func makeExternalXPCBundle(named name: String) throws -> (bundle: URL, sentinel: URL) {
        let root = scratch.appendingPathComponent("External-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent(name, isDirectory: true)
        let macos = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macos, withIntermediateDirectories: true)
        let executableName = name.hasPrefix("Installer") ? "Installer" : "Downloader"
        let executable = macos.appendingPathComponent(executableName)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let sentinel = bundle.appendingPathComponent("sentinel.txt")
        try Data("do not sign\n".utf8).write(to: sentinel)
        return (bundle, sentinel)
    }

    /// A scratch repository shaped like the checkout's `.build` output, with
    /// the real removal script copied into its own scripts directory so the
    /// script anchors to this scratch checkout rather than the real one.
    private func makeOwnedRepository(createBuildDirectory: Bool = true) throws -> URL {
        let repo = scratch.appendingPathComponent("Owned-\(UUID().uuidString)", isDirectory: true)
        let scripts = repo.appendingPathComponent("scripts", isDirectory: true)
        try fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
        let copied = scripts.appendingPathComponent("remove-owned-framework.sh")
        try fileManager.copyItem(at: removeScript, to: copied)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copied.path)
        if createBuildDirectory {
            try fileManager.createDirectory(
                at: repo.appendingPathComponent(".build/Ciaobot.app/Contents", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        // The helper only accepts the build's physical owned path, exactly as
        // scripts/build-app.sh passes it after `cd -P`.
        return URL(fileURLWithPath: try realPath(of: repo), isDirectory: true)
    }

    private func copiedRemoveScript(in repo: URL) -> URL {
        repo.appendingPathComponent("scripts/remove-owned-framework.sh")
    }

    private func makeFrameworkLayout(at framework: URL) throws {
        let version = framework.appendingPathComponent("Versions/B", isDirectory: true)
        try fileManager.createDirectory(at: version, withIntermediateDirectories: true)
        try link("B", at: framework.appendingPathComponent("Versions/Current"))
        try link("Versions/Current/Autoupdate", at: framework.appendingPathComponent("Autoupdate"))
        try link("Versions/Current/Headers", at: framework.appendingPathComponent("Headers"))
        try link("Versions/Current/Modules", at: framework.appendingPathComponent("Modules"))
        try link("Versions/Current/PrivateHeaders", at: framework.appendingPathComponent("PrivateHeaders"))
        try link("Versions/Current/Resources", at: framework.appendingPathComponent("Resources"))
        try link("Versions/Current/Sparkle", at: framework.appendingPathComponent("Sparkle"))
        try link("Versions/Current/Updater.app", at: framework.appendingPathComponent("Updater.app"))
        try link("Versions/Current/XPCServices", at: framework.appendingPathComponent("XPCServices"))

        for directory in ["Headers", "Modules", "PrivateHeaders", "Resources",
                          "Updater.app/Contents/MacOS",
                          "XPCServices/Installer.xpc/Contents/MacOS",
                          "XPCServices/Downloader.xpc/Contents/MacOS"] {
            try fileManager.createDirectory(
                at: version.appendingPathComponent(directory),
                withIntermediateDirectories: true
            )
        }
        let executables = [
            "Sparkle",
            "Autoupdate",
            "Updater.app/Contents/MacOS/Updater",
            "XPCServices/Installer.xpc/Contents/MacOS/Installer",
            "XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
        ]
        for name in executables {
            let url = version.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private func realPath(of url: URL) throws -> String {
        let result = try run("/bin/realpath", [url.path])
        XCTAssertEqual(result.status, 0, result.output)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func link(_ destination: String, at url: URL) throws {
        try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    private func fakeEnvironment(
        log: URL,
        bin: URL,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var environment = [
            "FAKE_CODESIGN_LOG": log.path,
            "PATH": bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"),
        ]
        environment.merge(extra) { _, new in new }
        return environment
    }

    private func makeFakeCodesign(in directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("codesign")
        let text = """
        #!/bin/sh
        [ -n "${FAKE_CODESIGN_LOG:-}" ] && {
            for argument in "$@"; do printf '%s|' "$argument"; done
            printf '\\n'
        } >> "$FAKE_CODESIGN_LOG"
        last=
        for argument in "$@"; do last=$argument; done
        case "$*" in
            -d\\ --entitlements*)
                if [ -n "${FAKE_GET_TASK_ALLOW_PATH:-}" ] && [ "$last" = "$FAKE_GET_TASK_ALLOW_PATH" ]; then
                    printf '%s\\n' '<?xml version="1.0" encoding="UTF-8"?>'
                    printf '%s\\n' '<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>'
                fi
                ;;
            -d\\ --verbose=4*)
                printf '%s\\n' 'flags=0x10002(adhoc,runtime)'
                ;;
        esac
        exit 0
        """
        try Data(text.utf8).write(to: script)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    /// Signing invocations in the fake log, in order. Inspection calls
    /// (`-d ...`) are excluded.
    private func signedPaths(in log: URL) throws -> [String] {
        let text = try String(contentsOf: log, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.first == "--force" else { return nil }
            return fields.dropLast().last
        }
    }

    private func makeApp(at url: URL) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macos, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>Scratch</string>
        <key>CFBundleIdentifier</key><string>test.ciaobot.sparkle</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleShortVersionString</key><string>1.2.3</string>
        <key>CFBundleVersion</key><string>7</string>
        </dict></plist>
        """
        try Data(plist.utf8).write(to: contents.appendingPathComponent("Info.plist"))
        let executable = macos.appendingPathComponent("Scratch")
        try fileManager.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    @discardableResult
    private func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = packageRoot
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
