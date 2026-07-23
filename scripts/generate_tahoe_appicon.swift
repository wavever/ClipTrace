#!/usr/bin/env swift
//
// Regenerates AppIcon.appiconset from the transparent master artwork.
//
// The Dock icon should be the Clipth artwork itself, with no extra background
// plate. A previous version drew a warm paper rounded-rect behind the icon for
// macOS 26 icon-shape handling, but that plate is visible in the Dock as a
// pale border. Keep the source transparent and only resize it for each slot.
//
// Usage: swift scripts/generate_tahoe_appicon.swift [path/to/AppIcon.appiconset]
// Source art: Clipth/Assets.xcassets/AppIconClassic.imageset/AppIconClassic.png

import AppKit
import ImageIO
import UniformTypeIdentifiers

let setPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Clipth/Assets.xcassets/AppIcon.appiconset"
let setURL = URL(fileURLWithPath: setPath)
let sourceURL = URL(
    fileURLWithPath: "Clipth/Assets.xcassets/AppIconClassic.imageset/AppIconClassic.png"
)

guard let srcData = try? Data(contentsOf: sourceURL),
      let srcSource = CGImageSourceCreateWithData(srcData as CFData, nil),
      let srcImage = CGImageSourceCreateImageAtIndex(srcSource, 0, nil) else {
    fatalError("Cannot load source icon at \(sourceURL.path)")
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(_ size: Int) -> CGContext {
    let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    return ctx
}

func aspectFitRect(source: CGSize, target: CGSize) -> CGRect {
    let scale = min(target.width / source.width, target.height / source.height)
    let width = source.width * scale
    let height = source.height * scale
    return CGRect(
        x: (target.width - width) / 2,
        y: (target.height - height) / 2,
        width: width,
        height: height
    )
}

let slots: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

let sourceSize = CGSize(width: srcImage.width, height: srcImage.height)

for (name, size) in slots {
    let targetSize = CGSize(width: size, height: size)
    let ctx = makeContext(size)
    ctx.draw(srcImage, in: aspectFitRect(source: sourceSize, target: targetSize))

    guard let image = ctx.makeImage() else { fatalError("Scale to \(size) failed") }
    let url = setURL.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("Cannot create \(name)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Cannot write \(name)") }
    print("Wrote \(name) (\(size)px)")
}

print("Done.")
