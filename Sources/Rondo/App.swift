import AppKit
import ServiceManagement
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private let drag = DragWatcher()
    private let hotKey = HotKey()
    private var settingsWindow: NSWindow?

    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--self-test"), i + 1 < args.count {
            return SelfTest.run(dir: URL(fileURLWithPath: args[i + 1]), office: args.contains("--office"))
        }
        if let i = args.firstIndex(of: "--arena-deck"), i + 1 < args.count {
            // Creates an Arena deck from a folder and prints its id (for testing).
            do { print("ok   deck id \(try Arena.addDeck(from: URL(fileURLWithPath: args[i + 1])))"); exit(0) }
            catch { print("FAIL arena: \(error.localizedDescription)"); exit(1) }
        }
                if let i = args.firstIndex(of: "--verify-update"), i + 1 < args.count {
            // Runs the updater's checks on a local DMG (needs <dmg>.sha256 next to it).
            let dmg = URL(fileURLWithPath: args[i + 1])
            do {
                let sum = try String(contentsOf: dmg.appendingPathExtension("sha256"), encoding: .utf8)
                let app = try Updater.prepare(dmgData: try Data(contentsOf: dmg), expectedSHA: sum, in: Paths.temp())
                print("ok   update ready: \(app.path) (\(Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?"))")
                exit(0)
            } catch { print("FAIL update: \(error.localizedDescription)"); exit(1) }
        }
                if let i = args.firstIndex(of: "--render-menu"), i + 1 < args.count {
            // Writes menu-dark.png and menu-light.png (image kind, Convert mode) for the README.
            _ = NSApplication.shared
            let dir = URL(fileURLWithPath: args[i + 1])
            let english = args.contains("--english")
            if english { Prefs.shared.language = .en }
            defer { if english { Prefs.shared.language = .system } }
            for (name, theme) in [("dark", ThemeChoice.dark), ("light", ThemeChoice.light)] {
                Prefs.shared.theme = theme
                let v = RadialView(frame: NSRect(x: 0, y: 0, width: 380, height: 380))
                v.palette = .current
                v.mode = .convert
                v.operations = Catalog.operations(kinds: [.image], mode: .convert)
                try? v.renderPNG(hover: 1)?.write(to: dir.appendingPathComponent("menu-\(name)\(english ? "-en" : "").png"))
            }
            Prefs.shared.theme = .system
            if args.contains("--settings") {
                let host = NSHostingView(rootView: SettingsView(height: 1500))
                host.frame = NSRect(x: 0, y: 0, width: 460, height: 1500)
                let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                w.contentView = host
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("settings.png"))
                }
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        AppDelegate.shared = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setBusy(false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        UserShortcuts.refresh()
        Updater.checkInBackgroundIfDue()
        drag.start()
        hotKey.register {
            let files = HotKey.finderSelection()
            if files.isEmpty {
                Toast.show("Rondo", sub: L("Выделите файлы в Finder", "Select files in Finder"))
            } else {
                RadialController.shared.showForClick(files: files)
            }
        }
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            openSettings()
        }
    }

    func setBusy(_ busy: Bool) {
        let name = busy ? "arrow.triangle.2.circlepath" : "circle.circle"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Rondo")
        img?.isTemplate = true
        statusItem?.button?.image = img
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        UserShortcuts.refresh()
        menu.removeAllItems()
        let hint = NSMenuItem(title: L("Тяните файл + ⇧ ⌃ ⌥ · ⌃⌥Пробел", "Drag a file + ⇧ ⌃ ⌥ · ⌃⌥Space"),
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let history = NSMenuItem(title: L("Недавние", "Recent"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let paths = Prefs.shared.history.filter { FileManager.default.fileExists(atPath: $0) }
        for p in paths {
            let item = NSMenuItem(title: (p as NSString).lastPathComponent, action: #selector(revealHistory(_:)), keyEquivalent: "")
            item.representedObject = p
            item.target = self
            item.image = NSWorkspace.shared.icon(forFile: p)
            item.image?.size = NSSize(width: 16, height: 16)
            sub.addItem(item)
        }
        if paths.isEmpty {
            let e = NSMenuItem(title: L("Пусто", "Empty"), action: nil, keyEquivalent: "")
            e.isEnabled = false
            sub.addItem(e)
        } else {
            sub.addItem(.separator())
            sub.addItem(withTitle: L("Очистить", "Clear"), action: #selector(clearHistory), keyEquivalent: "").target = self
        }
        history.submenu = sub
        menu.addItem(history)

        menu.addItem(withTitle: L("Папка результатов", "Output folder"), action: #selector(openOutput), keyEquivalent: "o").target = self
        menu.addItem(withTitle: L("Проверить обновления…", "Check for Updates…"), action: #selector(checkUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Настройки…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Выйти из Rondo", "Quit Rondo"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func revealHistory(_ item: NSMenuItem) {
        guard let p = item.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    @objc private func checkUpdates() { Updater.check(interactive: true) }

    @objc private func clearHistory() { Prefs.shared.history = [] }

    @objc private func openOutput() { NSWorkspace.shared.open(Paths.output) }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Rondo"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Finder service ("Rondo…" in the context menu → Quick Actions / Services)

    @objc func openMenu(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async { RadialController.shared.showForClick(files: urls) }
    }
}

// MARK: - Settings

struct SettingsView: View {
    var height: CGFloat = 640
    @ObservedObject private var prefs = Prefs.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var languageChanged = false
    @State private var autoUpdate = Updater.autoCheck
    @State private var toolsRefresh = 0

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Как пользоваться", "How to use")).font(.headline)
                    Text(L("Тяните файл и зажмите \(Mode.convert.key) — конвертация, \(Mode.tools.key) — инструменты, \(Mode.actions.key) — действия. Отпустите над сектором. Центр — отмена.",
                           "Drag a file and hold \(Mode.convert.key) to convert, \(Mode.tools.key) for tools, \(Mode.actions.key) for actions. Drop on a sector; the centre cancels."))
                    Text(L("Без мыши: выделите файлы в Finder и нажмите ⌃⌥Пробел (Tab — сменить режим). Или правый клик → Быстрые действия/Службы → Rondo.",
                           "Keyboard: select files in Finder and press ⌃⌥Space (Tab switches mode). Or right-click → Quick Actions/Services → Rondo."))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section(L("Оформление", "Appearance")) {
                Picker(L("Тема", "Theme"), selection: $prefs.theme) {
                    Text(L("Как в системе", "System")).tag(ThemeChoice.system)
                    Text(L("Тёмная (красно-чёрная)", "Dark (red/black)")).tag(ThemeChoice.dark)
                    Text(L("Светлая (бело-голубая)", "Light (white/blue)")).tag(ThemeChoice.light)
                }
                Picker(L("Язык", "Language"), selection: $prefs.language) {
                    Text(L("Как в системе", "System")).tag(LanguageChoice.system)
                    Text("Русский").tag(LanguageChoice.ru)
                    Text("English").tag(LanguageChoice.en)
                }
                .onChange(of: prefs.language) { _ in languageChanged = true }
                if languageChanged {
                    Text(L("Перезапустите Rondo, чтобы сменить язык меню.", "Restart Rondo to apply the language."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(L("Поведение", "Behaviour")) {
                Toggle(L("Открывать при входе в систему", "Open at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = !on }
                    }
                Toggle(L("Показывать результат в Finder", "Reveal result in Finder"), isOn: $prefs.revealResult)
                HStack {
                    Toggle(L("Проверять обновления раз в день", "Check for updates daily"), isOn: $autoUpdate)
                        .onChange(of: autoUpdate) { Updater.autoCheck = $0 }
                    Spacer()
                    Button(L("Проверить", "Check")) { Updater.check(interactive: true) }
                }
                Toggle(L("Сохранять рядом с исходным файлом", "Save next to the original file"), isOn: $prefs.saveNextToSource)
                HStack {
                    Text(prefs.saveNextToSource
                         ? L("Иначе и для вложений: ~/Downloads/Rondo", "Otherwise and for attachments: ~/Downloads/Rondo")
                         : L("Результаты: ~/Downloads/Rondo", "Output: ~/Downloads/Rondo"))
                    Spacer()
                    Button(L("Открыть", "Open")) { NSWorkspace.shared.open(Paths.output) }
                }
            }

            AdvancedSection()

            Section {
                let _ = toolsRefresh  // re-evaluate tool status when the window comes back
                tool("ffmpeg", Tools.ffmpeg != nil, L("аудио и видео", "audio & video"), "ffmpeg")
                tool("pandoc", Tools.pandoc != nil, "Markdown, EPUB", "pandoc")
                tool("7-Zip", Tools.sevenZip != nil, L("архивы 7z", "7z archives"), "sevenzip")
                tool("Microsoft Word", Tools.word, "DOCX → PDF", nil)
                tool("Microsoft Excel", Tools.excel, "XLSX ⇄ CSV, PDF", nil)
                tool("PowerPoint / Keynote", Tools.powerPoint || Tools.keynote, L("слайды → PDF, PNG", "slides → PDF, PNG"), nil)
            } header: {
                Text(L("Инструменты", "Tools"))
            } footer: {
                Text(L("«Установить» откроет Терминал и запустит установку через Homebrew. Когда она закончится, вернитесь сюда — статус обновится сам.",
                       "Install opens Terminal and runs Homebrew. When it finishes, come back here and the status updates."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in toolsRefresh += 1 }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in toolsRefresh += 1 }

            Section {
                HStack {
                    Text("Rondo \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    Spacer()
                    Link("GitHub", destination: URL(string: "https://github.com/kstepanchuk/rondo")!)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: height)
    }

    /// `package`: Homebrew formula to install when missing (nil for apps like Office).
    private func tool(_ name: String, _ ok: Bool, _ purpose: String, _ package: String?) -> some View {
        HStack(alignment: .center) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                Text(ok ? purpose : purpose + L(" — не установлен", " — not installed"))
                    .font(.caption).foregroundStyle(.secondary)
                if !ok, let package {
                    HStack(spacing: 4) {
                        Text("brew install \(package)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install \(package)", forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help(L("Скопировать команду", "Copy command"))
                    }
                }
            }
            Spacer()
            if !ok, let package {
                Button(L("Установить", "Install")) { Installer.install(package) }
                    .buttonStyle(.borderedProminent)
                    .help(L("Откроет Терминал и выполнит brew install \(package)",
                            "Opens Terminal and runs brew install \(package)"))
            }
        }
    }
}


/// Installs an optional engine with Homebrew in a visible Terminal window.
enum Installer {
    static func install(_ package: String) {
        guard let brew = Tools.find("brew") else {
            // No Homebrew yet: send the user to the official instructions.
            NSWorkspace.shared.open(URL(string: "https://brew.sh/ru/")!)
            return
        }
        let cmd = "\(brew) install \(package)"
        let script = """
            tell application "Terminal"
                activate
                do script \(Tools.quote(cmd))
            end tell
            """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err != nil {
            // Automation denied: fall back to copying the command.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew install \(package)", forType: .string)
            Toast.show(L("Команда скопирована", "Command copied"),
                       sub: L("Вставьте её в Терминал: brew install \(package)", "Paste into Terminal: brew install \(package)"))
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }
}
