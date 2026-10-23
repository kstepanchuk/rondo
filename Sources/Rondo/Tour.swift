import AppKit
import ServiceManagement
import SwiftUI

/// The welcome tour: what Rondo is, a hands-on practice drag, the three wheels,
/// the other ways in, and open-at-login. Shown on first launch and from the menu.
enum Tour {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L("Добро пожаловать в Rondo", "Welcome to Rondo")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: TourView { window?.close() })
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// A small picture to practise on, in a temporary folder (results land next to it).
    static let sample: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Rondo tour", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(L("Попробуй меня", "Try me") + ".png")
        if !FileManager.default.fileExists(atPath: url.path) {
            let side = 600
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGradient(colors: [NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.3, alpha: 1),
                                NSColor(calibratedRed: 0.55, green: 0.1, blue: 0.25, alpha: 1)])!
                .draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: -45)
            let p = NSMutableParagraphStyle(); p.alignment = .center
            NSAttributedString(string: "Rondo", attributes: [.font: NSFont.systemFont(ofSize: 110, weight: .heavy),
                                                             .foregroundColor: NSColor.white, .paragraphStyle: p])
                .draw(in: NSRect(x: 0, y: 230, width: side, height: 140))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        return url
    }()
}

struct TourView: View {
    let close: () -> Void
    @State var page = 0
    @State private var practiced: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private let pages = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: practice
                case 2: wheels
                case 3: otherWays
                default: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
            .transition(.opacity)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { i in
                        Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if page > 0 { Button(L("Назад", "Back")) { withAnimation { page -= 1 } } }
                if page < pages - 1 {
                    Button(page == 1 && practiced == nil ? L("Пропустить", "Skip") : L("Дальше", "Next")) {
                        withAnimation { page += 1 }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("Готово", "Done"), action: close).keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .onReceive(NotificationCenter.default.publisher(for: Runner.finished)) { note in
            let inputs = note.userInfo?["inputs"] as? [URL] ?? []
            let outputs = note.userInfo?["outputs"] as? [URL] ?? []
            if inputs.contains(Tour.sample) {
                practiced = outputs.first?.lastPathComponent ?? L("готово", "done")
            }
        }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(L("Колесо у курсора", "A wheel at your cursor")).font(.title.bold())
            Text(L("Тяните файл куда угодно, зажмите клавишу — и у курсора раскроется колесо с тем, что можно сделать с этим файлом. Отпустите над нужным сектором. Всё работает на вашем Mac, без интернета.",
                   "Drag a file anywhere, hold a key, and a wheel opens at the cursor with what you can do with that file. Drop it on a sector. Everything runs on your Mac, offline."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
        }
    }

    private var practice: some View {
        VStack(spacing: 16) {
            Text(L("Попробуем", "Let's try")).font(.title2.bold())
            Text(L("1. Потяните картинку ниже.\n2. Не отпуская, нажмите и держите ⇧ Shift.\n3. Отпустите её над любым форматом, например JPG.",
                   "1. Drag the picture below.\n2. While dragging, press and hold ⇧ Shift.\n3. Drop it on any format, for example JPG."))
                .multilineTextAlignment(.leading).frame(maxWidth: 360, alignment: .leading)
            SampleFile().frame(width: 140, height: 140)
            if let practiced {
                Label(L("Получилось! Готов файл «\(practiced)»", "It worked! Made “\(practiced)”"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
            } else {
                Text(L("Результат появится рядом с исходником, а в углу экрана — уведомление.",
                       "The result appears next to the original, with a notification in the corner."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var wheels: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Три колеса", "Three wheels")).font(.title2.bold())
            row("⇧", L("Конвертация", "Convert"), L("JPG, PNG, PDF, MP4, MP3, DOCX и другие форматы", "JPG, PNG, PDF, MP4, MP3, DOCX and more"))
            row("⌃", L("Инструменты", "Tools"), L("Кроп, убрать фон, сжать до N МБ, обрезать видео, OCR…", "Crop, remove background, fit under N MB, trim, OCR…"))
            row("⌥", L("Действия", "Actions"), L("ZIP, AirDrop, на телефон, переместить, метаданные…", "ZIP, AirDrop, to phone, move, metadata…"))
            Text(L("Пока колесо открыто, прокрутка переключает колёса, а задержка на «Ещё ›» показывает остальные операции. Центр колеса — отмена.",
                   "While the wheel is open, scroll to switch wheels; rest on “More ›” for the rest. The centre cancels."))
                .foregroundStyle(.secondary).padding(.top, 6)
        }
        .frame(maxWidth: 440, alignment: .leading)
    }

    private func row(_ key: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(key).font(.system(size: 24, weight: .bold)).foregroundStyle(Color.accentColor).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }

    private var otherWays: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("И без перетаскивания", "Without dragging")).font(.title2.bold())
            way("keyboard", L("Выделите файлы в Finder и нажмите ⌃⌥Пробел", "Select files in Finder and press ⌃⌥Space"))
            way("contextualmenu.and.cursorarrow", L("Правый клик → Службы → Rondo…", "Right-click → Services → Rondo…"))
            way("square.stack.3d.up", L("«Быстрые команды» и Spotlight: «Convert to JPEG with Rondo»", "Shortcuts and Spotlight: “Convert to JPEG with Rondo”"))
            way("folder.badge.gearshape", L("Папки-наблюдатели в настройках: файлы обрабатываются сами", "Watch folders in Settings: files are processed by themselves"))
            way("terminal", L("Терминал: rondo convert --to jpg *.heic", "Terminal: rondo convert --to jpg *.heic"))
        }
        .frame(maxWidth: 440, alignment: .leading)
    }

    private func way(_ symbol: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 24) }
    }

    private var finish: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text(L("Всё готово", "You're all set")).font(.title.bold())
            Text(L("Rondo живёт в строке меню. Там же настройки, история и этот тур.",
                   "Rondo lives in the menu bar, along with Settings, history and this tour."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 400)
            Toggle(L("Открывать Rondo при входе в систему", "Open Rondo at login"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in
                    do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                    catch { launchAtLogin = !on }
                }
        }
    }
}

/// The practice picture: an AppKit drag source, so Rondo can start watching
/// modifiers for a drag that begins inside its own window.
private struct SampleFile: NSViewRepresentable {
    func makeNSView(context: Context) -> SampleFileView { SampleFileView() }
    func updateNSView(_ nsView: SampleFileView, context: Context) {}
}

private final class SampleFileView: NSView, NSDraggingSource {
    override func draw(_ dirtyRect: NSRect) {
        guard let img = NSImage(contentsOf: Tour.sample) else { return }
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 16, yRadius: 16).addClip()
        img.draw(in: bounds.insetBy(dx: 4, dy: 4))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Tour.sample as NSURL)
        let icon = NSImage(contentsOf: Tour.sample) ?? NSImage()
        item.setDraggingFrame(bounds.insetBy(dx: 30, dy: 30), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        DragWatcher.shared.begin(kinds: [.image])
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
