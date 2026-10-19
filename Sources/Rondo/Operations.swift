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
    var key: String {
        switch self { case .convert: return "⇧"; case .tools: return "⌃"; case .actions: return "⌥" }
    }

    /// The mode for the currently held modifier, if any.
    static func from(_ flags: NSEvent.ModifierFlags) -> Mode? {
        if flags.contains(.shift) { return .convert }
        if flags.contains(.control) { return .tools }
        if flags.contains(.option) { return .actions }
        return nil
    }
}

enum Kind: Hashable {
    case image, video, audio, pdf, document, markdown, spreadsheet, csv, presentation, subtitle, archive, other

    static func of(_ url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "md", "markdown": return .markdown
        case "docx", "doc", "rtf", "odt", "txt", "html", "htm", "epub", "pages", "rtfd", "webarchive": return .document
        case "xlsx", "xls", "ods", "numbers": return .spreadsheet
        case "csv", "tsv": return .csv
        case "pptx", "ppt", "odp", "key": return .presentation
        case "srt", "vtt": return .subtitle
        case "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "tbz", "txz": return .archive
        default: break
        }
        guard let t = UTType(filenameExtension: ext) else { return .other }
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
            if mode != .actions, unique.allSatisfy({ $0 == .pdf || $0 == .image }) { batch.append(mergePDF) }
            if mode == .tools, unique.allSatisfy({ $0 == .image }) { batch.append(collage) }
            if mode == .actions { batch.append(zipAll) }
        }

        // Per-file operations available for every kind in the drop.
        var common = list(first, mode)
        for k in unique.dropFirst() {
            let ids = Set(list(k, mode).map(\.id))
            common = common.filter { ids.contains($0.id) }
        }
        if count > 1 && mode == .actions { common.removeAll { $0.id == "zip" } }
        return Array((batch + common).prefix(12))
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
        case .video:
            guard ff else { return [] }
            return [
                media("MP4", "mp4", ["-c:v", "libx264", "-preset", "medium", "-crf", "23", "-pix_fmt", "yuv420p",
                                     "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]),
                media("MOV", "mov", ["-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
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
            if Tools.word { ops.append(word("PDF", "pdf", "format PDF", symbol: "doc.richtext")) }
            ops += [textutil("DOCX", "docx"), textutil("RTF", "rtf"), textutil("TXT", "txt"),
                    textutil("HTML", "html"), textutil("ODT", "odt")]
            if Tools.pandoc != nil { ops += [pandoc("Markdown", "md"), pandoc("EPUB", "epub")] }
            return ops
        case .markdown:
            guard Tools.pandoc != nil else { return [] }
            var ops = [pandoc("DOCX", "docx"), pandoc("HTML", "html"), pandoc("EPUB", "epub")]
            if Tools.word {
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
            guard Tools.excel else { return [] }
            return [excel("PDF", "pdf", "PDF file format", symbol: "doc.richtext"),
                    excel("CSV", "csv", "CSV file format"),
                    excel("XLSX", "xlsx", "Excel XML file format")]
        case .csv:
            guard Tools.excel else { return [] }
            return [excel("XLSX", "xlsx", "Excel XML file format"), excel("PDF", "pdf", "PDF file format", symbol: "doc.richtext")]
        case .presentation:
            guard Tools.powerPoint || Tools.keynote else { return [] }
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
        case .archive, .other:
            return []
        }
    }

    // MARK: Tools

    private static func tools(_ k: Kind) -> [Operation] {
        let ff = Tools.ffmpeg != nil
        switch k {
        case .image:
            var ops = [
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
        case .pdf:
            return [explodePDF, ocr, qr,
                    single("pdf-split", L("По страницам", "Split pages"), "doc.on.doc", ext: nil, suffix: L(" страницы", " pages")) {
                        try PDF.split($0, into: $1)
                    },
                    single("pdf-small", L("Сжать", "Compress"), "arrow.down.circle", ext: "pdf", suffix: L(" сжатый", " small")) {
                        try PDF.compress($0, to: $1)
                    }]
        case .presentation:
            guard Tools.powerPoint || Tools.keynote else { return [] }
            return [explodeSlides]
        default:
            return []
        }
    }

    // MARK: Actions

    private static func actions(_ k: Kind) -> [Operation] {
        var ops: [Operation] = []
        if k == .archive { ops.append(unpack) }
        ops += [
            single("zip", "ZIP", "doc.zipper", ext: "zip") { s, d in
                try Tools.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", s.path, d.path])
            },
        ]
        if let sz = Tools.sevenZip {
            ops.append(single("7z", "7Z", "doc.zipper", ext: "7z") { s, d in
                try Tools.run(sz, ["a", "-bd", d.path, s.path])
            })
        }
        ops += [
            Operation(id: "path", title: L("Копировать путь", "Copy path"), symbol: "link") { urls in
                DispatchQueue.main.sync {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                }
                return []
            },
            Operation(id: "reveal", title: L("Показать в Finder", "Reveal in Finder"), symbol: "folder") { urls in
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                return []
            },
            Operation(id: "airdrop", title: "AirDrop", symbol: "airplayaudio") { urls in
                Extras.airDrop(urls)
                return []
            },
            Operation(id: "sha", title: "SHA-256", symbol: "number") { urls in
                let lines = try urls.map { "\(try Extras.sha256($0))  \($0.lastPathComponent)" }
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                return []
            },
            Operation(id: "dup", title: L("Дубликат", "Duplicate"), symbol: "plus.square.on.square") { urls in
                try urls.map { s in
                    let d = Paths.unique(s.deletingLastPathComponent(),
                                         s.deletingPathExtension().lastPathComponent + L(" копия", " copy"),
                                         s.pathExtension)
                    try FileManager.default.copyItem(at: s, to: d)
                    return d
                }
            },
        ]
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
        let d = Paths.unique(Paths.output, L("Коллаж", "Collage"), "png")
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

    private static let unpack = Operation(id: "unpack", title: L("Распаковать", "Extract"), symbol: "shippingbox") { urls in
        try urls.map { s in
            let dir = Paths.unique(Paths.output, s.deletingPathExtension().lastPathComponent, nil)
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
        let d = Paths.unique(Paths.output, L("Объединённый", "Merged"), "pdf")
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
        let d = Paths.unique(Paths.output, name, "zip")
        try Tools.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, d.path])
        return [d]
    }
}
