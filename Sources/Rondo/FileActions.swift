import AppKit
import AVFoundation
import ImageIO
import PDFKit

// Actions wheel: shelf, move, Terminal, share, metadata.

// MARK: - Shelf (a floating tray you can drag files back out of)

final class ShelfPanel: NSPanel {
    private static var open: [ShelfPanel] = []
    private let urls: [URL]

    static func show(_ urls: [URL]) {
        let p = ShelfPanel(urls: urls)
        open.append(p)
        p.orderFrontRegardless()
    }

    private init(urls: [URL]) {
        self.urls = urls
        let w: CGFloat = 220, h: CGFloat = 150
        let m = NSEvent.mouseLocation
        let offset = CGFloat(ShelfPanel.open.count) * 24
        super.init(contentRect: NSRect(x: m.x + 30 + offset, y: m.y - h / 2 - offset, width: w, height: h),
                   styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .hudWindow], backing: .buffered, defer: false)
        title = urls.count == 1 ? urls[0].lastPathComponent : L("Файлов: \(urls.count)", "\(urls.count) files")
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = ShelfView(urls: urls)
    }

    override func close() {
        super.close()
        ShelfPanel.open.removeAll { $0 === self }
    }
}

private final class ShelfView: NSView, NSDraggingSource {
    let urls: [URL]
    init(urls: [URL]) { self.urls = urls; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let icon = urls.count == 1 ? NSWorkspace.shared.icon(forFile: urls[0].path)
                                   : NSWorkspace.shared.icon(for: .folder)
        let s: CGFloat = 72
        icon.draw(in: NSRect(x: bounds.midX - s / 2, y: bounds.midY - s / 2 + 10, width: s, height: s))
        let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byTruncatingMiddle
        NSAttributedString(string: L("Перетащите отсюда", "Drag from here"), attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p,
        ]).draw(in: NSRect(x: 8, y: 10, width: bounds.width - 16, height: 16))
    }

    override func mouseDragged(with event: NSEvent) {
        let items = urls.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let img = NSWorkspace.shared.icon(forFile: url.path)
            img.size = NSSize(width: 64, height: 64)
            let p = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: p.x - 32, y: p.y - 32, width: 64, height: 64), contents: img)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Dropped somewhere that moved the file: the shelf has nothing left to hold.
        if operation == .move || !urls.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            window?.close()
        }
    }
}

// MARK: - Move / Terminal / Share

enum FileActions {
    private static var lastMoveFolder: URL? {
        get { UserDefaults.standard.url(forKey: "lastMoveFolder") }
        set { UserDefaults.standard.set(newValue, forKey: "lastMoveFolder") }
    }

    /// Asks for a folder (on the main thread) and moves the files there without overwriting.
    static func move(_ urls: [URL]) throws -> [URL] {
        var target: URL?
        DispatchQueue.main.sync {
            NSApp.activate(ignoringOtherApps: true)
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.canCreateDirectories = true
            p.prompt = L("Переместить", "Move")
            p.message = L("Куда переместить \(urls.count == 1 ? "«\(urls[0].lastPathComponent)»" : "файлы (\(urls.count))")?",
                          "Move \(urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) files") to:")
            p.directoryURL = lastMoveFolder ?? urls.first?.deletingLastPathComponent()
            if p.runModal() == .OK { target = p.url }
        }
        guard let target else { return [] }
        lastMoveFolder = target
        return try urls.map { s in
            let d = Paths.unique(target, s.deletingPathExtension().lastPathComponent, s.pathExtension)
            try FileManager.default.moveItem(at: s, to: d)
            return d
        }
    }

    static func openTerminal(_ urls: [URL]) throws {
        guard let first = urls.first else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
        let dir = isDir.boolValue ? first : first.deletingLastPathComponent()
        try Tools.run("/usr/bin/open", ["-a", "Terminal", dir.path])
    }

    static func share(_ urls: [URL]) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let m = NSEvent.mouseLocation
            let anchor = NSPanel(contentRect: NSRect(x: m.x, y: m.y, width: 1, height: 1),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
            anchor.backgroundColor = .clear
            anchor.level = .popUpMenu
            anchor.orderFrontRegardless()
            let picker = NSSharingServicePicker(items: urls)
            picker.show(relativeTo: .zero, of: anchor.contentView!, preferredEdge: .minY)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { anchor.orderOut(nil) }
        }
    }
}

// MARK: - Metadata

enum Metadata {
    static func describe(_ url: URL) -> [(String, String)] {
        var rows: [(String, String)] = []
        let fm = FileManager.default
        if let a = try? fm.attributesOfItem(atPath: url.path) {
            if let size = a[.size] as? Int64 { rows.append((L("Размер", "Size"), ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
            let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
            if let d = a[.creationDate] as? Date { rows.append((L("Создан", "Created"), df.string(from: d))) }
            if let d = a[.modificationDate] as? Date { rows.append((L("Изменён", "Modified"), df.string(from: d))) }
        }
        rows.append((L("Путь", "Path"), url.path))

        switch Kind.of(url) {
        case .image, .raw: rows += image(url)
        case .video, .audio: rows += media(url)
        case .pdf: rows += pdf(url)
        default: break
        }
        return rows
    }

    private static func image(_ url: URL) -> [(String, String)] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [] }
        var rows: [(String, String)] = []
        if let w = p[kCGImagePropertyPixelWidth], let h = p[kCGImagePropertyPixelHeight] {
            rows.append((L("Размер в пикселях", "Dimensions"), "\(w) × \(h)"))
        }
        if let m = p[kCGImagePropertyColorModel] { rows.append((L("Цветовая модель", "Color model"), "\(m)")) }
        if let prof = p[kCGImagePropertyProfileName] { rows.append((L("Профиль", "Profile"), "\(prof)")) }
        if (Kind.of(url) == .raw || p[kCGImagePropertyExifDictionary] != nil), let shot = try? Raw.shotInfo(url) {
            rows.append((L("Съёмка", "Shot"), shot))
        }
        if let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let la = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            let lo = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
            rows.append((L("Геопозиция", "Location"), String(format: "%.6f, %.6f", la, lo)))
        }
        return rows
    }

    private static func media(_ url: URL) -> [(String, String)] {
        let asset = AVURLAsset(url: url)
        var rows: [(String, String)] = []
        let sem = DispatchSemaphore(value: 0)
        Task {
            if let d = try? await asset.load(.duration), d.seconds.isFinite {
                let s = Int(d.seconds.rounded())
                rows.append((L("Длительность", "Duration"), String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)))
            }
            for t in (try? await asset.load(.tracks)) ?? [] {
                let desc = (try? await t.load(.formatDescriptions))?.first
                let codec = desc.map { CMFormatDescriptionGetMediaSubType($0) }.map(fourCC) ?? "?"
                let rate = (try? await t.load(.estimatedDataRate)) ?? 0
                if t.mediaType == .video {
                    let size = (try? await t.load(.naturalSize)) ?? .zero
                    let fps = (try? await t.load(.nominalFrameRate)) ?? 0
                    rows.append((L("Видео", "Video"), "\(codec) · \(Int(size.width))×\(Int(size.height)) · \(Int(fps.rounded())) fps · \(Int(rate / 1000)) kbps"))
                } else if t.mediaType == .audio {
                    let asbd = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                    let hz = asbd.map { "\(Int($0.mSampleRate)) Hz · \($0.mChannelsPerFrame) ch" } ?? ""
                    rows.append((L("Аудио", "Audio"), "\(codec) · \(hz) · \(Int(rate / 1000)) kbps"))
                }
            }
            for item in (try? await asset.load(.commonMetadata)) ?? [] {
                if let key = item.commonKey?.rawValue, let v = try? await item.load(.stringValue), !v.isEmpty {
                    rows.append((key.capitalized, v))
                }
            }
            sem.signal()
        }
        sem.wait()
        return rows
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let s = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "?"
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func pdf(_ url: URL) -> [(String, String)] {
        guard let d = PDFDocument(url: url) else { return [] }
        var rows: [(String, String)] = [(L("Страниц", "Pages"), "\(d.pageCount)")]
        let attrs = d.documentAttributes ?? [:]
        for (key, label) in [(PDFDocumentAttribute.titleAttribute, L("Название", "Title")),
                             (.authorAttribute, L("Автор", "Author")), (.creatorAttribute, L("Создано в", "Creator")),
                             (.producerAttribute, "Producer")] {
            if let v = attrs[key] { rows.append((label, "\(v)")) }
        }
        if d.isEncrypted { rows.append((L("Защита", "Security"), L("зашифрован", "encrypted"))) }
        return rows
    }

    /// Shows a small window with the facts and a "Copy all" button.
    static func show(_ urls: [URL]) {
        let text = urls.map { u in
            ([u.lastPathComponent] + describe(u).map { "\($0.0): \($0.1)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = urls.count == 1 ? urls[0].lastPathComponent : L("Метаданные", "Metadata")
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 10))
            tv.isEditable = false
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.string = text
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)
            let h = min(360, (tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 100) + 10)
            let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: h))
            sv.hasVerticalScroller = true
            sv.documentView = tv
            tv.frame.size.height = max(h, tv.frame.height)
            a.accessoryView = sv
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: L("Скопировать всё", "Copy all"))
            if a.runModal() == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}

// MARK: - Custom icons

enum CustomIcon {
    /// The image fitted into a transparent square, so Finder doesn't stretch it.
    static func squared(_ image: NSImage) -> NSImage {
        let side: CGFloat = 1024
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        let s = min(side / image.size.width, side / image.size.height)
        let w = image.size.width * s, h = image.size.height * s
        image.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        out.unlockFocus()
        return out
    }

    static func set(_ image: NSImage?, on urls: [URL]) throws {
        let icon = image.map(squared)
        for u in urls where !NSWorkspace.shared.setIcon(icon, forFile: u.path, options: []) {
            throw RondoError(L("Не удалось изменить иконку «\(u.lastPathComponent)»", "Couldn't change the icon of “\(u.lastPathComponent)”"))
        }
    }

    /// Asks for an image (on the main thread).
    static func pickImage() -> NSImage? {
        var img: NSImage?
        DispatchQueue.main.sync {
            NSApp.activate(ignoringOtherApps: true)
            let p = NSOpenPanel()
            p.allowedContentTypes = [.image]
            p.prompt = L("Выбрать", "Choose")
            p.message = L("Картинка для иконки", "Picture for the icon")
            if p.runModal() == .OK, let u = p.url { img = NSImage(contentsOf: u) }
        }
        return img
    }

    /// Asks for folders/files to put an icon on.
    static func pickTargets() -> [URL] {
        var urls: [URL] = []
        DispatchQueue.main.sync {
            NSApp.activate(ignoringOtherApps: true)
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = true
            p.allowsMultipleSelection = true
            p.prompt = L("Поставить иконку", "Set icon")
            p.message = L("Каким папкам или файлам поставить эту картинку как иконку?", "Which folders or files get this picture as their icon?")
            if p.runModal() == .OK { urls = p.urls }
        }
        return urls
    }
}
