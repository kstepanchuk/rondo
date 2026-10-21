import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Photo crop: an editor with aspect presets and a draggable frame (shares CropOverlay
/// with the video editor), plus a one-click centre square.
enum PhotoCrop {
    static let presets: [(String, CGFloat)] = [
        ("1:1", 1), ("4:5", 4.0 / 5), ("3:4", 3.0 / 4), ("2:3", 2.0 / 3), ("9:16", 9.0 / 16),
        ("16:9", 16.0 / 9), ("3:2", 3.0 / 2),
    ]

    /// Upright, full-size image (orientation applied, RAW developed by ImageIO).
    static func upright(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 16384,
              ] as CFDictionary)
        else { throw RondoError(L("Не удалось прочитать изображение", "Cannot read image")) }
        return img
    }

    /// Crops `src` to `rect` given in 0…1 of the upright image (origin top-left) and writes `dest`.
    static func crop(_ src: URL, normalized rect: CGRect, to dest: URL) throws {
        let img = try upright(src)
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let r = CGRect(x: rect.minX * w, y: rect.minY * h, width: rect.width * w, height: rect.height * h).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = img.cropping(to: r) else { throw RondoError(L("Ошибка кропа", "Crop failed")) }
        let type = UTType(filenameExtension: dest.pathExtension) ?? .jpeg
        try Images.write(out, to: dest, type: type)
    }

    /// Largest centred rect of `ratio` (w/h) inside an image of `size`, normalized.
    static func centred(_ ratio: CGFloat, in size: CGSize) -> CGRect {
        var w = size.width, h = w / ratio
        if h > size.height { h = size.height; w = h * ratio }
        return CGRect(x: (size.width - w) / 2 / size.width, y: (size.height - h) / 2 / size.height,
                      width: w / size.width, height: h / size.height)
    }

    /// Output keeps the format, except RAW (not writable) which becomes JPG.
    static func outputExt(_ src: URL) -> String {
        Kind.of(src) == .raw ? "jpg" : src.pathExtension
    }

    // MARK: Editor

    /// Shows the editor for the first image; returns the chosen normalized rect, or nil if cancelled.
    static func edit(_ url: URL) -> CGRect? {
        let sem = DispatchSemaphore(value: 0)
        var result: CGRect?
        DispatchQueue.main.async {
            guard let img = try? upright(url) else { sem.signal(); return }
            let ctl = PhotoCropWindow(image: img, title: url.lastPathComponent) { r in result = r; sem.signal() }
            ctl.show()
        }
        sem.wait()
        return result
    }
}

private final class PhotoCropWindow: NSWindowController, NSWindowDelegate {
    private static var open: [PhotoCropWindow] = []
    private let image: CGImage
    private let imageView = NSImageView()
    private let overlay = CropOverlay()
    private let aspect = NSSegmentedControl()
    private let sizeSlider = NSSlider(value: 1, minValue: 0.2, maxValue: 1, target: nil, action: nil)
    private var completion: ((CGRect?) -> Void)?

    init(image: CGImage, title: String, completion: @escaping (CGRect?) -> Void) {
        self.image = image
        self.completion = completion
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        overlay.videoRect = { [weak self] in self?.imageRect() ?? .zero }

        aspect.segmentCount = PhotoCrop.presets.count
        for (i, p) in PhotoCrop.presets.enumerated() { aspect.setLabel(p.0, forSegment: i) }
        aspect.selectedSegment = 0
        aspect.target = self
        aspect.action = #selector(changed)
        sizeSlider.target = self
        sizeSlider.action = #selector(changed)
        let sizeLabel = NSTextField(labelWithString: L("Размер", "Size"))
        let cancel = NSButton(title: L("Отмена", "Cancel"), target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: L("Обрезать", "Crop"), target: self, action: #selector(okTapped))
        ok.keyEquivalent = "\r"

        for v in [imageView, overlay, aspect, sizeLabel, sizeSlider, cancel, ok] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            aspect.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            aspect.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            sizeLabel.centerYAnchor.constraint(equalTo: aspect.centerYAnchor),
            sizeLabel.leadingAnchor.constraint(equalTo: aspect.trailingAnchor, constant: 16),
            sizeSlider.centerYAnchor.constraint(equalTo: aspect.centerYAnchor),
            sizeSlider.leadingAnchor.constraint(equalTo: sizeLabel.trailingAnchor, constant: 8),
            sizeSlider.widthAnchor.constraint(equalToConstant: 140),
            imageView.topAnchor.constraint(equalTo: aspect.bottomAnchor, constant: 10),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            imageView.bottomAnchor.constraint(equalTo: ok.topAnchor, constant: -10),
            overlay.topAnchor.constraint(equalTo: imageView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
            ok.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            ok.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            cancel.trailingAnchor.constraint(equalTo: ok.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: ok.centerYAnchor),
        ])
        changed()
    }

    /// Where the image is drawn inside the image view (aspect-fit), in overlay coordinates.
    private func imageRect() -> CGRect {
        let b = imageView.bounds
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let s = min(b.width / iw, b.height / ih)
        let w = iw * s, h = ih * s
        return CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
    }

    @objc private func changed() {
        overlay.setAspect(PhotoCrop.presets[aspect.selectedSegment].1, scale: sizeSlider.doubleValue)
    }

    func show() {
        PhotoCropWindow.open.append(self)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }

    @objc private func okTapped() {
        let ir = imageRect()
        guard let r = overlay.cropRect, ir.width > 0 else { return finish(nil) }
        // View coordinates are bottom-up; normalized output is top-down.
        finish(CGRect(x: (r.minX - ir.minX) / ir.width, y: (ir.maxY - r.maxY) / ir.height,
                      width: r.width / ir.width, height: r.height / ir.height))
    }

    @objc private func cancelTapped() { finish(nil) }

    func windowWillClose(_ notification: Notification) { finish(nil, closing: true) }

    private func finish(_ r: CGRect?, closing: Bool = false) {
        guard let c = completion else { return }
        completion = nil
        if !closing { window?.close() }
        PhotoCropWindow.open.removeAll { $0 === self }
        c(r)
    }
}
