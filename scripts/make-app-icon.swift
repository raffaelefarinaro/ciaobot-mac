#!/usr/bin/env swift
import AppKit
import CryptoKit
import Foundation

// Builds the client's macOS app icon from the existing PWA artwork.
//
// The PWA icon is a square, fully opaque orange tile. macOS masks an "Add to
// Dock" web app with the system squircle, but a native app's .icns is shown
// as-is, so shipping the square bytes makes the Dock tile look square next to
// the PWA. This tool applies the standard macOS app-icon geometry (a 1024
// canvas with an 824x824 rounded tile centred at 100,100 and a 185.4 corner
// radius) to the exact PWA pixels. It does not redraw the face.
//
// It also writes the runtime foreground mask the running app composes with a
// workspace colour. The mask is the same artwork with the border-connected
// orange tile background made transparent and every face pixel kept: recolour
// the tile, keep the face.
//
// Usage:
//   swift scripts/make-app-icon.swift [source.png] [output.png] [foreground.png]
//
// Defaults read Sources/CiaobotMac/Artwork/app-icon-source.png (a byte-for-byte
// snapshot of web/public/icons/icon-512.png) and write
// Sources/CiaobotMac/Resources/app-icon.png plus
// Sources/CiaobotMac/Resources/dock-icon-foreground.png. The app and the
// release build never run this script and never read the engine checkout;
// regenerate only when the PWA artwork changes.

let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repositoryRoot = scriptDirectory.deletingLastPathComponent()
let defaultSource = repositoryRoot.appendingPathComponent("Sources/CiaobotMac/Artwork/app-icon-source.png")
let defaultOutput = repositoryRoot.appendingPathComponent("Sources/CiaobotMac/Resources/app-icon.png")
let defaultForegroundOutput = repositoryRoot.appendingPathComponent("Sources/CiaobotMac/Resources/dock-icon-foreground.png")
let arguments = Array(CommandLine.arguments.dropFirst())
let sourceURL = arguments.count > 0 ? URL(fileURLWithPath: arguments[0]) : defaultSource
let outputURL = arguments.count > 1 ? URL(fileURLWithPath: arguments[1]) : defaultOutput
let foregroundOutputURL = arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : defaultForegroundOutput

let canvasSize = 1024
let tileSize: CGFloat = 824
let tileInset = (CGFloat(canvasSize) - tileSize) / 2
let cornerRadius: CGFloat = 185.4
let tileColor = NSColor(srgbRed: 0xFC / 255, green: 0x87 / 255, blue: 0x19 / 255, alpha: 1)

guard let source = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write(Data("Could not read \(sourceURL.path)\n".utf8))
    exit(1)
}
guard source.size.width > 0, source.size.height > 0 else {
    FileHandle.standardError.write(Data("The source artwork has no pixels\n".utf8))
    exit(1)
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasSize,
    pixelsHigh: canvasSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("Could not allocate the icon canvas\n".utf8))
    exit(1)
}
bitmap.size = NSSize(width: canvasSize, height: canvasSize)

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    FileHandle.standardError.write(Data("Could not create an icon drawing context\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.cgContext.setShouldAntialias(true)

// The tile is the only opaque region. Everything outside it stays
// transparent, which is what gives Finder and the Dock the rounded shape.
let tileRect = NSRect(x: tileInset, y: tileInset, width: tileSize, height: tileSize)
NSBezierPath(roundedRect: tileRect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
tileColor.setFill()
tileRect.fill()
source.draw(in: tileRect, from: .zero, operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Could not encode the icon PNG\n".utf8))
    exit(1)
}
do {
    try data.write(to: outputURL, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("Could not write \(outputURL.path): \(error)\n".utf8))
    exit(1)
}

// The running app's foreground mask. Only the border-connected tile
// background is removed; the face, its antialiased edges and the transparent
// exterior keep their exact pixels, and the tile's own alpha keeps the macOS
// shape. The app paints a preset colour behind this mask.
guard bitmap.samplesPerPixel == 4,
      bitmap.bitsPerSample == 8,
      !bitmap.isPlanar,
      bitmap.bytesPerRow == canvasSize * 4,
      let pixels = bitmap.bitmapData else {
    FileHandle.standardError.write(Data("The icon bitmap is not 8-bit RGBA\n".utf8))
    exit(1)
}

let width = bitmap.pixelsWide
let height = bitmap.pixelsHigh
let stride = bitmap.bytesPerRow
let backgroundOffset = (height / 2) * stride + (Int(tileInset) + 20) * 4
let background = (r: Int(pixels[backgroundOffset]),
                  g: Int(pixels[backgroundOffset + 1]),
                  b: Int(pixels[backgroundOffset + 2]))
// Antialiased blends near the tile edge are background too; a face pixel is
// far outside this tolerance.
let tolerance = 12

func isBackground(_ index: Int) -> Bool {
    let offset = index * 4
    let alpha = Int(pixels[offset + 3])
    // Only the tile edge is antialiased against the transparent exterior; the
    // face is painted onto the opaque tile, so every face pixel is opaque.
    if alpha < 255 { return true }
    return abs(Int(pixels[offset]) - background.r) <= tolerance
        && abs(Int(pixels[offset + 1]) - background.g) <= tolerance
        && abs(Int(pixels[offset + 2]) - background.b) <= tolerance
}

var visited = [Bool](repeating: false, count: width * height)
var stack: [Int] = []
for x in 0..<width {
    stack.append(x)
    stack.append((height - 1) * width + x)
}
for y in 0..<height {
    stack.append(y * width)
    stack.append(y * width + width - 1)
}

while let index = stack.popLast() {
    guard !visited[index], isBackground(index) else { continue }
    visited[index] = true
    let x = index % width
    let y = index / width
    if x > 0 { stack.append(index - 1) }
    if x + 1 < width { stack.append(index + 1) }
    if y > 0 { stack.append(index - width) }
    if y + 1 < height { stack.append(index + width) }
}

guard let foreground = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let foregroundPixels = foreground.bitmapData else {
    FileHandle.standardError.write(Data("Could not allocate the foreground mask\n".utf8))
    exit(1)
}
foreground.size = NSSize(width: width, height: height)
for index in 0..<(width * height) {
    guard !visited[index] else { continue }
    let source = index * 4
    let destination = (index / width) * foreground.bytesPerRow + (index % width) * 4
    foregroundPixels[destination] = pixels[source]
    foregroundPixels[destination + 1] = pixels[source + 1]
    foregroundPixels[destination + 2] = pixels[source + 2]
    foregroundPixels[destination + 3] = pixels[source + 3]
}

guard let foregroundData = foreground.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Could not encode the foreground PNG\n".utf8))
    exit(1)
}
do {
    try foregroundData.write(to: foregroundOutputURL, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("Could not write \(foregroundOutputURL.path): \(error)\n".utf8))
    exit(1)
}

let sourceHash = SHA256.hash(data: (try? Data(contentsOf: sourceURL)) ?? Data())
    .map { String(format: "%02x", $0) }.joined()
let foregroundHash = SHA256.hash(data: foregroundData)
    .map { String(format: "%02x", $0) }.joined()
print("Wrote \(outputURL.path)")
print("  canvas \(canvasSize)x\(canvasSize), tile \(Int(tileSize))x\(Int(tileSize)) at \(Int(tileInset)), radius \(cornerRadius)")
print("  source sha256 \(sourceHash)")
print("Wrote \(foregroundOutputURL.path)")
print("  face-only foreground, background #\(String(format: "%02X%02X%02X", background.r, background.g, background.b))")
print("  foreground sha256 \(foregroundHash)")
