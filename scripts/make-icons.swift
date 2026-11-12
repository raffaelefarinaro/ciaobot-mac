#!/usr/bin/env swift
import AppKit
import CryptoKit
import Foundation

// Builds the client's macOS artwork from the approved Ciaobot brand icon.
//
// Input (checked in, never read from the engine at build time):
//   Sources/CiaobotMac/Artwork/app-icon-source.png
//     a byte-for-byte snapshot of web/public/icons/icon-512.png, rasterised
//     from web/public/brand/ciaobot-icon.svg: the cream tile with the C mark.
//
// Outputs:
//   Sources/CiaobotMac/Resources/app-icon.png
//     The native app icon: the brand tile on Apple's macOS app-icon grid — a
//     1024 canvas with an 824x824 rounded tile at (100,100), 185.4 corner
//     radius, transparent outside. macOS shows a native .icns as-is, so this
//     is what makes Finder and the Dock match an installed PWA's proportions.
//   Sources/CiaobotMac/Resources/dock-icon-ink.png
//     The mark's ink coverage (the C stroke and its two dots) on the same
//     canvas. The running app replaces only the cream field around it with the
//     active workspace accent, keeping the C's own pixels byte-for-byte.
//   Sources/CiaobotMac/Resources/dock-icon-dots.png
//     The two dots alone. On an accent field the running app paints them in the
//     brand cream, so they stay visible on every preset (brand orange vanishes
//     on the amber field).
//   Sources/CiaobotMac/Resources/mark_template.png
//     The C mark alone in black-plus-alpha for the menu-bar item, where macOS
//     applies the light/dark system tint.
//
// The mark's geometry is copied from web/public/brand/ciaobot-mark.svg, the
// same way the web UI's CiaoMark.vue copies it; change them together.
//
// Usage:
//   swift scripts/make-icons.swift [source.png] [app-icon.png] [ink.png] [dots.png] [template.png]
//
// The app and the release build never run this script and never read the
// engine checkout; regenerate only when the brand artwork changes.

let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repositoryRoot = scriptDirectory.deletingLastPathComponent()
let resourcesDirectory = repositoryRoot.appendingPathComponent("Sources/CiaobotMac/Resources")
let defaultSource = repositoryRoot.appendingPathComponent("Sources/CiaobotMac/Artwork/app-icon-source.png")
let arguments = Array(CommandLine.arguments.dropFirst())
let sourceURL = arguments.count > 0 ? URL(fileURLWithPath: arguments[0]) : defaultSource
let appIconURL = arguments.count > 1
    ? URL(fileURLWithPath: arguments[1])
    : resourcesDirectory.appendingPathComponent("app-icon.png")
let inkURL = arguments.count > 2
    ? URL(fileURLWithPath: arguments[2])
    : resourcesDirectory.appendingPathComponent("dock-icon-ink.png")
let dotsURL = arguments.count > 3
    ? URL(fileURLWithPath: arguments[3])
    : resourcesDirectory.appendingPathComponent("dock-icon-dots.png")
let templateURL = arguments.count > 4
    ? URL(fileURLWithPath: arguments[4])
    : resourcesDirectory.appendingPathComponent("mark_template.png")

let canvasSize = 1024
let tileSize: CGFloat = 824
let tileInset = (CGFloat(canvasSize) - tileSize) / 2
let cornerRadius: CGFloat = 185.4
// web/public/brand/ciaobot-icon.svg: the cream tile's viewBox and fill.
let iconViewBox: CGFloat = 1254
let brandTileColor = NSColor(srgbRed: 0xF8 / 255, green: 0xF4 / 255, blue: 0xEF / 255, alpha: 1)
// web/public/brand/ciaobot-mark.svg: the C arc and its two accent dots.
let markViewBox = CGRect(x: 260, y: 250, width: 720, height: 720)
let arcRadius: CGFloat = 295
let arcStroke: CGFloat = 110
let arcStart = CGPoint(x: 718.7, y: 334.7)
let arcEnd = CGPoint(x: 768.5, y: 876.5)
let accentDots: [(centre: CGPoint, radius: CGFloat)] = [
    (CGPoint(x: 870, y: 346), 91),
    (CGPoint(x: 863, y: 800), 56),
]
let templatePixels = 36

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

/// A brand SVG coordinate space placed inside `box` on AppKit's y-up canvas.
struct MarkGeometry {
    /// The viewBox the mark's numbers are written in: the whole icon
    /// (`0 0 1254 1254`) or the mark's own crop.
    let viewBox: CGRect
    /// Where that viewBox lands on the canvas.
    let box: CGRect

    var scale: CGFloat { box.width / viewBox.width }

    func map(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: box.minX + (point.x - viewBox.minX) * scale,
            y: box.maxY - (point.y - viewBox.minY) * scale
        )
    }

    /// The circle the C is drawn on. An SVG arc defines two centres on the
    /// chord's perpendicular; the one left of the opening is the C's.
    var arcCentre: CGPoint {
        let dx = arcEnd.x - arcStart.x
        let dy = arcEnd.y - arcStart.y
        let chord = (dx * dx + dy * dy).squareRoot()
        let offset = (arcRadius * arcRadius - (chord / 2) * (chord / 2)).squareRoot()
        return CGPoint(
            x: (arcStart.x + arcEnd.x) / 2 - dy / chord * offset,
            y: (arcStart.y + arcEnd.y) / 2 + dx / chord * offset
        )
    }

    /// The C's centre line, from one round cap to the other.
    func strokePath() -> CGPath {
        let centre = map(arcCentre)
        let start = map(arcStart)
        let end = map(arcEnd)
        let startAngle = atan2(start.y - centre.y, start.x - centre.x)
        var endAngle = atan2(end.y - centre.y, end.x - centre.x)
        if endAngle < startAngle { endAngle += 2 * .pi }
        let path = CGMutablePath()
        path.addArc(
            center: centre,
            radius: arcRadius * scale,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        return path
    }

    func dotPath() -> CGPath {
        let path = CGMutablePath()
        for dot in accentDots {
            let centre = map(dot.centre)
            let radius = dot.radius * scale
            path.addEllipse(in: CGRect(
                x: centre.x - radius,
                y: centre.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        return path
    }
}

func makeCanvas(pixels: Int) -> (NSBitmapImageRep, NSGraphicsContext) {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fail("Could not allocate a \(pixels)px canvas") }
    bitmap.size = NSSize(width: pixels, height: pixels)
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fail("Could not create a \(pixels)px drawing context")
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.setShouldAntialias(true)
    return (bitmap, context)
}

func writePNG(_ bitmap: NSBitmapImageRep, to url: URL, label: String) -> String {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fail("Could not encode \(label)")
    }
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        fail("Could not write \(url.path): \(error)")
    }
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    print("Wrote \(url.path)")
    print("  \(label) sha256 \(hash)")
    return hash
}

guard let source = NSImage(contentsOf: sourceURL) else {
    fail("Could not read \(sourceURL.path)")
}
guard source.size.width > 0, source.size.height > 0 else {
    fail("The source artwork has no pixels")
}

// --- app-icon.png ---------------------------------------------------------

let (appIconBitmap, appIconContext) = makeCanvas(pixels: canvasSize)
let appIconCG = appIconContext.cgContext
let tileRect = CGRect(x: tileInset, y: tileInset, width: tileSize, height: tileSize)
appIconCG.addPath(CGPath(
    roundedRect: tileRect,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
))
appIconCG.clip()
// The tile is the only opaque region. Everything outside it stays
// transparent, which is what gives Finder and the Dock the rounded shape.
appIconCG.setFillColor(brandTileColor.cgColor)
appIconCG.fill(tileRect)
source.draw(in: tileRect, from: .zero, operation: .sourceOver, fraction: 1.0)
_ = writePNG(appIconBitmap, to: appIconURL, label: "app-icon.png")

// --- dock-icon-ink.png ---------------------------------------------------

let (inkBitmap, inkContext) = makeCanvas(pixels: canvasSize)
let inkCG = inkContext.cgContext
let inkGeometry = MarkGeometry(
    viewBox: CGRect(x: 0, y: 0, width: iconViewBox, height: iconViewBox),
    box: tileRect
)
inkCG.setStrokeColor(NSColor.black.cgColor)
inkCG.setLineWidth(arcStroke * inkGeometry.scale)
inkCG.setLineCap(.round)
inkCG.addPath(inkGeometry.strokePath())
inkCG.strokePath()
inkCG.setFillColor(NSColor.black.cgColor)
inkCG.addPath(inkGeometry.dotPath())
inkCG.fillPath()
_ = writePNG(inkBitmap, to: inkURL, label: "dock-icon-ink.png")

// --- dock-icon-dots.png --------------------------------------------------

let (dotsBitmap, dotsContext) = makeCanvas(pixels: canvasSize)
let dotsCG = dotsContext.cgContext
dotsCG.setFillColor(NSColor.black.cgColor)
dotsCG.addPath(inkGeometry.dotPath())
dotsCG.fillPath()
_ = writePNG(dotsBitmap, to: dotsURL, label: "dock-icon-dots.png")

// --- mark_template.png ---------------------------------------------------

let (templateBitmap, templateContext) = makeCanvas(pixels: templatePixels)
let templateCG = templateContext.cgContext
let templateGeometry = MarkGeometry(
    viewBox: markViewBox,
    box: CGRect(x: 0, y: 0, width: CGFloat(templatePixels), height: CGFloat(templatePixels))
)
templateCG.setStrokeColor(NSColor.black.cgColor)
templateCG.setLineWidth(arcStroke * templateGeometry.scale)
templateCG.setLineCap(.round)
templateCG.addPath(templateGeometry.strokePath())
templateCG.strokePath()
templateCG.setFillColor(NSColor.black.cgColor)
templateCG.addPath(templateGeometry.dotPath())
templateCG.fillPath()
_ = writePNG(templateBitmap, to: templateURL, label: "mark_template.png")

// --- summary -------------------------------------------------------------

let sourceHash = SHA256.hash(data: (try? Data(contentsOf: sourceURL)) ?? Data())
    .map { String(format: "%02x", $0) }.joined()
print("  canvas \(canvasSize)x\(canvasSize), tile \(Int(tileSize))x\(Int(tileSize)) at \(Int(tileInset)), radius \(cornerRadius)")
print("  source sha256 \(sourceHash)")
print("  mark viewBox \(Int(iconViewBox)) shared with web/public/brand; ink = C stroke + \(accentDots.count) dots")
print("  menu-bar template \(templatePixels)x\(templatePixels) black-plus-alpha")
