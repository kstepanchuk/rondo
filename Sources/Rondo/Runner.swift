import AppKit

/// Runs operations off the main thread and reports results.
enum Runner {
    /// "1,2 МБ → 340 КБ (−72 %)" for the total before and after.
    static func savings(_ inputs: [URL], _ outputs: [URL]) -> String? {
        func size(_ u: URL) -> Int64 { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0 }
        let before = inputs.map(size).reduce(0, +), after = outputs.map(size).reduce(0, +)
        guard before > 0, after > 0 else { return nil }
        let f = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let pct = Int((Double(after - before) / Double(before) * 100).rounded())
        return "\(f(before)) → \(f(after)) (\(pct > 0 ? "+" : "−")\(abs(pct)) %)"
    }

    /// Posted after an operation succeeds; userInfo has "inputs" and "outputs" ([URL]).
    static let finished = Notification.Name("RondoOperationFinished")

    private static var busy = 0 { didSet { AppDelegate.shared?.setBusy(busy > 0) } }
    private static let queue = DispatchQueue(label: "rondo.work", qos: .userInitiated, attributes: .concurrent)

    static func run(_ op: Operation, _ urls: [URL], at point: NSPoint? = nil) {
        busy += 1
        Usage.record(op.id, kinds: urls.map(Kind.of))
        let ring = op.interactive ? nil : point.map(ProgressRing.init(at:))
        queue.async {
            let result = Result { try op.perform(urls) }
            DispatchQueue.main.async {
                busy -= 1
                if case .success(let outputs) = result {
                    NotificationCenter.default.post(name: Runner.finished, object: nil, userInfo: ["inputs": urls, "outputs": outputs])
                }
                if case .success = result { ring?.finish(success: true) } else { ring?.finish(success: false) }
                switch result {
                case .success(let outputs):
                    guard !outputs.isEmpty else {
                        Toast.show(op.title, sub: L("Готово", "Done"))
                        return
                    }
                    outputs.forEach(Prefs.shared.remember)
                    if Catalog.shrinking.contains(op.id), let saved = savings(urls, outputs) {
                        Toast.show(L("Готово", "Done") + " · " + op.title, sub: saved, files: outputs) {
                            NSWorkspace.shared.activateFileViewerSelecting(outputs)
                        }
                        if Prefs.shared.revealResult { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                        return
                    }
                    let name = outputs.count == 1 ? outputs[0].lastPathComponent
                        : L("Файлов: \(outputs.count)", "\(outputs.count) files")
                    Toast.show(L("Готово", "Done") + " · " + op.title, sub: name, files: outputs) {
                        NSWorkspace.shared.activateFileViewerSelecting(outputs)
                    }
                    if Prefs.shared.revealResult { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                case .failure(let error):
                    NSSound.beep()
                    Toast.show(L("Ошибка", "Error") + " · " + op.title, sub: error.localizedDescription, error: true)
                }
            }
        }
    }
}

/// Small notification bubble under the menu bar. Click runs `action`.
/// With `files`, it shows the result's icon (drag it straight into another app) and an Undo button.
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ title: String, sub: String, error: Bool = false, files: [URL] = [], action: (() -> Void)? = nil) {
        panel?.orderOut(nil)
        let pal = Palette.current
        let width: CGFloat = files.isEmpty ? 320 : 360
        let height: CGFloat = files.isEmpty ? 64 : 72
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let v = ToastView(frame: p.contentRect(forFrameRect: p.frame))
        v.wantsLayer = true
        v.layer?.cornerRadius = 14
        v.layer?.backgroundColor = pal.background.cgColor
        v.layer?.borderColor = (error ? NSColor.systemRed : pal.accent).withAlphaComponent(0.6).cgColor
        v.layer?.borderWidth = 1
        v.action = action
        v.onHover = { inside in inside ? hideWork?.cancel() : scheduleHide(p, after: 2) }

        var textX: CGFloat = 16, textWidth = width - 32
        if !files.isEmpty {
            let icon = DraggableFileIcon(files: files)
            icon.frame = NSRect(x: 12, y: (height - 44) / 2, width: 44, height: 44)
            icon.toolTip = L("Перетащите результат куда нужно", "Drag the result anywhere")
            v.addSubview(icon)
            textX = 64

            let undo = NSButton(title: L("Отменить", "Undo"), target: nil, action: nil)
            undo.bezelStyle = .rounded
            undo.controlSize = .small
            undo.font = .systemFont(ofSize: 11)
            undo.sizeToFit()
            undo.frame.origin = NSPoint(x: width - undo.frame.width - 10, y: (height - undo.frame.height) / 2)
            let handler = UndoTarget(files: files, panel: p)
            undo.target = handler
            undo.action = #selector(UndoTarget.undo)
            objc_setAssociatedObject(undo, &UndoTarget.key, handler, .OBJC_ASSOCIATION_RETAIN)
            v.addSubview(undo)
            textWidth = undo.frame.minX - textX - 8
        }

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.textColor = error ? .systemRed : pal.accent
        t.lineBreakMode = .byTruncatingTail
        t.frame = NSRect(x: textX, y: height / 2 + 2, width: textWidth, height: 18)
        let s = NSTextField(labelWithString: sub)
        s.font = .systemFont(ofSize: 12)
        s.textColor = pal.text
        s.lineBreakMode = .byTruncatingMiddle
        s.frame = NSRect(x: textX, y: height / 2 - 20, width: textWidth, height: 18)
        s.toolTip = sub
        v.addSubview(t)
        v.addSubview(s)
        p.contentView = v

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: vf.maxX - width - 16, y: vf.maxY - height - 12))
        }
        p.orderFrontRegardless()
        panel = p
        scheduleHide(p, after: error ? 7 : (files.isEmpty ? 4 : 6))
    }

    private static func scheduleHide(_ p: NSPanel, after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { p.orderOut(nil); if panel === p { panel = nil } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Moves results to the Trash (recoverable), from the toast's Undo button.
private final class UndoTarget: NSObject {
    static var key = 0
    let files: [URL]
    weak var panel: NSPanel?
    init(files: [URL], panel: NSPanel) { self.files = files; self.panel = panel }

    @objc func undo() {
        NSWorkspace.shared.recycle(files) { _, error in
            self.panel?.orderOut(nil)
            if let error {
                Toast.show(L("Не удалось отменить", "Couldn't undo"), sub: error.localizedDescription, error: true)
            } else {
                Prefs.shared.history.removeAll { p in self.files.contains { $0.path == p } }
                Toast.show(L("Отменено", "Undone"), sub: L("Результат в Корзине", "The result is in the Trash"))
            }
        }
    }
}

/// The result's icon in the toast: drag it into any app or folder.
private final class DraggableFileIcon: NSView, NSDraggingSource {
    let files: [URL]
    init(files: [URL]) { self.files = files; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    private var icon: NSImage {
        files.count == 1 ? NSWorkspace.shared.icon(forFile: files[0].path) : NSWorkspace.shared.icon(for: .folder)
    }

    override func draw(_ dirtyRect: NSRect) { icon.draw(in: bounds) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let items = files.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }
}

private final class ToastView: NSView {
    var action: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        action?()
        window?.orderOut(nil)
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
