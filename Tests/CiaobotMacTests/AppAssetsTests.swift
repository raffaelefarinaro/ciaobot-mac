import XCTest
import AppKit
import CryptoKit
@testable import CiaobotMac

final class AppAssetsTests: XCTestCase {
    /// SHA-256 of the original Ciaobot face artwork
    /// (`web/public/face.png` in the engine checkout). Pinning the bytes proves
    /// the client ships that exact image rather than reading it from the
    /// engine at runtime.
    private static let originalFaceSHA256 = "6284686859001c475281799e159435e027fc703e44e47a6a7b98f7d80f4d4a8d"

    /// The PWA artwork (`web/public/icons/icon-512.png`) that the native app
    /// icon is generated from. Pinning the source bytes proves the snapshot
    /// kept in the repository is that artwork, not a later local redraw.
    private static let pwaIconSHA256 = "04277a5fba92b4831de8d4f03ca1c7281398b9a4fb74ed82d3e998f4b4322e1e"

    /// The generated icon follows Apple's macOS app-icon grid: a 1024 canvas
    /// with an 824-point tile at (100,100), so the Dock shows it at the same
    /// scale as an installed PWA instead of as a full-bleed square.
    private static let appIconCanvas = 1024
    private static let appIconTile = 824
    private static let appIconInset = 100

    /// The legacy tray template (`ciao/stock/deploy/face_template.png`) from
    /// the retired engine deployment assets. It is copied byte-for-byte and
    /// loaded as a template image, so the menu bar applies the system tint.
    private static let trayTemplateSHA256 = "765fa6963f2ad7ba680d1c9477fa45311791d8a27902414d3f88831ba246c0a6"

    func testFaceImageIsPackagedAndMatchesOriginalArtwork() throws {
        let url = try XCTUnwrap(
            AppAssets.faceImageURL(),
            "face.png is missing from the built SwiftPM resources"
        )
        XCTAssertEqual(url.lastPathComponent, "face.png")

        let data = try Data(contentsOf: url)
        XCTAssertEqual(try sha256(of: url), Self.originalFaceSHA256)
        XCTAssertEqual(data.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertEqual(image.size.width, 1024)
        XCTAssertEqual(image.size.height, 1024)
        XCTAssertNotNil(AppAssets.faceImage, "The connection screen could not decode the packaged face.")
    }

    /// Runs only after `scripts/build-app.sh`; the default test run has no
    /// release bundle yet and reports an explicit skip rather than a failure.
    func testBuiltReleaseAppBundleContainsResolvableFaceImage() throws {
        let app = packageRoot.appendingPathComponent(".build/Ciaobot.app")
        let contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/CiaobotMac")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Run scripts/build-app.sh first to verify the release .app layout.")
        }

        let resources = contents.appendingPathComponent("Resources")
        let flat = resources.appendingPathComponent("face.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: flat.path),
                      "The release app is missing Contents/Resources/face.png")
        XCTAssertEqual(try sha256(of: flat), Self.originalFaceSHA256)

        let resolved = AppAssets.faceImageURL(
            moduleResourceURL: nil,
            moduleBundleURL: nil,
            mainResourceURL: resources,
            mainBundleURL: app,
            executableURL: executable,
            environment: [:]
        )
        XCTAssertEqual(resolved?.standardizedFileURL, flat.standardizedFileURL)
        XCTAssertNotNil(NSImage(contentsOf: flat))
    }

    func testAppIconSourceIsTheExactPWAArtwork() throws {
        let source = try XCTUnwrap(
            sourceArtworkURL,
            "app-icon-source.png is missing from Sources/CiaobotMac/Artwork"
        )
        XCTAssertEqual(try sha256(of: source), Self.pwaIconSHA256,
                       "The checked-in source must stay byte-for-byte identical to the PWA icon.")
        let image = try XCTUnwrap(NSImage(contentsOf: source))
        XCTAssertEqual(image.size.width, 512)
        XCTAssertEqual(image.size.height, 512)
    }

    /// The app icon must be the PWA face, not a new drawing, and it must have
    /// the transparent rounded corners a native macOS icon needs. The opaque
    /// region is checked at its exact macOS-grid boundary rather than by
    /// eye-balling a screenshot.
    func testAppIconIsRoundedPWAArtworkWithMacOSProportions() throws {
        let url = try XCTUnwrap(
            AppAssets.appIconURL(),
            "app-icon.png is missing from the built SwiftPM resources"
        )
        XCTAssertEqual(url.lastPathComponent, "app-icon.png")

        let data = try Data(contentsOf: url)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertTrue(bitmap.hasAlpha, "A rounded icon needs a transparent outside.")
        XCTAssertEqual(bitmap.pixelsWide, Self.appIconCanvas)
        XCTAssertEqual(bitmap.pixelsHigh, Self.appIconCanvas)
        XCTAssertNotNil(AppAssets.appIconImage, "The app could not decode the packaged icon.")

        let canvas = Self.appIconCanvas
        let inset = Self.appIconInset
        let farEdge = inset + Self.appIconTile
        func alpha(_ x: Int, _ y: Int) -> CGFloat {
            bitmap.colorAt(x: x, y: y)?.alphaComponent ?? -1
        }

        // All four canvas corners and the outside of the tile are transparent.
        for (x, y) in [(0, 0), (canvas - 1, 0), (0, canvas - 1), (canvas - 1, canvas - 1)] {
            XCTAssertEqual(alpha(x, y), 0, "The icon canvas corner at \(x),\(y) is not transparent.")
        }
        XCTAssertEqual(alpha(inset - 1, canvas / 2), 0)
        XCTAssertEqual(alpha(farEdge, canvas / 2), 0)
        XCTAssertEqual(alpha(canvas / 2, inset - 1), 0)
        XCTAssertEqual(alpha(canvas / 2, farEdge), 0)

        // The tile is exactly the macOS 824-of-1024 grid, centred.
        XCTAssertEqual(alpha(inset, canvas / 2), 1)
        XCTAssertEqual(alpha(farEdge - 1, canvas / 2), 1)
        XCTAssertEqual(alpha(canvas / 2, inset), 1)
        XCTAssertEqual(alpha(canvas / 2, farEdge - 1), 1)

        // The corners of the tile are rounded, not square. Radius 185.4 means
        // the straight top edge starts around x = 100 + 185.
        XCTAssertEqual(alpha(inset, inset), 0, "The tile corner is square.")
        XCTAssertEqual(alpha(inset + 100, inset), 0, "The tile corner radius is too small.")
        XCTAssertEqual(alpha(inset + 200, inset), 1, "The tile's top edge is missing.")
        XCTAssertEqual(alpha(canvas - inset - 1, canvas - inset - 1), 0, "The tile corner is square.")

        // The visible fill is the PWA orange; the face is present inside it.
        let orange = try XCTUnwrap(bitmap.colorAt(x: inset + 20, y: canvas / 2)?.usingColorSpace(.sRGB))
        XCTAssertEqual(Double(orange.redComponent), 0xFC / 255, accuracy: 0.01)
        XCTAssertEqual(Double(orange.greenComponent), 0x87 / 255, accuracy: 0.01)
        XCTAssertEqual(Double(orange.blueComponent), 0x19 / 255, accuracy: 0.01)
        let face = try XCTUnwrap(bitmap.colorAt(x: canvas / 2, y: canvas / 2)?.usingColorSpace(.sRGB))
        let difference = abs(face.redComponent - orange.redComponent)
            + abs(face.greenComponent - orange.greenComponent)
            + abs(face.blueComponent - orange.blueComponent)
        XCTAssertGreaterThan(difference, 0.2,
                             "The centre is still blank orange; the PWA face was not drawn.")
    }

    func testMenuBarTemplateIsPackagedAndLoadsAsATintedTemplate() throws {
        let url = try XCTUnwrap(
            AppAssets.menuBarImageURL(),
            "face_template.png is missing from the built SwiftPM resources"
        )
        XCTAssertEqual(url.lastPathComponent, "face_template.png")
        XCTAssertEqual(try sha256(of: url), Self.trayTemplateSHA256)

        let data = try Data(contentsOf: url)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertTrue(bitmap.hasAlpha, "A tray template needs transparency to tint correctly.")

        let image = try XCTUnwrap(AppAssets.menuBarImage)
        XCTAssertTrue(image.isTemplate, "The menu bar must tint the legacy face with the system colour.")
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }

    func testAppIconAndMenuBarTemplateResolveFromAReleaseAppLayout() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Ciaobot.app/Contents")
        let resources = contents.appendingPathComponent("Resources")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let copiedIcon = resources.appendingPathComponent("app-icon.png")
        let copiedTemplate = resources.appendingPathComponent("face_template.png")
        try copyPackaged(AppAssets.appIconURL(), to: copiedIcon)
        try copyPackaged(AppAssets.menuBarImageURL(), to: copiedTemplate)

        let lookup = { (module: URL?, main: URL?, bundle: URL?, executable: URL?) in
            AppAssets.imageURL(
                named: "app-icon",
                fileExtension: "png",
                moduleResourceURL: module,
                moduleBundleURL: nil,
                mainResourceURL: main,
                mainBundleURL: bundle,
                executableURL: executable,
                environment: [:]
            )
        }
        let app = root.appendingPathComponent("Ciaobot.app")
        XCTAssertEqual(
            lookup(nil, resources, app, macOS.appendingPathComponent("CiaobotMac"))?.standardizedFileURL,
            copiedIcon.standardizedFileURL
        )
        XCTAssertEqual(
            AppAssets.menuBarImageURL(
                moduleResourceURL: nil,
                moduleBundleURL: nil,
                mainResourceURL: resources,
                mainBundleURL: app,
                executableURL: macOS.appendingPathComponent("CiaobotMac"),
                environment: [:]
            )?.standardizedFileURL,
            copiedTemplate.standardizedFileURL
        )
    }

    /// Runs only after `scripts/build-app.sh`; the default test run has no
    /// release bundle yet and reports an explicit skip rather than a failure.
    func testBuiltReleaseAppBundleContainsTheNativeIconAndMenuBarTemplate() throws {
        let app = packageRoot.appendingPathComponent(".build/Ciaobot.app")
        let contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/CiaobotMac")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Run scripts/build-app.sh first to verify the release .app layout.")
        }

        let resources = contents.appendingPathComponent("Resources")
        let icon = resources.appendingPathComponent("AppIcon.icns")
        XCTAssertTrue(FileManager.default.fileExists(atPath: icon.path),
                      "The release app is missing Contents/Resources/AppIcon.icns")
        let iconData = try Data(contentsOf: icon)
        XCTAssertEqual(iconData.prefix(4), Data("icns".utf8))
        let iconImage = try XCTUnwrap(NSImage(contentsOf: icon), "iconutil did not produce a loadable .icns")
        let representations = iconImage.representations.compactMap { $0 as? NSBitmapImageRep }
        XCTAssertFalse(representations.isEmpty, "The .icns has no bitmap representation to inspect.")
        for representation in representations {
            let width = representation.pixelsWide
            let height = representation.pixelsHigh
            guard width > 0, height > 0 else { continue }
            XCTAssertEqual(representation.colorAt(x: 0, y: 0)?.alphaComponent, 0,
                           "The \(width)x\(height) .icns representation has an opaque corner.")
            XCTAssertEqual(representation.colorAt(x: width - 1, y: height - 1)?.alphaComponent, 0,
                           "The \(width)x\(height) .icns representation has an opaque corner.")
        }

        // The flat PNG copied beside the .icns is the same rounded master, so
        // a future edit cannot leave the two icons out of sync.
        let flatIcon = try XCTUnwrap(
            NSBitmapImageRep(data: try Data(contentsOf: resources.appendingPathComponent("app-icon.png")))
        )
        XCTAssertEqual(flatIcon.pixelsWide, Self.appIconCanvas)
        XCTAssertTrue(flatIcon.hasAlpha)
        XCTAssertEqual(flatIcon.colorAt(x: 0, y: 0)?.alphaComponent, 0)
        XCTAssertEqual(try sha256(of: resources.appendingPathComponent("face_template.png")),
                       Self.trayTemplateSHA256)

        let plistData = try Data(contentsOf: contents.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon",
                       "Info.plist must point the Dock and Finder at the packaged icon.")
    }

    func testFaceImageResolvesFromReleaseAppBundle() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Ciaobot.app/Contents")
        let resources = contents.appendingPathComponent("Resources")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let flat = resources.appendingPathComponent("face.png")
        try copyPackagedFace(to: flat)

        let resolved = AppAssets.faceImageURL(
            moduleResourceURL: nil,
            moduleBundleURL: nil,
            mainResourceURL: resources,
            mainBundleURL: root.appendingPathComponent("Ciaobot.app"),
            executableURL: macOS.appendingPathComponent("CiaobotMac"),
            environment: [:]
        )
        XCTAssertEqual(resolved?.standardizedFileURL, flat.standardizedFileURL)

        // A bundle-only Contents/Resources layout must resolve too.
        try FileManager.default.removeItem(at: flat)
        let bundleRoot = resources.appendingPathComponent(AppAssets.resourceBundleName)
        let bundled = bundleRoot.appendingPathComponent("face.png")
        try copyPackagedFace(to: bundled)
        let resolvedBundle = AppAssets.faceImageURL(
            moduleResourceURL: nil,
            moduleBundleURL: nil,
            mainResourceURL: resources,
            mainBundleURL: root.appendingPathComponent("Ciaobot.app"),
            executableURL: macOS.appendingPathComponent("CiaobotMac"),
            environment: [:]
        )
        XCTAssertEqual(resolvedBundle?.standardizedFileURL, bundled.standardizedFileURL)

        // SwiftPM's Xcode build system uses a real macOS bundle layout.
        try FileManager.default.removeItem(at: bundled)
        let xcodeBundled = bundleRoot.appendingPathComponent("Contents/Resources/face.png")
        try copyPackagedFace(to: xcodeBundled)
        let resolvedXcodeBundle = AppAssets.faceImageURL(
            moduleResourceURL: nil,
            moduleBundleURL: nil,
            mainResourceURL: resources,
            mainBundleURL: root.appendingPathComponent("Ciaobot.app"),
            executableURL: macOS.appendingPathComponent("CiaobotMac"),
            environment: [:]
        )
        XCTAssertEqual(resolvedXcodeBundle?.standardizedFileURL, xcodeBundled.standardizedFileURL)
    }

    func testFaceImageResolvesFromSwiftPMDebugLayout() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root
            .appendingPathComponent(AppAssets.resourceBundleName)
            .appendingPathComponent("face.png")
        try copyPackagedFace(to: bundled)

        // A bare executable has no Contents/Resources; its Bundle.main
        // resource and bundle URLs point at the build products directory.
        let resolved = AppAssets.faceImageURL(
            moduleResourceURL: nil,
            moduleBundleURL: nil,
            mainResourceURL: root,
            mainBundleURL: root,
            executableURL: root.appendingPathComponent("CiaobotMac"),
            environment: [:]
        )
        XCTAssertEqual(resolved?.standardizedFileURL, bundled.standardizedFileURL)
    }

    /// `swift test` under SwiftPM's native build system — the default with
    /// Xcode, and what the CI runner uses — puts the resource bundle beside
    /// `CiaobotMacPackageTests.xctest` in the build products directory, and
    /// leaves the .xctest bundle's own Contents/Resources empty. The lookup
    /// must therefore look next to the bundle that contains this code.
    func testFaceImageResolvesFromTheNativeBuildProductsDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let products = root.appendingPathComponent("arm64-apple-macosx/debug")
        let testBundle = products.appendingPathComponent("CiaobotMacPackageTests.xctest")
        let testResources = testBundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: testResources, withIntermediateDirectories: true)

        // Copied from the checked-in artwork so this test only exercises the
        // lookup order, not whatever the current build happens to ship.
        let bundled = products
            .appendingPathComponent(AppAssets.resourceBundleName)
            .appendingPathComponent("face.png")
        try FileManager.default.createDirectory(
            at: bundled.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: packageRoot.appendingPathComponent("Sources/CiaobotMac/Resources/face.png"),
            to: bundled
        )

        // The rest of the runtime matches CI: Bundle.main is the `xctest` tool
        // in the Xcode toolchain, not the package's build directory.
        let toolDirectory = root.appendingPathComponent("Xcode.app/Contents/Developer/usr/bin")
        let resolved = AppAssets.faceImageURL(
            moduleResourceURL: testResources,
            moduleBundleURL: testBundle,
            mainResourceURL: toolDirectory,
            mainBundleURL: toolDirectory,
            executableURL: toolDirectory.appendingPathComponent("xctest"),
            environment: [:]
        )
        XCTAssertEqual(resolved?.standardizedFileURL, bundled.standardizedFileURL)
    }

    func testFaceImageResolvesFromXCTestResourceBundleOverride() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resourceBundle = root.appendingPathComponent(AppAssets.resourceBundleName)
        let bundled = resourceBundle.appendingPathComponent("face.png")
        try copyPackagedFace(to: bundled)

        let resolved = AppAssets.faceImageURL(
            moduleResourceURL: nil,
            moduleBundleURL: nil,
            mainResourceURL: nil,
            mainBundleURL: nil,
            executableURL: nil,
            environment: ["PACKAGE_RESOURCE_BUNDLE_PATH": resourceBundle.path]
        )
        XCTAssertEqual(resolved?.standardizedFileURL, bundled.standardizedFileURL)
    }

    func testFaceImageLookupFailsWhenAssetIsMissingOrADirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(AppAssets.faceImageURL(
            moduleResourceURL: nil,
            moduleBundleURL: nil,
            mainResourceURL: root,
            mainBundleURL: root,
            executableURL: root.appendingPathComponent("CiaobotMac"),
            environment: [:]
        ))

        // A directory with the expected name must not be treated as artwork.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("face.png"),
            withIntermediateDirectories: true
        )
        XCTAssertNil(AppAssets.faceImageURL(
            moduleResourceURL: nil,
            moduleBundleURL: nil,
            mainResourceURL: root,
            mainBundleURL: root,
            executableURL: root.appendingPathComponent("CiaobotMac"),
            environment: [:]
        ))
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Kept outside the target's Resources directory: it is the reference
    /// artwork for regeneration and tests, not a file the running app loads.
    private var sourceArtworkURL: URL? {
        let url = packageRoot
            .appendingPathComponent("Sources/CiaobotMac/Artwork/app-icon-source.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CiaobotMacTests-AppAssets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes the packaged artwork where a given layout expects it.
    private func copyPackagedFace(to destination: URL) throws {
        try copyPackaged(AppAssets.faceImageURL(), to: destination)
    }

    private func copyPackaged(_ source: URL?, to destination: URL) throws {
        let source = try XCTUnwrap(source)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
