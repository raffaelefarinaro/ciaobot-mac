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
// Usage:
//   swift scripts/make-app-icon.swift [source.png] [output.png]
//
// Defaults read Sources/CiaobotMac/Artwork/app-icon-source.png (a byte-for-byte
// snapshot of web/public/icons/icon-512.png) and write
// Sources/CiaobotMac/Resources/app-icon.png. The app and the release build
// never run this script and never read the engine checkout; regenerate only
// when the PWA artwork changes.

let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repositoryRoot = scriptDirectory.deletingLastPathComponent()
let defaultSource = repositoryRoot.appendingPathComponent("Sources/CiaobotMac/Artwork/app-icon-source.png")
let defaultOutput = repositoryRoot.appendingPathComponent("Sources/CiaobotMac/Resources/app-icon.png")
let arguments = Array(CommandLine.arguments.dropFirst())
let sourceURL = arguments.count > 0 ? URL(fileURLWithPath: arguments[0]) : defaultSource
let outputURL = arguments.count > 1 ? URL(fileURLWithPath: arguments[1]) : defaultOutput

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

let sourceHash = SHA256.hash(data: (try? Data(contentsOf: sourceURL)) ?? Data())
    .map { String(format: "%02x", $0) }.joined()
print("Wrote \(outputURL.path)")
print("  canvas \(canvasSize)x\(canvasSize), tile \(Int(tileSize))x\(Int(tileSize)) at \(Int(tileInset)), radius \(cornerRadius)")
print("  source sha256 \(sourceHash)")
