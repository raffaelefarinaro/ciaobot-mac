import AppKit
import Foundation

/// Locates artwork that ships inside this client, never in the Ciaobot engine
/// checkout. SwiftPM puts processed resources in
/// `CiaobotMac_CiaobotMac.bundle`; `scripts/build-app.sh` copies that bundle and
/// the flat files into the app's `Contents/Resources`. The lookup order below
/// covers both layouts, the bare debug executable, and `swift test`'s
/// resource-bundle environment override.
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

    /// SwiftPM's native build products put resources at the bundle root, while
    /// its Xcode build system and a normal macOS bundle use
    /// `Contents/Resources`. Check both and, when available, let Foundation
    /// resolve the bundle so localized layouts keep working.
    private static func resourceBundleCandidates(at parent: URL, flatName: String, name: String, fileExtension: String) -> [URL] {
        let bundleURL = parent.appendingPathComponent(resourceBundleName)
        var candidates = [
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
        mainResourceURL: URL? = Bundle.main.resourceURL,
        mainBundleURL: URL? = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let flatName = "\(name).\(fileExtension)"
        var candidates: [URL] = []

        // The bundle that contains this code: the app's Contents/Resources in
        // production, or the .xctest bundle's Contents/Resources in tests.
        if let moduleResourceURL {
            candidates.append(moduleResourceURL.appendingPathComponent(flatName))
            candidates.append(contentsOf: resourceBundleCandidates(
                at: moduleResourceURL,
                flatName: flatName,
                name: name,
                fileExtension: fileExtension
            ))
        }

        // Inside a .app, Bundle.main.resourceURL is Contents/Resources. A bare
        // executable reports its own directory instead.
        if let mainResourceURL {
            candidates.append(mainResourceURL.appendingPathComponent(flatName))
            candidates.append(contentsOf: resourceBundleCandidates(
                at: mainResourceURL,
                flatName: flatName,
                name: name,
                fileExtension: fileExtension
            ))
        }

        // Bare executable (swift build / swift run) and SwiftPM's Xcode build
        // products, where the resource bundle sits beside the executable.
        if let mainBundleURL {
            candidates.append(mainBundleURL.appendingPathComponent(flatName))
            candidates.append(contentsOf: resourceBundleCandidates(
                at: mainBundleURL,
                flatName: flatName,
                name: name,
                fileExtension: fileExtension
            ))
        }

        if let executableURL {
            let directory = executableURL.deletingLastPathComponent()
            candidates.append(directory.appendingPathComponent(flatName))
            candidates.append(contentsOf: resourceBundleCandidates(
                at: directory,
                flatName: flatName,
                name: name,
                fileExtension: fileExtension
            ))
            // Defensive fallback for a .app whose resource URL was not useful:
            // Contents/MacOS -> Contents/Resources.
            let resources = directory.deletingLastPathComponent().appendingPathComponent("Resources")
            candidates.append(resources.appendingPathComponent(flatName))
            candidates.append(contentsOf: resourceBundleCandidates(
                at: resources,
                flatName: flatName,
                name: name,
                fileExtension: fileExtension
            ))
        }

        // swift test points PACKAGE_RESOURCE_BUNDLE_PATH at the built resource
        // bundle. PACKAGE_RESOURCE_BUNDLE_URL is the older spelling.
        if let override = environment["PACKAGE_RESOURCE_BUNDLE_PATH"] ?? environment["PACKAGE_RESOURCE_BUNDLE_URL"],
           !override.isEmpty {
            let bundleURL = URL(fileURLWithPath: override)
            candidates.append(bundleURL.appendingPathComponent(flatName))
            candidates.append(contentsOf: resourceBundleCandidates(
                at: bundleURL,
                flatName: flatName,
                name: name,
                fileExtension: fileExtension
            ))
            // Some toolchains report the parent of the bundle rather than the
            // bundle itself.
            candidates.append(contentsOf: resourceBundleCandidates(
                at: bundleURL.deletingLastPathComponent(),
                flatName: flatName,
                name: name,
                fileExtension: fileExtension
            ))
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
