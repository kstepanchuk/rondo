import AppKit
import Carbon.HIToolbox

/// Shows the radial menu while a file is being dragged anywhere and ⇧/⌃/⌥ is held.
/// Uses only mouse monitors and polled modifier flags, so no Accessibility permission is needed.
final class DragWatcher {
    static let shared = DragWatcher()
    private var monitors: [Any] = []
    private var timer: Timer?
    private var startCount = 0
    private var dragging = false
    private var kinds: [Kind] = []
    private let dragPB = NSPasteboard(name: .drag)

    func start() {
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            self.startCount = self.dragPB.changeCount
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            self?.dragged()
        } as Any)
    }

    private func dragged() {
        guard !dragging, dragPB.changeCount != startCount else { return }
        let k = Payload.kinds(of: dragPB)
        guard !k.isEmpty else { return }
        begin(kinds: k)
    }

    /// Starts watching modifiers for a drag of `kinds`. Global monitors don't see drags that
    /// start inside Rondo itself (the welcome tour's sample file), so those call this directly.
    func begin(kinds k: [Kind]) {
        guard !dragging else { return }
        kinds = k
        dragging = true
        // .common: keep ticking while a drag session runs this app's event-tracking loop.
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            // Drag ended. Give performDragOperation a moment, then make sure the menu is gone.
            dragging = false
            startCount = dragPB.changeCount
            timer?.invalidate()
            timer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { RadialController.shared.hide() }
            return
        }
        let menu = RadialController.shared
        let mode = Mode.from(NSEvent.modifierFlags)
        if menu.isVisible { menu.modifierMode(mode) } else if let mode { menu.showForDrag(kinds: kinds, mode: mode) }
    }
}

/// ⌃⌥Space: radial menu for the current Finder selection.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var action: (() -> Void)?

    func register(_ action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x524E_444F), id: 1) // 'RNDO'
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }

    static func finderSelection() -> [URL] {
        let script = """
            tell application "Finder"
                set out to ""
                repeat with f in (get selection)
                    set out to out & POSIX path of (f as alias) & linefeed
                end repeat
                return out
            end tell
            """
        var err: NSDictionary?
        let res = NSAppleScript(source: script)?.executeAndReturnError(&err)
        return (res?.stringValue ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}
