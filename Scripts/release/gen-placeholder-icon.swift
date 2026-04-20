// gen-placeholder-icon.swift
//
// Writes a solid-color PNG of the given size to the given path.
// Used by assemble-app.sh as a fallback when AppShell/AppIcon.iconset/ is
// empty — generates a recognizable placeholder so codesign / iconutil /
// Finder don't see a missing-icon edge case.
//
// Usage:
//   swift gen-placeholder-icon.swift <size> <output.png>
//
// Intentionally dependency-free: runs off the Swift toolchain that already
// has to be present to build the app. Ten invocations for the ten iconset
// sizes would be slow, so assemble-app.sh renders one master at 1024 and
// uses `sips` to downscale.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3, let size = Int(args[1]), size > 0 else {
    FileHandle.standardError.write(Data("usage: gen-placeholder-icon.swift <size> <output.png>\n".utf8))
    exit(2)
}

let path = args[2]
let bytesPerRow = size * 4

guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("failed to create CGContext\n".utf8))
    exit(1)
}

// Deep indigo — distinct enough from stock macOS icons that the placeholder
// is obvious in Finder / Dock.
ctx.setFillColor(CGColor(srgbRed: 0.24, green: 0.18, blue: 0.55, alpha: 1.0))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Inner white "G" blocky monogram — just barely informative at small sizes.
let inset = CGFloat(size) * 0.22
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1.0))
ctx.fillEllipse(in: CGRect(
    x: inset,
    y: inset,
    width: CGFloat(size) - inset * 2,
    height: CGFloat(size) - inset * 2
))
ctx.setFillColor(CGColor(srgbRed: 0.24, green: 0.18, blue: 0.55, alpha: 1.0))
let hole = CGFloat(size) * 0.32
ctx.fillEllipse(in: CGRect(
    x: (CGFloat(size) - hole) / 2,
    y: (CGFloat(size) - hole) / 2,
    width: hole,
    height: hole
))

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write(Data("failed to rasterize image\n".utf8))
    exit(1)
}

let url = URL(fileURLWithPath: path)
guard let dst = CGImageDestinationCreateWithURL(
    url as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    FileHandle.standardError.write(Data("failed to create image destination\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(dst, image, nil)
guard CGImageDestinationFinalize(dst) else {
    FileHandle.standardError.write(Data("failed to write PNG\n".utf8))
    exit(1)
}
