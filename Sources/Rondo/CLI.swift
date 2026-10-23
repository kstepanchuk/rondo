import AppKit

/// `rondo` on the command line: the same engine as the wheel, without the UI.
///
///   rondo convert --to jpg *.heic       convert files (results next to each original)
///   rondo list photo.heic               every operation available for these files
///   rondo run img-half photo.png        run any operation by id
///   rondo formats                       what each file kind can become
enum CLI {
    static let commands: Set<String> = ["convert", "list", "run", "formats", "info", "pages", "watermark", "tags", "icon", "help", "--help", "-h", "--version"]

    static func isInvocation(_ args: [String]) -> Bool {
        args.count > 1 && commands.contains(args[1])
    }

    static func run(_ args: [String]) -> Never {
        _ = NSApplication.shared   // AppKit/Vision helpers expect an app object
        var rest = Array(args.dropFirst())
        let command = rest.removeFirst()
        var code: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        // Operations may hop to the main thread, so run them off it and keep the run loop alive.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                switch command {
                case "convert": try convert(rest)
                case "list": try list(rest)
                case "run": try runOp(rest)
                case "formats": formats()
                case "pages":
                    // rondo pages keep|delete "1-3,5" file.pdf…
                    guard rest.count >= 3, ["keep", "delete"].contains(rest[0]) else { throw RondoError(usage) }
                    let keep = rest[0] == "keep", spec = rest[1]
                    let (_, files) = try parse(Array(rest.dropFirst(2)))
                    for f in files {
                        let d = Paths.out(for: f, ext: "pdf", suffix: (keep ? " pages " : " without ") + spec)
                        try PDFTools.select(f, pages: spec, keep: keep, to: d)
                        print("✓ \(f.lastPathComponent) → \(d.path)")
                    }
                case "tags":
                    // rondo tags file.mp3 --title T --artist A --album B --date 2026 --genre G --track 1 --cover pic.jpg
                    var a = rest, tags: [String: String] = [:], cover: NSImage?
                    for key in AudioTags.fields.map(\.key) + ["year"] {
                        if let i = a.firstIndex(of: "--" + key.replacingOccurrences(of: "_", with: "-")), i + 1 < a.count {
                            tags[key == "year" ? "date" : key] = a[i + 1]; a.removeSubrange(i...(i + 1))
                        }
                    }
                    if let i = a.firstIndex(of: "--cover"), i + 1 < a.count {
                        cover = NSImage(contentsOfFile: a[i + 1]); a.removeSubrange(i...(i + 1))
                        if cover == nil { throw RondoError("can't read the cover image") }
                    }
                    let (_, files) = try parse(a)
                    for f in files {
                        let d = Paths.out(for: f, ext: f.pathExtension, suffix: " tagged")
                        try AudioTags.write(f, tags: tags, cover: cover, to: d)
                        print("✓ \(f.lastPathComponent) → \(d.path)")
                    }
                case "icon":
                    // rondo icon picture.png <folders/files…>   |   rondo icon --reset <folders/files…>
                    guard rest.count >= 2 else { throw RondoError(usage) }
                    let reset = rest[0] == "--reset"
                    let img = reset ? nil : NSImage(contentsOfFile: rest[0])
                    if !reset && img == nil { throw RondoError("can't read the image \(rest[0])") }
                    let (_, targets) = try parse(Array(rest.dropFirst()))
                    var failure: Error?
                    DispatchQueue.main.sync { do { try CustomIcon.set(img, on: targets) } catch { failure = error } }
                    if let failure { throw failure }
                    for t in targets { print("✓ \(t.lastPathComponent): \(reset ? "default icon" : "custom icon")") }
                case "watermark":
                    guard rest.count >= 2 else { throw RondoError(usage) }
                    let (_, files) = try parse(Array(rest.dropFirst()))
                    for f in files {
                        let d = Paths.out(for: f, ext: "pdf", suffix: " watermarked")
                        try PDFTools.watermark(f, text: rest[0], to: d)
                        print("✓ \(f.lastPathComponent) → \(d.path)")
                    }
                case "info":
                    let (_, files) = try parse(rest)
                    for f in files {
                        print(f.lastPathComponent)
                        for (k, v) in Metadata.describe(f) { print("  \(k): \(v)") }
                    }
                case "--version": print(version)
                default: print(usage)
                }
            } catch {
                FileHandle.standardError.write(Data("rondo: \(error.localizedDescription)\n".utf8))
                code = 1
            }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(code)
    }

    /// Homebrew links /opt/homebrew/bin/rondo to the app binary; follow the link to find Info.plist.
    static var version: String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (Bundle(url: app) ?? Bundle.main).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static let usage = """
        Usage:
          rondo convert --to <format> [--out <dir>] <files…>   e.g. rondo convert --to jpg *.heic
          rondo list <files…>                                  operations for these files
          rondo run <operation-id> [--out <dir>] <files…>      e.g. rondo run img-half photo.png
          rondo formats                                        conversions per file kind
          rondo info <files…>                                  size, dimensions, camera, codecs, pages…
          rondo pages keep|delete "1-3,5" <pdfs…>              keep or delete PDF pages
          rondo watermark "DRAFT" <pdfs…>                      diagonal watermark on every page
          rondo tags <audio…> --title T --artist A --cover pic.jpg   audio tags and cover art
          rondo icon <picture> <folders…>  |  rondo icon --reset <folders…>   custom Finder icons
        Results go next to each original unless --out is given. Originals are never overwritten.
        """

    // MARK: Commands

    private static func parse(_ args: [String], needs flag: String? = nil) throws -> (value: String?, files: [URL]) {
        var a = args, value: String?
        if let flag {
            guard let i = a.firstIndex(of: flag), i + 1 < a.count else { throw RondoError("missing \(flag)\n\n" + usage) }
            value = a[i + 1]
            a.removeSubrange(i...(i + 1))
        }
        if let i = a.firstIndex(of: "--out"), i + 1 < a.count {
            let dir = URL(fileURLWithPath: a[i + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            Paths.overrideOutput = dir
            a.removeSubrange(i...(i + 1))
        }
        let files = a.map { URL(fileURLWithPath: $0).standardizedFileURL }
        guard !files.isEmpty else { throw RondoError("no files given\n\n" + usage) }
        for f in files where !FileManager.default.fileExists(atPath: f.path) { throw RondoError("no such file: \(f.path)") }
        return (value, files)
    }

    /// Finds the Convert operation whose label is the target format ("jpg", "PDF", "tiff"…).
    static func convertOp(for kind: Kind, to format: String) -> Operation? {
        let target = format.lowercased().replacingOccurrences(of: ".", with: "")
        let aliases = ["jpeg": "jpg", "tif": "tiff", "markdown": "md"]
        let want = aliases[target] ?? target
        return Catalog.operations(kinds: [kind], mode: .convert).first { op in
            let first = op.title.lowercased().split(separator: " ").first.map(String.init) ?? ""
            let normalized = aliases[first] ?? first
            return normalized == want || (want == "md" && first == "markdown")
        }
    }

    private static func convert(_ args: [String]) throws {
        let (format, files) = try parse(args, needs: "--to")
        var failed = 0
        for f in files {
            guard let op = convertOp(for: Kind.of(f), to: format!) else {
                print("✗ \(f.lastPathComponent): can't convert to \(format!) (try: rondo list \"\(f.lastPathComponent)\")")
                failed += 1; continue
            }
            failed += perform(op, [f])
        }
        if failed > 0 { throw RondoError("\(failed) of \(files.count) failed") }
    }

    private static func runOp(_ args: [String]) throws {
        guard let id = args.first else { throw RondoError("missing operation id\n\n" + usage) }
        let (_, files) = try parse(Array(args.dropFirst()))
        let kinds = files.map(Kind.of)
        let op = Mode.allCases.lazy.flatMap { Catalog.operations(kinds: kinds, mode: $0) }.first { $0.id == id }
        guard let op else { throw RondoError("operation “\(id)” isn't available for these files (see: rondo list)") }
        guard !op.interactive else { throw RondoError("“\(id)” opens an editor; use it from the wheel") }
        if perform(op, files) > 0 { throw RondoError("failed") }
    }

    /// Runs one operation and prints the result; returns the number of failures.
    private static func perform(_ op: Operation, _ files: [URL]) -> Int {
        do {
            let outputs = try op.perform(files)
            let names = files.map(\.lastPathComponent).joined(separator: ", ")
            if outputs.isEmpty { print("✓ \(names) · \(op.title)") }
            for o in outputs { print("✓ \(names) → \(o.path)") }
            return 0
        } catch {
            print("✗ \(files.map(\.lastPathComponent).joined(separator: ", ")) · \(op.title): \(error.localizedDescription)")
            return 1
        }
    }

    private static func list(_ args: [String]) throws {
        let (_, files) = try parse(args)
        let kinds = files.map(Kind.of)
        for mode in Mode.allCases {
            let ops = Catalog.operations(kinds: kinds, mode: mode).filter { !$0.interactive }
            guard !ops.isEmpty else { continue }
            print("\(mode.title):")
            for op in ops { print("  \(op.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(op.title)") }
        }
    }

    private static func formats() {
        let samples: [(String, Kind)] = [
            ("Images", .image), ("Camera RAW", .raw), ("Video", .video), ("Audio", .audio), ("PDF", .pdf),
            ("Documents", .document), ("Markdown", .markdown), ("Spreadsheets", .spreadsheet), ("CSV", .csv),
            ("Presentations", .presentation), ("Subtitles", .subtitle),
        ]
        for (name, kind) in samples {
            let titles = Catalog.operations(kinds: [kind], mode: .convert).map(\.title)
            print("\(name.padding(toLength: 14, withPad: " ", startingAt: 0)) → " + (titles.isEmpty ? "(needs an optional engine)" : titles.joined(separator: ", ")))
        }
    }
}
