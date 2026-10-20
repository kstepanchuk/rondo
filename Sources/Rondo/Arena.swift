import AppKit
import UniformTypeIdentifiers

/// Resolume Arena / Avenue via its REST API (Preferences → Webserver).
/// A folder becomes a new deck named after the folder, with its images and
/// videos in naturally sorted order loaded into layer 1, one clip per column.
enum Arena {
    static var port: Int {
        get { UserDefaults.standard.object(forKey: "arena.port") as? Int ?? 8080 }
        set { UserDefaults.standard.set(newValue, forKey: "arena.port") }
    }
    private static var base: String { "http://127.0.0.1:\(port)/api/v1" }

    // MARK: HTTP

    @discardableResult
    private static func request(_ method: String, _ path: String, json: Any? = nil, text: String? = nil) throws -> Data {
        guard let url = URL(string: base + path) else { throw RondoError("Bad Arena URL") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let text {
            req.httpBody = Data(text.utf8)
            req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        }
        let sem = DispatchSemaphore(value: 0)
        var out = Data(), status = 0, failure: Error?
        URLSession.shared.dataTask(with: req) { d, r, e in
            out = d ?? Data(); status = (r as? HTTPURLResponse)?.statusCode ?? 0; failure = e; sem.signal()
        }.resume()
        sem.wait()
        if failure != nil || status == 0 {
            throw RondoError(L("Arena не отвечает. Запустите её и включите Preferences → Webserver (порт \(port)).",
                               "Arena isn't responding. Start it and enable Preferences → Webserver (port \(port))."))
        }
        guard (200..<300).contains(status) else {
            let msg = String(decoding: out, as: UTF8.self)
            throw RondoError("Arena \(method) \(path): HTTP \(status) \(msg.prefix(120))")
        }
        return out
    }

    private static func composition() throws -> [String: Any] {
        guard let c = try JSONSerialization.jsonObject(with: request("GET", "/composition")) as? [String: Any]
        else { throw RondoError(L("Неожиданный ответ Arena", "Unexpected Arena response")) }
        return c
    }

    private static func deckIDs(_ c: [String: Any]) -> [Int64] {
        (c["decks"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? NSNumber)?.int64Value }
    }

    // MARK: Folder → deck

    /// Image and video files Arena can play, in Finder order (01, 02 … 10).
    static func slides(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { u in
            guard let t = UTType(filenameExtension: u.pathExtension) else { return false }
            return (t.conforms(to: .image) && !t.conforms(to: .rawImage)) || t.conforms(to: .movie)
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Creates a deck named after `folder` and fills layer 1. Returns the new deck id.
    @discardableResult
    static func addDeck(from folder: URL) throws -> Int64 {
        let files = slides(in: folder)
        guard !files.isEmpty else {
            throw RondoError(L("В папке «\(folder.lastPathComponent)» нет картинок или видео",
                               "No images or videos in “\(folder.lastPathComponent)”"))
        }
        let before = Set(deckIDs(try composition()))
        try request("POST", "/composition/decks/add")
        guard let id = deckIDs(try composition()).first(where: { !before.contains($0) }) else {
            throw RondoError(L("Arena не создала деку", "Arena did not create a deck"))
        }
        try request("POST", "/composition/decks/by-id/\(id)/select")
        try request("PUT", "/composition/decks/by-id/\(id)", json: ["name": ["value": folder.lastPathComponent]])

        // The selected deck now owns /composition/layers and /columns.
        var c = try composition()
        if (c["layers"] as? [Any] ?? []).isEmpty {
            try request("POST", "/composition/layers/add")
            c = try composition()
        }
        let columns = (c["columns"] as? [Any] ?? []).count
        for _ in 0..<max(0, files.count - columns) { try request("POST", "/composition/columns/add") }

        for (i, f) in files.enumerated() {
            try request("POST", "/composition/layers/1/clips/\(i + 1)/open", text: f.absoluteURL.absoluteString)
        }
        return id
    }

    static func deleteDeck(_ id: Int64) throws { try request("DELETE", "/composition/decks/by-id/\(id)") }
    static func selectDeck(_ id: Int64) throws { try request("POST", "/composition/decks/by-id/\(id)/select") }
    static func selectedDeck() throws -> Int64? {
        (try composition()["decks"] as? [[String: Any]] ?? [])
            .first { (($0["selected"] as? [String: Any])?["value"] as? Bool) == true }
            .flatMap { ($0["id"] as? NSNumber)?.int64Value }
    }
}
