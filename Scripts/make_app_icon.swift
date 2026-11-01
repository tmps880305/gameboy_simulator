// Renders the GBEmu app icon (1024×1024 PNG) with CoreGraphics.
// Usage: swift Scripts/make_app_icon.swift <output.png>
//
// Original artwork: a generic handheld face with a pixel-art lightning bolt
// (a nod to fast-forward) on a four-shade green LCD.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!
// Use a top-left origin so coordinates read like a design spec.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ path: CGPath, _ fillColor: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(fillColor)
    ctx.fillPath()
}

func withShadow(offset: CGFloat, blur: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: offset), blur: blur, color: color(0x000000, alpha))
    draw()
    ctx.restoreGState()
}

// Body: diagonal purple gradient.
let body = CGGradient(colorsSpace: space, colors: [color(0x7B5CFF), color(0x3B1F9E)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(body, start: .zero, end: CGPoint(x: size, y: size), options: [])
// Soft highlight in the top-left.
let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 220, y: 160), startRadius: 0, endCenter: CGPoint(x: 220, y: 160), endRadius: 700, options: [])

// Screen bezel and 10:9 LCD.
let bezel = CGRect(x: 172, y: 112, width: 680, height: 560)
withShadow(offset: 14, blur: 30, alpha: 0.35) {
    fill(roundedRect(bezel, 56), color(0x23213A))
}
let lcd = CGRect(x: 262, y: 166, width: 500, height: 450)
fill(roundedRect(lcd, 14), color(0x9BBC0F))

// Pixel-art lightning bolt (12×12 grid).
let bolt = [
    "........###.",
    ".......###..",
    "......###...",
    ".....###....",
    "....###.....",
    "...########.",
    "......###...",
    ".....###....",
    "....###.....",
    "...###......",
    "..##........",
    ".#..........",
]
let cell: CGFloat = 32
let gridOrigin = CGPoint(x: lcd.midX - cell * 6.5, y: lcd.midY - cell * 6)
for (row, line) in bolt.enumerated() {
    for (column, char) in line.enumerated() where char == "#" {
        let rect = CGRect(x: gridOrigin.x + CGFloat(column) * cell, y: gridOrigin.y + CGFloat(row) * cell, width: cell, height: cell)
        // Drop shadow pixel in the mid-dark shade, then the bolt itself.
        ctx.setFillColor(color(0x306230))
        ctx.fill(rect.offsetBy(dx: 12, dy: 12))
    }
}
for (row, line) in bolt.enumerated() {
    for (column, char) in line.enumerated() where char == "#" {
        let rect = CGRect(x: gridOrigin.x + CGFloat(column) * cell, y: gridOrigin.y + CGFloat(row) * cell, width: cell, height: cell)
        ctx.setFillColor(color(0x0F380F))
        ctx.fill(rect)
    }
}

// D-pad.
let dpadCenter = CGPoint(x: 312, y: 832)
let arm: CGFloat = 74
let span: CGFloat = 230
withShadow(offset: 10, blur: 18, alpha: 0.35) {
    let cross = CGMutablePath()
    cross.addPath(roundedRect(CGRect(x: dpadCenter.x - span / 2, y: dpadCenter.y - arm / 2, width: span, height: arm), 16))
    cross.addPath(roundedRect(CGRect(x: dpadCenter.x - arm / 2, y: dpadCenter.y - span / 2, width: arm, height: span), 16))
    fill(cross, color(0x1C1A2E))
}

// Face buttons on a diagonal.
for (center, hex) in [(CGPoint(x: 650, y: 872), UInt32(0xFF4F8B)), (CGPoint(x: 790, y: 792), UInt32(0xFF4F8B))] {
    withShadow(offset: 10, blur: 18, alpha: 0.35) {
        fill(CGPath(ellipseIn: CGRect(x: center.x - 60, y: center.y - 60, width: 120, height: 120), transform: nil), color(hex))
    }
    // Specular highlight.
    fill(CGPath(ellipseIn: CGRect(x: center.x - 34, y: center.y - 44, width: 46, height: 30), transform: nil), color(0xFFFFFF, 0.35))
}

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: output)
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Failed to write \(output)")
}
print("Wrote \(output)")
