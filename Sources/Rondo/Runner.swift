import AppKit

/// Runs operations off the main thread and reports results.
enum Runner {
    private static var busy = 0 { didSet { AppDelegate.shared?.setBusy(busy > 0) } }
    private static let queue = DispatchQueue(label: "rondo.work", qos: .userInitiated, attributes: .concurrent)

    static func run(_ op: Operation, _ urls: [URL], at point: NSPoint? = nil) {
        busy += 1
        let ring = point.map(ProgressRing.init(at:))
        queue.async {
            let result = Result { try op.perform(urls) }
            DispatchQueue.main.async {
                busy -= 1
                if case .success = result { ring?.finish(success: true) } else { ring?.finish(success: false) }
                switch result {
                case .success(let outputs):
                    guard !outputs.isEmpty else {
                        Toast.show(op.title, sub: L("Готово", "Done"))
                        return
                    }
                    outputs.forEach(Prefs.shared.remember)
                    let name = outputs.count == 1 ? outputs[0].lastPathComponent
                        : L("Файлов: \(outputs.count)", "\(outputs.count) files")
                    Toast.show(L("Готово", "Done") + " · " + op.title, sub: name) {
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
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ title: String, sub: String, error: Bool = false, action: (() -> Void)? = nil) {
        panel?.orderOut(nil)
        let pal = Palette.current
        let width: CGFloat = 320
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 64),
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

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.textColor = error ? .systemRed : pal.accent
        t.lineBreakMode = .byTruncatingTail
        t.frame = NSRect(x: 16, y: 34, width: width - 32, height: 18)
        let s = NSTextField(labelWithString: sub)
        s.font = .systemFont(ofSize: 12)
        s.textColor = pal.text
        s.lineBreakMode = .byTruncatingMiddle
        s.frame = NSRect(x: 16, y: 12, width: width - 32, height: 18)
        s.toolTip = sub
        v.addSubview(t)
        v.addSubview(s)
        p.contentView = v

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: vf.maxX - width - 16, y: vf.maxY - 64 - 12))
        }
        p.orderFrontRegardless()
        panel = p

        hideWork?.cancel()
        let work = DispatchWorkItem { p.orderOut(nil); if panel === p { panel = nil } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 7 : 4), execute: work)
    }
}

private final class ToastView: NSView {
    var action: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        action?()
        window?.orderOut(nil)
    }
}
