import AppKit
import AVFoundation
import AVKit

/// Trim (audio & video) and crop (video) window. Uses AVKit's QuickTime-style
/// trimming bar; crop is a draggable frame with fixed aspect presets.
struct EditResult {
    var start: Double
    var end: Double
    /// Crop in displayed-video pixels (after rotation), nil = no crop.
    var crop: CGRect?
}

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private let url: URL
    private let isVideo: Bool
    private let player: AVPlayer
    private let playerView = AVPlayerView()
    private let overlay = CropOverlay()
    private let aspect = NSSegmentedControl()
    private let sizeSlider = NSSlider(value: 1, minValue: 0.3, maxValue: 1, target: nil, action: nil)
    private var displaySize = CGSize(width: 1, height: 1)
    private var completion: ((EditResult?) -> Void)?
    private var finished = false

    private static let aspects: [(String, CGFloat?)] = [
        (L("Без кропа", "No crop"), nil), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("1:1", 1), ("4:5", 4.0 / 5),
    ]

    init(url: URL, isVideo: Bool, completion: @escaping (EditResult?) -> Void) {
        self.url = url
        self.isVideo = isVideo
        self.completion = completion
        player = AVPlayer(url: url)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: isVideo ? 600 : 220),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = url.lastPathComponent
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(playerView)

        let hint = NSTextField(labelWithString: L("Двигайте жёлтые края полосы, чтобы обрезать, затем «Обрезать».",
                                                  "Drag the yellow handles to trim, then press Trim."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        var cons = [
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ]

        if isVideo {
            aspect.segmentCount = Self.aspects.count
            for (i, a) in Self.aspects.enumerated() { aspect.setLabel(a.0, forSegment: i) }
            aspect.selectedSegment = 0
            aspect.target = self
            aspect.action = #selector(aspectChanged)
            aspect.translatesAutoresizingMaskIntoConstraints = false
            sizeSlider.target = self
            sizeSlider.action = #selector(aspectChanged)
            sizeSlider.isEnabled = false
            sizeSlider.translatesAutoresizingMaskIntoConstraints = false
            let sizeLabel = NSTextField(labelWithString: L("Размер", "Size"))
            sizeLabel.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(aspect)
            content.addSubview(sizeLabel)
            content.addSubview(sizeSlider)

            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.isHidden = true
            playerView.addSubview(overlay)  // above the video, below AVKit's own controls
            cons += [
                aspect.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
                aspect.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
                sizeLabel.centerYAnchor.constraint(equalTo: aspect.centerYAnchor),
                sizeLabel.leadingAnchor.constraint(equalTo: aspect.trailingAnchor, constant: 18),
                sizeSlider.centerYAnchor.constraint(equalTo: aspect.centerYAnchor),
                sizeSlider.leadingAnchor.constraint(equalTo: sizeLabel.trailingAnchor, constant: 8),
                sizeSlider.widthAnchor.constraint(equalToConstant: 160),
                playerView.topAnchor.constraint(equalTo: aspect.bottomAnchor, constant: 10),
                overlay.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: playerView.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
            ]
            loadDisplaySize()
        } else {
            cons.append(playerView.topAnchor.constraint(equalTo: content.topAnchor))
        }
        NSLayoutConstraint.activate(cons)
        overlay.videoRect = { [weak self] in self?.playerView.videoBounds ?? .zero }
    }

    private func loadDisplaySize() {
        Task { [weak self] in
            guard let self, let track = try? await AVURLAsset(url: self.url).loadTracks(withMediaType: .video).first,
                  let (size, t) = try? await track.load(.naturalSize, .preferredTransform) else { return }
            let r = CGRect(origin: .zero, size: size).applying(t)
            await MainActor.run { self.displaySize = CGSize(width: abs(r.width), height: abs(r.height)) }
        }
    }

    @objc private func aspectChanged() {
        let ratio = Self.aspects[aspect.selectedSegment].1
        sizeSlider.isEnabled = ratio != nil
        overlay.isHidden = ratio == nil
        overlay.setAspect(ratio, scale: sizeSlider.doubleValue)
    }

    func show() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        // Trimming UI needs the item to be ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.startTrimming() }
    }

    private func startTrimming() {
        guard playerView.canBeginTrimming else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.startTrimming() }
            return
        }
        playerView.beginTrimming { [weak self] result in
            guard let self else { return }
            if result == .okButton, let item = self.player.currentItem {
                let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime.seconds : 0
                let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime.seconds : item.duration.seconds
                self.finish(EditResult(start: max(0, start), end: end, crop: self.cropInPixels()))
            } else {
                self.finish(nil)
            }
        }
    }

    private func cropInPixels() -> CGRect? {
        guard isVideo, !overlay.isHidden, let rect = overlay.cropRect else { return nil }
        let vb = playerView.videoBounds
        guard vb.width > 0, vb.height > 0 else { return nil }
        let sx = displaySize.width / vb.width, sy = displaySize.height / vb.height
        // View coordinates are bottom-up; ffmpeg crop is top-down. Round to even pixels for H.264.
        func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.down) * 2 }
        let w = even(rect.width * sx), h = even(rect.height * sy)
        let x = even((rect.minX - vb.minX) * sx)
        let y = even((vb.maxY - rect.maxY) * sy)
        return CGRect(x: max(0, x), y: max(0, y), width: w, height: h)
    }

    private func finish(_ r: EditResult?) {
        guard !finished else { return }
        finished = true
        player.pause()
        let c = completion
        completion = nil
        window?.close()
        c?(r)
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        player.pause()
        let c = completion
        completion = nil
        c?(nil)
    }
}

/// Dims everything outside a fixed-aspect frame; drag inside the frame to move it.
final class CropOverlay: NSView {
    var videoRect: () -> CGRect = { .zero }
    private var ratio: CGFloat?
    private var scale: CGFloat = 1
    private var center: CGPoint?   // relative 0…1 within the video rect
    private var dragStart: (CGPoint, CGPoint)?

    func setAspect(_ r: CGFloat?, scale s: Double) {
        ratio = r
        scale = CGFloat(s)
        needsDisplay = true
    }

    var cropRect: CGRect? {
        guard let ratio else { return nil }
        let vb = videoRect()
        guard vb.width > 0 else { return nil }
        var w = vb.width, h = w / ratio
        if h > vb.height { h = vb.height; w = h * ratio }
        w *= scale; h *= scale
        let c = center ?? CGPoint(x: 0.5, y: 0.5)
        var x = vb.minX + c.x * vb.width - w / 2
        var y = vb.minY + c.y * vb.height - h / 2
        x = min(max(x, vb.minX), vb.maxX - w)
        y = min(max(y, vb.minY), vb.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only grab the mouse inside the frame so AVKit's controls keep working.
        guard !isHidden, let r = cropRect, r.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let r = cropRect else { return }
        let vb = videoRect()
        let mask = NSBezierPath(rect: vb)
        mask.append(NSBezierPath(rect: r).reversed)
        NSColor.black.withAlphaComponent(0.55).setFill()
        mask.fill()
        Palette.current.accent.setStroke()
        let border = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()
        // Rule-of-thirds guides.
        NSColor.white.withAlphaComponent(0.35).setStroke()
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
            let g = NSBezierPath()
            g.move(to: CGPoint(x: x, y: r.minY)); g.line(to: CGPoint(x: x, y: r.maxY))
            g.move(to: CGPoint(x: r.minX, y: y)); g.line(to: CGPoint(x: r.maxX, y: y))
            g.lineWidth = 0.5
            g.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = (convert(event.locationInWindow, from: nil), center ?? CGPoint(x: 0.5, y: 0.5))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let (p0, c0) = dragStart else { return }
        let vb = videoRect()
        let p = convert(event.locationInWindow, from: nil)
        center = CGPoint(x: c0.x + (p.x - p0.x) / vb.width, y: c0.y + (p.y - p0.y) / vb.height)
        if let r = cropRect {  // keep the stored centre consistent with the clamped frame
            center = CGPoint(x: (r.midX - vb.minX) / vb.width, y: (r.midY - vb.minY) / vb.height)
        }
        needsDisplay = true
    }

    override func resetCursorRects() {
        if let r = cropRect { addCursorRect(r, cursor: .openHand) }
    }
}

enum Editor {
    private static var open: [EditorWindowController] = []

    /// Shows the editor on the main thread and blocks the calling (worker) thread until it closes.
    static func edit(_ url: URL, isVideo: Bool) -> EditResult? {
        let sem = DispatchSemaphore(value: 0)
        var result: EditResult?
        DispatchQueue.main.async {
            var ctl: EditorWindowController?
            ctl = EditorWindowController(url: url, isVideo: isVideo) { r in
                result = r
                open.removeAll { $0 === ctl }
                sem.signal()
            }
            open.append(ctl!)
            ctl!.show()
        }
        sem.wait()
        return result
    }

    /// Exports the edit with ffmpeg: frame-accurate trim, optional crop.
    static func export(_ src: URL, _ r: EditResult, to dest: URL, isVideo: Bool) throws {
        var args = ["-ss", String(format: "%.3f", r.start), "-i", src.path,
                    "-t", String(format: "%.3f", max(0.05, r.end - r.start))]
        if isVideo {
            if let c = r.crop {
                args += ["-vf", "crop=\(Int(c.width)):\(Int(c.height)):\(Int(c.minX)):\(Int(c.minY))"]
            }
            args += ["-c:v", "libx264", "-preset", "medium", "-crf", Settings.videoCRF, "-pix_fmt", "yuv420p",
                     "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        }
        try Tools.ffmpeg(args + [dest.path])
    }
}
