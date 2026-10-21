import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Vision

private func copyToClipboard(_ s: String) {
    DispatchQueue.main.async {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

enum Extras {
    // MARK: QR / barcodes

    static func barcodes(in url: URL) throws -> [String] {
        var images: [CGImage] = []
        if url.pathExtension.lowercased() == "pdf" {
            let doc = try PDF.open(url)
            for i in 0..<doc.pageCount {
                if let p = doc.page(at: i), let img = PDF.render(p, size: PDF.dpiSize(PDF.pageSize(p))) { images.append(img) }
            }
        } else {
            images = [try Images.load(url).1]
        }
        var found: [String] = []
        for img in images {
            let req = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: img).perform([req])
            found += (req.results ?? []).compactMap(\.payloadStringValue)
        }
        guard !found.isEmpty else { throw RondoError(L("QR-коды не найдены", "No QR codes found")) }
        copyToClipboard(found.joined(separator: "\n"))
        return found
    }

    // MARK: SHA-256

    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Web-ready photo

    /// Longest side ≤ 2048 px (configurable), JPEG 80 %, no metadata.
    static func webPhoto(_ src: URL, to dest: URL) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Settings.webMaxSize,
              ] as CFDictionary)
        else { throw RondoError(L("Не удалось прочитать изображение", "Cannot read image")) }
        guard let dst = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw RondoError(L("Ошибка записи", "Write failed")) }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.8,
                                              kCGImageDestinationBackgroundColor: CGColor(gray: 1, alpha: 1)] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw RondoError(L("Ошибка записи", "Write failed")) }
    }

    // MARK: Fit under a size

    /// A JPEG no bigger than `maxBytes`: lowers quality first (to 50 %), then the pixel
    /// size (down to 640 px on the long side). Throws rather than produce a uselessly tiny file.
    static func fitImage(_ src: URL, to dest: URL, maxBytes: Int) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let full = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 16384,
              ] as CFDictionary)
        else { throw RondoError(L("Не удалось прочитать изображение", "Cannot read image")) }

        func encode(_ img: CGImage, _ q: Double) -> Data? {
            let data = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: q,
                                                  kCGImageDestinationBackgroundColor: CGColor(gray: 1, alpha: 1)] as CFDictionary)
            return CGImageDestinationFinalize(dst) ? data as Data : nil
        }
        func scaled(_ img: CGImage, _ f: CGFloat) -> CGImage? {
            let w = Int(CGFloat(img.width) * f), h = Int(CGFloat(img.height) * f)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }

        var img = full
        while true {
            for q in stride(from: 0.9, through: 0.5, by: -0.1) {
                if let d = encode(img, q), d.count <= maxBytes { return try d.write(to: dest) }
            }
            let long = max(img.width, img.height)
            guard long > 640, let smaller = scaled(img, max(0.6, 640 / CGFloat(long) > 0.85 ? 640 / CGFloat(long) : 0.85)) else {
                throw RondoError(L("Не помещается в \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)) без потери читаемости",
                                   "Can't fit in \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)) without becoming unreadable"))
            }
            img = smaller
        }
    }

    /// Re-encodes a video to land just under `maxBytes` (H.264 + 96 kbps AAC, two-pass bitrate math).
    static func fitVideo(_ src: URL, to dest: URL, maxBytes: Int) throws {
        guard let ffprobe = Tools.find("ffprobe") else { throw RondoError(L("Нужен ffmpeg: brew install ffmpeg", "ffmpeg required: brew install ffmpeg")) }
        let dur = Double(try Tools.run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", src.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard dur > 0 else { throw RondoError(L("Не удалось узнать длительность видео", "Couldn't read the video's duration")) }
        let audio = 96_000.0
        let video = Double(maxBytes) * 8 * 0.94 / dur - audio   // 6 % for container overhead
        guard video > 150_000 else {
            throw RondoError(L("Видео слишком длинное для такого размера", "The video is too long for that size"))
        }
        let tmp = Paths.temp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let log = tmp.appendingPathComponent("pass").path
        let common = ["-i", src.path, "-c:v", "libx264", "-preset", "medium", "-b:v", "\(Int(video))", "-pix_fmt", "yuv420p",
                      "-passlogfile", log]
        try Tools.ffmpeg(common + ["-pass", "1", "-an", "-f", "mp4", "/dev/null"])
        try Tools.ffmpeg(common + ["-pass", "2", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", dest.path])
    }

    // MARK: App icons (ICNS + ICO)

    private static func square(_ src: URL, _ px: Int) throws -> CGImage {
        let (_, img) = try Images.load(src)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RondoError(L("Ошибка обработки", "Processing failed")) }
        ctx.interpolationQuality = .high
        let s = CGFloat(px) / CGFloat(max(img.width, img.height))
        let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
        ctx.draw(img, in: CGRect(x: (CGFloat(px) - w) / 2, y: (CGFloat(px) - h) / 2, width: w, height: h))
        return ctx.makeImage()!
    }

    private static func png(_ img: CGImage) -> Data {
        NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
    }

    /// Writes "<name> иконки/" with icon.icns and icon.ico.
    static func icons(_ src: URL, into dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = Paths.temp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let set = tmp.appendingPathComponent("icon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            try png(square(src, base)).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
            try png(square(src, base * 2)).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
        }
        try Tools.run("/usr/bin/iconutil", ["-c", "icns", set.path, "-o", dir.appendingPathComponent("icon.icns").path])

        // ICO with embedded PNGs (supported since Windows Vista).
        let sizes = [16, 24, 32, 48, 64, 128, 256]
        let blobs = try sizes.map { try png(square(src, $0)) }
        var ico = Data()
        func le16(_ v: Int) { var x = UInt16(v).littleEndian; ico.append(Data(bytes: &x, count: 2)) }
        func le32(_ v: Int) { var x = UInt32(v).littleEndian; ico.append(Data(bytes: &x, count: 4)) }
        le16(0); le16(1); le16(sizes.count)
        var offset = 6 + 16 * sizes.count
        for (s, b) in zip(sizes, blobs) {
            ico.append(UInt8(s >= 256 ? 0 : s)); ico.append(UInt8(s >= 256 ? 0 : s))
            ico.append(0); ico.append(0)
            le16(1); le16(32); le32(b.count); le32(offset)
            offset += b.count
        }
        blobs.forEach { ico.append($0) }
        try ico.write(to: dir.appendingPathComponent("icon.ico"))
    }

    // MARK: Colour palette

    /// Six dominant colours (k-means on a 64×64 thumbnail) → swatch PNG; HEX list to clipboard.
    static func palette(_ src: URL, to dest: URL) throws {
        let (_, img) = try Images.load(src)
        let n = 64
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RondoError(L("Ошибка обработки", "Processing failed")) }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
        var points: [SIMD3<Float>] = []
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 128 {
            points.append(SIMD3(Float(px[i]), Float(px[i + 1]), Float(px[i + 2])))
        }
        guard !points.isEmpty else { throw RondoError(L("Пустое изображение", "Empty image")) }
        let k = min(6, points.count)
        var centers = (0..<k).map { points[$0 * points.count / k] }
        var counts = [Int](repeating: 0, count: k)
        for _ in 0..<12 {
            var sums = [SIMD3<Float>](repeating: .zero, count: k)
            counts = [Int](repeating: 0, count: k)
            for p in points {
                let j = (0..<k).min { simd_distance_squared(p, centers[$0]) < simd_distance_squared(p, centers[$1]) }!
                sums[j] += p; counts[j] += 1
            }
            for j in 0..<k where counts[j] > 0 { centers[j] = sums[j] / Float(counts[j]) }
        }
        let order = (0..<k).sorted { counts[$0] > counts[$1] }
        let hex = order.map { j in
            String(format: "#%02X%02X%02X", Int(centers[j].x), Int(centers[j].y), Int(centers[j].z))
        }
        copyToClipboard(hex.joined(separator: " "))

        let cell = 200, height = 260
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cell * k, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: cell * k, height: height).fill()
        for (i, j) in order.enumerated() {
            let c = centers[j]
            NSColor(srgbRed: CGFloat(c.x) / 255, green: CGFloat(c.y) / 255, blue: CGFloat(c.z) / 255, alpha: 1).setFill()
            NSRect(x: i * cell, y: 60, width: cell, height: height - 60).fill()
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            NSAttributedString(string: hex[i], attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .medium),
                .foregroundColor: NSColor.black, .paragraphStyle: style,
            ]).draw(in: NSRect(x: i * cell, y: 16, width: cell, height: 30))
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: dest)
    }

    // MARK: Collage

    /// Grid of images on white, 600 px cells, aspect-fit.
    static func collage(_ urls: [URL], to dest: URL) throws {
        let imgs = urls.compactMap { try? Images.load($0).1 }
        guard !imgs.isEmpty else { throw RondoError(L("Нет изображений", "No images")) }
        let cols = Int(ceil(sqrt(Double(imgs.count)))), rows = Int(ceil(Double(imgs.count) / Double(cols)))
        let cell = 600, gap = 16
        let w = cols * cell + (cols + 1) * gap, h = rows * cell + (rows + 1) * gap
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RondoError(L("Ошибка обработки", "Processing failed")) }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        for (i, img) in imgs.enumerated() {
            let col = i % cols, row = i / cols
            let s = CGFloat(cell) / CGFloat(max(img.width, img.height))
            let iw = CGFloat(img.width) * s, ih = CGFloat(img.height) * s
            let x = CGFloat(gap + col * (cell + gap)) + (CGFloat(cell) - iw) / 2
            let y = CGFloat(h - (row + 1) * (cell + gap)) + (CGFloat(cell) - ih) / 2
            ctx.draw(img, in: CGRect(x: x, y: y, width: iw, height: ih))
        }
        try Images.write(ctx.makeImage()!, to: dest, type: .png)
    }

    // MARK: AirDrop

    static func airDrop(_ urls: [URL]) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
        }
    }
}

// MARK: - User Shortcuts (Shortcuts.app folder "Rondo")

enum UserShortcuts {
    private(set) static var names: [String] = []

    /// Refreshes the list in the background; the menu uses whatever is cached.
    static func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let out = (try? Tools.run("/usr/bin/shortcuts", ["list", "--folder-name", "Rondo"])) ?? ""
            let list = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            DispatchQueue.main.async { names = list }
        }
    }

    static var operations: [Operation] {
        names.prefix(4).map { name in
            Operation(id: "sc-" + name, title: name, symbol: "square.stack.3d.up") { urls in
                try Tools.run("/usr/bin/shortcuts", ["run", name] + urls.flatMap { ["-i", $0.path] })
                return []
            }
        }
    }
}
