import AppKit

/// What was dragged, as far as we can tell before the drop.
enum Payload {
    static func kinds(of pb: NSPasteboard) -> [Kind] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map(Kind.of)
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            return promises.flatMap { $0.fileTypes.map(Kind.of(uti:)) }
        }
        if NSImage.canInit(with: pb) { return [.image] }
        if pb.string(forType: .string) != nil { return [.document] }
        return []
    }

    /// Turns the drop into real files: file URLs as is, file promises and raw
    /// images/text saved into ~/Downloads/Rondo first.
    static func resolve(_ pb: NSPasteboard, _ done: @escaping ([URL]) -> Void) {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return done(urls)
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            let group = DispatchGroup()
            var got: [URL] = []
            let lock = NSLock()
            let queue = OperationQueue()
            for p in promises {
                group.enter()
                p.receivePromisedFiles(atDestination: Paths.output, options: [:], operationQueue: queue) { url, err in
                    if err == nil { lock.lock(); got.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { done(got) }
            return
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = L("Вложение ", "Attachment ") + stamp.string(from: Date())
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let u = Paths.unique(Paths.output, base, "png")
            if (try? png.write(to: u)) != nil { return done([u]) }
        }
        if let s = pb.string(forType: .string) {
            let u = Paths.unique(Paths.output, base, "txt")
            if (try? s.write(to: u, atomically: true, encoding: .utf8)) != nil { return done([u]) }
        }
        done([])
    }
}

// MARK: - Panel

final class RadialPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class RadialController {
    static let shared = RadialController()

    private let size: CGFloat = 380
    private lazy var panel: RadialPanel = {
        let p = RadialPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = view
        // Click mode: clicking elsewhere closes the menu.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) {
            [weak self] _ in if self?.files != nil { self?.hide() }
        }
        return p
    }()
    private let view = RadialView()

    private(set) var isVisible = false
    /// Files for click mode (hotkey). nil while showing for a drag.
    private var files: [URL]?
    private var kinds: [Kind] = []

    func showForDrag(kinds: [Kind], mode: Mode) {
        files = nil
        present(kinds: kinds, mode: mode, interactive: false)
    }

    func showForClick(files: [URL]) {
        self.files = files
        present(kinds: files.map(Kind.of), mode: .convert, interactive: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    private func present(kinds: [Kind], mode: Mode, interactive: Bool) {
        self.kinds = kinds
        view.interactive = interactive
        view.palette = .current
        setMode(mode)
        let m = NSEvent.mouseLocation
        var frame = NSRect(x: m.x - size / 2, y: m.y - size / 2, width: size, height: size)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(m) }) {
            let vf = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, vf.minX), vf.maxX - size)
            frame.origin.y = min(max(frame.minY, vf.minY), vf.maxY - size)
        }
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        view.animateIn()
        panel.orderFrontRegardless()
        isVisible = true
    }

    func setMode(_ mode: Mode) {
        guard view.mode != mode || view.operations.isEmpty else { return }
        view.mode = mode
        view.operations = Catalog.operations(kinds: kinds, mode: mode)
        view.hovered = nil
        if isVisible { view.animateIn(fast: true) } else { view.needsDisplay = true }
    }

    func cycleMode() {
        setMode(Mode(rawValue: (view.mode.rawValue + 1) % Mode.allCases.count)!)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        files = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
        })
    }

    /// Called by the view when a sector is chosen.
    func choose(_ op: Operation, pasteboard: NSPasteboard?) {
        let clicked = files
        let at = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        hide()
        if let clicked { return Runner.run(op, clicked, at: at) }
        guard let pb = pasteboard else { return }
        Payload.resolve(pb) { urls in
            guard !urls.isEmpty else { return }
            Runner.run(op, urls, at: at)
        }
    }
}

// MARK: - View

final class RadialView: NSView {
    var mode: Mode = .convert
    var operations: [Operation] = []
    var hovered: Int?
    var interactive = false
    var palette = Palette.current

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var outer: CGFloat { bounds.width / 2 - 14 }
    private let inner: CGFloat = 58
    private var trackingArea: NSTrackingArea?

    // Animation: `appear` 0→1 unfolds the sectors; `lift[i]` 0→1 pushes the hovered sector out.
    private var appear: CGFloat = 1
    private var appearStart = Date()
    private var appearDuration: TimeInterval = 0.32
    private var lift: [CGFloat] = []
    private var animTimer: Timer?

    /// Static, fully-open rendering for README screenshots (`--render-menu`).
    func renderPNG(hover: Int?) -> Data? {
        appear = 1
        hovered = hover
        lift = operations.indices.map { $0 == hover ? 1 : 0 }
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    func animateIn(fast: Bool = false) {
        appear = 0
        appearStart = Date()
        appearDuration = fast ? 0.18 : 0.32
        lift = Array(repeating: 0, count: operations.count)
        startTimer()
    }

    private func startTimer() {
        guard animTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // keeps running during drag sessions
        animTimer = t
    }

    private func tick() {
        appear = min(1, CGFloat(Date().timeIntervalSince(appearStart) / appearDuration))
        if lift.count != operations.count { lift = Array(repeating: 0, count: operations.count) }
        var settled = appear >= 1
        for i in lift.indices {
            let target: CGFloat = i == hovered ? 1 : 0
            lift[i] += (target - lift[i]) * 0.28
            if abs(target - lift[i]) > 0.005 { settled = false } else { lift[i] = target }
        }
        needsDisplay = true
        if settled { animTimer?.invalidate(); animTimer = nil }
    }

    private static func easeOutBack(_ t: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
    private static func easeOut(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png,
                                 NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")]
                                + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let t = trackingArea { removeTrackingArea(t) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
                                      owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    // MARK: Geometry

    private var step: CGFloat { 360 / CGFloat(max(operations.count, 1)) }

    private func index(at p: CGPoint) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let r = hypot(dx, dy)
        guard r > inner, r < outer + 30, !operations.isEmpty else { return nil }
        var theta = 90 - atan2(dy, dx) * 180 / .pi   // 0° at top, clockwise
        theta = theta.truncatingRemainder(dividingBy: 360)
        if theta < 0 { theta += 360 }
        return min(Int(theta / step), operations.count - 1)
    }

    private func setHover(_ i: Int?) {
        guard i != hovered else { return }
        hovered = i
        if i != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        startTimer()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let p = palette
        let a = RadialView.easeOut(appear)
        let pop = RadialView.easeOutBack(min(1, appear * 1.15))
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setAlpha(a)
        // Whole wheel grows from 70 % with a slight overshoot.
        let scale = 0.7 + 0.3 * pop
        cg.translateBy(x: center.x, y: center.y)
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -center.x, y: -center.y)
        let disc = NSBezierPath(ovalIn: NSRect(x: center.x - outer - 6, y: center.y - outer - 6,
                                               width: (outer + 6) * 2, height: (outer + 6) * 2))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        p.background.setFill()
        disc.fill()
        NSGraphicsContext.restoreGraphicsState()

        if operations.isEmpty {
            drawCenter(sub: L("Нет операций", "Nothing here"))
            return
        }

        let gap: CGFloat = operations.count > 1 ? 1.2 : 0
        for (i, op) in operations.enumerated() {
            // Sectors unfold one after another, clockwise from the top.
            let delay = CGFloat(i) / CGFloat(max(operations.count, 1)) * 0.45
            let t = RadialView.easeOutBack(max(0, min(1, (appear - delay) / 0.55)))
            let h = i < lift.count ? lift[i] : 0
            let rIn = inner + 6
            let rOut = rIn + (outer - rIn) * t + 10 * h
            let sweep = step * min(1, t)
            let start = 90 - CGFloat(i) * step - gap
            let end = start - sweep + 2 * gap
            guard end < start else { continue }
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: rOut, startAngle: start, endAngle: end, clockwise: true)
            path.appendArc(withCenter: center, radius: rIn, startAngle: end, endAngle: start, clockwise: false)
            path.close()
            (p.sector.blended(withFraction: h, of: p.accent) ?? p.sector).setFill()
            path.fill()

            let mid = (90 - (CGFloat(i) + 0.5) * step) * .pi / 180
            let r = (outer + inner + 6) / 2 + 5 * h
            let c = CGPoint(x: center.x + cos(mid) * r, y: center.y + sin(mid) * r)
            let color = p.text.blended(withFraction: h, of: .white) ?? p.text
            cg.saveGState()
            cg.setAlpha(a * max(0, min(1, (t - 0.4) / 0.6)))
            drawLabel(op, at: c, color: color)
            cg.restoreGState()
        }
        drawCenter(sub: nil)
    }

    private func drawLabel(_ op: Operation, at c: CGPoint, color: NSColor) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        if let img = NSImage(systemSymbolName: op.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg), let tinted = img.tinted(color) {
            let s = tinted.size
            tinted.draw(in: NSRect(x: c.x - s.width / 2, y: c.y + 2, width: s.width, height: s.height))
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: color, .paragraphStyle: style,
        ]
        let width: CGFloat = max(64, min(96, 2 * .pi * 120 / CGFloat(operations.count) - 8))
        NSAttributedString(string: op.title, attributes: attrs)
            .draw(in: NSRect(x: c.x - width / 2, y: c.y - 30, width: width, height: 30))
    }

    private func drawCenter(sub: String?) {
        let p = palette
        let r = inner
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        p.sector.setFill()
        circle.fill()
        p.stroke.setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let key = NSAttributedString(string: mode.key, attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: p.accent, .paragraphStyle: style])
        key.draw(in: NSRect(x: center.x - r, y: center.y + 2, width: r * 2, height: 26))
        let title = NSAttributedString(string: sub ?? mode.title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: p.secondaryText, .paragraphStyle: style])
        title.draw(in: NSRect(x: center.x - r + 4, y: center.y - 22, width: r * 2 - 8, height: 26))
    }

    // MARK: Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let m = Mode.from(NSEvent.modifierFlags) { RadialController.shared.setMode(m) }
        setHover(index(at: convert(sender.draggingLocation, from: nil)))
        return hovered == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setHover(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = index(at: convert(sender.draggingLocation, from: nil)) else { return false }
        RadialController.shared.choose(operations[i], pasteboard: sender.draggingPasteboard)
        return true
    }

    // MARK: Click mode

    override func mouseMoved(with event: NSEvent) {
        guard interactive else { return }
        setHover(index(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - center.x, p.y - center.y) <= inner { return RadialController.shared.cycleMode() }
        if let i = index(at: p) { RadialController.shared.choose(operations[i], pasteboard: nil) }
        else { RadialController.shared.hide() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: RadialController.shared.hide()                      // Esc
        case 48: RadialController.shared.cycleMode()                 // Tab
        case 36, 76:                                                  // Return
            if let h = hovered { RadialController.shared.choose(operations[h], pasteboard: nil) }
        case 123, 125:                                                // ← ↓
            setHover(((hovered ?? 0) - 1 + operations.count) % max(operations.count, 1))
        case 124, 126:                                                // → ↑
            setHover(((hovered ?? -1) + 1) % max(operations.count, 1))
        default: super.keyDown(with: event)
        }
    }

    override func resignFirstResponder() -> Bool { true }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage? {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return img
    }
}
