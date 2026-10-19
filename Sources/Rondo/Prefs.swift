import AppKit

enum ThemeChoice: String, CaseIterable { case system, dark, light }
enum LanguageChoice: String, CaseIterable { case system, ru, en }

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
    @Published var history: [String] {
        didSet { d.set(history, forKey: "history") }
    }

    private init() {
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        language = LanguageChoice(rawValue: d.string(forKey: "language") ?? "") ?? .system
        revealResult = d.object(forKey: "revealResult") as? Bool ?? false
        saveNextToSource = d.object(forKey: "saveNextToSource") as? Bool ?? true
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
    static func dir(for src: URL?) -> URL {
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
