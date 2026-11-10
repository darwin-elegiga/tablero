import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Cork tile (macOS icon grid: 824px body with ~100px margin)
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 24
shadow.set()
NSColor(red: 0.42, green: 0.27, blue: 0.14, alpha: 1).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()

let cork = NSBezierPath(roundedRect: body.insetBy(dx: 34, dy: 34), xRadius: 150, yRadius: 150)
NSGradient(starting: NSColor(red: 0.85, green: 0.65, blue: 0.42, alpha: 1),
           ending: NSColor(red: 0.74, green: 0.53, blue: 0.31, alpha: 1))!.draw(in: cork, angle: -90)

// Cork speckles
NSGraphicsContext.saveGraphicsState()
cork.addClip()
var seed: UInt64 = 42
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
for _ in 0..<420 {
    let r = 3 + rnd() * 6
    NSColor(red: 0.45, green: 0.28, blue: 0.12, alpha: 0.18 + rnd() * 0.2).setFill()
    NSBezierPath(ovalIn: NSRect(x: 130 + rnd() * 770, y: 130 + rnd() * 770, width: r, height: r)).fill()
}
NSGraphicsContext.restoreGraphicsState()

// Sticky note, tilted
ctx.saveGState()
ctx.translateBy(x: 512, y: 500)
ctx.rotate(by: -0.10)
let note = NSRect(x: -250, y: -250, width: 500, height: 500)
NSGraphicsContext.saveGraphicsState()
let noteShadow = NSShadow()
noteShadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
noteShadow.shadowOffset = NSSize(width: 6, height: -18)
noteShadow.shadowBlurRadius = 26
noteShadow.set()
let notePath = NSBezierPath()
notePath.move(to: NSPoint(x: note.minX, y: note.maxY))
notePath.line(to: NSPoint(x: note.maxX, y: note.maxY))
notePath.line(to: NSPoint(x: note.maxX, y: note.minY + 70))
notePath.curve(to: NSPoint(x: note.maxX - 70, y: note.minY),
               controlPoint1: NSPoint(x: note.maxX - 10, y: note.minY + 30),
               controlPoint2: NSPoint(x: note.maxX - 40, y: note.minY + 8))
notePath.line(to: NSPoint(x: note.minX, y: note.minY))
notePath.close()
NSGradient(starting: NSColor(red: 1.0, green: 0.94, blue: 0.45, alpha: 1),
           ending: NSColor(red: 1.0, green: 0.87, blue: 0.30, alpha: 1))!.draw(in: notePath, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Checklist lines on the note
let ink = NSColor(red: 0.30, green: 0.25, blue: 0.18, alpha: 0.85)
for (i, done) in [true, true, false].enumerated() {
    let y = note.maxY - 175 - CGFloat(i) * 105
    let box = NSBezierPath(roundedRect: NSRect(x: note.minX + 60, y: y - 26, width: 56, height: 56), xRadius: 10, yRadius: 10)
    box.lineWidth = 12
    ink.setStroke()
    box.stroke()
    if done {
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: note.minX + 70, y: y + 2))
        tick.line(to: NSPoint(x: note.minX + 88, y: y - 18))
        tick.line(to: NSPoint(x: note.minX + 128, y: y + 34))
        tick.lineWidth = 16
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round
        NSColor(red: 0.16, green: 0.55, blue: 0.27, alpha: 1).setStroke()
        tick.stroke()
    }
    let line = NSBezierPath()
    line.move(to: NSPoint(x: note.minX + 150, y: y + 2))
    line.line(to: NSPoint(x: note.maxX - (done ? 120 : 60), y: y + 2))
    line.lineWidth = 18
    line.lineCapStyle = .round
    ink.withAlphaComponent(done ? 0.35 : 0.85).setStroke()
    line.stroke()
}

// Red push pin
let pinCenter = NSPoint(x: 0, y: note.maxY - 40)
NSGraphicsContext.saveGraphicsState()
let pinShadow = NSShadow()
pinShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
pinShadow.shadowOffset = NSSize(width: 10, height: -14)
pinShadow.shadowBlurRadius = 12
pinShadow.set()
let pin = NSBezierPath(ovalIn: NSRect(x: pinCenter.x - 58, y: pinCenter.y - 58, width: 116, height: 116))
NSGradient(starting: NSColor(red: 0.98, green: 0.36, blue: 0.33, alpha: 1),
           ending: NSColor(red: 0.72, green: 0.10, blue: 0.12, alpha: 1))!.draw(in: pin, relativeCenterPosition: NSPoint(x: -0.35, y: 0.35))
NSGraphicsContext.restoreGraphicsState()
NSColor.white.withAlphaComponent(0.7).setFill()
NSBezierPath(ovalIn: NSRect(x: pinCenter.x - 32, y: pinCenter.y + 8, width: 30, height: 22)).fill()
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
