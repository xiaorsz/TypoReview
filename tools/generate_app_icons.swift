import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let darkSourceURL = root.appendingPathComponent("tools/AppIconSource.png")
let lightSourceURL = root.appendingPathComponent("tools/AppIconSource-Light.png")
let outputDirectory = root.appendingPathComponent(
    "错字复习/Assets.xcassets/AppIcon.appiconset",
    isDirectory: true
)

guard let darkSourceImage = NSImage(contentsOf: darkSourceURL),
      let lightSourceImage = NSImage(contentsOf: lightSourceURL) else {
    throw NSError(
        domain: "AppIconGeneration",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Unable to load app icon source images"]
    )
}

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

func renderIcon(
    sourceImage: NSImage,
    backgroundRGB: (red: CGFloat, green: CGFloat, blue: CGFloat),
    destinationURL: URL
) throws {
    let size = 1024
    guard let sourceCGImage = sourceImage.cgImage(
        forProposedRect: nil,
        context: nil,
        hints: nil
    ) else {
        throw NSError(domain: "AppIconGeneration", code: 2)
    }

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.noneSkipLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw NSError(domain: "AppIconGeneration", code: 3)
    }

    context.setFillColor(
        red: backgroundRGB.red,
        green: backgroundRGB.green,
        blue: backgroundRGB.blue,
        alpha: 1
    )
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.interpolationQuality = .high
    context.draw(sourceCGImage, in: CGRect(x: 0, y: 0, width: size, height: size))

    guard let renderedImage = context.makeImage() else {
        throw NSError(domain: "AppIconGeneration", code: 4)
    }
    let bitmap = NSBitmapImageRep(cgImage: renderedImage)
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppIconGeneration", code: 5)
    }
    try pngData.write(to: destinationURL, options: .atomic)
}

let lightFilename = "Icon-1024-Light.png"
let darkFilename = "Icon-1024-dark.png"

try renderIcon(
    sourceImage: lightSourceImage,
    backgroundRGB: (233.0 / 255.0, 238.0 / 255.0, 245.0 / 255.0),
    destinationURL: outputDirectory.appendingPathComponent(lightFilename)
)
try renderIcon(
    sourceImage: darkSourceImage,
    backgroundRGB: (17.0 / 255.0, 24.0 / 255.0, 39.0 / 255.0),
    destinationURL: outputDirectory.appendingPathComponent(darkFilename)
)

let contents: [String: Any] = [
    "images": [
        [
            "filename": lightFilename,
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024"
        ],
        [
            "appearances": [[
                "appearance": "luminosity",
                "value": "dark"
            ]],
            "filename": darkFilename,
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024"
        ]
    ],
    "info": [
        "author": "xcode",
        "version": 1
    ]
]
var contentsData = try JSONSerialization.data(
    withJSONObject: contents,
    options: [.prettyPrinted, .sortedKeys]
)
contentsData.append(0x0A)
try contentsData.write(
    to: outputDirectory.appendingPathComponent("Contents.json"),
    options: .atomic
)

// Remove files from the legacy per-size layout. Xcode now derives all device
// sizes from the two universal 1024 px masters above.
let activeFilenames = Set([lightFilename, darkFilename, "Contents.json"])
for url in try FileManager.default.contentsOfDirectory(
    at: outputDirectory,
    includingPropertiesForKeys: nil
) where !activeFilenames.contains(url.lastPathComponent) {
    try FileManager.default.removeItem(at: url)
}

print("Generated opaque universal light and dark app icons")
