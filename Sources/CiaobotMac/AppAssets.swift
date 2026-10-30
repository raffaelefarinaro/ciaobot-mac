import AppKit
import Foundation

/// Locates artwork that ships inside this client, never in the Ciaobot engine
/// checkout. SwiftPM puts processed resources in
/// `CiaobotMac_CiaobotMac.bundle`; `scripts/build-app.sh` copies that bundle and
/// the flat files into the app's `Contents/Resources`. The lookup order below
/// covers both layouts, the bare debug executable, the build products
/// directory `swift test` runs from, and `swift test`'s resource-bundle
/// environment override.
enum AppAssets {
    static let faceImageName = "face"
    static let faceImageExtension = "png"
    static let appIconName = "app-icon"
    static let appIconExtension = "png"
    static let menuBarImageName = "face_template"
    static let menuBarImageExtension = "png"
    static let resourceBundleName = "CiaobotMac_CiaobotMac.bundle"

    /// The menu bar asks for a small template image; the 40-point legacy face
    /// is scaled down to this point size so it matches neighbouring items.
    static let menuBarImagePointSize = NSSize(width: 18, height: 18)

    /// Anchor for `Bundle(for:)`, which resolves the bundle that contains this
    /// code: the app bundle in production and the .xctest bundle under
    /// `swift test`.
    private final class AssetBundleToken {}

    /// Every directory that can hold the artwork is checked both for the flat
    /// file and for `CiaobotMac_CiaobotMac.bundle`, at the bundle root and in
    /// `Contents/Resources`: SwiftPM's native build system writes the flat
    /// files at the bundle root, while its Xcode build system and a normal
    /// macOS bundle use `Contents/Resources`. Foundation is also asked, so
    /// localized layouts keep working.
    private static func assetCandidates(
        in directory: URL,
        flatName: String,
        name: String,
        fileExtension: String
    ) -> [URL] {
        let bundleURL = directory.appendingPathComponent(resourceBundleName)
        var candidates = [
            directory.appendingPathComponent(flatName),
            bundleURL.appendingPathComponent(flatName),
            bundleURL.appendingPathComponent("Contents/Resources/\(flatName)"),
        ]
        if let bundle = Bundle(url: bundleURL),
           let resolved = bundle.url(forResource: name, withExtension: fileExtension) {
            candidates.append(resolved)
        }
        return candidates
    }

    /// Returns the first readable, regular file that matches the packaged
    /// artwork. A directory with the expected name must not count.
    static func imageURL(
        named name: String,
        fileExtension: String,
        fileManager: FileManager = .default,
        moduleResourceURL: URL? = Bundle(for: AssetBundleToken.self).resourceURL,
        moduleBundleURL: URL? = Bundle(for: AssetBundleToken.self).bundleURL,
        mainResourceURL: URL? = Bundle.main.resourceURL,
        mainBundleURL: URL? = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let flatName = "\(name).\(fileExtension)"
        var candidates: [URL] = []

        func append(_ directory: URL) {
            candidates.append(contentsOf: assetCandidates(
                in: directory,
                flatName: flatName,
                name: name,
                fileExtension: fileExtension
            ))
        }

        // The bundle that contains this code: the app's Contents/Resources in
        // production, or the .xctest bundle's Contents/Resources in tests.
        if let moduleResourceURL {
            append(moduleResourceURL)
        }

        // The bundle root itself: `scripts/build-app.sh` keeps the resource
        // bundle in the app's Contents/Resources (covered above), and a debug
        // build products directory keeps it beside the executable.
        if let moduleBundleURL {
            append(moduleBundleURL)
        }

        // Inside a .app, Bundle.main.resourceURL is Contents/Resources. A bare
        // executable reports its own directory instead.
        if let mainResourceURL {
            append(mainResourceURL)
        }

        // Bare executable (swift build / swift run) and SwiftPM's Xcode build
        // products, where the resource bundle sits beside the executable.
        if let mainBundleURL {
            append(mainBundleURL)
        }

        if let executableURL {
            let directory = executableURL.deletingLastPathComponent()
            append(directory)
            // Defensive fallback for a .app whose resource URL was not useful:
            // Contents/MacOS -> Contents/Resources.
            append(directory.deletingLastPathComponent().appendingPathComponent("Resources"))
        }

        // swift test points PACKAGE_RESOURCE_BUNDLE_PATH at the built resource
        // bundle. PACKAGE_RESOURCE_BUNDLE_URL is the older spelling.
        if let override = environment["PACKAGE_RESOURCE_BUNDLE_PATH"] ?? environment["PACKAGE_RESOURCE_BUNDLE_URL"],
           !override.isEmpty {
            let bundleURL = URL(fileURLWithPath: override)
            append(bundleURL)
            // Some toolchains report the parent of the bundle rather than the
            // bundle itself.
            append(bundleURL.deletingLastPathComponent())
        }

        // Last resort: SwiftPM's native build system — the default under Xcode
        // and what the CI runner uses — writes `CiaobotMac_CiaobotMac.bundle`
        // beside `CiaobotMacPackageTests.xctest` in the build products
        // directory instead of inside the test bundle, so `swift test` also
        // checks the directory that contains the bundle holding this code.
        if let moduleBundleURL {
            append(moduleBundleURL.deletingLastPathComponent())
        }

        return candidates.first { candidate in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
                return false
            }
            return !isDirectory.boolValue && fileManager.isReadableFile(atPath: candidate.path)
        }
    }

    static func faceImageURL(
        fileManager: FileManager = .default,
        moduleResourceURL: URL? = Bundle(for: AssetBundleToken.self).resourceURL,
        moduleBundleURL: URL? = Bundle(for: AssetBundleToken.self).bundleURL,
        mainResourceURL: URL? = Bundle.main.resourceURL,
        mainBundleURL: URL? = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        imageURL(
            named: faceImageName,
            fileExtension: faceImageExtension,
            fileManager: fileManager,
            moduleResourceURL: moduleResourceURL,
            moduleBundleURL: moduleBundleURL,
            mainResourceURL: mainResourceURL,
            mainBundleURL: mainBundleURL,
            executableURL: executableURL,
            environment: environment
        )
    }

    /// The rounded macOS app icon generated from the PWA artwork. It is used
    /// by the debug executable's Dock icon and is copied beside the packaged
    /// `.app`'s `AppIcon.icns`, which `CFBundleIconFile` names. Regenerate it
    /// with `scripts/make-app-icon.swift`; the original square PWA snapshot is
    /// kept in `Sources/CiaobotMac/Artwork` for provenance and tests.
    static func appIconURL(
        fileManager: FileManager = .default,
        moduleResourceURL: URL? = Bundle(for: AssetBundleToken.self).resourceURL,
        moduleBundleURL: URL? = Bundle(for: AssetBundleToken.self).bundleURL,
        mainResourceURL: URL? = Bundle.main.resourceURL,
        mainBundleURL: URL? = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        imageURL(
            named: appIconName,
            fileExtension: appIconExtension,
            fileManager: fileManager,
            moduleResourceURL: moduleResourceURL,
            moduleBundleURL: moduleBundleURL,
            mainResourceURL: mainResourceURL,
            mainBundleURL: mainBundleURL,
            executableURL: executableURL,
            environment: environment
        )
    }

    /// The legacy Ciaobot face template used by the menu-bar item.
    static func menuBarImageURL(
        fileManager: FileManager = .default,
        moduleResourceURL: URL? = Bundle(for: AssetBundleToken.self).resourceURL,
        moduleBundleURL: URL? = Bundle(for: AssetBundleToken.self).bundleURL,
        mainResourceURL: URL? = Bundle.main.resourceURL,
        mainBundleURL: URL? = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        imageURL(
            named: menuBarImageName,
            fileExtension: menuBarImageExtension,
            fileManager: fileManager,
            moduleResourceURL: moduleResourceURL,
            moduleBundleURL: moduleBundleURL,
            mainResourceURL: mainResourceURL,
            mainBundleURL: mainBundleURL,
            executableURL: executableURL,
            environment: environment
        )
    }

    /// Loaded once; the connection screen can re-render without touching disk.
    /// A missing asset only omits the image, leaving the title and layout
    /// unchanged rather than failing the screen.
    static let faceImage: NSImage? = faceImageURL().flatMap { NSImage(contentsOf: $0) }

    /// Used for the debug executable, which has no `CFBundleIconFile`. The
    /// packaged `.app` uses the `.icns` produced by `scripts/build-app.sh`.
    static let appIconImage: NSImage? = appIconURL().flatMap { NSImage(contentsOf: $0) }

    /// A template image (black pixels plus alpha) so macOS applies the menu-bar
    /// tint, including in dark mode and while the menu is open.
    static let menuBarImage: NSImage? = menuBarImageURL().flatMap { url -> NSImage? in
        guard let image = NSImage(contentsOf: url)?.copy() as? NSImage else { return nil }
        image.isTemplate = true
        image.size = menuBarImagePointSize
        return image
    }
}
