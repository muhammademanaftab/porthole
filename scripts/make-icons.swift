import AppKit
import CoreGraphics
import Foundation

struct Palette {
    var top: CGColor
    var bottom: CGColor
    var glassTop: CGColor
    var glassBottom: CGColor
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

let viewer = Palette(top: rgb(0x2F86F0), bottom: rgb(0x0B2A6F), glassTop: rgb(0xA9E4FF), glassBottom: rgb(0x2D7FE0))

func gradient(_ ctx: CGContext, _ a: CGColor, _ b: CGColor, from p0: CGPoint, to p1: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a, b] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func draw(_ p: Palette, pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(p.bottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    gradient(ctx, p.top, p.bottom, from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    ctx.restoreGState()

    let c = CGPoint(x: 512, y: 500)
    let outer: CGFloat = 300, inner: CGFloat = 214

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.4))
    ctx.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
    ctx.setFillColor(rgb(0xDDE3EA))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    let ring = CGMutablePath()
    ring.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
    ring.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
    ctx.addPath(ring)
    ctx.clip(using: .evenOdd)
    gradient(ctx, rgb(0xFBFCFD), rgb(0x9AA6B4), from: CGPoint(x: c.x - 200, y: c.y + outer), to: CGPoint(x: c.x + 200, y: c.y - outer))
    ctx.restoreGState()

    ctx.setStrokeColor(rgb(0x6B7685, 0.55))
    ctx.setLineWidth(4)
    ctx.strokeEllipse(in: CGRect(x: c.x - inner - 2, y: c.y - inner - 2, width: inner * 2 + 4, height: inner * 2 + 4))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.7))
    ctx.setLineWidth(3)
    ctx.strokeEllipse(in: CGRect(x: c.x - outer + 2, y: c.y - outer + 2, width: outer * 2 - 4, height: outer * 2 - 4))

    let boltR: CGFloat = (outer + inner) / 2
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4 + .pi / 8
        let b = CGPoint(x: c.x + cos(a) * boltR, y: c.y + sin(a) * boltR)
        ctx.setFillColor(rgb(0x7D8896))
        ctx.fillEllipse(in: CGRect(x: b.x - 15, y: b.y - 15, width: 30, height: 30))
        ctx.setFillColor(rgb(0xEEF2F6))
        ctx.fillEllipse(in: CGRect(x: b.x - 11, y: b.y - 7, width: 18, height: 18))
    }

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
    ctx.clip()
    gradient(ctx, p.glassTop, p.glassBottom, from: CGPoint(x: c.x, y: c.y + inner), to: CGPoint(x: c.x, y: c.y - inner))

    let win = CGRect(x: c.x - 132, y: c.y - 110, width: 264, height: 190)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x000000, 0.28))
    ctx.addPath(CGPath(roundedRect: win, cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: win, cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.clip()
    ctx.setFillColor(rgb(0xE9EEF4))
    ctx.fill(CGRect(x: win.minX, y: win.maxY - 46, width: win.width, height: 46))
    ctx.restoreGState()
    for (i, color) in [rgb(0xFF5F57), rgb(0xFEBC2E), rgb(0x28C840)].enumerated() {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: win.minX + 22 + CGFloat(i) * 32, y: win.maxY - 33, width: 20, height: 20))
    }
    ctx.setFillColor(p.waves ? rgb(0xF4A261, 0.55) : rgb(0x8EC5FF, 0.6))
    for row in 0..<3 {
        let w: CGFloat = row == 2 ? 120 : 200
        ctx.addPath(CGPath(roundedRect: CGRect(x: win.minX + 30, y: win.maxY - 86 - CGFloat(row) * 32, width: w, height: 14),
                           cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.fillPath()
    }

    ctx.setFillColor(rgb(0xFFFFFF, 0.22))
    let shine = CGMutablePath()
    shine.addArc(center: c, radius: inner - 18, startAngle: .pi * 0.58, endAngle: .pi * 0.98, clockwise: false)
    shine.addArc(center: c, radius: inner - 52, startAngle: .pi * 0.98, endAngle: .pi * 0.58, clockwise: true)
    shine.closeSubpath()
    ctx.addPath(shine)
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets")
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                              ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, palette) in [("Porthole", viewer)] {
    let set = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).iconset")
    try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for (suffix, px) in sizes { writePNG(draw(palette, pixels: px), to: set.appendingPathComponent("icon_\(suffix).png")) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", set.path, "-o", out.appendingPathComponent("\(name).icns").path]
    try! p.run()
    p.waitUntilExit()
    try? FileManager.default.removeItem(at: set)
    print("\(name).icns", p.terminationStatus == 0 ? "ok" : "failed")
    if p.terminationStatus != 0 { exit(1) }
}
