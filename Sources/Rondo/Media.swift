import AppKit
import AVFoundation
import CoreImage
import ImageIO
import PDFKit
import Speech
import UniformTypeIdentifiers
import Vision

// MARK: - Images (ImageIO)

enum Images {
    /// ImageIO writes AVIF only on newer macOS versions.
    static let canWriteAVIF: Bool = {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains("public.avif")
    }()

    static func load(_ url: URL) throws -> (CGImageSource, CGImage) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary)
        else { throw RondoError(L("Не удалось прочитать изображение", "Cannot read image")) }
        return (src, img)
    }

    static func write(_ image: CGImage, to url: URL, type: UTType,
                      properties: [CFString: Any] = [:]) throws {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw RondoError(L("Формат не поддерживается", "Format not supported")) }
        var props = properties
        props[kCGImageDestinationLossyCompressionQuality] = Settings.imageQuality
        CGImageDestinationAddImage(dst, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw RondoError(L("Ошибка записи", "Write failed")) }
    }

    /// Re-encodes the image into another container, keeping metadata.
    static func convert(_ src: URL, to dest: URL, type: UTType) throws {
        if type == .pdf {
            guard let ns = NSImage(contentsOf: src), let page = PDFPage(image: ns) else {
                throw RondoError(L("Не удалось прочитать изображение", "Cannot read image"))
            }
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            guard doc.write(to: dest) else { throw RondoError(L("Ошибка записи", "Write failed")) }
            return
        }
        let (source, _) = try load(src)
        guard let dst = CGImageDestinationCreateWithURL(dest as CFURL, type.identifier as CFString, 1, nil)
        else { throw RondoError(L("Формат не поддерживается", "Format not supported")) }
        var opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Settings.imageQuality]
        if type == .jpeg { opts[kCGImageDestinationBackgroundColor] = CGColor(gray: 1, alpha: 1) }
        CGImageDestinationAddImageFromSource(dst, source, 0, opts as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw RondoError(L("Ошибка записи", "Write failed")) }
    }

    static func stripMetadata(_ src: URL, to dest: URL) throws {
        let (source, img) = try load(src)
        let type = UTType(CGImageSourceGetType(source) as String? ?? "") ?? .jpeg
        // Keep orientation so the photo isn't rotated, drop EXIF/GPS/IPTC/TIFF/XMP.
        var props: [CFString: Any] = [:]
        if let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let o = p[kCGImagePropertyOrientation] { props[kCGImagePropertyOrientation] = o }
        try write(img, to: dest, type: type, properties: props)
    }

    static func transform(_ src: URL, to dest: URL, _ body: (CIImage) -> CIImage) throws {
        guard let ci = CIImage(contentsOf: src, options: [.applyOrientationProperty: true])
        else { throw RondoError(L("Не удалось прочитать изображение", "Cannot read image")) }
        let out = body(ci)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(out, from: out.extent)
        else { throw RondoError(L("Ошибка обработки", "Processing failed")) }
        let type = UTType(filenameExtension: dest.pathExtension) ?? .png
        try write(cg, to: dest, type: type)
    }

    static func halve(_ src: URL, to dest: URL) throws {
        try transform(src, to: dest) { img in
            let f = CIFilter(name: "CILanczosScaleTransform")!
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(0.5, forKey: kCIInputScaleKey)
            f.setValue(1.0, forKey: kCIInputAspectRatioKey)
            return f.outputImage!
        }
    }

    static func rotate(_ src: URL, to dest: URL) throws {
        try transform(src, to: dest) { $0.oriented(.right) }
    }

    static func flip(_ src: URL, to dest: URL) throws {
        try transform(src, to: dest) { $0.oriented(.upMirrored) }
    }

    @available(macOS 14.0, *)
    static func removeBackground(_ src: URL, to dest: URL) throws {
        guard let ci = CIImage(contentsOf: src, options: [.applyOrientationProperty: true])
        else { throw RondoError(L("Не удалось прочитать изображение", "Cannot read image")) }
        let handler = VNImageRequestHandler(ciImage: ci)
        let req = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([req])
        guard let obs = req.results?.first, !obs.allInstances.isEmpty else {
            throw RondoError(L("Объект на фото не найден", "No subject found"))
        }
        let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler,
                                                 croppedToInstancesExtent: false)
        let out = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(out, from: out.extent)
        else { throw RondoError(L("Ошибка обработки", "Processing failed")) }
        try write(cg, to: dest, type: .png)
    }
}

// MARK: - PDF

enum PDF {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let d = PDFDocument(url: url) else { throw RondoError(L("Не удалось открыть PDF", "Cannot open PDF")) }
        if d.isLocked { throw RondoError(L("PDF защищён паролем", "PDF is password-protected")) }
        return d
    }

    /// Renders a page to a CGImage at exactly `size` pixels (white background).
    static func render(_ page: PDFPage, size: CGSize) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let pageW = rotated ? box.height : box.width
        let pageH = rotated ? box.width : box.height
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(w) / pageW, y: CGFloat(h) / pageH)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    static func pageSize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox)
        return page.rotation % 180 != 0 ? CGSize(width: b.height, height: b.width) : b.size
    }

    /// Writes every page as 01.png, 02.png… into `dir`. `sizeFor` picks pixel size per page.
    static func explode(_ doc: PDFDocument, into dir: URL, sizeFor: (CGSize) -> CGSize) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digits = max(2, String(doc.pageCount).count)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i),
                  let img = render(page, size: sizeFor(pageSize(page))) else { continue }
            let name = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
            try Images.write(img, to: dir.appendingPathComponent(name + ".png"), type: .png)
        }
    }

    static func dpiSize(_ points: CGSize, dpi: CGFloat = 200) -> CGSize {
        CGSize(width: points.width * dpi / 72, height: points.height * dpi / 72)
    }

    /// Slides: height 1080, width from the aspect ratio (16:9 → 1920×1080).
    static func slideSize(_ points: CGSize) -> CGSize {
        let ratio = points.width / points.height
        if abs(ratio - 16.0 / 9.0) < 0.02 { return CGSize(width: 1920, height: 1080) }
        return CGSize(width: (1080 * ratio).rounded(), height: 1080)
    }

    static func text(_ url: URL) throws -> String {
        try open(url).string ?? ""
    }

    static func split(_ url: URL, into dir: URL) throws {
        let doc = try open(url)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digits = max(2, String(doc.pageCount).count)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let one = PDFDocument()
            one.insert(page.copy() as! PDFPage, at: 0)
            let n = String(i + 1)
            let name = String(repeating: "0", count: max(0, digits - n.count)) + n
            one.write(to: dir.appendingPathComponent(name + ".pdf"))
        }
    }

    static func compress(_ url: URL, to dest: URL) throws {
        let doc = try open(url)
        var opts: [PDFDocumentWriteOption: Any] = [:]
        if #available(macOS 13.4, *) {
            opts[.saveImagesAsJPEGOption] = true
            opts[.optimizeImagesForScreenOption] = true
        }
        guard doc.write(to: dest, withOptions: opts) else { throw RondoError(L("Ошибка записи", "Write failed")) }
    }

    /// Merges PDFs and images (in the given order) into one PDF.
    static func merge(_ urls: [URL], to dest: URL) throws {
        let out = PDFDocument()
        for u in urls {
            if u.pathExtension.lowercased() == "pdf" {
                let d = try open(u)
                for i in 0..<d.pageCount {
                    if let p = d.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) }
                }
            } else if let img = NSImage(contentsOf: u), let p = PDFPage(image: img) {
                out.insert(p, at: out.pageCount)
            }
        }
        guard out.write(to: dest) else { throw RondoError(L("Ошибка записи", "Write failed")) }
    }
}

// MARK: - OCR (Vision)

enum OCR {
    static func recognize(_ image: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["ru-RU", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func text(of url: URL) throws -> String {
        if url.pathExtension.lowercased() == "pdf" {
            let doc = try PDF.open(url)
            var parts: [String] = []
            for i in 0..<doc.pageCount {
                guard let p = doc.page(at: i),
                      let img = PDF.render(p, size: PDF.dpiSize(PDF.pageSize(p), dpi: 250)) else { continue }
                parts.append(try recognize(img))
            }
            return parts.joined(separator: "\n\n")
        }
        return try recognize(Images.load(url).1)
    }
}

// MARK: - Speech to text

enum Transcriber {
    static func authorize() throws {
        let sem = DispatchSemaphore(value: 0)
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { status = $0; sem.signal() }
            sem.wait()
        }
        guard status == .authorized else {
            throw RondoError(L("Разрешите распознавание речи в Системных настройках → Конфиденциальность",
                               "Allow Speech Recognition in System Settings → Privacy"))
        }
    }

    static func transcribe(_ url: URL) throws -> String {
        try authorize()
        // Extract audio to m4a first so video files and odd codecs work.
        let tmp = Paths.temp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let audio = tmp.appendingPathComponent("a.m4a")
        if Tools.ffmpeg != nil {
            try Tools.ffmpeg(["-i", url.path, "-vn", "-ac", "1", "-c:a", "aac", audio.path])
        } else {
            try exportAudio(url, to: audio)
        }

        let locale = Locale(identifier: Prefs.shared.isRussian ? "ru-RU" : "en-US")
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            throw RondoError(L("Распознавание речи недоступно", "Speech recognition unavailable"))
        }
        rec.queue = OperationQueue()
        let req = SFSpeechURLRecognitionRequest(url: audio)
        req.shouldReportPartialResults = false
        // Never send audio to Apple's servers: on-device only.
        guard rec.supportsOnDeviceRecognition else {
            throw RondoError(L("Офлайн-распознавание недоступно: скачайте язык в Настройках → Клавиатура → Диктовка",
                               "On-device recognition unavailable: download the language in Settings → Keyboard → Dictation"))
        }
        req.requiresOnDeviceRecognition = true
        req.addsPunctuation = true

        let sem = DispatchSemaphore(value: 0)
        var text = "", failure: Error?
        let task = rec.recognitionTask(with: req) { result, error in
            if let result, result.isFinal { text = result.bestTranscription.formattedString; sem.signal() }
            else if let error { failure = error; sem.signal() }
        }
        sem.wait()
        task.cancel()
        if let failure, text.isEmpty { throw failure }
        return text
    }

    private static func exportAudio(_ src: URL, to dest: URL) throws {
        let asset = AVURLAsset(url: src)
        guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw RondoError(L("Не удалось извлечь звук", "Cannot extract audio"))
        }
        s.outputURL = dest
        s.outputFileType = .m4a
        let sem = DispatchSemaphore(value: 0)
        s.exportAsynchronously { sem.signal() }
        sem.wait()
        if let e = s.error { throw e }
    }
}

// MARK: - Subtitles

enum Subtitles {
    private struct Cue { var start: String; var end: String; var text: [String] }

    private static func parse(_ s: String) -> [Cue] {
        let blocks = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        var cues: [Cue] = []
        for b in blocks {
            let lines = b.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[i].components(separatedBy: "-->")
            let start = parts[0].trimmingCharacters(in: .whitespaces)
            let end = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            let text = lines[(i + 1)...].filter { !$0.isEmpty }
            cues.append(Cue(start: start, end: end, text: Array(text)))
        }
        return cues
    }

    /// Normalizes "mm:ss.mmm" / "hh:mm:ss,mmm" to "hh:mm:ss<sep>mmm".
    private static func time(_ t: String, sep: String) -> String {
        var t = t.replacingOccurrences(of: ",", with: ".")
        if t.split(separator: ":").count == 2 { t = "00:" + t }
        return t.replacingOccurrences(of: ".", with: sep)
    }

    static func srtToVtt(_ src: URL, to dest: URL) throws {
        let cues = parse(try String(contentsOf: src, encoding: .utf8))
        var out = "WEBVTT\n\n"
        for c in cues {
            out += "\(time(c.start, sep: ".")) --> \(time(c.end, sep: "."))\n" + c.text.joined(separator: "\n") + "\n\n"
        }
        try out.write(to: dest, atomically: true, encoding: .utf8)
    }

    static func vttToSrt(_ src: URL, to dest: URL) throws {
        let cues = parse(try String(contentsOf: src, encoding: .utf8))
        var out = ""
        for (n, c) in cues.enumerated() {
            out += "\(n + 1)\n\(time(c.start, sep: ",")) --> \(time(c.end, sep: ","))\n" + c.text.joined(separator: "\n") + "\n\n"
        }
        try out.write(to: dest, atomically: true, encoding: .utf8)
    }
}
