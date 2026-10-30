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
        let frameworks = scratch.appendingPathComponent("Frameworks", isDirectory: true)

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
        let frameworks = scratch.appendingPathComponent("Frameworks", isDirectory: true)

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
        let frameworks = scratch.appendingPathComponent("Frameworks", isDirectory: true)

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
        let frameworks = scratch.appendingPathComponent("Frameworks", isDirectory: true)

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
        let frameworks = scratch.appendingPathComponent("Frameworks", isDirectory: true)
        let installed = try run(
            "/bin/sh",
            [installScript.path, xcframework.path, try hostArchitecture(), frameworks.path]
        )
        XCTAssertEqual(installed.status, 0, installed.output)

        let source = scratch.appendingPathComponent("Probe.swift")
        try Data("import Sparkle\nprint(SPUUpdater.self)\n".utf8).write(to: source)
        let binary = scratch.appendingPathComponent("bin/Probe")
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
        for name in ["install-sparkle-framework.sh", "sign-sparkle.sh"] {
            let url = scriptsDirectory.appendingPathComponent(name)
            XCTAssertTrue(
                fileManager.isExecutableFile(atPath: url.path),
                "scripts/\(name) is invoked directly and must keep its executable bit"
            )
        }
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

    /// Framework fixture used by both selection and signing tests.
    private func makeFrameworkFixture() throws -> URL {
        let framework = scratch.appendingPathComponent("Signing/Sparkle.framework", isDirectory: true)
        try makeFrameworkLayout(at: framework)
        return framework
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
