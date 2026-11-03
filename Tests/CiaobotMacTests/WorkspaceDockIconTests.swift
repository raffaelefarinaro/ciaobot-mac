import XCTest
import AppKit
@testable import CiaobotMac

/// Colour-field Dock icon tests. They read the packaged artwork and the
/// generated foreground mask, and inject every icon setter, so no test writes
/// `NSApp.applicationIconImage` or touches the real Dock.
@MainActor
final class WorkspaceDockIconTests: XCTestCase {
    private static let canvas = 1024
    private static let tileInset = 100
    private static let tileSize = 824

    /// The engine's `WORKSPACE_COLOR_PRESETS` swatches. Pinned here so a drift
    /// in the client table fails locally; `testPresetsMatchTheEngineCheckout`
    /// additionally reads the engine file when this checkout has one.
    private struct ExpectedSwatch: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    private struct Pixel: Equatable {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int
    }

    private static let expectedSwatches: [WorkspaceColorPreset: ExpectedSwatch] = [
        .amber: ExpectedSwatch(red: 0xFB, green: 0x92, blue: 0x3C),
        .pink: ExpectedSwatch(red: 0xFF, green: 0x4D, blue: 0x6D),
        .cyan: ExpectedSwatch(red: 0x38, green: 0xBD, blue: 0xF8),
        .emerald: ExpectedSwatch(red: 0x34, green: 0xD3, blue: 0x99),
        .violet: ExpectedSwatch(red: 0xA7, green: 0x8B, blue: 0xFA),
        .blue: ExpectedSwatch(red: 0x60, green: 0xA5, blue: 0xFA),
        .teal: ExpectedSwatch(red: 0x2D, green: 0xD4, blue: 0xBF),
        .lime: ExpectedSwatch(red: 0xA3, green: 0xE6, blue: 0x35),
        .fuchsia: ExpectedSwatch(red: 0xE8, green: 0x79, blue: 0xF9),
    ]

    func testPresetsMatchTheEngineSwatches() {
        for preset in WorkspaceColorPreset.allCases {
            let expected = Self.expectedSwatches[preset]
            XCTAssertNotNil(expected, "Missing pinned swatch for \(preset.rawValue)")
            XCTAssertEqual(
                preset.swatch,
                WorkspaceSwatch(red: expected!.red, green: expected!.green, blue: expected!.blue)
            )
        }
        XCTAssertEqual(WorkspaceColorPreset.allCases.count, 9)
    }

    /// When the sibling engine checkout is present, prove the client table is
    /// the engine's table rather than a local guess. CI checks this repository
    /// alone, so a missing engine file is an explicit skip, not a failure.
    func testPresetsMatchTheEngineCheckout() throws {
        let engine = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ciaobot/web/src/lib/workspaceColors.ts")
        guard FileManager.default.fileExists(atPath: engine.path) else {
            throw XCTSkip("The Ciaobot engine checkout is not beside this repository.")
        }
        let source = try String(contentsOf: engine, encoding: .utf8)
        for preset in WorkspaceColorPreset.allCases {
            let expected = Self.expectedSwatches[preset]!
            let line = "{ id: '\(preset.rawValue)', label: "
            let match = try XCTUnwrap(
                source.split(separator: "\n").first { $0.contains(line) },
                "workspaceColors.ts no longer has the \(preset.rawValue) preset"
            )
            // `{ id: 'amber', label: 'Ciao Orange', swatch: '#fb923c' },`
            let quoted = match.split(separator: "'").map(String.init)
            guard let swatchIndex = quoted.firstIndex(where: { $0.contains("swatch:") }),
                  quoted.indices.contains(swatchIndex + 1) else {
                return XCTFail("The \(preset.rawValue) preset has no swatch")
            }
            let raw = quoted[swatchIndex + 1]
            let value = (raw.hasPrefix("#") ? String(raw.dropFirst()) : raw).uppercased()
            guard value.count == 6,
                  let red = UInt8(value.prefix(2), radix: 16),
                  let green = UInt8(value.dropFirst(2).prefix(2), radix: 16),
                  let blue = UInt8(value.suffix(2), radix: 16) else {
                return XCTFail("The \(preset.rawValue) swatch is not a six-digit hex colour: \(raw)")
            }
            XCTAssertEqual(
                ExpectedSwatch(red: red, green: green, blue: blue), expected,
                "The client's \(preset.rawValue) swatch drifted from workspaceColors.ts"
            )
        }
    }

    func testForegroundMaskKeepsTheFaceAndDropsTheTileBackground() throws {
        let url = try XCTUnwrap(AppAssets.dockIconForegroundURL(),
                                "dock-icon-foreground.png is missing from the resources")
        XCTAssertEqual(url.lastPathComponent, "dock-icon-foreground.png")
        let foreground = try bitmap(at: url)
        let artwork = try bitmap(at: try XCTUnwrap(AppAssets.appIconURL()))

        XCTAssertEqual(foreground.pixelsWide, Self.canvas)
        XCTAssertEqual(foreground.pixelsHigh, Self.canvas)
        XCTAssertTrue(foreground.hasAlpha)

        // The transparent exterior stays transparent.
        for (x, y) in [(0, 0), (Self.canvas - 1, 0), (Self.canvas / 2, 50),
                       (Self.canvas - 1, Self.canvas - 1)] {
            XCTAssertEqual(alpha(foreground, x, y), 0,
                           "The foreground invented opacity at \(x),\(y)")
            XCTAssertEqual(alpha(artwork, x, y), 0)
        }
        // The tile background is transparent, and a rounded tile corner is too.
        for (x, y) in [(200, Self.canvas / 2), (Self.canvas / 2, 150),
                       (Self.tileInset, Self.tileInset)] {
            XCTAssertEqual(alpha(foreground, x, y), 0,
                           "The foreground keeps the tile background at \(x),\(y)")
        }
        XCTAssertEqual(alpha(artwork, 200, Self.canvas / 2), 1, "The artwork background must stay opaque")
        // The face is opaque and carries the artwork's pixels.
        for (x, y) in [(Self.canvas / 2, Self.canvas / 2), (511, 200), (700, 700)] {
            XCTAssertEqual(alpha(foreground, x, y), 1, "The foreground lost the face at \(x),\(y)")
            XCTAssertEqual(color(foreground, x, y), color(artwork, x, y),
                           "The foreground redrew the face at \(x),\(y)")
        }
    }

    func testEveryPresetRecoloursOnlyTheTileBackground() throws {
        let artwork = try bitmap(at: try XCTUnwrap(AppAssets.appIconURL()))
        let foreground = try bitmap(at: try XCTUnwrap(AppAssets.dockIconForegroundURL()))
        let renderer = try XCTUnwrap(WorkspaceDockIconRenderer(
            artwork: AppAssets.appIconImage,
            foreground: AppAssets.dockIconForegroundImage
        ))

        for preset in WorkspaceColorPreset.allCases {
            let image = try XCTUnwrap(renderer.icon(for: preset), "\(preset.rawValue) did not render")
            let rendered = try bitmap(image)
            XCTAssertEqual(rendered.pixelsWide, Self.canvas)
            XCTAssertEqual(rendered.pixelsHigh, Self.canvas)

            // The background is exactly the preset's swatch.
            let expected = preset.swatch
            for (x, y) in [(200, Self.canvas / 2), (Self.canvas / 2, 150), (750, 750)] {
                if alpha(foreground, x, y) == 0 {
                    let drawn = pixel(rendered, x, y)
                    XCTAssertEqual(drawn.red, Int(expected.red), "\(preset.rawValue) background red at \(x),\(y)")
                    XCTAssertEqual(drawn.green, Int(expected.green), "\(preset.rawValue) background green at \(x),\(y)")
                    XCTAssertEqual(drawn.blue, Int(expected.blue), "\(preset.rawValue) background blue at \(x),\(y)")
                    XCTAssertEqual(drawn.alpha, 255, "\(preset.rawValue) background alpha at \(x),\(y)")
                }
            }

            // Every sampled face pixel is byte-for-byte the bundled artwork.
            var compared = 0
            for y in stride(from: 0, to: Self.canvas, by: 17) {
                for x in stride(from: 0, to: Self.canvas, by: 17) where alpha(foreground, x, y) > 0 {
                    XCTAssertEqual(color(rendered, x, y), color(artwork, x, y),
                                   "\(preset.rawValue) changed the face at \(x),\(y)")
                    compared += 1
                }
            }
            XCTAssertGreaterThan(compared, 500, "Too few face pixels were sampled")

            // The macOS shape and the transparent exterior are unchanged.
            let originalAlphas = [
                (0, 0), (Self.canvas - 1, Self.canvas - 1),
                (Self.tileInset, Self.canvas / 2), (Self.tileInset + Self.tileSize, Self.canvas / 2),
                (Self.canvas / 2, Self.tileInset - 1), (Self.canvas / 2, Self.tileInset + Self.tileSize),
                (Self.tileInset, Self.tileInset),
            ]
            for (x, y) in originalAlphas {
                XCTAssertEqual(alpha(rendered, x, y), alpha(artwork, x, y),
                               "\(preset.rawValue) changed the tile alpha at \(x),\(y)")
            }
        }
    }

    func testRendererCachesEachPreset() throws {
        let renderer = try XCTUnwrap(WorkspaceDockIconRenderer(
            artwork: AppAssets.appIconImage,
            foreground: AppAssets.dockIconForegroundImage
        ))
        let first = try XCTUnwrap(renderer.icon(for: .teal))
        let second = try XCTUnwrap(renderer.icon(for: .teal))
        XCTAssertTrue(first === second, "The renderer must cache a preset instead of redrawing it")
        let other = try XCTUnwrap(renderer.icon(for: .lime))
        XCTAssertFalse(first === other)
    }

    func testRendererRefusesMissingArtworkOrForeground() {
        XCTAssertNil(WorkspaceDockIconRenderer(artwork: nil, foreground: AppAssets.dockIconForegroundImage))
        XCTAssertNil(WorkspaceDockIconRenderer(artwork: AppAssets.appIconImage, foreground: nil))
        XCTAssertNil(WorkspaceDockIconRenderer(artwork: nil, foreground: nil))
    }

    // MARK: - Controller

    func testControllerOwnsTheLaunchFallbackAndDeduplicates() throws {
        let artwork = try XCTUnwrap(AppAssets.appIconImage)
        let renderer = CountingRenderer(image: artwork)
        var applied: [NSImage?] = []
        let controller = WorkspaceDockIconController(
            artwork: artwork,
            renderer: renderer,
            setter: { applied.append($0) }
        )

        controller.reset()
        XCTAssertEqual(applied.count, 1, "The launch fallback must be applied once")
        XCTAssertTrue(applied[0] === artwork)
        XCTAssertNil(controller.current)
        controller.reset()
        XCTAssertEqual(applied.count, 1, "Repeating the fallback must be a no-op")

        controller.apply(.amber)
        XCTAssertEqual(renderer.requests, [.amber])
        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(controller.current, .amber)
        controller.apply(.amber)
        XCTAssertEqual(renderer.requests, [.amber], "A repeated accent must not re-render")
        XCTAssertEqual(applied.count, 2, "A repeated accent must not repaint the Dock")

        controller.apply(.cyan)
        controller.apply(nil)
        XCTAssertEqual(renderer.requests, [.amber, .cyan])
        XCTAssertEqual(applied.count, 4)
        XCTAssertNil(controller.current)
        XCTAssertTrue(applied.last! === artwork)
    }

    func testControllerFallsBackToTheBundledIconWhenARenderFails() throws {
        let artwork = try XCTUnwrap(AppAssets.appIconImage)
        let renderer = CountingRenderer(image: nil)
        var applied: [NSImage?] = []
        let controller = WorkspaceDockIconController(
            artwork: artwork,
            renderer: renderer,
            setter: { applied.append($0) }
        )
        controller.apply(.violet)
        XCTAssertEqual(applied.count, 1)
        XCTAssertTrue(applied[0] === artwork, "A failed render must not leave a colour-only tile")
    }

    // MARK: - Helpers

    private final class CountingRenderer: WorkspaceDockIconRendering {
        let image: NSImage?
        private(set) var requests: [WorkspaceColorPreset] = []

        init(image: NSImage?) { self.image = image }

        func icon(for preset: WorkspaceColorPreset) -> NSImage? {
            requests.append(preset)
            return image
        }
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func bitmap(at url: URL) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        return NSBitmapImageRep(cgImage: cgImage)
    }

    /// Reads the stored RGBA bytes. `colorAt`/`usingColorSpace(.sRGB)` on this
    /// SDK applies an HDR colour conversion that changes the numbers, so the
    /// exact byte comparison uses the bitmap's own samples.
    private func pixel(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> Pixel {
        guard bitmap.samplesPerPixel == 4,
              bitmap.bitsPerSample == 8,
              let data = bitmap.bitmapData else {
            return Pixel(red: -1, green: -1, blue: -1, alpha: -1)
        }
        let offset = y * bitmap.bytesPerRow + x * 4
        return Pixel(
            red: Int(data[offset]),
            green: Int(data[offset + 1]),
            blue: Int(data[offset + 2]),
            alpha: Int(data[offset + 3])
        )
    }

    private func alpha(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        CGFloat(pixel(bitmap, x, y).alpha) / 255
    }

    private func color(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> Pixel {
        pixel(bitmap, x, y)
    }
}
