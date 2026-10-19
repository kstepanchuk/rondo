import AppKit
import QuartzCore

/// A ring left at the drop point while an operation runs: spins, then fills
/// and turns into a check mark (or a red cross that shakes on error).
final class ProgressRing {
    private let panel: NSPanel
    private let ring = CAShapeLayer()
    private let track = CAShapeLayer()
    private let mark = CAShapeLayer()
    private static let size: CGFloat = 76

    init(at point: NSPoint) {
        let s = ProgressRing.size
        panel = NSPanel(contentRect: NSRect(x: point.x - s / 2, y: point.y - s / 2, width: s, height: s),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let pal = Palette.current
        let v = NSView(frame: NSRect(x: 0, y: 0, width: s, height: s))
        v.wantsLayer = true
        let root = v.layer!
        let bg = CALayer()
        bg.frame = root.bounds.insetBy(dx: 4, dy: 4)
        bg.cornerRadius = bg.frame.width / 2
        bg.backgroundColor = pal.background.cgColor
        bg.shadowOpacity = 0.3
        bg.shadowRadius = 8
        bg.shadowOffset = CGSize(width: 0, height: -2)
        root.addSublayer(bg)

        let circle = CGPath(ellipseIn: root.bounds.insetBy(dx: 16, dy: 16), transform: nil)
        for l in [track, ring] {
            l.frame = root.bounds
            l.path = circle
            l.fillColor = nil
            l.lineWidth = 4
            l.lineCap = .round
            root.addSublayer(l)
        }
        track.strokeColor = pal.stroke.withAlphaComponent(0.25).cgColor
        ring.strokeColor = pal.accent.cgColor
        ring.strokeStart = 0
        ring.strokeEnd = 0.28
        // Rotate around the centre; the path starts at 3 o'clock, start from 12.
        ring.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 2))

        mark.frame = root.bounds
        mark.fillColor = nil
        mark.lineWidth = 4
        mark.lineCap = .round
        mark.lineJoin = .round
        mark.strokeEnd = 0
        root.addSublayer(mark)

        panel.contentView = v
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = CGFloat.pi / 2
        spin.toValue = CGFloat.pi / 2 - 2 * .pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
    }

    func finish(success: Bool) {
        let pal = Palette.current
        let b = ring.bounds
        ring.removeAnimation(forKey: "spin")
        ring.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 2))
        if !success { ring.strokeColor = NSColor.systemRed.cgColor }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        ring.strokeEnd = 1
        CATransaction.commit()

        let path = CGMutablePath()
        if success {
            path.move(to: CGPoint(x: b.midX - 10, y: b.midY))
            path.addLine(to: CGPoint(x: b.midX - 3, y: b.midY - 7))
            path.addLine(to: CGPoint(x: b.midX + 11, y: b.midY + 8))
        } else {
            path.move(to: CGPoint(x: b.midX - 8, y: b.midY - 8)); path.addLine(to: CGPoint(x: b.midX + 8, y: b.midY + 8))
            path.move(to: CGPoint(x: b.midX - 8, y: b.midY + 8)); path.addLine(to: CGPoint(x: b.midX + 8, y: b.midY - 8))
        }
        mark.path = path
        mark.strokeColor = (success ? pal.accent : .systemRed).cgColor
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.beginTime = CACurrentMediaTime() + 0.2
        draw.duration = 0.25
        draw.fillMode = .backwards
        mark.strokeEnd = 1
        mark.add(draw, forKey: "draw")

        if let root = panel.contentView?.layer {
            if success {
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [1, 1.12, 1]
                pop.keyTimes = [0, 0.5, 1]
                pop.beginTime = CACurrentMediaTime() + 0.4
                pop.duration = 0.25
                root.sublayers?.forEach { $0.add(pop, forKey: "pop") }
            } else {
                let shake = CAKeyframeAnimation(keyPath: "position.x")
                let x = root.position.x
                shake.values = [x, x - 6, x + 6, x - 4, x + 4, x]
                shake.duration = 0.35
                shake.beginTime = CACurrentMediaTime() + 0.2
                root.add(shake, forKey: "shake")
            }
        }

        let p = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 },
                                                 completionHandler: { p.orderOut(nil) })
        }
    }
}
