import AppKit
import UniformTypeIdentifiers

enum Mode: Int, CaseIterable {
    case convert, tools, actions

    var title: String {
        switch self {
        case .convert: return L("Конвертация", "Convert")
        case .tools: return L("Инструменты", "Tools")
        case .actions: return L("Действия", "Actions")
        }
    }
    var key: String { Settings.key(self).symbol }

    /// The mode for the currently held modifier, if any.
    static func from(_ flags: NSEvent.ModifierFlags) -> Mode? {
        Mode.allCases.first { flags.contains(Settings.key($0).flag) }
    }
}

enum Kind: Hashable {
    case folder, image, raw, video, audio, data, yaml, text, pdf, document, markdown, spreadsheet, csv, presentation, subtitle, archive, other

    static func of(_ url: URL) -> Kind {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
           !NSWorkspace.shared.isFilePackage(atPath: url.path) {
            return .folder
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "md", "markdown": return .markdown
        case "docx", "doc", "rtf", "odt", "txt", "html", "htm", "epub", "pages", "rtfd", "webarchive": return .document
        case "xlsx", "xls", "ods", "numbers": return .spreadsheet
        case "csv", "tsv": return .csv
        case "pptx", "ppt", "odp", "key": return .presentation
        case "srt", "vtt": return .subtitle
        case "json", "jsonl": return .data
        case "yaml", "yml": return .yaml
        case "log", "ini", "cfg", "conf", "nfo", "xml", "lrc", "cue", "m3u", "sub", "ass", "ssa", "tex", "bat", "sh": return .text
        case "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "tbz", "txz": return .archive
        default: break
        }
        guard let t = UTType(filenameExtension: ext) else { return .other }
        if t.conforms(to: .rawImage) { return .raw }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        return .other
    }

    /// Kind guessed from a UTI (used for file promises and raw drag data).
    static func of(uti: String) -> Kind {
        guard let t = UTType(uti), let ext = t.preferredFilenameExtension else { return .other }
        return of(URL(fileURLWithPath: "x." + ext))
    }
}

struct Operation {
    let id: String
    let title: String
    let symbol: String
    /// Opens its own window (no progress ring at the drop point while the user edits).
    var interactive = false
    /// Receives all dropped files at once; returns the files it produced.
    let perform: ([URL]) throws -> [URL]
}

// MARK: - Catalog

enum Catalog {
    static func operations(kinds: [Kind], mode: Mode) -> [Operation] {
        let unique = Array(Set(kinds))
        let count = kinds.count
        guard let first = unique.first else { return [] }

        // Batch-only operations that make one output from many inputs.
        var batch: [Operation] = []
        if count > 1 {
            if mode != .actions, unique.allSatisfy({ $0 == .pdf || $0 == .image || $0 == .raw }) { batch.append(mergePDF) }
            if mode == .tools, unique.allSatisfy({ $0 == .image || $0 == .raw }) { batch.append(collage) }
            if mode == .actions { batch.append(zipAll) }
        }

        // Per-file operations available for every kind in the drop.
        var common = list(first, mode)
        for k in unique.dropFirst() {
            let ids = Set(list(k, mode).map(\.id))
            common = common.filter { ids.contains($0.id) }
        }
        if count > 1 && mode == .actions { common.removeAll { $0.id == "zip" } }
        var all = (batch + common).filter { !Settings.isHidden($0.id) }
        if unique.count == 1, let order = Settings.order(layoutKey(first, mode)) {
            let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            all = all.enumerated().sorted { (rank[$0.element.id] ?? 1000 + $0.offset) < (rank[$1.element.id] ?? 1000 + $1.offset) }
                .map(\.element)
        }
        return all
    }

    static func layoutKey(_ kind: Kind, _ mode: Mode) -> String { "\(kind).\(mode)" }

    /// Every operation for a kind/mode, ignoring hidden/order (for the settings editor).
    static func allOperations(_ kind: Kind, _ mode: Mode) -> [Operation] {
        list(kind, mode)
    }

    private static func list(_ kind: Kind, _ mode: Mode) -> [Operation] {
        switch mode {
        case .convert: return convert(kind)
        case .tools: return tools(kind)
        case .actions: return actions(kind)
        }
    }

    // MARK: Convert

    private static func convert(_ k: Kind) -> [Operation] {
        let ff = Tools.ffmpeg != nil
        switch k {
        case .image:
            return [
                image("JPG", .jpeg), image("PNG", .png), image("HEIC", .heic),
                image("AVIF", UTType("public.avif")!), image("TIFF", .tiff), image("GIF", .gif),
                image("PDF", .pdf, symbol: "doc.richtext"),
                single("icons", L("Иконка ICNS+ICO", "Icon ICNS+ICO"), "app.badge", ext: nil, suffix: L(" иконки", " icons")) {
                    try Extras.icons($0, into: $1)
                },
            ]
        case .raw:
            return [rawConv("JPG", .jpeg), rawConv("HEIC", .heic), rawConv(L("TIFF 16 бит", "TIFF 16-bit"), .tiff, ext: "tiff"),
                    rawConv("PNG", .png), rawConv("AVIF", UTType("public.avif")!)]
        case .video:
            guard ff else { return [] }
            return [
                media("MP4", "mp4", ["-c:v", "libx264", "-preset", "medium", "-crf", Settings.videoCRF, "-pix_fmt", "yuv420p",
                                     "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]),
                media("MOV", "mov", ["-c:v", "libx264", "-crf", Settings.videoCRF, "-pix_fmt", "yuv420p", "-c:a", "aac"]),
                media("WebM", "webm", ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]),
                media("GIF", "gif", ["-vf", "fps=12,scale='min(720,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                                     "-loop", "0"], symbol: "photo.stack"),
                media("MP3", "mp3", ["-vn", "-c:a", "libmp3lame", "-q:a", "2"], symbol: "music.note"),
            ]
        case .audio:
            guard ff else { return [] }
            return [
                media("MP3", "mp3", ["-vn", "-c:a", "libmp3lame", "-q:a", "2"], symbol: "music.note"),
                media("WAV", "wav", ["-vn"], symbol: "waveform"),
                media("M4A", "m4a", ["-vn", "-c:a", "aac", "-b:a", "192k"], symbol: "music.note"),
                media("FLAC", "flac", ["-vn", "-c:a", "flac"], symbol: "waveform"),
                media("OGG", "ogg", ["-vn", "-c:a", "libopus", "-b:a", "128k"], symbol: "waveform"),
            ]
        case .pdf:
            // PDF → DOCX via Word is left out: Word shows a modal "convert PDF?" prompt.
            return [
                single("pdf-txt", "TXT", "text.alignleft", ext: "txt") { s, d in
                    try PDF.text(s).write(to: d, atomically: true, encoding: .utf8)
                },
                single("pdf-png", L("PNG (1 стр.)", "PNG (page 1)"), "photo", ext: "png") { s, d in
                    let doc = try PDF.open(s)
                    guard let p = doc.page(at: 0), let img = PDF.render(p, size: PDF.dpiSize(PDF.pageSize(p)))
                    else { throw RondoError(L("Пустой PDF", "Empty PDF")) }
                    try Images.write(img, to: d, type: .png)
                },
            ]
        case .document:
            var ops: [Operation] = []
            if Tools.word || Tools.libreOffice != nil {
                ops.append(word("PDF", "pdf", "format PDF", symbol: "doc.richtext"))
            }
            ops += [textutil("DOCX", "docx"), textutil("RTF", "rtf"), textutil("TXT", "txt"),
                    textutil("HTML", "html"), textutil("ODT", "odt")]
            if Tools.pandoc != nil { ops += [pandoc("Markdown", "md"), pandoc("EPUB", "epub")] }
            return ops
        case .markdown:
            guard Tools.pandoc != nil else { return [] }
            var ops = [pandoc("DOCX", "docx"), pandoc("HTML", "html"), pandoc("EPUB", "epub")]
            if Tools.word || Tools.libreOffice != nil {
                ops.insert(single("md-pdf", "PDF", "doc.richtext", ext: "pdf") { s, d in
                    let tmp = Paths.temp()
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    let docx = tmp.appendingPathComponent(s.deletingPathExtension().lastPathComponent + ".docx")
                    try Tools.run(Tools.pandoc!, ["--sandbox", s.path, "-o", docx.path])
                    try Office.word(docx, to: d, format: "format PDF")
                }, at: 0)
            }
            return ops
        case .spreadsheet:
            var ops: [Operation] = []
            if Tools.excel || Tools.libreOffice != nil {
                ops = [excel("PDF", "pdf", "PDF file format", symbol: "doc.richtext"),
                       excel("CSV", "csv", "CSV file format"),
                       excel("XLSX", "xlsx", "Excel XML file format")]
            } else {
                ops.append(dataConv("csv", only: "xlsx"))
            }
            return ops + [dataConv("json", only: "xlsx"), dataConv("yaml", only: "xlsx")]
        case .csv:
            var ops = [dataConv("json"), dataConv("yaml")]
            if Tools.excel || Tools.libreOffice != nil {
                ops = [excel("XLSX", "xlsx", "Excel XML file format"), excel("PDF", "pdf", "PDF file format", symbol: "doc.richtext")] + ops
            } else {
                ops.insert(dataConv("xlsx"), at: 0)
            }
            return ops
        case .presentation:
            guard Tools.powerPoint || Tools.keynote || Tools.libreOffice != nil else { return [] }
            return [single("ppt-pdf", "PDF", "doc.richtext", ext: "pdf") { s, d in
                try Office.presentationToPDF(s, to: d)
            }]
        case .subtitle:
            return [
                single("vtt", "VTT", "captions.bubble", ext: "vtt") { s, d in
                    if s.pathExtension.lowercased() == "vtt" { try FileManager.default.copyItem(at: s, to: d) }
                    else { try Subtitles.srtToVtt(s, to: d) }
                },
                single("srt", "SRT", "captions.bubble", ext: "srt") { s, d in
                    if s.pathExtension.lowercased() == "srt" { try FileManager.default.copyItem(at: s, to: d) }
                    else { try Subtitles.vttToSrt(s, to: d) }
                },
            ]
        case .data:
            return ["yaml", "csv", "xlsx"].map { dataConv($0) }
        case .yaml:
            return ["json", "csv", "xlsx"].map { dataConv($0) }
        case .archive, .other, .folder, .text:
            return []
        }
    }

    // MARK: Tools

    private static func tools(_ k: Kind) -> [Operation] {
        let ff = Tools.ffmpeg != nil
        switch k {
        case .image:
            var ops = [
                photoCrop, square,
                single("img-half", L("Уменьшить ×0.5", "Shrink ×0.5"), "arrow.down.right.and.arrow.up.left", suffix: L(" уменьш", " small")) {
                    try Images.halve($0, to: $1)
                },
                single("img-rot", L("Повернуть 90°", "Rotate 90°"), "rotate.right", suffix: L(" поворот", " rotated")) {
                    try Images.rotate($0, to: $1)
                },
                single("img-flip", L("Отразить", "Flip"), "arrow.left.and.right.righttriangle.left.righttriangle.right", suffix: L(" отраж", " flipped")) {
                    try Images.flip($0, to: $1)
                },
                single("img-exif", L("Без EXIF и GPS", "Strip EXIF/GPS"), "location.slash", suffix: L(" чистое", " clean")) {
                    try Images.stripMetadata($0, to: $1)
                },
                ocr,
                single("web", L("Для веба", "Web-ready"), "globe", ext: "jpg", suffix: " web") { try Extras.webPhoto($0, to: $1) },
                qr,
                fitImage(1), fitImage(5), fitImage(8), fitImage(25),
                single("palette", L("Палитра", "Palette"), "paintpalette", ext: "png", suffix: L(" палитра", " palette")) {
                    try Extras.palette($0, to: $1)
                },
            ]
            if #available(macOS 14.0, *) {
                ops.insert(single("img-bg", L("Убрать фон", "Remove background"), "person.crop.rectangle", ext: "png",
                                  suffix: L(" без фона", " cutout")) { try Images.removeBackground($0, to: $1) }, at: 0)
            }
            return ops
        case .video:
            var ops: [Operation] = []
            if ff {
                ops.append(editOp(video: true))
                ops += [fitVideo(8), fitVideo(25)]
                ops += [
                    media(L("Сжать", "Compress"), nil, ["-c:v", "libx264", "-preset", "slow", "-crf", "28", "-pix_fmt", "yuv420p",
                                                        "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"],
                          symbol: "arrow.down.circle", id: "v-small", ext: "mp4", suffix: L(" сжатое", " small")),
                    media(L("Без звука", "Mute"), nil, ["-c", "copy", "-an"], symbol: "speaker.slash",
                          id: "v-mute", suffix: L(" без звука", " muted")),
                    media(L("Первый кадр", "First frame"), "png", ["-frames:v", "1"], symbol: "photo", id: "v-frame"),
                    single("v-subs", L("Субтитры → SRT", "Subtitles → SRT"), "captions.bubble", ext: "srt") { s, d in
                        do { try Tools.ffmpeg(["-i", s.path, "-map", "0:s:0", d.path]) }
                        catch { throw RondoError(L("В видео нет субтитров", "No subtitle track in video")) }
                    },
                ]
                ops.append(media(L("Вертикаль 9:16", "Vertical 9:16"), nil,
                                 ["-vf", "crop='min(iw,ih*9/16)':'min(ih,iw*16/9)',scale=1080:1920,setsar=1",
                                  "-c:v", "libx264", "-crf", "21", "-pix_fmt", "yuv420p", "-c:a", "aac"],
                                 symbol: "rectangle.portrait", id: "v-vertical", ext: "mp4", suffix: " 9x16"))
            }
            ops.append(transcribe)
            return ops
        case .audio:
            var ops: [Operation] = []
            if ff {
                ops.append(editOp(video: false))
                ops += [
                    media(L("Моно", "Mono"), nil, ["-ac", "1"], symbol: "speaker.wave.1", id: "a-mono", suffix: L(" моно", " mono")),
                    media(L("Выровнять громкость", "Normalize"), nil, ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11"],
                          symbol: "dial.medium", id: "a-norm", suffix: L(" норм", " norm")),
                    media(L("Убрать тишину", "Trim silence"), nil,
                          ["-af", "silenceremove=start_periods=1:start_threshold=-45dB:stop_periods=-1:stop_duration=0.6:stop_threshold=-45dB"],
                          symbol: "waveform.badge.minus", id: "a-silence", suffix: L(" без тишины", " trimmed")),
                ]
            }
            ops.append(transcribe)
            return ops
        case .raw:
            return [
                photoCrop, square,
                single("raw-preview", L("Быстрое превью", "Quick preview"), "bolt", ext: "jpg", suffix: L(" превью", " preview")) {
                    try Raw.embeddedPreview($0, to: $1)
                },
                single("web", L("Для веба", "Web-ready"), "globe", ext: "jpg", suffix: " web") { try Extras.webPhoto($0, to: $1) },
                fitImage(1), fitImage(5), fitImage(8), fitImage(25),
                Operation(id: "raw-info", title: L("Данные съёмки", "Shot info"), symbol: "camera") { urls in
                    let text = try urls.map { "\($0.lastPathComponent): \(try Raw.shotInfo($0))" }.joined(separator: "\n")
                    DispatchQueue.main.async {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    return []
                },
                single("palette", L("Палитра", "Palette"), "paintpalette", ext: "png", suffix: L(" палитра", " palette")) {
                    try Extras.palette($0, to: $1)
                },
            ]
        case .pdf:
            return [explodePDF, ocr, qr,
                    single("pdf-split", L("По страницам", "Split pages"), "doc.on.doc", ext: nil, suffix: L(" страницы", " pages")) {
                        try PDF.split($0, into: $1)
                    },
                    single("pdf-small", L("Сжать", "Compress"), "arrow.down.circle", ext: "pdf", suffix: L(" сжатый", " small")) {
                        try PDF.compress($0, to: $1)
                    }]
        case .presentation:
            guard Tools.powerPoint || Tools.keynote || Tools.libreOffice != nil else { return [] }
            return [explodeSlides]
        case .document, .markdown, .csv, .subtitle, .data, .yaml, .text:
            return [toUTF8]
        default:
            return []
        }
    }

    // MARK: Actions

    private static func actions(_ k: Kind) -> [Operation] {
        let zip = single("zip", "ZIP", "doc.zipper", ext: "zip") { s, d in
            try Tools.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", s.path, d.path])
        }
        let sevenZip: Operation? = Tools.sevenZip.map { sz in
            single("7z", "7Z", "doc.zipper", ext: "7z") { s, d in try Tools.run(sz, ["a", "-bd", d.path, s.path]) }
        }
        let path = Operation(id: "path", title: L("Копировать путь", "Copy path"), symbol: "link") { urls in
            DispatchQueue.main.sync {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            }
            return []
        }
        let reveal = Operation(id: "reveal", title: L("Показать в Finder", "Reveal in Finder"), symbol: "folder") { urls in
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            return []
        }
        let airdrop = Operation(id: "airdrop", title: "AirDrop", symbol: "airplayaudio") { urls in
            Extras.airDrop(urls)
            return []
        }
        let share = Operation(id: "share", title: L("Поделиться", "Share"), symbol: "square.and.arrow.up") { urls in
            FileActions.share(urls)
            return []
        }
        let shelf = Operation(id: "shelf", title: L("Полочка", "Shelf"), symbol: "tray") { urls in
            DispatchQueue.main.async { ShelfPanel.show(urls) }
            return []
        }
        let move = Operation(id: "move", title: L("Переместить в…", "Move to…"), symbol: "folder.badge.plus") { urls in
            try FileActions.move(urls)
        }
        let terminal = Operation(id: "terminal", title: L("Терминал", "Terminal"), symbol: "terminal") { urls in
            try FileActions.openTerminal(urls)
            return []
        }
        let meta = Operation(id: "meta", title: L("Метаданные", "Metadata"), symbol: "info.circle") { urls in
            Metadata.show(urls)
            return []
        }
        let sha = Operation(id: "sha", title: "SHA-256", symbol: "number") { urls in
            let lines = try urls.map { "\(try Extras.sha256($0))  \($0.lastPathComponent)" }
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            }
            return []
        }
        let dup = Operation(id: "dup", title: L("Дубликат", "Duplicate"), symbol: "plus.square.on.square") { urls in
            try urls.map { s in
                let d = Paths.unique(s.deletingLastPathComponent(),
                                     s.deletingPathExtension().lastPathComponent + L(" копия", " copy"),
                                     s.pathExtension)
                try FileManager.default.copyItem(at: s, to: d)
                return d
            }
        }

        // Most used first: the first seven stay on the main ring, the rest go under "More".
        var ops: [Operation] = []
        if k == .archive { ops.append(unpack) }
        if k == .folder { ops.append(arenaDeck) }
        ops += [zip, airdrop, share, shelf, move, path, reveal, terminal, meta]
        if k != .folder { ops.append(sha) }
        ops.append(dup)
        if let sevenZip { ops.append(sevenZip) }
        return ops + UserShortcuts.operations
    }

    // MARK: Builders

    /// A per-file operation writing to ~/Downloads/Rondo/<name><suffix>.<ext>.
    /// `ext == nil` with a non-default suffix produces a folder; otherwise keeps the source extension.
    private static func single(_ id: String, _ title: String, _ symbol: String,
                               ext: String? = "", suffix: String = "",
                               _ body: @escaping (URL, URL) throws -> Void) -> Operation {
        Operation(id: id, title: title, symbol: symbol) { urls in
            try urls.map { s in
                let e: String? = ext == "" ? s.pathExtension : ext
                let d = Paths.out(for: s, ext: e, suffix: suffix)
                try body(s, d)
                return d
            }
        }
    }

    private static func fitImage(_ mb: Int) -> Operation {
        single("fit-\(mb)", L("До \(mb) МБ", "Under \(mb) MB"), "arrow.down.right.and.arrow.up.left.circle",
               ext: "jpg", suffix: L(" до \(mb) МБ", " \(mb)MB")) { try Extras.fitImage($0, to: $1, maxBytes: mb * 1_000_000) }
    }

    private static func fitVideo(_ mb: Int) -> Operation {
        single("vfit-\(mb)", L("До \(mb) МБ", "Under \(mb) MB"), "arrow.down.right.and.arrow.up.left.circle",
               ext: "mp4", suffix: L(" до \(mb) МБ", " \(mb)MB")) { try Extras.fitVideo($0, to: $1, maxBytes: mb * 1_000_000) }
    }

    /// Operations whose point is a smaller file: the toast shows the savings.
    static let shrinking: Set<String> = ["web", "v-small", "pdf-small", "img-half", "img-exif",
                                         "fit-1", "fit-5", "fit-8", "fit-25", "vfit-8", "vfit-25"]

    /// "Trim…" (audio/video) / "Trim & crop…" (video): opens the editor for the first file.
    private static func editOp(video: Bool) -> Operation {
        Operation(id: video ? "v-edit" : "a-edit",
                  title: video ? L("Обрезать и кроп…", "Trim & crop…") : L("Обрезать…", "Trim…"),
                  symbol: video ? "crop" : "scissors", interactive: true) { urls in
            guard let s = urls.first, let r = Editor.edit(s, isVideo: video) else { return [] }
            let d = Paths.out(for: s, ext: video ? "mp4" : s.pathExtension, suffix: L(" обрезка", " trimmed"))
            try Editor.export(s, r, to: d, isVideo: video)
            return [d]
        }
    }

    private static let square = Operation(id: "square", title: L("Квадрат", "Square"), symbol: "square") { urls in
        try urls.map { s in
            let img = try PhotoCrop.upright(s)
            let r = PhotoCrop.centred(1, in: CGSize(width: img.width, height: img.height))
            let d = Paths.out(for: s, ext: PhotoCrop.outputExt(s), suffix: L(" квадрат", " square"))
            try PhotoCrop.crop(s, normalized: r, to: d)
            return d
        }
    }

    /// Editor for the first photo; the same frame is applied to all of them.
    private static let photoCrop = Operation(id: "crop", title: L("Кроп…", "Crop…"), symbol: "crop", interactive: true) { urls in
        guard let first = urls.first, let rect = PhotoCrop.edit(first) else { return [] }
        return try urls.map { s in
            let d = Paths.out(for: s, ext: PhotoCrop.outputExt(s), suffix: L(" кроп", " crop"))
            try PhotoCrop.crop(s, normalized: rect, to: d)
            return d
        }
    }

    /// JSON / YAML / CSV / XLSX conversion without Office. `only` limits it to one source extension.
    private static func dataConv(_ ext: String, only: String? = nil) -> Operation {
        let title = ["json": "JSON", "yaml": "YAML", "csv": "CSV", "xlsx": "XLSX"][ext] ?? ext.uppercased()
        return single("d-\(ext)", title, ext == "xlsx" || ext == "csv" ? "tablecells" : "curlybraces", ext: ext) { s, d in
            let se = s.pathExtension.lowercased()
            if let only, se != only { throw RondoError(L("Только для .\(only)", "Only for .\(only)")) }
            if se == ext || (ext == "yaml" && se == "yml") {
                throw RondoError(L("Файл уже в \(title)", "Already \(title)"))
            }
            try DataConvert.convert(s, to: d)
        }
    }

    private static let toUTF8 = Operation(id: "utf8", title: L("В UTF-8", "To UTF-8"), symbol: "character.textbox") { urls in
        try urls.map { s in
            let d = Paths.out(for: s, ext: s.pathExtension, suffix: " (UTF-8)")
            let from = try TextEncoding.toUTF8(s, to: d)
            DispatchQueue.main.async { Toast.show("UTF-8", sub: L("Было: \(from)", "Was: \(from)")) }
            return d
        }
    }

    private static func rawConv(_ title: String, _ type: UTType, ext: String? = nil) -> Operation {
        single("raw-" + (ext ?? title.lowercased()), title, "camera.aperture", ext: ext ?? title.lowercased()) { s, d in
            try Raw.convert(s, to: d, type: type)
        }
    }

    private static func image(_ title: String, _ type: UTType, symbol: String = "photo") -> Operation {
        single("img-" + title, title, symbol, ext: title.lowercased()) { s, d in
            try Images.convert(s, to: d, type: type)
        }
    }

    private static func media(_ title: String, _ ext: String?, _ args: [String], symbol: String = "film",
                              id: String? = nil, ext forced: String? = nil, suffix: String = "") -> Operation {
        single(id ?? "ff-" + (ext ?? title), title, symbol, ext: forced ?? ext ?? "", suffix: suffix) { s, d in
            try Tools.ffmpeg(["-i", s.path] + args + [d.path])
        }
    }

    private static func textutil(_ title: String, _ ext: String) -> Operation {
        single("tu-" + ext, title, "doc.text", ext: ext) { s, d in
            if s.pathExtension.lowercased() == ext { try FileManager.default.copyItem(at: s, to: d); return }
            try Tools.run("/usr/bin/textutil", ["-convert", ext, "-output", d.path, s.path])
        }
    }

    private static func pandoc(_ title: String, _ ext: String) -> Operation {
        single("pd-" + ext, title, "doc.text", ext: ext) { s, d in
            try Tools.run(Tools.pandoc!, ["--sandbox", s.path, "-o", d.path])
        }
    }

    private static func word(_ title: String, _ ext: String, _ format: String, symbol: String = "doc.text") -> Operation {
        single("w-" + ext, title, symbol, ext: ext) { s, d in try Office.word(s, to: d, format: format) }
    }

    private static func excel(_ title: String, _ ext: String, _ format: String, symbol: String = "tablecells") -> Operation {
        single("x-" + ext, title, symbol, ext: ext) { s, d in try Office.excel(s, to: d, format: format) }
    }

    private static let ocr = single("ocr", L("Текст (OCR)", "Text (OCR)"), "text.viewfinder", ext: "txt", suffix: " OCR") { s, d in
        let text = try OCR.text(of: s)
        try text.write(to: d, atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private static let qr = Operation(id: "qr", title: L("QR → текст", "Read QR"), symbol: "qrcode.viewfinder") { urls in
        _ = try urls.flatMap(Extras.barcodes)
        return []
    }

    private static let collage = Operation(id: "collage", title: L("Коллаж", "Collage"), symbol: "square.grid.3x2") { urls in
        let d = Paths.unique(Paths.dir(for: urls.first), L("Коллаж", "Collage"), "png")
        try Extras.collage(urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }, to: d)
        return [d]
    }

    private static let transcribe = single("stt", L("Расшифровать", "Transcribe"), "text.bubble", ext: "txt") { s, d in
        try Transcriber.transcribe(s).write(to: d, atomically: true, encoding: .utf8)
    }

    /// Folder next to the source named like the file.
    private static func folderNextTo(_ s: URL) -> URL {
        Paths.unique(s.deletingLastPathComponent(), s.deletingPathExtension().lastPathComponent, nil)
    }

    private static let explodePDF = Operation(id: "explode", title: L("Разложить в PNG", "Explode to PNG"),
                                              symbol: "square.grid.2x2") { urls in
        try urls.map { s in
            let dir = folderNextTo(s)
            try PDF.explode(PDF.open(s), into: dir) { PDF.dpiSize($0) }
            return dir
        }
    }

    private static let explodeSlides = Operation(id: "explode", title: L("Разложить в PNG", "Explode to PNG"),
                                                 symbol: "square.grid.2x2") { urls in
        try urls.map { s in
            let tmp = Paths.temp()
            defer { try? FileManager.default.removeItem(at: tmp) }
            let pdf = tmp.appendingPathComponent("slides.pdf")
            try Office.presentationToPDF(s, to: pdf)
            let dir = folderNextTo(s)
            try PDF.explode(PDF.open(pdf), into: dir) { PDF.slideSize($0) }
            return dir
        }
    }

    private static let arenaDeck = Operation(id: "arena-deck", title: L("В Arena как деку", "Arena deck"),
                                             symbol: "square.stack.3d.down.right") { urls in
        let names = try urls.map { folder -> String in
            try Arena.addDeck(from: folder)
            return "«\(folder.lastPathComponent)» (\(Arena.slides(in: folder).count))"
        }
        DispatchQueue.main.async {
            Toast.show(L("Добавлено в Arena", "Added to Arena"), sub: names.joined(separator: ", "))
        }
        return []
    }

    private static let unpack = Operation(id: "unpack", title: L("Распаковать", "Extract"), symbol: "shippingbox") { urls in
        try urls.map { s in
            let dir = Paths.unique(Paths.dir(for: s), s.deletingPathExtension().lastPathComponent, nil)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = s.pathExtension.lowercased()
            if ext == "zip" {
                try Tools.run("/usr/bin/ditto", ["-x", "-k", s.path, dir.path])
            } else if ext == "7z", let sz = Tools.sevenZip {
                try Tools.run(sz, ["x", "-bd", "-o" + dir.path, s.path])
            } else {
                try Tools.run("/usr/bin/bsdtar", ["-xf", s.path, "-C", dir.path])
            }
            return dir
        }
    }

    private static let mergePDF = Operation(id: "merge", title: L("Объединить в PDF", "Merge to PDF"),
                                            symbol: "rectangle.stack") { urls in
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let d = Paths.unique(Paths.dir(for: urls.first), L("Объединённый", "Merged"), "pdf")
        try PDF.merge(sorted, to: d)
        return [d]
    }

    private static let zipAll = Operation(id: "zip-all", title: L("ZIP всех", "ZIP all"), symbol: "doc.zipper") { urls in
        let tmp = Paths.temp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let name = L("Архив", "Archive")
        let folder = tmp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for u in urls {
            try FileManager.default.copyItem(at: u, to: Paths.unique(folder, u.deletingPathExtension().lastPathComponent, u.pathExtension))
        }
        let d = Paths.unique(Paths.dir(for: urls.first), name, "zip")
        try Tools.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, d.path])
        return [d]
    }
}
