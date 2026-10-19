// Renders docs/social-preview.png (1280×640) for the GitHub social preview.
import AppKit

let docs = URL(fileURLWithPath: CommandLine.arguments[1])
let W = 1280, H = 640
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let red = NSColor(calibratedRed: 0.90, green: 0.16, blue: 0.19, alpha: 1)
NSGradient(colors: [NSColor(calibratedRed: 0.09, green: 0.08, blue: 0.09, alpha: 1),
                    NSColor(calibratedRed: 0.03, green: 0.03, blue: 0.04, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -60)
// Soft red glow behind the wheel.
NSGradient(colors: [red.withAlphaComponent(0.28), red.withAlphaComponent(0)])!
    .draw(fromCenter: NSPoint(x: 940, y: 320), radius: 0, toCenter: NSPoint(x: 940, y: 320), radius: 320, options: [])

// Wheel on the right, inside the 40pt safe area.
if let menu = NSImage(contentsOf: docs.appendingPathComponent("menu-dark-en.png")) {
    menu.draw(in: NSRect(x: 940 - 240, y: 320 - 240, width: 480, height: 480))
}

// Left column: icon, name, tagline, keys.
if let icon = NSImage(contentsOf: docs.appendingPathComponent("icon.png")) {
    icon.draw(in: NSRect(x: 70, y: 448, width: 120, height: 120))
}
/// Draws text whose bottom edge sits at `y`.
func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, _ x: CGFloat, _ y: CGFloat) {
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        .draw(at: NSPoint(x: x, y: y))
}
text("Rondo", 92, .heavy, .white, 78, 320)
text("Drag a file, hold a key,\ndrop on a format.", 36, .semibold, NSColor(white: 1, alpha: 0.86), 82, 200)
text("File converter for macOS · free & open source", 21, .regular, NSColor(white: 1, alpha: 0.5), 82, 150)

// Key chips.
var x: CGFloat = 82
for (k, label) in [("⇧", "Convert"), ("⌃", "Tools"), ("⌥", "Actions")] {
    let s = NSAttributedString(string: "\(k)  \(label)", attributes: [
        .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white])
    let w = s.size().width + 28
    let chip = NSBezierPath(roundedRect: NSRect(x: x, y: 70, width: w, height: 40), xRadius: 20, yRadius: 20)
    (k == "⇧" ? red : NSColor(white: 1, alpha: 0.12)).setFill()
    chip.fill()
    s.draw(at: NSPoint(x: x + 14, y: 78))
    x += w + 12
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: docs.appendingPathComponent("social-preview.png"))
