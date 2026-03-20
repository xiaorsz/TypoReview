import AppKit
import Foundation

struct IconSpec {
    let filename: String
    let size: Int
}

let specs: [IconSpec] = [
    .init(filename: "Icon-20@2x.png", size: 40),
    .init(filename: "Icon-20@3x.png", size: 60),
    .init(filename: "Icon-29@2x.png", size: 58),
    .init(filename: "Icon-29@3x.png", size: 87),
    .init(filename: "Icon-40@2x.png", size: 80),
    .init(filename: "Icon-40@3x.png", size: 120),
    .init(filename: "Icon-60@2x.png", size: 120),
    .init(filename: "Icon-60@3x.png", size: 180),
    .init(filename: "Icon-20-ipad@1x.png", size: 20),
    .init(filename: "Icon-20-ipad@2x.png", size: 40),
    .init(filename: "Icon-29-ipad@1x.png", size: 29),
    .init(filename: "Icon-29-ipad@2x.png", size: 58),
    .init(filename: "Icon-40-ipad@1x.png", size: 40),
    .init(filename: "Icon-40-ipad@2x.png", size: 80),
    .init(filename: "Icon-76-ipad@1x.png", size: 76),
    .init(filename: "Icon-76-ipad@2x.png", size: 152),
    .init(filename: "Icon-83.5-ipad@2x.png", size: 167),
    .init(filename: "Icon-1024.png", size: 1024)
]

let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("错字复习/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1.0) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xff) / 255.0,
        green: CGFloat((hex >> 8) & 0xff) / 255.0,
        blue: CGFloat(hex & 0xff) / 255.0,
        alpha: alpha
    )
}

func saveIcon(size: Int, to url: URL, opaque: Bool = false) throws {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let corner = CGFloat(size) * 0.23
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: opaque ? 3 : 4,
        hasAlpha: !opaque,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconGeneration", code: 1)
    }

    bitmap.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "IconGeneration", code: 2)
    }
    NSGraphicsContext.current = context

    if opaque {
        color(0xF59A5A).setFill()
        rect.fill()
    }

    let bgPath = opaque
        ? NSBezierPath(rect: rect)
        : NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

    let bgGradient = NSGradient(colors: [
        color(0xFFCC73),
        color(0xFF9052)
    ])!
    bgGradient.draw(in: bgPath, angle: -45)

    let grainInset = rect.insetBy(dx: CGFloat(size) * 0.04, dy: CGFloat(size) * 0.04)
    let grainPath = opaque
        ? NSBezierPath(rect: grainInset)
        : NSBezierPath(roundedRect: grainInset, xRadius: corner * 0.85, yRadius: corner * 0.85)
    color(0xFFFFFF, alpha: 0.14).setStroke()
    grainPath.lineWidth = max(2, CGFloat(size) * 0.01)
    grainPath.stroke()

    let notebookRect = NSRect(
        x: CGFloat(size) * 0.18,
        y: CGFloat(size) * 0.16,
        width: CGFloat(size) * 0.64,
        height: CGFloat(size) * 0.68
    )
    let notebookPath = NSBezierPath(roundedRect: notebookRect, xRadius: CGFloat(size) * 0.08, yRadius: CGFloat(size) * 0.08)
    color(0xFFF9F0).setFill()
    notebookPath.fill()

    let topBandRect = NSRect(
        x: notebookRect.minX,
        y: notebookRect.maxY - CGFloat(size) * 0.15,
        width: notebookRect.width,
        height: CGFloat(size) * 0.15
    )
    let topBandPath = NSBezierPath(roundedRect: topBandRect, xRadius: CGFloat(size) * 0.08, yRadius: CGFloat(size) * 0.08)
    color(0x2D5B8E).setFill()
    topBandPath.fill()

    let lineColor = color(0xE2D7CC)
    lineColor.setStroke()
    for index in 0..<4 {
        let y = notebookRect.minY + CGFloat(size) * (0.16 + 0.1 * CGFloat(index))
        let line = NSBezierPath()
        line.move(to: NSPoint(x: notebookRect.minX + CGFloat(size) * 0.09, y: y))
        line.line(to: NSPoint(x: notebookRect.maxX - CGFloat(size) * 0.08, y: y))
        line.lineWidth = max(1.5, CGFloat(size) * 0.007)
        line.stroke()
    }

    let title = "听写"
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let titleFont = NSFont.systemFont(ofSize: CGFloat(size) * 0.16, weight: .bold)
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: color(0xE6683C),
        .paragraphStyle: paragraph
    ]
    let titleRect = NSRect(
        x: notebookRect.minX,
        y: notebookRect.minY + CGFloat(size) * 0.18,
        width: notebookRect.width,
        height: CGFloat(size) * 0.2
    )
    title.draw(in: titleRect, withAttributes: titleAttrs)

    let sub = "复习本"
    let subFont = NSFont.systemFont(ofSize: CGFloat(size) * 0.072, weight: .semibold)
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: subFont,
        .foregroundColor: color(0x6E7B8B),
        .paragraphStyle: paragraph
    ]
    let subRect = NSRect(
        x: notebookRect.minX,
        y: notebookRect.minY + CGFloat(size) * 0.08,
        width: notebookRect.width,
        height: CGFloat(size) * 0.11
    )
    sub.draw(in: subRect, withAttributes: subAttrs)

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGeneration", code: 3)
    }

    try pngData.write(to: url)
}

for spec in specs {
    try saveIcon(
        size: spec.size,
        to: outputDir.appendingPathComponent(spec.filename),
        opaque: spec.filename == "Icon-1024.png"
    )
}

print("Generated \(specs.count) icons in \(outputDir.path)")
