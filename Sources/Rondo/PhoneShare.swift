import AppKit
import CoreImage
import Network

/// "Send to phone": serves the chosen files over the local network for a few minutes
/// and shows a QR code. The phone's camera opens a page with download links.
/// Only these files are served, under a random 128-bit token, and only while the window is open.
final class PhoneShare {
    private static var active: [PhoneShare] = []

    private let files: [URL]
    private let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    private var listener: NWListener?
    private var window: NSWindow?
    private var deadline = Date()
    private var timer: Timer?
    private let queue = DispatchQueue(label: "rondo.phone-share")

    /// 5 minutes, plus 1 minute per 200 MB, at most 30 minutes.
    static func lifetime(for files: [URL]) -> TimeInterval {
        let bytes = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        let extra = Double(bytes) / 200_000_000 * 60
        return min(30 * 60, 5 * 60 + extra)
    }

    static func start(_ urls: [URL]) throws {
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { throw RondoError(L("Папки отправить нельзя — сначала ZIP", "Folders can't be sent; ZIP them first")) }
        guard let ip = localIPv4() else {
            throw RondoError(L("Mac не подключён к локальной сети (Wi-Fi или кабель)", "This Mac isn't on a local network"))
        }
        let share = PhoneShare(files: files)
        try share.listen(ip: ip)
        active.append(share)
    }

    private init(files: [URL]) { self.files = files }

    // MARK: Server

    private func listen(ip: String) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let port = listener.port?.rawValue {
                let url = "http://\(ip):\(port)/\(self.token)/"
                if ProcessInfo.processInfo.environment["RONDO_PRINT_SHARE_URL"] != nil { print(url); fflush(stdout) }
                DispatchQueue.main.async { self.showWindow(url: url) }
            }
            if case .failed(let e) = state {
                DispatchQueue.main.async {
                    Toast.show(L("Не удалось открыть раздачу", "Couldn't start sharing"), sub: e.localizedDescription, error: true)
                    self.stop()
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else { c.cancel(); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else { return self.reply(c, 405, "text/plain", Data("Method not allowed".utf8)) }
            let path = String(parts[1])
            let prefix = "/\(self.token)/"
            guard path.hasPrefix(prefix) else { return self.reply(c, 404, "text/plain", Data("Not found".utf8)) }
            let rest = path.dropFirst(prefix.count)
            if rest.isEmpty { return self.reply(c, 200, "text/html; charset=utf-8", Data(self.page().utf8)) }
            guard let i = Int(rest), self.files.indices.contains(i) else { return self.reply(c, 404, "text/plain", Data("Not found".utf8)) }
            self.sendFile(c, self.files[i])
        }
    }

    private func reply(_ c: NWConnection, _ status: Int, _ type: String, _ body: Data) {
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    /// Streams the file in 1 MB chunks so large videos don't load into memory.
    private func sendFile(_ c: NWConnection, _ url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return reply(c, 404, "text/plain", Data("Not found".utf8))
        }
        let name = url.lastPathComponent
        let ascii = name.unicodeScalars.map { $0.isASCII && $0 != "\"" ? String($0) : "_" }.joined()
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ascii
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(size)\r\n" +
            "Content-Disposition: attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        func next() {
            let chunk = (try? h.read(upToCount: 1 << 20)) ?? Data()
            if chunk.isEmpty {
                try? h.close()
                c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
                return
            }
            c.send(content: chunk, completion: .contentProcessed { error in
                if error == nil { next() } else { try? h.close(); c.cancel() }
            })
        }
        next()
    }

    private func page() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let fmt = { (u: URL) in ByteCountFormatter.string(fromByteCount: Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file) }
        let rows = files.enumerated().map { i, u in
            "<a class=f href=\"\(i)\" download><b>\(esc(u.lastPathComponent))</b><span>\(fmt(u))</span></a>"
        }.joined()
        return """
            <!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
            <title>Rondo</title><style>
            body{font:16px -apple-system,system-ui,sans-serif;margin:0;padding:24px;background:#0f0f12;color:#f2f2f2}
            h1{font-size:20px;margin:0 0 16px} .f{display:flex;justify-content:space-between;gap:12px;padding:16px;margin:10px 0;
            border-radius:14px;background:#1c1b1f;color:#fff;text-decoration:none;border:1px solid #333}
            .f b{word-break:break-all} .f span{color:#e5292f;white-space:nowrap} p{color:#999;font-size:13px}
            </style></head><body><h1>📲 Rondo</h1>\(rows)<p>\(L("Нажмите на файл, чтобы скачать.", "Tap a file to download it."))</p></body></html>
            """
    }

    // MARK: Window

    private func showWindow(url: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 380), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = L("Отправить на телефон", "Send to phone")
        w.isReleasedWhenClosed = false
        w.level = .floating
        let v = NSView(frame: w.contentLayoutRect)

        let qr = NSImageView(frame: NSRect(x: 30, y: 120, width: 240, height: 240))
        qr.image = Self.qrImage(url)
        qr.imageScaling = .scaleProportionallyUpOrDown
        let names = files.count == 1 ? files[0].lastPathComponent : L("Файлов: \(files.count)", "\(files.count) files")
        let label = NSTextField(wrappingLabelWithString: L("Наведите камеру телефона на код. Телефон должен быть в той же сети Wi-Fi.",
                                                           "Point your phone's camera at the code. It must be on the same Wi-Fi."))
        label.frame = NSRect(x: 20, y: 62, width: 260, height: 50)
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        let info = NSTextField(labelWithString: names)
        info.frame = NSRect(x: 20, y: 40, width: 260, height: 18)
        info.alignment = .center
        info.lineBreakMode = .byTruncatingMiddle
        info.font = .systemFont(ofSize: 12, weight: .semibold)
        let countdown = NSTextField(labelWithString: "")
        countdown.frame = NSRect(x: 20, y: 16, width: 260, height: 18)
        countdown.alignment = .center
        countdown.textColor = .secondaryLabelColor
        countdown.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        [qr, label, info, countdown].forEach(v.addSubview)
        w.contentView = v
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        window = w

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.stop()
        }
        deadline = Date().addingTimeInterval(Self.lifetime(for: files))
        let tick = { [weak self] in
            guard let self else { return }
            let left = Int(self.deadline.timeIntervalSinceNow)
            if left <= 0 { self.window?.close(); return }
            countdown.stringValue = L("Раздача закроется через ", "Sharing stops in ") + String(format: "%d:%02d", left / 60, left % 60)
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick() }
    }

    private func stop() {
        timer?.invalidate()
        listener?.cancel()
        listener = nil
        Self.active.removeAll { $0 === self }
    }

    // MARK: Helpers

    static func qrImage(_ text: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// The Mac's IPv4 address on Wi-Fi or Ethernet (not VPN tunnels or loopback).
    static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(String, String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(ifa.ifa_flags) & IFF_UP) != 0, (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }   // skip utun (VPN), bridge, awdl
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                candidates.append((name, String(cString: host)))
            }
        }
        return candidates.sorted { $0.0 < $1.0 }.first?.1
    }
}
