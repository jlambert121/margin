import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Usage: make-icon.swift <AppIcon.iconset>
let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let shape = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)

func tile(_ c: CGContext, top: UInt32, bottom: UInt32) {
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.18))
    c.addPath(shape); c.setFillColor(rgb(bottom)); c.fillPath()
    c.restoreGState()
    c.addPath(shape); c.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
}

func glyph(_ c: CGContext, _ text: String, font: String, size: CGFloat, color: CGColor, center: CGPoint) {
    let attributes: [NSAttributedString.Key: Any] = [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName(font as CFString, size, nil), kCTForegroundColorAttributeName as NSAttributedString.Key: color]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    c.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
    CTLineDraw(line, c)
}

let design: (CGContext) -> Void = { c in
    tile(c, top: 0x2A302C, bottom: 0x1B1F1D)
    c.setFillColor(rgb(0xA2B99A)); c.fill(CGRect(x: 318, y: 100, width: 12, height: 824))
    glyph(c, "m", font: "Georgia-Italic", size: 520, color: rgb(0xE9ECE3), center: CGPoint(x: 590, y: 500))
}

func render(_ design: (CGContext) -> Void, size: Int, to url: URL) {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    design(context)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
}

for size in [16, 32, 128, 256, 512] {
    render(design, size: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    render(design, size: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
