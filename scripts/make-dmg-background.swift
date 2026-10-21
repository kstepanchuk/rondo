// Draws the DMG window background (660×600 pt) at 1x and 2x.
// Icons (128 pt) sit at Rondo (170, 170), Applications (490, 170) and
// the "allow launch" script (330, 430), in Finder's top-down coordinates.
//
// Resources/dmg/background.tiff = both sizes, JPEG 92 → LZW RGB TIFF, ~450 KB:
//   for f in background background@2x; do
//     sips -s format jpeg -s formatOptions 92 $f.png --out $f.jpg
//     sips -s format tiff -s formatOptions lzw $f.jpg --out $f-rgb.tiff
//   done
//   tiffutil -cathidpicheck background-rgb.tiff background@2x-rgb.tiff -out background.tiff
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let W: CGFloat = 660, H: CGFloat = 600
let red = NSColor(calibratedRed: 0.90, green: 0.16, blue: 0.19, alpha: 1)

/// Converts Finder's top-down y to AppKit's bottom-up y.
func y(_ top: CGFloat) -> CGFloat { H - top }

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)   // 2x rep keeps 660×600 pt
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.09, blue: 0.10, alpha: 1),
                        NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    NSGradient(colors: [red.withAlphaComponent(0.22), red.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 170, y: y(170)), radius: 0, toCenter: NSPoint(x: 170, y: y(170)), radius: 190, options: [])

    // Arrow from Rondo to Applications.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: y(170)))
    arrow.line(to: NSPoint(x: 388, y: y(170)))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    let dash: [CGFloat] = [2, 9]
    arrow.setLineDash(dash, count: 2, phase: 0)
    NSColor(white: 1, alpha: 0.45).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 380, y: y(158))); head.line(to: NSPoint(x: 396, y: y(170))); head.line(to: NSPoint(x: 380, y: y(182)))
    head.lineWidth = 3; head.lineCapStyle = .round; head.lineJoinStyle = .round
    red.setStroke()
    head.stroke()

    // Light pills under the Finder labels (Finder draws them dark on a dark background).
    func pill(_ x: CGFloat, _ top: CGFloat, width: CGFloat = 124) {
        NSColor(white: 1, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: NSRect(x: x - width / 2, y: y(top + 24), width: width, height: 24),
                     xRadius: 12, yRadius: 12).fill()
    }
    pill(170, 240)
    pill(490, 240)
    pill(330, 500, width: 176)

    func center(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, top: CGFloat) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                   .foregroundColor: color, .paragraphStyle: p])
            .draw(in: NSRect(x: 0, y: y(top + size * 1.4), width: W, height: size * 1.4))
    }
    center("Перетащите Rondo в Applications", 17, .semibold, NSColor(white: 1, alpha: 0.9), top: 284)
    center("Drag Rondo to Applications to install", 12, .regular, NSColor(white: 1, alpha: 0.45), top: 312)

    // Divider, then the Gatekeeper helper.
    NSColor(white: 1, alpha: 0.08).setFill()
    NSRect(x: 120, y: y(344), width: W - 240, height: 1).fill()
    center("Не открывается? Перетащите «Разрешить запуск» в Терминал и нажмите Enter", 12, .medium,
           NSColor(white: 1, alpha: 0.75), top: 536)
    center("Won't open? Drag “Разрешить запуск” into Terminal and press Return", 11, .regular,
           NSColor(white: 1, alpha: 0.4), top: 556)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
try! render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
