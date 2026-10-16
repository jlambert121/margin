import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Usage: make-icon.swift <AppIcon.iconset> <Icons directory>
// The night design becomes the bundle icon; every design is also written as a
// PNG for the runtime Dock icon picker. Names must match AppIconChoice.
let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
let choices = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: choices, withIntermediateDirectories: true)
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
let shape = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
let paper: UInt32 = 0xFBF9F2, paperLow: UInt32 = 0xEFEBDD, ink: UInt32 = 0x3A403C
let sage: UInt32 = 0x537460, sageLight: UInt32 = 0x6E8C76, sageDeep: UInt32 = 0x3C5A48, quote: UInt32 = 0xA0B39A

func tile(_ c: CGContext, top: UInt32, bottom: UInt32) {
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.18))
    c.addPath(shape); c.setFillColor(rgb(bottom)); c.fillPath()
    c.restoreGState()
    c.addPath(shape); c.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
}
func bar(_ c: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, _ color: CGColor) {
    c.addPath(CGPath(roundedRect: CGRect(x: x, y: y - height / 2, width: width, height: height), cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
    c.setFillColor(color); c.fillPath()
}
func glyph(_ c: CGContext, _ text: String, font: String, size: CGFloat, color: CGColor, center: CGPoint) {
    let attributes: [NSAttributedString.Key: Any] = [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName(font as CFString, size, nil), kCTForegroundColorAttributeName as NSAttributedString.Key: color]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    c.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
    CTLineDraw(line, c)
}

let designs: [String: (CGContext) -> Void] = [
    "ruled": { c in
        tile(c, top: paper, bottom: paperLow)
        for i in 0..<7 { c.setFillColor(rgb(0x9FB4C4, 0.35)); c.fill(CGRect(x: 100, y: 757 - CGFloat(i) * 92, width: 824, height: 6)) }
        c.setFillColor(rgb(sage)); c.fill(CGRect(x: 318, y: 100, width: 14, height: 824))
        for (i, width) in [432, 478, 350, 460, 267].enumerated() { bar(c, x: 382, y: 790 - CGFloat(i) * 92, width: CGFloat(width), height: 34, rgb(ink, 0.78)) }
    },
    "serif": { c in
        tile(c, top: paper, bottom: paperLow)
        c.setFillColor(rgb(sage)); c.fill(CGRect(x: 272, y: 100, width: 12, height: 824))
        glyph(c, "m", font: "Georgia", size: 560, color: rgb(ink), center: CGPoint(x: 580, y: 500))
    },
    "note": { c in
        tile(c, top: paper, bottom: paperLow)
        for (i, width) in [386, 423, 313, 405, 239].enumerated() { bar(c, x: 420, y: 720 - CGFloat(i) * 105, width: CGFloat(width), height: 38, rgb(ink, 0.75)) }
        c.setStrokeColor(rgb(sage)); c.setLineWidth(30); c.setLineCap(.round); c.setLineJoin(.round)
        c.move(to: CGPoint(x: 330, y: 740))
        c.addCurve(to: CGPoint(x: 290, y: 545), control1: CGPoint(x: 280, y: 720), control2: CGPoint(x: 310, y: 580))
        c.addCurve(to: CGPoint(x: 330, y: 350), control1: CGPoint(x: 310, y: 510), control2: CGPoint(x: 280, y: 370))
        c.strokePath()
        c.setFillColor(rgb(sage)); c.fillEllipse(in: CGRect(x: 200, y: 520, width: 50, height: 50))
    },
    "offset": { c in
        tile(c, top: sageLight, bottom: sageDeep)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.25))
        c.addPath(CGPath(roundedRect: CGRect(x: 360, y: 190, width: 480, height: 644), cornerWidth: 28, cornerHeight: 28, transform: nil)); c.setFillColor(rgb(paper)); c.fillPath()
        c.restoreGState()
        for (i, width) in [330, 360, 260, 340, 200].enumerated() { bar(c, x: 420, y: 730 - CGFloat(i) * 95, width: CGFloat(width), height: 30, rgb(ink, 0.55)) }
        bar(c, x: 190, y: 730, width: 110, height: 30, rgb(paper, 0.85))
    },
    "quote": { c in
        tile(c, top: sageLight, bottom: sageDeep)
        c.addPath(CGPath(roundedRect: CGRect(x: 290, y: 277, width: 44, height: 470), cornerWidth: 22, cornerHeight: 22, transform: nil)); c.setFillColor(rgb(quote)); c.fillPath()
        for (i, width) in [380, 430, 320, 400].enumerated() { bar(c, x: 400, y: 700 - CGFloat(i) * 125, width: CGFloat(width), height: 46, rgb(paper)) }
    },
    "night": { c in
        tile(c, top: 0x2A302C, bottom: 0x1B1F1D)
        c.setFillColor(rgb(0xA2B99A)); c.fill(CGRect(x: 318, y: 100, width: 12, height: 824))
        glyph(c, "m", font: "Georgia-Italic", size: 520, color: rgb(0xE9ECE3), center: CGPoint(x: 590, y: 500))
    },
]

func render(_ design: (CGContext) -> Void, size: Int, to url: URL) {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    design(context)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
}
for size in [16, 32, 128, 256, 512] {
    render(designs["night"]!, size: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    render(designs["night"]!, size: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
for (name, design) in designs { render(design, size: 512, to: choices.appendingPathComponent("\(name).png")) }
