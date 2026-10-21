import AppKit
import CoreServices
import SwiftUI

/// Watch folders: new files that land in a folder are processed automatically,
/// results go into its "Готово" (Done) subfolder.
struct WatchRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    /// A target format understood by CLI.convertOp ("jpg", "pdf"…), or "utf8" / "compress".
    var action: String

    static let actions: [(String, String)] = [
        ("jpg", "→ JPG"), ("png", "→ PNG"), ("heic", "→ HEIC"), ("pdf", "→ PDF"), ("mp4", "→ MP4"),
        ("mp3", "→ MP3"), ("docx", "→ DOCX"), ("utf8", L("В UTF-8", "To UTF-8")), ("compress", L("Сжать", "Compress")),
    ]

    var folder: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var outputFolder: URL { folder.appendingPathComponent(L("Готово", "Done"), isDirectory: true) }

    func operation(for kind: Kind) -> Operation? {
        switch action {
        case "utf8": return Catalog.operations(kinds: [kind], mode: .tools).first { $0.id == "utf8" }
        case "compress":
            return Catalog.operations(kinds: [kind], mode: .tools).first { ["web", "v-small", "pdf-small"].contains($0.id) }
        default: return CLI.convertOp(for: kind, to: action)
        }
    }
}

final class WatchFolders: ObservableObject {
    static let shared = WatchFolders()
    @Published var rules: [WatchRule] = [] {
        didSet { save(); restart() }
    }
    private var stream: FSEventStreamRef?
    private var seen: [String: Int64] = [:]       // path → size at first sight, to wait until a copy finishes
    private var done = Set<String>()              // processed paths, never touch twice

    private init() {
        if let d = UserDefaults.standard.data(forKey: "watchRules"),
           let r = try? JSONDecoder().decode([WatchRule].self, from: d) { rules = r }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: "watchRules")
    }

    func start() { restart() }

    private func restart() {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
        let paths = rules.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }
        // Files already there when watching starts are not processed.
        for r in rules { for f in files(in: r.folder) { done.insert(f.path) } }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let me = Unmanaged<WatchFolders>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { me.scan() }
        }
        stream = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                     0.5, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    private func files(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    /// Picks up files whose size stopped changing since the last look, then processes them.
    private func scan() {
        for rule in rules {
            for f in files(in: rule.folder) where !done.contains(f.path) {
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
                if let prev = seen[f.path], prev == size, size > 0 {
                    seen[f.path] = nil
                    done.insert(f.path)
                    process(f, rule)
                } else {
                    seen[f.path] = size
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.scan() }
                }
            }
        }
    }

    private func process(_ file: URL, _ rule: WatchRule) {
        guard let op = rule.operation(for: Kind.of(file)) else { return }   // not this rule's kind of file
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: rule.outputFolder, withIntermediateDirectories: true)
                let tmp = Paths.temp()
                defer { try? FileManager.default.removeItem(at: tmp) }
                // Produce into a private folder, then move into "Done" (Paths.overrideOutput is global).
                let produced: [URL] = try Self.lock.withLock {
                    Paths.overrideOutput = tmp
                    defer { Paths.overrideOutput = nil }
                    return try op.perform([file])
                }
                for p in produced {
                    let d = Paths.unique(rule.outputFolder, p.deletingPathExtension().lastPathComponent, p.pathExtension)
                    try FileManager.default.moveItem(at: p, to: d)
                    DispatchQueue.main.async { Prefs.shared.remember(d) }
                }
            } catch {
                DispatchQueue.main.async {
                    Toast.show(L("Папка «\(rule.folder.lastPathComponent)»", "Folder “\(rule.folder.lastPathComponent)”"),
                               sub: "\(file.lastPathComponent): \(error.localizedDescription)", error: true)
                }
            }
        }
    }

    private static let lock = NSLock()

    func addRule() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = L("Наблюдать", "Watch")
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let url = p.url else { return }
        rules.append(WatchRule(path: url.path, action: "jpg"))
    }
}

struct WatchFoldersSection: View {
    @ObservedObject private var w = WatchFolders.shared

    var body: some View {
        Section {
            ForEach($w.rules) { $rule in
                HStack {
                    Image(systemName: "folder")
                    Text(rule.folder.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        .help(rule.path)
                    Spacer()
                    Picker("", selection: $rule.action) {
                        ForEach(WatchRule.actions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().frame(width: 130)
                    Button { w.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button(L("Добавить папку…", "Add folder…")) { w.addRule() }
        } header: {
            Text(L("Папки-наблюдатели", "Watch folders"))
        } footer: {
            Text(L("Новые файлы в этих папках обрабатываются сами, результат — в подпапке «Готово».",
                   "New files in these folders are processed automatically; results go to a “Done” subfolder."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
