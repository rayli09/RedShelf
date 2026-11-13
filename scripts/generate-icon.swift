import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("RedShelf/Assets.xcassets/App Icon & Top Shelf Image.brandassets")

func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func makeLayer(_ name: String, _ width: Int, _ height: Int, _ output: URL) throws {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot allocate image") }
    context.scaleBy(x: CGFloat(width) / 800, y: CGFloat(height) / 480)
    if name == "Back" {
        let colors = [NSColor(srgbRed: 0.31, green: 0.025, blue: 0.075, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.77, green: 0.08, blue: 0.18, alpha: 1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 800, y: 480), options: [])
    } else {
        context.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        context.setFillColor(NSColor.white.withAlphaComponent(0.38).cgColor)
        context.addPath(rounded(252, 112, 160, 240, 25)); context.fillPath()
        context.setFillColor(NSColor.white.withAlphaComponent(0.66).cgColor)
        context.addPath(rounded(334, 125, 160, 240, 25)); context.fillPath()
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(rounded(414, 138, 160, 240, 25)); context.fillPath()
        context.setShadow(offset: .zero, blur: 0)
        context.setFillColor(NSColor(srgbRed: 0.84, green: 0.12, blue: 0.23, alpha: 1).cgColor)
        context.move(to: CGPoint(x: 475, y: 216)); context.addLine(to: CGPoint(x: 475, y: 300)); context.addLine(to: CGPoint(x: 533, y: 258)); context.closePath(); context.fillPath()
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
