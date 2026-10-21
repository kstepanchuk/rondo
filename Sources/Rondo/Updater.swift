import AppKit
import CryptoKit

/// Self-updater backed by GitHub Releases of kstepanchuk/rondo.
/// Each release carries `Rondo-<ver>.dmg` and `Rondo-<ver>.dmg.sha256`.
/// The update is applied only if the checksum matches, the new bundle has the
/// same bundle id and its code signature verifies.
enum Updater {
    static let repo = "kstepanchuk/rondo"
    private static let lastCheckKey = "lastUpdateCheck"
    private static var running = false

    static var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdate") }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Called at launch: checks at most once a day, silently unless an update exists.
    static func checkInBackgroundIfDue() {
        guard autoCheck else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        check(interactive: false)
    }

    private struct Release: Decodable {
        let tag_name: String
        let body: String?
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func check(interactive: Bool) {
        guard !running else { return }
        running = true
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                running = false
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                guard let data, error == nil, let rel = try? JSONDecoder().decode(Release.self, from: data) else {
                    if interactive { alert(L("Не удалось проверить обновления", "Could not check for updates"), error?.localizedDescription ?? "") }
                    return
                }
                let version = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard isNewer(version, than: currentVersion) else {
                    if interactive { alert(L("У вас последняя версия", "You're up to date"), "Rondo \(currentVersion)") }
                    return
                }
                guard let dmg = rel.assets.first(where: { $0.name == "Rondo-\(version).dmg" }),
                      let sum = rel.assets.first(where: { $0.name == "Rondo-\(version).dmg.sha256" }) else { return }
                offer(version: version, notes: rel.body ?? "", dmg: dmg.browser_download_url, sum: sum.browser_download_url)
            }
        }.resume()
    }

    private static func offer(version: String, notes: String, dmg: URL, sum: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("Доступна версия \(version)", "Version \(version) is available")
        a.accessoryView = ReleaseNotes.view(notes)
        a.addButton(withTitle: L("Установить и перезапустить", "Install and relaunch"))
        a.addButton(withTitle: L("Позже", "Later"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Toast.show("Rondo", sub: L("Загружаю обновление…", "Downloading update…"))
        DispatchQueue.global().async {
            do {
                try install(dmg: dmg, sum: sum)
            } catch {
                DispatchQueue.main.async { alert(L("Обновление не установлено", "Update failed"), error.localizedDescription) }
            }
        }
    }

    private static func download(_ url: URL) throws -> Data {
        guard url.scheme == "https", let host = url.host,
              host == "github.com" || host.hasSuffix(".githubusercontent.com")
        else { throw RondoError("Unexpected download host") }
        let sem = DispatchSemaphore(value: 0)
        var out: Data?, err: Error?
        URLSession.shared.dataTask(with: url) { d, r, e in
            if let http = r as? HTTPURLResponse, http.statusCode != 200 { err = RondoError("HTTP \(http.statusCode)") }
            out = d; err = err ?? e; sem.signal()
        }.resume()
        sem.wait()
        if let err { throw err }
        guard let out else { throw RondoError("Empty download") }
        return out
    }

    private static func install(dmg: URL, sum: URL) throws {
        let data = try download(dmg)
        let expected = String(decoding: try download(sum), as: UTF8.self)
        let tmp = Paths.temp()
        let newApp = try prepare(dmgData: data, expectedSHA: expected, in: tmp)
        // Swap the bundle after we quit, then relaunch.
        let current = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            rm -rf "$1.old" && mv "$1" "$1.old" && mv "$2" "$1" && rm -rf "$1.old" || mv "$1.old" "$1"
            open "$1"
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "rondo-update", current.path, newApp.path]
        try p.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// Verifies the DMG checksum, copies Rondo.app out of it into `dir` and checks
    /// bundle id and code signature. Returns the extracted app.
    static func prepare(dmgData data: Data, expectedSHA: String, in dir: URL) throws -> URL {
        let expected = expectedSHA.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard !expected.isEmpty, expected == actual else {
            throw RondoError(L("Контрольная сумма не совпала", "Checksum mismatch"))
        }
        let image = dir.appendingPathComponent("update.dmg")
        let mount = dir.appendingPathComponent("mnt", isDirectory: true)
        try data.write(to: image)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try Tools.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                           "-mountpoint", mount.path, image.path])
        defer { try? Tools.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }

        let newApp = dir.appendingPathComponent("Rondo.app")
        try Tools.run("/usr/bin/ditto", [mount.appendingPathComponent("Rondo.app").path, newApp.path])
        guard let b = Bundle(url: newApp), b.bundleIdentifier == Bundle.main.bundleIdentifier ?? "io.github.kstepanchuk.rondo" else {
            throw RondoError(L("В образе не Rondo", "Disk image doesn't contain Rondo"))
        }
        try Tools.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        try? Tools.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        return newApp
    }

    private static func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}


/// Renders GitHub release notes (Markdown) for the update dialog: clickable links,
/// "#12" for pull request URLs, @mentions linked to profiles, headings and bold.
enum ReleaseNotes {
    static func attributed(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let base: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor]
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            var attrs = base
            if line.hasPrefix("#") {
                line = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                attrs[.font] = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
                if out.length > 0 && !out.string.hasSuffix("\n\n") {
                    out.append(NSAttributedString(string: "\n", attributes: base))
                }
            } else if line.hasPrefix("* ") || line.hasPrefix("- ") {
                line = "•  " + line.dropFirst(2)
            }
            out.append(inline(line, attrs))
            out.append(NSAttributedString(string: "\n", attributes: base))
        }
        return out
    }

    /// `code`, **bold**, *italic*, URLs and @mentions in one line.
    private static func inline(_ line: String, _ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let s = NSMutableAttributedString()
        // `code` first: its content is shown as is, in a monospaced font.
        for (ci, chunk) in line.components(separatedBy: "`").enumerated() {
            if ci % 2 == 1, let f = attrs[.font] as? NSFont {
                var a = attrs
                a[.font] = NSFont.monospacedSystemFont(ofSize: f.pointSize - 0.5, weight: .regular)
                a[.backgroundColor] = NSColor.quaternaryLabelColor
                s.append(NSAttributedString(string: chunk, attributes: a))
                continue
            }
            for (bi, part) in chunk.components(separatedBy: "**").enumerated() {
                for (ii, piece) in part.components(separatedBy: "*").enumerated() {
                    var a = attrs
                    if let f = a[.font] as? NSFont {
                        var traits: NSFontTraitMask = []
                        if bi % 2 == 1 { traits.insert(.boldFontMask) }
                        if ii % 2 == 1 { traits.insert(.italicFontMask) }
                        if !traits.isEmpty { a[.font] = NSFontManager.shared.convert(f, toHaveTrait: traits) }
                    }
                    s.append(links(piece, a))
                }
            }
        }
        return s
    }

    private static let token = try! NSRegularExpression(pattern: #"https?://[^\s)]+|@[A-Za-z0-9-]+"#)

    private static func links(_ text: String, _ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let ns = text as NSString
        var last = 0
        for m in token.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            s.append(NSAttributedString(string: ns.substring(with: NSRange(location: last, length: m.range.location - last)), attributes: attrs))
            let match = ns.substring(with: m.range)
            var label = match
            var url = URL(string: match)
            if match.hasPrefix("@") {
                url = URL(string: "https://github.com/" + match.dropFirst())
            } else if let u = url, u.host == "github.com" {
                let parts = u.pathComponents
                if parts.count >= 5, ["pull", "issues"].contains(parts[3]) { label = "#" + parts[4] }   // /owner/repo/pull/12
                else if parts.count >= 5, parts[3] == "compare" { label = parts[4] }                    // v0.1.5...v0.1.6
            }
            var a = attrs
            if let url { a[.link] = url }
            s.append(NSAttributedString(string: label, attributes: a))
            last = m.range.location + m.range.length
        }
        s.append(NSAttributedString(string: ns.substring(from: last), attributes: attrs))
        return s
    }

    /// A scrollable, selectable text view sized for an NSAlert accessory.
    static func view(_ markdown: String) -> NSView {
        let width: CGFloat = 340
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.textStorage?.setAttributedString(attributed(markdown))
        text.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let needed = (text.layoutManager?.usedRect(for: text.textContainer!).height ?? 100) + 8
        let height = min(max(needed, 40), 220)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = needed > height
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        text.frame.size.height = max(needed, height)
        text.autoresizingMask = [.width]
        scroll.documentView = text
        return scroll
    }
}
