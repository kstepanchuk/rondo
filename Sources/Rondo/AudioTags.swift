import AppKit

/// Audio tags (title, artist, album, year, genre, track) and cover art, written with ffmpeg
/// into a copy of the file. Cover art goes into MP3, M4A and FLAC.
enum AudioTags {
    static let fields: [(key: String, ru: String, en: String)] = [
        ("title", "Название", "Title"), ("artist", "Исполнитель", "Artist"), ("album", "Альбом", "Album"),
        ("album_artist", "Исполнитель альбома", "Album artist"), ("date", "Год", "Year"),
        ("genre", "Жанр", "Genre"), ("track", "Номер трека", "Track"),
    ]

    static func coverSupported(_ url: URL) -> Bool { ["mp3", "m4a", "flac", "aac", "mp4"].contains(url.pathExtension.lowercased()) }

    /// Current tags, read with ffprobe (format and stream tags, case-insensitive).
    static func read(_ url: URL) -> [String: String] {
        guard let ffprobe = Tools.find("ffprobe"),
              let out = try? Tools.run(ffprobe, ["-v", "error", "-show_entries", "format_tags:stream_tags", "-of", "json", url.path]),
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { return [:] }
        var tags: [String: String] = [:]
        let streams = (json["streams"] as? [[String: Any]] ?? []).compactMap { $0["tags"] as? [String: String] }
        for dict in streams + [(json["format"] as? [String: Any])?["tags"] as? [String: String] ?? [:]] {
            for (k, v) in dict { tags[k.lowercased()] = v }
        }
        if tags["date"] == nil, let y = tags["year"] { tags["date"] = y }
        return tags
    }

    static func write(_ src: URL, tags: [String: String], cover: NSImage?, to dest: URL) throws {
        let tmp = Paths.temp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var args = ["-i", src.path]
        let withCover = cover != nil && coverSupported(src)
        if withCover, let cover, let tiff = cover.tiffRepresentation,
           let jpg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
            let art = tmp.appendingPathComponent("cover.jpg")
            try jpg.write(to: art)
            args += ["-i", art.path, "-map", "0:a", "-map", "1:v", "-disposition:v:0", "attached_pic",
                     "-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)"]
        } else {
            args += ["-map", "0"]
        }
        args += ["-c", "copy", "-map_metadata", "0"]
        for (k, v) in tags { args += ["-metadata", "\(k)=\(v)"] }
        if src.pathExtension.lowercased() == "mp3" { args += ["-id3v2_version", "3"] }
        try Tools.ffmpeg(args + [dest.path])
    }

    /// The tag form; returns nil if cancelled.
    static func edit(_ url: URL) -> (tags: [String: String], cover: NSImage?)? {
        let current = read(url)
        var result: (tags: [String: String], cover: NSImage?)?
        DispatchQueue.main.sync {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = L("Теги и обложка", "Tags and cover")
            a.informativeText = url.lastPathComponent
            let grid = NSGridView()
            grid.rowSpacing = 6
            grid.columnSpacing = 8
            var inputs: [String: NSTextField] = [:]
            for f in fields {
                let field = NSTextField(string: current[f.key] ?? "")
                field.widthAnchor.constraint(equalToConstant: 220).isActive = true
                inputs[f.key] = field
                grid.addRow(with: [NSTextField(labelWithString: L(f.ru, f.en) + ":"), field])
            }
            grid.column(at: 0).xPlacement = .trailing

            let well = NSImageView()
            well.isEditable = true            // drop an image onto it
            well.imageFrameStyle = .grayBezel
            well.imageScaling = .scaleProportionallyUpOrDown
            well.widthAnchor.constraint(equalToConstant: 140).isActive = true
            well.heightAnchor.constraint(equalToConstant: 140).isActive = true
            well.image = existingCover(url)
            let pick = NSButton(title: L("Выбрать картинку…", "Choose picture…"), target: nil, action: nil)
            let picker = CoverPicker(well: well)
            pick.target = picker
            pick.action = #selector(CoverPicker.choose)
            objc_setAssociatedObject(pick, &CoverPicker.key, picker, .OBJC_ASSOCIATION_RETAIN)
            let coverBox = NSStackView(views: [well, pick])
            coverBox.orientation = .vertical
            if !coverSupported(url) {
                well.isEnabled = false; pick.isEnabled = false
                pick.title = L("Обложка: только MP3, M4A, FLAC", "Cover: MP3, M4A, FLAC only")
            }
            let row = NSStackView(views: [grid, coverBox])
            row.alignment = .top
            row.spacing = 16
            row.frame = NSRect(x: 0, y: 0, width: 520, height: 230)
            a.accessoryView = row
            a.addButton(withTitle: L("Сохранить копию", "Save a copy"))
            a.addButton(withTitle: L("Отмена", "Cancel"))
            a.window.initialFirstResponder = inputs["title"]
            guard a.runModal() == .alertFirstButtonReturn else { return }
            var tags: [String: String] = [:]
            for (k, field) in inputs where field.stringValue != (current[k] ?? "") { tags[k] = field.stringValue }
            let newCover = well.image.flatMap { img in img === existingCoverCache ? nil : img }
            result = (tags, newCover)
        }
        return result
    }

    private static var existingCoverCache: NSImage?

    /// The embedded cover, if any (extracted with ffmpeg).
    private static func existingCover(_ url: URL) -> NSImage? {
        existingCoverCache = nil
        let tmp = Paths.temp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let out = tmp.appendingPathComponent("cover.png")
        guard (try? Tools.ffmpeg(["-i", url.path, "-an", "-frames:v", "1", out.path])) != nil,
              let img = NSImage(contentsOf: out) else { return nil }
        existingCoverCache = img
        return img
    }
}

private final class CoverPicker: NSObject {
    static var key = 0
    weak var well: NSImageView?
    init(well: NSImageView) { self.well = well }
    @objc func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let url = p.url, let img = NSImage(contentsOf: url) { well?.image = img }
    }
}
