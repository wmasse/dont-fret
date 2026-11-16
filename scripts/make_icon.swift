import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Squircle background with gradient
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill(); bg.fill()
ctx.restoreGState()
bg.addClip()
let grad = NSGradient(colors: [NSColor(red: 1.0, green: 0.68, blue: 0.30, alpha: 1), NSColor(red: 0.98, green: 0.33, blue: 0.40, alpha: 1), NSColor(red: 0.55, green: 0.22, blue: 0.62, alpha: 1)],
                      atLocations: [0, 0.6, 1], colorSpace: .sRGB)!
grad.draw(in: rect, angle: -60)
// soft highlight
let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
glow.draw(in: NSBezierPath(ovalIn: CGRect(x: 120, y: 520, width: 640, height: 520)), relativeCenterPosition: .zero)

// Guitar pick
let pick = NSBezierPath()
let cx = size / 2
pick.move(to: CGPoint(x: cx, y: 215))
pick.curve(to: CGPoint(x: 250, y: 650), controlPoint1: CGPoint(x: 420, y: 300), controlPoint2: CGPoint(x: 250, y: 470))
pick.curve(to: CGPoint(x: cx, y: 815), controlPoint1: CGPoint(x: 250, y: 780), controlPoint2: CGPoint(x: 380, y: 815))
pick.curve(to: CGPoint(x: 774, y: 650), controlPoint1: CGPoint(x: 644, y: 815), controlPoint2: CGPoint(x: 774, y: 780))
pick.curve(to: CGPoint(x: cx, y: 215), controlPoint1: CGPoint(x: 774, y: 470), controlPoint2: CGPoint(x: 604, y: 300))
pick.close()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: NSColor.black.withAlphaComponent(0.3).cgColor)
NSColor(white: 1, alpha: 0.97).setFill(); pick.fill()
ctx.restoreGState()

// Chord grid on the pick
let ink = NSColor(red: 0.13, green: 0.12, blue: 0.16, alpha: 1)
let gx: CGFloat = 372, gw: CGFloat = 280, gTop: CGFloat = 700, gh: CGFloat = 330
ink.withAlphaComponent(0.85).setStroke()
for s in 0..<6 {
    let x = gx + CGFloat(s) * gw / 5
    let p = NSBezierPath(); p.move(to: CGPoint(x: x, y: gTop)); p.line(to: CGPoint(x: x, y: gTop - gh)); p.lineWidth = 7; p.stroke()
}
for f in 0...4 {
    let y = gTop - CGFloat(f) * gh / 4
    let p = NSBezierPath(); p.move(to: CGPoint(x: gx, y: y)); p.line(to: CGPoint(x: gx + gw, y: y)); p.lineWidth = f == 0 ? 20 : 6; p.stroke()
}
// dots (G chord-ish)
let dotGrad = NSGradient(colors: [NSColor(red: 1.0, green: 0.62, blue: 0.27, alpha: 1), NSColor(red: 0.98, green: 0.33, blue: 0.42, alpha: 1)])!
for (s, f) in [(0, 3), (1, 2), (5, 3)] {
    let x = gx + CGFloat(s) * gw / 5
    let y = gTop - (CGFloat(f) - 0.5) * gh / 4
    let r: CGFloat = 34
    dotGrad.draw(in: NSBezierPath(ovalIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), angle: -90)
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
