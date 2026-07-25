#!/usr/bin/env swift
//
// Regenerates AppIcon.appiconset from the transparent master artwork.
//
// The Dock and Spotlight icon should be the Clipth artwork itself, with no
// extra background plate. A previous version drew a warm paper rounded-rect
// behind the icon for macOS 26 icon-shape handling, but that plate is visible
// as a pale border. Keep the source transparent, then fit the non-transparent
// artwork bounds to each slot so macOS 26 doesn't show its fallback plate
// around an undersized icon.
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

func alphaBounds(of image: CGImage, threshold: UInt8 = 4) -> CGRect {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)

    pixels.withUnsafeMutableBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.interpolationQuality = .none
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1

    for y in 0..<height {
        let row = y * width * 4
        for x in 0..<width {
            let alpha = pixels[row + x * 4 + 3]
            guard alpha > threshold else { continue }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }

    guard maxX >= minX, maxY >= minY else {
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    return CGRect(
        x: minX,
        y: minY,
        width: maxX - minX + 1,
        height: maxY - minY + 1
    )
}

func rectFittingContent(_ content: CGRect, source: CGSize, target: CGSize) -> CGRect {
    let scale = min(target.width / content.width, target.height / content.height)
    let center = CGPoint(x: target.width / 2, y: target.height / 2)
    return CGRect(
        x: center.x - content.midX * scale,
        y: center.y - content.midY * scale,
        width: source.width * scale,
        height: source.height * scale
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
let sourceContentBounds = alphaBounds(of: srcImage)
print(
    "Source content bounds: "
        + "\(Int(sourceContentBounds.width))x\(Int(sourceContentBounds.height)) "
        + "at (\(Int(sourceContentBounds.minX)), \(Int(sourceContentBounds.minY)))"
)

for (name, size) in slots {
    let targetSize = CGSize(width: size, height: size)
    let ctx = makeContext(size)
    ctx.draw(
        srcImage,
        in: rectFittingContent(sourceContentBounds, source: sourceSize, target: targetSize)
    )

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
