import AppKit
import Foundation

struct ScreenshotResizeError: Error, CustomStringConvertible {
    let description: String
}

func fail(_ message: String) throws -> Never {
    throw ScreenshotResizeError(description: message)
}

func pngFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension.lowercased() == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func resizedImage(from sourceURL: URL, width targetWidth: Int, height targetHeight: Int) throws -> NSBitmapImageRep {
    guard let sourceImage = NSImage(contentsOf: sourceURL),
          let sourceRep = sourceImage.representations.first as? NSBitmapImageRep else {
        try fail("Could not read PNG: \(sourceURL.path)")
    }

    let sourceWidth = sourceRep.pixelsWide
    let sourceHeight = sourceRep.pixelsHigh
    let targetAspect = CGFloat(targetWidth) / CGFloat(targetHeight)
    let sourceAspect = CGFloat(sourceWidth) / CGFloat(sourceHeight)

    let cropRect: CGRect
    if sourceAspect > targetAspect {
        let cropWidth = Int((CGFloat(sourceHeight) * targetAspect).rounded())
        let x = (sourceWidth - cropWidth) / 2
        cropRect = CGRect(x: x, y: 0, width: cropWidth, height: sourceHeight)
    } else {
        let cropHeight = Int((CGFloat(sourceWidth) / targetAspect).rounded())
        let y = (sourceHeight - cropHeight) / 2
        cropRect = CGRect(x: 0, y: y, width: sourceWidth, height: cropHeight)
    }

    guard let croppedCGImage = sourceRep.cgImage?.cropping(to: cropRect) else {
        try fail("Could not crop PNG: \(sourceURL.path)")
    }

    guard let context = CGContext(
        data: nil,
        width: targetWidth,
        height: targetHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        try fail("Could not create drawing context")
    }

    context.interpolationQuality = .high
    context.draw(croppedCGImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

    guard let resizedCGImage = context.makeImage() else {
        try fail("Could not render resized image")
    }

    return NSBitmapImageRep(cgImage: resizedCGImage)
}

func writePNG(_ image: NSBitmapImageRep, to outputURL: URL) throws {
    guard let data = image.representation(using: .png, properties: [:]) else {
        try fail("Could not encode PNG: \(outputURL.path)")
    }
    try data.write(to: outputURL, options: .atomic)
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 5,
          let targetWidth = Int(arguments[3]),
          let targetHeight = Int(arguments[4]) else {
        try fail("Usage: resize_app_store_screenshots <input-dir> <output-dir> <width> <height>")
    }

    let inputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    let inputFiles = try pngFiles(in: inputDirectory)
    guard !inputFiles.isEmpty else {
        try fail("No PNG files found in \(inputDirectory.path)")
    }

    for inputURL in inputFiles {
        let outputURL = outputDirectory.appendingPathComponent(inputURL.lastPathComponent)
        let image = try resizedImage(from: inputURL, width: targetWidth, height: targetHeight)
        try writePNG(image, to: outputURL)
        print("\(inputURL.lastPathComponent): \(targetWidth)x\(targetHeight)")
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
