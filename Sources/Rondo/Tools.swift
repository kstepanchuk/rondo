import AppKit

struct RondoError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Tools {
    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    static func find(_ names: String...) -> String? {
        for name in names {
            for dir in searchPaths {
                let p = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    static var ffmpeg: String? { find("ffmpeg") }
    static var pandoc: String? { find("pandoc") }
    static var sevenZip: String? { find("7zz", "7z") }
    /// LibreOffice's open-source headless converter (Homebrew cask: libreoffice).
    static var libreOffice: String? {
        if let executable = find("soffice") { return executable }
        let candidates = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/LibreOffice.app/Contents/MacOS/soffice").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func hasApp(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
    static var word: Bool { hasApp("com.microsoft.Word") }
    static var excel: Bool { hasApp("com.microsoft.Excel") }
    static var powerPoint: Bool { hasApp("com.microsoft.Powerpoint") }
    static var keynote: Bool { hasApp("com.apple.Keynote") }

    /// True when Office documents should go through LibreOffice: chosen in Settings,
    /// or Auto/Office with no Office app for the job. False if LibreOffice is missing.
    static func useLibreOffice(insteadOf nativeAvailable: Bool) -> Bool {
        guard libreOffice != nil else { return false }
        return Prefs.shared.docEngine == .libreOffice || !nativeAvailable
    }

    /// Runs a process, throwing with its stderr on failure. Returns stdout.
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        // Drain stderr on another thread so neither pipe can fill up and deadlock the child.
        var e = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: e, as: UTF8.self)
                .split(separator: "\n").suffix(3).joined(separator: "\n")
            throw RondoError("\((exe as NSString).lastPathComponent): \(msg)")
        }
        return String(decoding: o, as: UTF8.self)
    }

    static func ffmpeg(_ args: [String]) throws {
        guard let ff = ffmpeg else { throw RondoError(L("Нужен ffmpeg: brew install ffmpeg", "ffmpeg required: brew install ffmpeg")) }
        try run(ff, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                       "-protocol_whitelist", "file,pipe"] + args)
    }

    static func osascript(_ source: String) throws -> String {
        try run("/usr/bin/osascript", ["-e", source]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Microsoft Office / Keynote automation. Office apps are sandboxed, so files are
/// staged through the shared Office group container to avoid "Grant access" prompts.
enum Office {
    private static var stage: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/UBF8T346G9.Office/Rondo", isDirectory: true)
        let u = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Copies `src` into a staging dir, runs `script(in, out)`, moves the result to `dest`.
    private static func staged(_ src: URL, outName: String, dest: URL,
                               _ script: (String, String) -> String) throws {
        let dir = stage
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in." + src.pathExtension)
        let output = dir.appendingPathComponent(outName)
        try FileManager.default.copyItem(at: src, to: input)
        _ = try Tools.osascript(script(input.path, output.path))
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw RondoError(L("Office не создал файл", "Office did not produce a file"))
        }
        try FileManager.default.moveItem(at: output, to: dest)
    }

    static func word(_ src: URL, to dest: URL, format: String) throws {
        // Use the native app when present; otherwise LibreOffice can export headlessly.
        if Tools.useLibreOffice(insteadOf: Tools.word) {
            return try libreOfficeConvert(src, to: dest, format: dest.pathExtension)
        }
        // format: "format PDF", "format document" (docx), "format rtf", "format plain text"
        try staged(src, outName: "out." + dest.pathExtension, dest: dest) { i, o in
            """
            tell application "Microsoft Word"
                set d to open file name \(Tools.quote(i))
                set d to active document
                save as d file name \(Tools.quote(o)) file format \(format)
                close d saving no
            end tell
            """
        }
    }

    static func excel(_ src: URL, to dest: URL, format: String) throws {
        // format: "PDF file format", "CSV file format", "Excel XML file format"
        if Tools.useLibreOffice(insteadOf: Tools.excel) {
            return try libreOfficeConvert(src, to: dest, format: dest.pathExtension)
        }
        // Excel reads a UTF-8 CSV without a byte-order mark in the legacy Mac encoding,
        // which garbles Cyrillic and other non-ASCII text. Hand it a copy with the BOM.
        var input = src
        let tmp = Paths.temp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        if ["csv", "tsv"].contains(src.pathExtension.lowercased()), let data = try? Data(contentsOf: src),
           !data.starts(with: [0xEF, 0xBB, 0xBF]), String(data: data, encoding: .utf8) != nil {
            input = tmp.appendingPathComponent(src.lastPathComponent)
            try (Data([0xEF, 0xBB, 0xBF]) + data).write(to: input)
        }
        try staged(input, outName: "out." + dest.pathExtension, dest: dest) { i, o in
            """
            tell application "Microsoft Excel"
                open \(Tools.quote(i))
                set wb to active workbook
                save workbook as wb filename \(Tools.quote(o)) file format \(format) with overwrite
                close wb saving no
            end tell
            """
        }
    }

    static func presentationToPDF(_ src: URL, to dest: URL) throws {
        if Tools.useLibreOffice(insteadOf: Tools.powerPoint || Tools.keynote) {
            try libreOfficeConvert(src, to: dest, format: "pdf")
        } else if Tools.powerPoint {
            try staged(src, outName: "out.pdf", dest: dest) { i, o in
                """
                set outPath to (POSIX file \(Tools.quote(o))) as text
                tell application "Microsoft PowerPoint"
                    open \(Tools.quote(i))
                    set p to active presentation
                    save p in outPath as save as PDF
                    close p saving no
                end tell
                """
            }
        } else if Tools.keynote {
            let dir = Paths.temp()
            defer { try? FileManager.default.removeItem(at: dir) }
            let out = dir.appendingPathComponent("out.pdf")
            _ = try Tools.osascript("""
                tell application "Keynote"
                    set d to open POSIX file \(Tools.quote(src.path))
                    export d to POSIX file \(Tools.quote(out.path)) as PDF
                    close d saving no
                end tell
                """)
            try FileManager.default.moveItem(at: out, to: dest)
        } else {
            try libreOfficeConvert(src, to: dest, format: "pdf")
        }
    }

    /// Converts a document in an isolated LibreOffice profile and temporary output folder.
    /// This avoids GUI startup, profile-lock conflicts, and overwriting an existing result.
    private static func libreOfficeConvert(_ src: URL, to dest: URL, format: String) throws {
        guard let executable = Tools.libreOffice else {
            throw RondoError(L("Установите LibreOffice: brew install --cask libreoffice",
                               "Install LibreOffice: brew install --cask libreoffice"))
        }
        let work = Paths.temp()
        defer { try? FileManager.default.removeItem(at: work) }
        let input = work.appendingPathComponent(src.lastPathComponent)
        let outputDir = work.appendingPathComponent("output", isDirectory: true)
        let profileDir = work.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: input)

        let profileURL = profileDir.absoluteURL
        _ = try Tools.run(executable, [
            "--headless", "--nologo", "--nodefault", "--nolockcheck", "--norestore",
            "-env:UserInstallation=\(profileURL.absoluteString)",
            "--convert-to", format, "--outdir", outputDir.path, input.path,
        ])
        let output = outputDir.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(format)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw RondoError(L("LibreOffice не создал файл", "LibreOffice did not produce a file"))
        }
        try FileManager.default.moveItem(at: output, to: dest)
    }
}
