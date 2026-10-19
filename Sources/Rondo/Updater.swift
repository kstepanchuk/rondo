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
        a.informativeText = String(notes.prefix(600))
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
