// Draws the PodSD icon: a white "broadcast" mark (dot, stem, radiating arcs) on an indigo squircle.
// Usage: swift draw_icon.swift <out.png> <size> <app|favicon>
//   app     = macOS style: transparent margin around the squircle (824/1024) and a soft shadow
//   favicon = full-bleed rounded square, bolder mark so it survives at 16px
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 4, let px = Int(args[2]) else { print("usage: draw_icon <out.png> <size> <app|favicon>"); exit(1) }
let out = URL(fileURLWithPath: args[1])
let isApp = args[3] == "app"

let S = CGFloat(px)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.interpolationQuality = .high
ctx.setAllowsAntialiasing(true)

// Work in a 1024 design space, scaled to the requested size.
ctx.scaleBy(x: S / 1024, y: S / 1024)

let margin: CGFloat = isApp ? 100 : 0
let box = CGRect(x: margin, y: margin, width: 1024 - 2 * margin, height: 1024 - 2 * margin)
let radius = box.width * (isApp ? 0.225 : 0.22)
let body = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Soft shadow under the app icon body.
if isApp {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(body); ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
}

// Indigo gradient body.
ctx.saveGState()
ctx.addPath(body); ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.47, green: 0.38, blue: 1.00, alpha: 1),   // top
    CGColor(red: 0.17, green: 0.11, blue: 0.58, alpha: 1),   // bottom
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: box.maxY), end: CGPoint(x: 512, y: box.minY), options: [])
// Gentle top sheen.
let sheen = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: box.maxY), end: CGPoint(x: 512, y: box.midY), options: [])
ctx.restoreGState()

// The mark. Favicon gets a heavier stroke and fewer, larger parts.
let white = CGColor(gray: 1, alpha: 1)
let k: CGFloat = isApp ? 1.0 : 1.18                 // scale the mark up a little in the favicon
let cx: CGFloat = 512
let cy: CGFloat = isApp ? 575 : 560
let stroke: CGFloat = isApp ? 52 : 74
ctx.setStrokeColor(white); ctx.setFillColor(white)
ctx.setLineCap(.round); ctx.setLineWidth(stroke)

// Arcs left and right of the dot.
let radii: [CGFloat] = isApp ? [175 * k, 295 * k] : [190 * k, 330 * k]
let half: CGFloat = 50 * .pi / 180
for r in radii {
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: -half, endAngle: half, clockwise: false)
    ctx.strokePath()
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .pi - half, endAngle: .pi + half, clockwise: false)
    ctx.strokePath()
}

// Dot and stem.
let dot: CGFloat = (isApp ? 76 : 96) * k
ctx.fillEllipse(in: CGRect(x: cx - dot, y: cy - dot, width: 2 * dot, height: 2 * dot))
let stemW: CGFloat = isApp ? 76 : 104
let stemBottom: CGFloat = isApp ? 285 : 250
let stem = CGPath(roundedRect: CGRect(x: cx - stemW / 2, y: stemBottom, width: stemW, height: cy - stemBottom),
                  cornerWidth: stemW / 2, cornerHeight: stemW / 2, transform: nil)
ctx.addPath(stem); ctx.fillPath()

guard let img = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
