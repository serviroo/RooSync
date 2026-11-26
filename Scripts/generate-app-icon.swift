import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = CommandLine.arguments.dropFirst().first
    ?? "RooSync/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let bounds = CGRect(x: 0, y: 0, width: size, height: size)
let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let colors = [
    CGColor(red: 0.08, green: 0.15, blue: 0.27, alpha: 1),
    CGColor(red: 0.03, green: 0.07, blue: 0.14, alpha: 1)
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 1024), end: CGPoint(x: 930, y: 0), options: [])

context.setFillColor(CGColor(red: 0.10, green: 0.24, blue: 0.39, alpha: 0.4))
context.fillEllipse(in: CGRect(x: 142, y: 142, width: 740, height: 740))

context.setStrokeColor(CGColor(red: 0.30, green: 0.82, blue: 0.95, alpha: 1))
context.setLineWidth(28)
context.setLineCap(.round)
let upperArc = CGMutablePath()
upperArc.addArc(center: CGPoint(x: 512, y: 512), radius: 370, startAngle: .pi * 0.18, endAngle: .pi * 0.91, clockwise: false)
context.addPath(upperArc)
context.strokePath()

context.setStrokeColor(CGColor(red: 1, green: 0.55, blue: 0.34, alpha: 1))
let lowerArc = CGMutablePath()
lowerArc.addArc(center: CGPoint(x: 512, y: 512), radius: 370, startAngle: .pi * 1.18, endAngle: .pi * 1.91, clockwise: false)
context.addPath(lowerArc)
context.strokePath()

func fill(_ points: [CGPoint], color: CGColor) {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    context.addPath(path)
    context.setFillColor(color)
    context.fillPath()
}

fill([CGPoint(x: 306, y: 730), CGPoint(x: 358, y: 886), CGPoint(x: 474, y: 755)], color: CGColor(gray: 0.98, alpha: 1))
fill([CGPoint(x: 718, y: 730), CGPoint(x: 666, y: 886), CGPoint(x: 550, y: 755)], color: CGColor(gray: 0.98, alpha: 1))

let face = CGMutablePath()
face.move(to: CGPoint(x: 512, y: 784))
face.addCurve(to: CGPoint(x: 314, y: 570), control1: CGPoint(x: 344, y: 777), control2: CGPoint(x: 296, y: 681))
face.addCurve(to: CGPoint(x: 512, y: 374), control1: CGPoint(x: 324, y: 420), control2: CGPoint(x: 409, y: 374))
face.addCurve(to: CGPoint(x: 710, y: 570), control1: CGPoint(x: 615, y: 374), control2: CGPoint(x: 700, y: 420))
face.addCurve(to: CGPoint(x: 512, y: 784), control1: CGPoint(x: 728, y: 681), control2: CGPoint(x: 680, y: 777))
face.closeSubpath()
context.addPath(face)
context.setFillColor(CGColor(gray: 0.98, alpha: 1))
context.fillPath()

context.setFillColor(CGColor(red: 0.08, green: 0.15, blue: 0.25, alpha: 1))
context.fillEllipse(in: CGRect(x: 410, y: 576, width: 24, height: 36))
context.fillEllipse(in: CGRect(x: 590, y: 576, width: 24, height: 36))
context.setFillColor(CGColor(red: 1, green: 0.55, blue: 0.34, alpha: 1))
context.fillEllipse(in: CGRect(x: 493, y: 492, width: 38, height: 24))

fill([CGPoint(x: 235, y: 780), CGPoint(x: 275, y: 742), CGPoint(x: 285, y: 793)], color: CGColor(red: 0.30, green: 0.82, blue: 0.95, alpha: 1))
fill([CGPoint(x: 789, y: 244), CGPoint(x: 749, y: 282), CGPoint(x: 739, y: 231)], color: CGColor(red: 1, green: 0.55, blue: 0.34, alpha: 1))

let image = context.makeImage()!
let url = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
precondition(CGImageDestinationFinalize(destination))
