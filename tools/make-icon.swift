// Draws the app icon: four corner brackets and one green status light on black.
//   swift tools/make-icon.swift ios/Cleanroom/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Brackets, like the corners of a viewfinder or an instrument panel.
let inset: CGFloat = 248, arm: CGFloat = 132, stroke: CGFloat = 30
context.setStrokeColor(CGColor(red: 0.949, green: 0.953, blue: 0.961, alpha: 1))
context.setLineWidth(stroke)
context.setLineCap(.butt)
context.setLineJoin(.miter)
let low = inset, high = CGFloat(size) - inset
for (x, y, dx, dy) in [(low, low, 1.0, 1.0), (high, low, -1.0, 1.0), (low, high, 1.0, -1.0), (high, high, -1.0, -1.0)] {
    context.move(to: CGPoint(x: x + CGFloat(dx) * arm, y: y))
    context.addLine(to: CGPoint(x: x, y: y))
    context.addLine(to: CGPoint(x: x, y: y + CGFloat(dy) * arm))
    context.strokePath()
}

// The status light: the one accent color, used for "verified clean".
let light: CGFloat = 148
context.setFillColor(CGColor(red: 0.271, green: 0.878, blue: 0.541, alpha: 1))
context.fill(CGRect(x: (CGFloat(size) - light) / 2, y: (CGFloat(size) - light) / 2, width: light, height: light))

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
