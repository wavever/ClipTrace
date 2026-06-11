import AppKit

let args = CommandLine.arguments
guard args.count == 4 else {
    fputs("usage: render_dmg_background.swift <output.png> <app-name> <icon.png>\n", stderr)
    exit(64)
}

let outputURL = URL(fileURLWithPath: args[1])
let appName = args[2]
let iconPath = args[3]

let canvas = NSSize(width: 720, height: 440)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas.width),
    pixelsHigh: Int(canvas.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("failed to create bitmap context\n", stderr)
    exit(1)
}
bitmap.size = canvas

func centeredAttributes(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    return [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ]
}

func fittedAttributes(
    text: String,
    maxWidth: CGFloat,
    startingSize: CGFloat,
    minSize: CGFloat,
    weight: NSFont.Weight,
    color: NSColor
) -> [NSAttributedString.Key: Any] {
    var size = startingSize
    while size > minSize {
        let attrs = centeredAttributes(size: size, weight: weight, color: color)
        if (text as NSString).size(withAttributes: attrs).width <= maxWidth {
            return attrs
        }
        size -= 1
    }
    return centeredAttributes(size: minSize, weight: weight, color: color)
}

guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("failed to create graphics context\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
graphicsContext.cgContext.setShouldAntialias(true)

NSColor(calibratedRed: 0.985, green: 0.978, blue: 0.958, alpha: 1).setFill()
NSRect(origin: .zero, size: canvas).fill()

let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 46, weight: .bold),
    .foregroundColor: NSColor.black,
]
let titleSize = (appName as NSString).size(withAttributes: titleAttrs)
let titleIconSize: CGFloat = 54
let titleGap: CGFloat = 16
let titleWidth = titleIconSize + titleGap + titleSize.width
let titleX = (canvas.width - titleWidth) / 2
let titleY: CGFloat = 338

if let appIcon = NSImage(contentsOfFile: iconPath) {
    let iconRect = NSRect(x: titleX, y: titleY - 2, width: titleIconSize, height: titleIconSize)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: iconRect, xRadius: 13, yRadius: 13).addClip()
    appIcon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

(appName as NSString).draw(
    in: NSRect(x: titleX + titleIconSize + titleGap, y: titleY + 2, width: titleSize.width + 8, height: 58),
    withAttributes: titleAttrs
)

let instruction = "将 \(appName) 拖入 Applications 文件夹安装"
let instructionAttrs = fittedAttributes(
    text: instruction,
    maxWidth: canvas.width - 72,
    startingSize: 34,
    minSize: 24,
    weight: .regular,
    color: NSColor(calibratedWhite: 0.08, alpha: 1)
)
(instruction as NSString).draw(
    in: NSRect(x: 36, y: 38, width: canvas.width - 72, height: 48),
    withAttributes: instructionAttrs
)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("failed to render DMG background\n", stderr)
    exit(1)
}

do {
    try png.write(to: outputURL)
} catch {
    fputs("failed to write \(outputURL.path): \(error)\n", stderr)
    exit(1)
}
