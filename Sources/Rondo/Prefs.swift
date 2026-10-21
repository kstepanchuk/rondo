import AppKit

enum ThemeChoice: String, CaseIterable { case system, dark, light }
enum LanguageChoice: String, CaseIterable { case system, ru, en }
/// Which app converts Word/Excel/PowerPoint files.
enum DocEngine: String, CaseIterable { case auto, office, libreOffice }

final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var theme: ThemeChoice {
        didSet { d.set(theme.rawValue, forKey: "theme") }
    }
    @Published var language: LanguageChoice {
        didSet { d.set(language.rawValue, forKey: "language") }
    }
    @Published var revealResult: Bool {
        didSet { d.set(revealResult, forKey: "revealResult") }
    }
    /// Save results next to the source file (default) instead of ~/Downloads/Rondo.
    @Published var saveNextToSource: Bool {
        didSet { d.set(saveNextToSource, forKey: "saveNextToSource") }
    }
    @Published var docEngine: DocEngine {
        didSet { d.set(docEngine.rawValue, forKey: "docEngine") }
    }
    @Published var history: [String] {
        didSet { d.set(history, forKey: "history") }
    }

    private init() {
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        language = LanguageChoice(rawValue: d.string(forKey: "language") ?? "") ?? .system
        revealResult = d.object(forKey: "revealResult") as? Bool ?? false
        saveNextToSource = d.object(forKey: "saveNextToSource") as? Bool ?? true
        docEngine = DocEngine(rawValue: d.string(forKey: "docEngine") ?? "") ?? .auto
        history = d.stringArray(forKey: "history") ?? []
    }

    func remember(_ url: URL) {
        var h = history.filter { $0 != url.path }
        h.insert(url.path, at: 0)
        history = Array(h.prefix(20))
    }

    var isRussian: Bool {
        switch language {
        case .ru: return true
        case .en: return false
        case .system:
            return (Locale.preferredLanguages.first ?? "en").hasPrefix("ru")
        }
    }
}

/// Localized string: L("Конвертация", "Convert")
func L(_ ru: String, _ en: String) -> String {
    Prefs.shared.isRussian ? ru : en
}

struct Palette {
    let background: NSColor
    let sector: NSColor
    let accent: NSColor
    let text: NSColor
    let secondaryText: NSColor
    let stroke: NSColor

    static var current: Palette {
        let dark: Bool
        switch Prefs.shared.theme {
        case .dark: dark = true
        case .light: dark = false
        case .system:
            dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return dark ? .redBlack : .whiteBlue
    }

    static let redBlack = Palette(
        background: NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.07, alpha: 0.94),
        sector: NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.13, alpha: 1),
        accent: NSColor(calibratedRed: 0.90, green: 0.16, blue: 0.19, alpha: 1),
        text: .white,
        secondaryText: NSColor(white: 1, alpha: 0.55),
        stroke: NSColor(white: 1, alpha: 0.08))

    static let whiteBlue = Palette(
        background: NSColor(calibratedWhite: 0.99, alpha: 0.96),
        sector: NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.99, alpha: 1),
        accent: NSColor(calibratedRed: 0.13, green: 0.47, blue: 0.95, alpha: 1),
        text: NSColor(calibratedWhite: 0.1, alpha: 1),
        secondaryText: NSColor(calibratedWhite: 0.1, alpha: 0.5),
        stroke: NSColor(calibratedRed: 0.13, green: 0.47, blue: 0.95, alpha: 0.12))
}

enum Paths {
    static var output: URL {
        let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let u = dl.appendingPathComponent("Rondo", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A non-existing URL in `dir` named `base.ext`, adding " (2)", " (3)"… if needed.
    static func unique(_ dir: URL, _ base: String, _ ext: String?) -> URL {
        let fm = FileManager.default
        func make(_ n: Int) -> URL {
            let name = n == 1 ? base : "\(base) (\(n))"
            let u = dir.appendingPathComponent(name)
            if let ext, !ext.isEmpty { return u.appendingPathExtension(ext) }
            return u
        }
        var n = 1
        while fm.fileExists(atPath: make(n).path) { n += 1 }
        return make(n)
    }

    /// Where results for `src` go: its own folder when that setting is on and the
    /// folder is writable (not a mounted DMG etc.), otherwise ~/Downloads/Rondo.
    /// Set by the command line's --out.
    static var overrideOutput: URL?

    static func dir(for src: URL?) -> URL {
        if let overrideOutput { return overrideOutput }
        if Prefs.shared.saveNextToSource, let src {
            let parent = src.deletingLastPathComponent()
            if FileManager.default.isWritableFile(atPath: parent.path) { return parent }
        }
        return output
    }

    static func out(for src: URL, ext: String?, suffix: String = "") -> URL {
        unique(dir(for: src), src.deletingPathExtension().lastPathComponent + suffix, ext)
    }

    static func temp() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("rondo-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

// MARK: - Advanced settings (optional; defaults apply while the section is off)

enum ModKey: String, CaseIterable, Identifiable {
    case shift, control, option, command
    var id: String { rawValue }
    var flag: NSEvent.ModifierFlags {
        switch self { case .shift: return .shift; case .control: return .control; case .option: return .option; case .command: return .command }
    }
    var symbol: String {
        switch self { case .shift: return "⇧"; case .control: return "⌃"; case .option: return "⌥"; case .command: return "⌘" }
    }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case high, medium, compact
    var id: String { rawValue }
    var crf: String { switch self { case .high: return "18"; case .medium: return "23"; case .compact: return "28" } }
}

final class AdvancedPrefs: ObservableObject {
    static let shared = AdvancedPrefs()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "adv.enabled") } }
    @Published var imageQuality: Double { didSet { d.set(imageQuality, forKey: "adv.imageQuality") } }
    @Published var webMaxSize: Int { didSet { d.set(webMaxSize, forKey: "adv.webMaxSize") } }
    @Published var videoQuality: VideoQuality { didSet { d.set(videoQuality.rawValue, forKey: "adv.videoQuality") } }
    @Published var keyConvert: ModKey { didSet { d.set(keyConvert.rawValue, forKey: "adv.keyConvert") } }
    @Published var keyTools: ModKey { didSet { d.set(keyTools.rawValue, forKey: "adv.keyTools") } }
    @Published var keyActions: ModKey { didSet { d.set(keyActions.rawValue, forKey: "adv.keyActions") } }
    /// Operation ids hidden from the wheel.
    @Published var hidden: Set<String> { didSet { d.set(Array(hidden), forKey: "adv.hidden") } }
    /// Custom sector order per "<kind>.<mode>" key.
    @Published var order: [String: [String]] { didSet { d.set(order, forKey: "adv.order") } }

    private init() {
        enabled = d.bool(forKey: "adv.enabled")
        imageQuality = d.object(forKey: "adv.imageQuality") as? Double ?? 0.9
        webMaxSize = d.object(forKey: "adv.webMaxSize") as? Int ?? 2048
        videoQuality = VideoQuality(rawValue: d.string(forKey: "adv.videoQuality") ?? "") ?? .medium
        keyConvert = ModKey(rawValue: d.string(forKey: "adv.keyConvert") ?? "") ?? .shift
        keyTools = ModKey(rawValue: d.string(forKey: "adv.keyTools") ?? "") ?? .control
        keyActions = ModKey(rawValue: d.string(forKey: "adv.keyActions") ?? "") ?? .option
        hidden = Set(d.stringArray(forKey: "adv.hidden") ?? [])
        order = d.dictionary(forKey: "adv.order") as? [String: [String]] ?? [:]
    }

    func resetLayout() { hidden = []; order = [:] }
}

/// Effective values: advanced ones when enabled, defaults otherwise.
enum Settings {
    private static var a: AdvancedPrefs { .shared }
    static var imageQuality: Double { a.enabled ? a.imageQuality : 0.9 }
    static var webMaxSize: Int { a.enabled ? a.webMaxSize : 2048 }
    static var videoCRF: String { a.enabled ? a.videoQuality.crf : "23" }
    static func key(_ mode: Mode) -> ModKey {
        guard a.enabled else { return [ModKey.shift, .control, .option][mode.rawValue] }
        switch mode { case .convert: return a.keyConvert; case .tools: return a.keyTools; case .actions: return a.keyActions }
    }
    static func isHidden(_ id: String) -> Bool { a.enabled && a.hidden.contains(id) }
    static func order(_ key: String) -> [String]? { a.enabled ? a.order[key] : nil }
}
