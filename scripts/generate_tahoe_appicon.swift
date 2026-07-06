#!/usr/bin/env swift
//
// Regenerates AppIcon.appiconset for the macOS 26 icon treatment.
//
// Tahoe puts any icon whose pixels protrude beyond the classic rounded-rect
// icon grid into "squircle jail": the artwork is shrunk onto a system-grey
// plate. The previous ClipTrace icon was die-cut (clipboard clip poking above
// a sage card covering ~90% of the canvas), so it got jailed. This script
// re-plates it: a warm paper squircle drawn exactly on the Apple icon grid
// (824×824 @ 1024) with the full existing artwork scaled to fit inside, so
// Tahoe re-masks it seamlessly and older systems keep the same design language.
//
// Usage: swift scripts/generate_tahoe_appicon.swift [path/to/AppIcon.appiconset]
// The current icon_512x512@2x.png inside the set is used as the source art.

import AppKit
import ImageIO
import UniformTypeIdentifiers

let fm = FileManager.default
let setPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "ClipTrace/Assets.xcassets/AppIcon.appiconset"
let setURL = URL(fileURLWithPath: setPath)
let sourceURL = setURL.appendingPathComponent("icon_512x512@2x.png")

guard let srcData = try? Data(contentsOf: sourceURL),
      let srcSource = CGImageSourceCreateWithData(srcData as CFData, nil),
      let srcImage = CGImageSourceCreateImageAtIndex(srcSource, 0, nil) else {
    fatalError("Cannot load source icon at \(sourceURL.path)")
}

let canvas = 1024
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(_ size: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    return ctx
}

// MARK: - Measure the opaque bounding box of the source art

let measure = makeContext(canvas)
measure.draw(srcImage, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
guard let buf = measure.data else { fatalError("No bitmap data") }
let bytesPerRow = measure.bytesPerRow
var minX = canvas, maxX = -1, minY = canvas, maxY = -1
for y in 0..<canvas {
    let row = buf.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
    for x in 0..<canvas {
        // Alpha is the 4th component (RGBA); > 8 skips faint AA fringes.
        if row[x * 4 + 3] > 8 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
}
guard maxX >= minX, maxY >= minY else { fatalError("Source appears empty") }
// CGContext rows are bottom-up in CG coordinates; the scan above already used
// CG-space y because we read the context we drew into, so no flip is needed.
let bbox = CGRect(
    x: CGFloat(minX), y: CGFloat(minY),
    width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1)
)
print("Source art bbox: \(bbox)")

// MARK: - Compose the new 1024 master

// Apple's classic macOS icon grid: 824×824 centered, continuous corners ≈185.
let plateRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let plateRadius: CGFloat = 185.4
// Keep every art pixel comfortably inside the plate so Tahoe's shape
// detection sees a perfectly conforming rounded-rect icon.
let artBounds: CGFloat = 724

let master = makeContext(canvas)
let platePath = CGPath(
    roundedRect: plateRect,
    cornerWidth: plateRadius, cornerHeight: plateRadius,
    transform: nil
)
master.saveGState()
master.addPath(platePath)
master.clip()
// Warm paper plate with a faint top-light so it reads as a sheet, not a slab.
let gradient = CGGradient(
    colorsSpace: srgb,
    colors: [
        CGColor(srgbRed: 0.972, green: 0.956, blue: 0.924, alpha: 1),
        CGColor(srgbRed: 0.944, green: 0.920, blue: 0.874, alpha: 1)
    ] as CFArray,
    locations: [0, 1]
)!
master.drawLinearGradient(
    gradient,
    start: CGPoint(x: 512, y: plateRect.maxY),
    end: CGPoint(x: 512, y: plateRect.minY),
    options: []
)
master.restoreGState()

// Scale the whole source canvas so its opaque bbox fits `artBounds`, centered.
let scale = min(artBounds / bbox.width, artBounds / bbox.height)
let drawSize = CGFloat(canvas) * scale
let bboxCenter = CGPoint(x: bbox.midX * scale, y: bbox.midY * scale)
let origin = CGPoint(x: 512 - bboxCenter.x, y: 512 - bboxCenter.y)
master.draw(srcImage, in: CGRect(x: origin.x, y: origin.y, width: drawSize, height: drawSize))

guard let masterImage = master.makeImage() else { fatalError("Compose failed") }

// MARK: - Emit every slot of the icon set

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

for (name, size) in slots {
    let ctx = makeContext(size)
    ctx.draw(masterImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let image = ctx.makeImage() else { fatalError("Scale to \(size) failed") }
    let url = setURL.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("Cannot create \(name)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Cannot write \(name)") }
    print("Wrote \(name) (\(size)px)")
}
print("Done.")
