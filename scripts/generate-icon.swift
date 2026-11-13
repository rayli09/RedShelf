import AppKit
import CoreGraphics
import CoreText
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("RedShelf/Assets.xcassets/App Icon & Top Shelf Image.brandassets")
let artworkURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Artwork/pixel-top-shelf.png")
guard let artwork = NSImage(contentsOf: artworkURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("Cannot load pixel artwork") }

func drawArtwork(_ context: CGContext, width: CGFloat, height: CGFloat) {
    let scale = max(width / CGFloat(artwork.width), height / CGFloat(artwork.height))
    let size = CGSize(width: CGFloat(artwork.width) * scale, height: CGFloat(artwork.height) * scale)
    context.interpolationQuality = .none
    context.draw(artwork, in: CGRect(x: (width - size.width) / 2, y: (height - size.height) / 2, width: size.width, height: size.height))
}

func pixelWordmark() -> CGImage {
    guard let pixels = CGContext(data: nil, width: 144, height: 48, bitsPerComponent: 8,
                                 bytesPerRow: 144 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot allocate wordmark") }
    pixels.setAllowsAntialiasing(false)
    let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 42, nil)
    let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: NSColor.white.cgColor] as CFDictionary
    let text = CFAttributedStringCreate(nil, "小红书" as CFString, attrs)!
    let line = CTLineCreateWithAttributedString(text)
    let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    pixels.textPosition = CGPoint(x: (144 - textWidth) / 2, y: 6)
    CTLineDraw(line, pixels)
    guard let wordmark = pixels.makeImage() else { fatalError("Cannot render wordmark") }
    return wordmark
}

func makeTopShelf(_ scale: Int, _ output: URL) throws {
    let width = 1920 * scale, height = 720 * scale
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot allocate image") }
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    drawArtwork(context, width: 1920, height: 720)
    context.interpolationQuality = .none
    context.draw(pixelWordmark(), in: CGRect(x: 90, y: 242, width: 600, height: 200))
    guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Cannot encode image") }
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: output)
}

func makeLayer(_ name: String, _ width: Int, _ height: Int, _ output: URL) throws {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot allocate image") }
    context.scaleBy(x: CGFloat(width) / 800, y: CGFloat(height) / 480)
    if name == "Back" {
        drawArtwork(context, width: 800, height: 480)
    } else {
        context.interpolationQuality = .none
        context.draw(pixelWordmark(), in: CGRect(x: 18, y: 180, width: 360, height: 120))
    }
    guard let image = context.makeImage() else { fatalError("Cannot render image") }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode image") }
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: output)
}

for (stack, size) in [("App Icon", (400, 240)), ("App Icon - App Store", (1280, 768))] {
    for layer in ["Front", "Back"] {
        let directory = root.appendingPathComponent("\(stack).imagestack/\(layer).imagestacklayer/Content.imageset")
        if stack == "App Icon" {
            try makeLayer(layer, size.0, size.1, directory.appendingPathComponent("\(layer).png"))
            try makeLayer(layer, size.0 * 2, size.1 * 2, directory.appendingPathComponent("\(layer)@2x.png"))
        } else {
            try makeLayer(layer, size.0, size.1, directory.appendingPathComponent("\(layer).png"))
        }
    }
}

let topShelf = root.appendingPathComponent("Top Shelf Image.imageset")
try makeTopShelf(1, topShelf.appendingPathComponent("TopShelf.png"))
try makeTopShelf(2, topShelf.appendingPathComponent("TopShelf@2x.png"))
