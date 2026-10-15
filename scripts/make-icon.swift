import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func render(_ size: Int, to url: URL) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.16))
    context.addPath(shape); context.setFillColor(CGColor(red: 0.24, green: 0.36, blue: 0.28, alpha: 1)); context.fillPath()
    context.restoreGState()
    context.saveGState(); context.addPath(shape); context.clip()
    let gradient = CGGradient(colorsSpace: colorSpace, colors: [CGColor(red: 0.40, green: 0.52, blue: 0.40, alpha: 1), CGColor(red: 0.22, green: 0.34, blue: 0.27, alpha: 1)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 700, y: 100), options: [])
    context.restoreGState()
    context.setStrokeColor(CGColor(red: 0.98, green: 0.97, blue: 0.92, alpha: 1))
    context.setLineWidth(65); context.setLineCap(.round); context.setLineJoin(.round)
    context.move(to: CGPoint(x: 285, y: 350)); context.addLine(to: CGPoint(x: 285, y: 670)); context.addLine(to: CGPoint(x: 425, y: 480)); context.addLine(to: CGPoint(x: 565, y: 670)); context.addLine(to: CGPoint(x: 565, y: 350)); context.strokePath()
    context.setLineWidth(52)
    context.move(to: CGPoint(x: 735, y: 660)); context.addLine(to: CGPoint(x: 735, y: 355)); context.strokePath()
    context.move(to: CGPoint(x: 659, y: 425)); context.addLine(to: CGPoint(x: 735, y: 349)); context.addLine(to: CGPoint(x: 811, y: 425)); context.strokePath()
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
}
for size in [16, 32, 128, 256, 512] {
    render(size, to: directory.appendingPathComponent("icon_\(size)x\(size).png"))
    render(size * 2, to: directory.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
