import AVFoundation
import ImageIO
import PDFKit

/// Short explanations shown in the wheel's hub while a sector is hovered,
/// and the file card under the wheel.
enum Hints {
    static func text(for id: String) -> String? {
        if id.hasPrefix("fit-") { return L("JPG не больше \(id.dropFirst(4)) МБ", "JPG no bigger than \(id.dropFirst(4)) MB") }
        if id.hasPrefix("vfit-") { return L("Для Discord и почты", "For Discord and mail") }
        if id.hasPrefix("sc-") { return L("Ваша быстрая команда", "Your shortcut") }
        let table: [String: (String, String)] = [
            "img-JPG": ("Маленький, без прозрачности", "Small, no transparency"),
            "img-PNG": ("Без потерь, прозрачность", "Lossless, transparency"),
            "img-HEIC": ("Вдвое меньше JPG", "Half the size of JPG"),
            "img-AVIF": ("Ещё меньше, для веба", "Even smaller, for the web"),
            "img-TIFF": ("Без потерь, для печати", "Lossless, for print"),
            "img-GIF": ("256 цветов", "256 colours"),
            "img-PDF": ("Картинка как документ", "Image as a document"),
            "webp": ("Для веба, меньше JPG", "For the web, smaller than JPG"),
            "icons": ("Иконки для Mac и Windows", "Icons for Mac and Windows"),
            "raw-jpg": ("Проявить как камера", "Developed like the camera"),
            "raw-tiff": ("16 бит для обработки", "16-bit for editing"),
            "raw-preview": ("Мгновенно, JPEG камеры", "Instant, the camera's JPEG"),
            "raw-info": ("Выдержка, ISO в буфер", "Shutter, ISO to clipboard"),
            "ff-mp4": ("H.264, открывается везде", "H.264, plays everywhere"),
            "ff-mov": ("Для Apple и монтажа", "For Apple apps and editing"),
            "ff-webm": ("VP9 для веба", "VP9 for the web"),
            "ff-gif": ("Анимация без звука", "Animation, no sound"),
            "ff-mp3": ("Только звук", "Sound only"),
            "remux": ("Без перекодирования, за секунды", "No re-encoding, seconds"),
            "v-720": ("720p, меньше и легче", "720p, smaller"),
            "v-rot": ("На 90° по часовой", "90° clockwise"),
            "v-fast": ("Вдвое быстрее", "Twice as fast"),
            "v-small": ("Меньше, почти без потерь", "Smaller, nearly lossless"),
            "v-mute": ("Убрать дорожку звука", "Drop the audio track"),
            "v-frame": ("Первый кадр в PNG", "First frame as PNG"),
            "v-vertical": ("1080×1920 для Reels", "1080×1920 for Reels"),
            "v-edit": ("Обрезать и кадрировать", "Trim and crop"),
            "a-edit": ("Обрезать по времени", "Trim by time"),
            "join": ("В один файл по порядку", "Into one file, in order"),
            "stt": ("Офлайн, в TXT", "Offline, to TXT"),
            "a-norm": ("Ровная громкость", "Even loudness"),
            "a-silence": ("Вырезать паузы", "Cut the pauses"),
            "a-mono": ("Один канал", "One channel"),
            "tags": ("Название, альбом, обложка", "Title, album, cover"),
            "img-bg": ("PNG с прозрачностью", "PNG with transparency"),
            "img-half": ("Вдвое меньше по сторонам", "Half the width and height"),
            "img-exif": ("Убрать камеру и GPS", "Remove camera and GPS"),
            "ocr": ("Текст в буфер и TXT", "Text to clipboard and TXT"),
            "qr": ("Содержимое QR в буфер", "QR content to clipboard"),
            "palette": ("6 цветов, HEX в буфер", "6 colours, HEX to clipboard"),
            "web": ("≤ 2048 px, JPEG 80 %", "≤ 2048 px, JPEG 80 %"),
            "square": ("Кроп 1:1 по центру", "Centre 1:1 crop"),
            "crop": ("Редактор с пресетами", "Editor with presets"),
            "explode": ("PNG в папку рядом", "PNGs in a folder next to it"),
            "merge": ("Один PDF по порядку", "One PDF, in order"),
            "collage": ("Сетка на белом", "A grid on white"),
            "pdf-split": ("По файлу на страницу", "One file per page"),
            "pdf-small": ("Сжать картинки внутри", "Shrink the images inside"),
            "pdf-rot": ("Все страницы на 90°", "All pages by 90°"),
            "pdf-num": ("«1 / 10» внизу страниц", "“1 / 10” at the bottom"),
            "pdf-pages": ("Оставить нужные страницы", "Keep the pages you need"),
            "pdf-delete": ("Убрать лишние страницы", "Remove pages"),
            "pdf-mark": ("Текст по диагонали", "Diagonal text"),
            "utf8": ("Из 1251, KOI8, 866", "From 1251, KOI8, 866"),
            "zip": ("Архив рядом", "Archive next to it"),
            "zip-all": ("Один архив на всё", "One archive for all"),
            "unpack": ("В папку рядом", "Into a folder next to it"),
            "airdrop": ("На iPhone и Mac рядом", "To a nearby iPhone or Mac"),
            "phone": ("QR для любого телефона", "QR for any phone"),
            "share": ("В любое приложение", "To any app"),
            "shelf": ("Подержать и перетащить", "Hold it, drag it later"),
            "move": ("В выбранную папку", "To a folder you pick"),
            "path": ("Путь в буфер", "Path to clipboard"),
            "reveal": ("Открыть папку", "Open the folder"),
            "terminal": ("Терминал в этой папке", "Terminal in this folder"),
            "meta": ("Камера, GPS, кодеки", "Camera, GPS, codecs"),
            "sha": ("Контрольная сумма в буфер", "Checksum to clipboard"),
            "dup": ("Копия рядом", "A copy next to it"),
            "icon": ("Картинка как иконка", "An image as its icon"),
            "arena-deck": ("Новая дека с папкой", "A new deck from the folder"),
        ]
        if let (ru, en) = table[id] { return L(ru, en) }
        if id.hasPrefix("w-") || id.hasPrefix("x-") || id == "ppt-pdf" { return L("Через Office или LibreOffice", "Through Office or LibreOffice") }
        if id.hasPrefix("tu-") { return L("Встроенный конвертер macOS", "Built-in macOS converter") }
        if id.hasPrefix("d-") { return L("Без Office", "No Office needed") }
        return nil
    }

    // MARK: File card

    /// "photo.heic · 3.2 MB · 4032 × 3024", or "5 files · 48 MB".
    static func card(for files: [URL]) -> String? {
        guard let first = files.first else { return nil }
        func size(_ u: URL) -> Int64 { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0 }
        let fmt = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        if files.count > 1 {
            return L("Файлов: \(files.count)", "\(files.count) files") + " · " + fmt(files.map(size).reduce(0, +))
        }
        var parts = [first.lastPathComponent]
        if !first.hasDirectoryPath { parts.append(fmt(size(first))) }
        switch Kind.of(first) {
        case .image, .raw:
            if let src = CGImageSourceCreateWithURL(first as CFURL, nil),
               let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = p[kCGImagePropertyPixelWidth], let h = p[kCGImagePropertyPixelHeight] {
                parts.append("\(w) × \(h)")
            }
        case .video, .audio:
            let sem = DispatchSemaphore(value: 0)
            var seconds = 0.0
            Task {
                seconds = (try? await AVURLAsset(url: first).load(.duration).seconds) ?? 0
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 1.5)
            if seconds.isFinite, seconds > 0 {
                let s = Int(seconds.rounded())
                parts.append(s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                                       : String(format: "%d:%02d", s / 60, s % 60))
            }
        case .pdf:
            if let d = CGPDFDocument(first as CFURL) { parts.append(L("\(d.numberOfPages) стр.", "\(d.numberOfPages) pages")) }
        default: break
        }
        return parts.joined(separator: " · ")
    }

    /// The name a Convert sector will give its result, e.g. "photo.jpg".
    static func resultName(for files: [URL], op: Operation, mode: Mode) -> String? {
        guard mode == .convert, files.count == 1, let first = files.first else { return nil }
        let ext = op.title.lowercased().split(separator: " ").first.map(String.init) ?? ""
        guard ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return first.deletingPathExtension().lastPathComponent + "." + (ext == "jpeg" ? "jpg" : ext)
    }
}
