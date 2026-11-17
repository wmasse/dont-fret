import AppKit

// Draws the Don't Fret app icon ("Pick Wave"): a cream guitar pick on navy with a plucked string inside it.
// usage: swift scripts/make_icon.swift <out.png>   (1024 x 1024; see docs/DEVELOPING.md for making the .icns)

let S: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func col(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func linear(_ c: CGContext, _ cs: [CGColor], _ a: CGPoint, _ b: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: cs as CFArray, locations: nil)!
    c.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func radial(_ c: CGContext, _ cs: [CGColor], _ p: CGPoint, _ r: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: cs as CFArray, locations: nil)!
    c.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [.drawsAfterEndLocation])
}
func mix(_ a: UInt32, _ b: UInt32, _ f: CGFloat) -> CGColor {
    func ch(_ h: UInt32, _ s: UInt32) -> CGFloat { CGFloat((h >> s) & 255) / 255 }
    return CGColor(srgbRed: ch(a, 16) + (ch(b, 16) - ch(a, 16)) * f, green: ch(a, 8) + (ch(b, 8) - ch(a, 8)) * f,
                   blue: ch(a, 0) + (ch(b, 0) - ch(a, 0)) * f, alpha: 1)
}

// macOS icon shape: a superellipse on the standard 824 px grid.
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let n: CGFloat = 5
    for i in 0..<1440 {
        let t = CGFloat(i) / 1440 * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        let pt = P(r.midX + x * r.width / 2, r.midY + y * r.height / 2)
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

// Guitar pick, point down, centred on (512, 512).
func pickPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: P(512, 200))
    p.addCurve(to: P(240, 650), control1: P(415, 290), control2: P(240, 465))
    p.addCurve(to: P(512, 825), control1: P(240, 785), control2: P(375, 825))
    p.addCurve(to: P(784, 650), control1: P(649, 825), control2: P(784, 785))
    p.addCurve(to: P(512, 200), control1: P(784, 465), control2: P(609, 290))
    p.closeSubpath()
    return p
}

let c = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let shape = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))

// drop shadow + navy background
c.saveGState()
c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: col(0, 0.38))
c.addPath(shape); c.setFillColor(col(0)); c.fillPath()
c.restoreGState()
c.saveGState()
c.addPath(shape); c.clip()
linear(c, [col(0x1B2C5C), col(0x0A1024)], P(0, 924), P(0, 100))
radial(c, [col(0x6A7CFF, 0.30), col(0x6A7CFF, 0)], P(512, 512), 420)

// the pick
let pick = pickPath()
c.saveGState()
c.setShadow(offset: .zero, blur: 60, color: col(0x8F6BFF, 0.6))
c.addPath(pick); c.setFillColor(col(0xFFF7EE)); c.fillPath()
c.restoreGState()
c.saveGState()
c.addPath(pick); c.clip()
linear(c, [col(0xFFFFFF), col(0xF6E6D8)], P(0, 830), P(0, 200))

// the plucked string: frozen positions of a standing wave
let a = P(250, 580), b = P(774, 580)
c.setLineCap(.round); c.setLineJoin(.round)
for k in 0...8 {
    let f = CGFloat(k) / 8
    let amp = 150 * cos(f * .pi)
    let path = CGMutablePath()
    path.move(to: a)
    var x = a.x
    while x < b.x {
        x = min(b.x, x + 4)
        path.addLine(to: P(x, a.y + amp * sin(.pi * (x - a.x) / (b.x - a.x))))
    }
    let edge = k == 0 || k == 8
    c.addPath(path)
    c.setStrokeColor(mix(0x2B7BFF, 0x8F4BFF, f).copy(alpha: edge ? 1 : 0.5)!)
    c.setLineWidth(edge ? 16 : 9)
    c.strokePath()
}
c.restoreGState()

// hairline rim
c.addPath(squircle(CGRect(x: 101.5, y: 101.5, width: 821, height: 821)))
c.setStrokeColor(col(0xFFFFFF, 0.12)); c.setLineWidth(3); c.strokePath()
c.restoreGState()

let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
