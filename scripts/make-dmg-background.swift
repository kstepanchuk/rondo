// Draws the DMG window background (660×400 pt) at 1x and 2x.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let W: CGFloat = 660, H: CGFloat = 400
let red = NSColor(calibratedRed: 0.90, green: 0.16, blue: 0.19, alpha: 1)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)   // 2x rep keeps 660×400 pt
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.09, blue: 0.10, alpha: 1),
                        NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    NSGradient(colors: [red.withAlphaComponent(0.22), red.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 170, y: 210), radius: 0, toCenter: NSPoint(x: 170, y: 210), radius: 190, options: [])

    // Arrow from the app slot (x 170) to Applications (x 490), icon centres at y 210 (from bottom).
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: 210))
    arrow.line(to: NSPoint(x: 388, y: 210))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    let dash: [CGFloat] = [2, 9]
    arrow.setLineDash(dash, count: 2, phase: 0)
    NSColor(white: 1, alpha: 0.45).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 380, y: 222)); head.line(to: NSPoint(x: 396, y: 210)); head.line(to: NSPoint(x: 380, y: 198))
    head.lineWidth = 3; head.lineCapStyle = .round; head.lineJoinStyle = .round
    red.setStroke()
    head.stroke()

    // Light pills under the Finder labels (Finder draws them dark), icons 128 pt at y 190 from top.
    for x in [170.0, 490.0] {
        let pill = NSBezierPath(roundedRect: NSRect(x: x - 62, y: H - 282, width: 124, height: 24), xRadius: 12, yRadius: 12)
        NSColor(white: 1, alpha: 0.88).setFill()
        pill.fill()
    }

    func center(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, _ y: CGFloat) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                   .foregroundColor: color, .paragraphStyle: p])
            .draw(in: NSRect(x: 0, y: y, width: W, height: size * 1.5))
    }
    center("Перетащите Rondo в Applications", 17, .semibold, NSColor(white: 1, alpha: 0.9), 72)
    center("Drag Rondo to Applications to install", 12, .regular, NSColor(white: 1, alpha: 0.45), 50)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
try! render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
