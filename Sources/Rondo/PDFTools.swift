import AppKit
import CoreText
import PDFKit

/// PDF page tools: rotate, page numbers, keep/delete pages, watermark.
enum PDFTools {
    static func rotate(_ src: URL, to dest: URL) throws {
        let doc = try PDF.open(src)
        for i in 0..<doc.pageCount { doc.page(at: i).map { $0.rotation = ($0.rotation + 90) % 360 } }
        guard doc.write(to: dest) else { throw RondoError(L("Ошибка записи", "Write failed")) }
    }

    /// "1-3, 5, 8-" → 0-based page indexes within `count` pages.
    static func parsePages(_ text: String, count: Int) throws -> Set<Int> {
        var out = Set<Int>()
        for part in text.replacingOccurrences(of: " ", with: "").split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            switch bounds.count {
            case 1 where bounds[0] != nil: out.insert(bounds[0]! - 1)
            case 2:
                let a = bounds[0] ?? 1, b = bounds[1] ?? count
                guard a <= b else { throw RondoError(L("Неверный диапазон «\(part)»", "Bad range “\(part)”")) }
                for p in a...b { out.insert(p - 1) }
            default: throw RondoError(L("Не понял «\(part)». Пример: 1-3, 5", "Can't read “\(part)”. Example: 1-3, 5"))
            }
        }
        out = out.filter { (0..<count).contains($0) }
        guard !out.isEmpty else { throw RondoError(L("Таких страниц нет", "No such pages")) }
        return out
    }

    /// Keeps (or removes) the listed pages.
    static func select(_ src: URL, pages: String, keep: Bool, to dest: URL) throws {
        let doc = try PDF.open(src)
        let chosen = try parsePages(pages, count: doc.pageCount)
        let out = PDFDocument()
        for i in 0..<doc.pageCount where chosen.contains(i) == keep {
            if let p = doc.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) }
        }
        guard out.pageCount > 0 else { throw RondoError(L("Не осталось ни одной страницы", "No pages left")) }
        guard out.write(to: dest) else { throw RondoError(L("Ошибка записи", "Write failed")) }
    }

    /// Redraws every page into a new PDF and lets `overlay` paint on top (in page points).
    private static func redraw(_ src: URL, to dest: URL, overlay: (CGContext, CGSize, Int, Int) -> Void) throws {
        let doc = try PDF.open(src)
        guard let ctx = CGContext(dest as CFURL, mediaBox: nil, nil) else { throw RondoError(L("Ошибка записи", "Write failed")) }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let size = PDF.pageSize(page)
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            ctx.saveGState()
            page.draw(with: .cropBox, to: ctx)   // applies the page's rotation
            ctx.restoreGState()
            overlay(ctx, size, i, doc.pageCount)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    private static func line(_ text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> CTLine {
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ])
        return CTLineCreateWithAttributedString(attr)
    }

    static func number(_ src: URL, to dest: URL) throws {
        try redraw(src, to: dest) { ctx, size, i, n in
            let fontSize = max(8, min(12, size.width / 50))
            let l = line("\(i + 1) / \(n)", size: fontSize, color: .darkGray)
            let w = CTLineGetTypographicBounds(l, nil, nil, nil)
            ctx.textPosition = CGPoint(x: (size.width - CGFloat(w)) / 2, y: max(14, size.height * 0.025))
            CTLineDraw(l, ctx)
        }
    }

    static func watermark(_ src: URL, text: String, to dest: URL) throws {
        try redraw(src, to: dest) { ctx, size, _, _ in
            let diagonal = hypot(size.width, size.height)
            let probe = line(text, size: 100, color: .clear, weight: .bold)
            let w100 = CGFloat(CTLineGetTypographicBounds(probe, nil, nil, nil))
            let fontSize = max(12, min(160, diagonal * 0.6 / max(w100, 1) * 100))
            let l = line(text, size: fontSize, color: NSColor(white: 0.5, alpha: 0.28), weight: .bold)
            let w = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
            ctx.saveGState()
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: atan2(size.height, size.width))
            ctx.textPosition = CGPoint(x: -w / 2, y: -fontSize / 3)
            CTLineDraw(l, ctx)
            ctx.restoreGState()
        }
    }
}

/// A small text prompt shown on the main thread from a background operation.
enum Ask {
    static func text(_ title: String, _ message: String, placeholder: String, initial: String = "") -> String? {
        var result: String?
        let ask = {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = title
            a.informativeText = message
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = placeholder
            field.stringValue = initial
            a.accessoryView = field
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: L("Отмена", "Cancel"))
            a.window.initialFirstResponder = field
            if a.runModal() == .alertFirstButtonReturn {
                let v = field.stringValue.trimmingCharacters(in: .whitespaces)
                result = v.isEmpty ? nil : v
            }
        }
        if Thread.isMainThread { ask() } else { DispatchQueue.main.sync(execute: ask) }
        return result
    }
}
