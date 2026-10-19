// Draws the Rondo app icon (red radial menu on a dark squircle) into an .iconset.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.13, alpha: 1),
                        NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: 1)])!.draw(in: bg, angle: -90)

    let c = NSPoint(x: s / 2, y: s / 2)
    let outer = rect.width * 0.36, inner = rect.width * 0.15
    let n = 6, step = 360.0 / Double(n), gap = 4.0
    for i in 0..<n {
        let start = CGFloat(90 - Double(i) * step - gap), end = CGFloat(90 - Double(i + 1) * step + gap)
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: outer, startAngle: start, endAngle: end, clockwise: true)
        p.appendArc(withCenter: c, radius: inner + rect.width * 0.03, startAngle: end, endAngle: start, clockwise: false)
        p.close()
        (i == 0 ? NSColor(calibratedRed: 0.90, green: 0.16, blue: 0.19, alpha: 1)
                : NSColor(white: 1, alpha: 0.14)).setFill()
        p.fill()
    }
    NSColor(calibratedRed: 0.90, green: 0.16, blue: 0.19, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - inner * 0.55, y: c.y - inner * 0.55, width: inner * 1.1, height: inner * 1.1)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = draw(base * scale).representation(using: .png, properties: [:])!
        try! data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
    }
}
