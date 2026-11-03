import AppKit

/// An sRGB colour written as bytes so the generated icon carries the exact
/// swatch value instead of a colour-managed approximation.
struct WorkspaceSwatch: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

/// The active workspace accent the web UI publishes on
/// `#ciao-app[data-workspace-color]`. The raw values are the exact preset IDs,
/// and `swatch` is the same dark-theme swatch, from the engine's
/// `web/src/lib/workspaceColors.ts`. The client never reads the engine
/// checkout, so this table is its own validated copy: a value that is not one
/// of these IDs is not a colour the Dock may use.
enum WorkspaceColorPreset: String, CaseIterable, Equatable {
    case amber
    case pink
    case cyan
    case emerald
    case violet
    case blue
    case teal
    case lime
    case fuchsia

    var swatch: WorkspaceSwatch {
        switch self {
        case .amber: return WorkspaceSwatch(red: 0xFB, green: 0x92, blue: 0x3C)
        case .pink: return WorkspaceSwatch(red: 0xFF, green: 0x4D, blue: 0x6D)
        case .cyan: return WorkspaceSwatch(red: 0x38, green: 0xBD, blue: 0xF8)
        case .emerald: return WorkspaceSwatch(red: 0x34, green: 0xD3, blue: 0x99)
        case .violet: return WorkspaceSwatch(red: 0xA7, green: 0x8B, blue: 0xFA)
        case .blue: return WorkspaceSwatch(red: 0x60, green: 0xA5, blue: 0xFA)
        case .teal: return WorkspaceSwatch(red: 0x2D, green: 0xD4, blue: 0xBF)
        case .lime: return WorkspaceSwatch(red: 0xA3, green: 0xE6, blue: 0x35)
        case .fuchsia: return WorkspaceSwatch(red: 0xE8, green: 0x79, blue: 0xF9)
        }
    }

    /// The longest preset ID is `fuchsia`; a page message may carry a short
    /// value, never an unbounded string.
    static let maximumMessageLength = 32
}

/// Composes the running app icon: the bundled artwork with only its tile
/// background replaced by the preset colour. The face, the tile alpha and the
/// transparent exterior come from the artwork unchanged.
protocol WorkspaceDockIconRendering: AnyObject {
    func icon(for preset: WorkspaceColorPreset) -> NSImage?
}

final class WorkspaceDockIconRenderer: WorkspaceDockIconRendering {
    private let artwork: NSImage
    private let foreground: NSImage
    private var cache: [WorkspaceColorPreset: NSImage] = [:]

    /// Fails when either required image is missing, so the caller can fall back
    /// to the original icon rather than drawing a colour-only tile.
    init?(artwork: NSImage?, foreground: NSImage?) {
        guard let artwork, let foreground else { return nil }
        self.artwork = artwork
        self.foreground = foreground
    }

    func icon(for preset: WorkspaceColorPreset) -> NSImage? {
        if let cached = cache[preset] { return cached }
        guard let image = Self.compose(artwork: artwork, foreground: foreground, preset: preset) else {
            return nil
        }
        cache[preset] = image
        return image
    }

    /// Pixels are handled in premultiplied 8-bit sRGB RGBA. The foreground
    /// mask's alpha decides what is face (copy the artwork pixel) and what is
    /// tile background (paint the swatch, keeping the tile's original alpha).
    static func compose(artwork: NSImage, foreground: NSImage, preset: WorkspaceColorPreset) -> NSImage? {
        guard let source = pixels(of: artwork),
              let mask = pixels(of: foreground),
              source.width == mask.width,
              source.height == mask.height else { return nil }

        var output = source.data
        let swatch = preset.swatch
        for offset in stride(from: 0, to: output.count, by: 4) where mask.data[offset + 3] == 0 {
            let alpha = Int(source.data[offset + 3])
            output[offset] = UInt8((Int(swatch.red) * alpha + 127) / 255)
            output[offset + 1] = UInt8((Int(swatch.green) * alpha + 127) / 255)
            output[offset + 2] = UInt8((Int(swatch.blue) * alpha + 127) / 255)
            output[offset + 3] = UInt8(alpha)
        }

        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: source.width,
                  height: source.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: source.width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }

        let result = NSImage(size: NSSize(width: source.width, height: source.height))
        result.addRepresentation(NSBitmapImageRep(cgImage: image))
        return result
    }

    private static func pixels(of image: NSImage) -> (data: [UInt8], width: Int, height: Int)? {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return (data, width, height)
    }
}

/// Owns the running app's Dock icon. Production sets `NSApp.applicationIconImage`;
/// tests inject a setter, so no test touches the real Dock. The controller also
/// owns the launch fallback: the bundled icon until a page reports a valid
/// workspace colour, and again after a disconnect or an unknown value.
@MainActor
protocol WorkspaceDockIconControlling: AnyObject {
    /// The colour currently drawn, or nil for the bundled artwork.
    var current: WorkspaceColorPreset? { get }
    func apply(_ preset: WorkspaceColorPreset?)
    /// Show the bundled artwork, including at launch when nothing was applied.
    func reset()
}

@MainActor
final class WorkspaceDockIconController: WorkspaceDockIconControlling {
    typealias Setter = @MainActor (NSImage?) -> Void

    private let artwork: NSImage?
    private let renderer: WorkspaceDockIconRendering?
    private let setter: Setter

    private(set) var current: WorkspaceColorPreset?
    private var hasApplied = false

    init(
        artwork: NSImage? = AppAssets.appIconImage,
        foreground: NSImage? = AppAssets.dockIconForegroundImage,
        renderer: WorkspaceDockIconRendering? = nil,
        setter: Setter? = nil
    ) {
        self.artwork = artwork
        self.renderer = renderer ?? WorkspaceDockIconRenderer(artwork: artwork, foreground: foreground)
        self.setter = setter ?? Self.systemSetter
    }

    /// Production writes the real Dock tile. Tests inject their own setter and
    /// never reach this.
    private static func systemSetter(_ image: NSImage?) {
        NSApp.applicationIconImage = image
    }

    /// Applies the colour once. A repeated value is a no-op, and a failed
    /// render falls back to the bundled icon instead of a colour-only tile.
    func apply(_ preset: WorkspaceColorPreset?) {
        guard !hasApplied || current != preset else { return }
        let image = preset.flatMap { renderer?.icon(for: $0) } ?? artwork
        current = preset
        hasApplied = true
        setter(image)
    }

    func reset() {
        apply(nil)
    }
}
