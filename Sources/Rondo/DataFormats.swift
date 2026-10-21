import Foundation

// Text encodings and structured data (JSON, YAML, CSV, XLSX) without any office suite.

// MARK: - Text encoding → UTF-8

enum TextEncoding {
    private static let candidates: [(String, String.Encoding)] = [
        ("Windows-1251", .windowsCP1251),
        ("KOI8-R", String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)))),
        ("DOS-866", String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosRussian.rawValue)))),
        ("Windows-1252", .windowsCP1252),
        ("Mac Cyrillic", String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.macCyrillic.rawValue)))),
    ]

    /// How "Russian" a decoding looks: common lowercase letters score, rare/garbage glyphs cost.
    private static func score(_ s: String) -> Int {
        let common = Set("оеаинтсрвлкмдпуяыьгзбчйхжшюцщэфъё")
        var n = 0
        for ch in s.prefix(20_000) {
            if common.contains(ch) { n += 2 }
            else if ch.isLetter && ch.isASCII { n += 1 }
            else if "╬╫╪┘┌█▄▌▐▀ЂЃЉЊЌЋЏђѓљњќћџ¤¦§©«®°±".contains(ch) { n -= 4 }
        }
        return n
    }

    /// Returns the decoded text and the name of the encoding it was in.
    static func decode(_ data: Data) throws -> (String, String) {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) {
            return (s, "UTF-16")
        }
        if let s = String(data: data, encoding: .utf8) { return (s, "UTF-8") }
        var best: (String, String, Int)?
        for (name, enc) in candidates {
            guard let s = String(data: data, encoding: enc) else { continue }
            let sc = score(s)
            if best == nil || sc > best!.2 { best = (s, name, sc) }
        }
        guard let best else { throw RondoError(L("Не удалось определить кодировку", "Couldn't detect the encoding")) }
        return (best.0, best.1)
    }

    static func toUTF8(_ src: URL, to dest: URL) throws -> String {
        let data = try Data(contentsOf: src)
        guard data.count < 200_000_000 else { throw RondoError(L("Файл слишком большой", "File too large")) }
        let (text, name) = try decode(data)
        if name == "UTF-8" { throw RondoError(L("Файл уже в UTF-8", "Already UTF-8")) }
        var out = text
        if out.hasPrefix("\u{FEFF}") { out.removeFirst() }
        try out.write(to: dest, atomically: true, encoding: .utf8)
        return name
    }
}

// MARK: - CSV

enum CSV {
    static func parse(_ text: String) -> [[String]] {
        let delimiter: Character = {
            let first = text.prefix { $0 != "\n" }
            let counts: [(Character, Int)] = [",", ";", "\t"].map { d in (d, first.filter { $0 == d }.count) }
            return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
        }()
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = text.replacingOccurrences(of: "\r\n", with: "\n").makeIterator()
        var pending: Character?
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() {
                        if n == "\"" { field.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" {
                row.append(field); rows.append(row); row = []; field = ""
            } else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func write(_ rows: [[String]]) -> String {
        rows.map { r in
            r.map { f in
                f.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
            }.joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }
}

// MARK: - Tables ⇄ JSON

enum Table {
    /// First row = header → [{header: value}], numbers and booleans typed.
    static func toObjects(_ rows: [[String]]) -> [[String: Any]] {
        guard let header = rows.first else { return [] }
        return rows.dropFirst().filter { !$0.allSatisfy(\.isEmpty) }.map { r in
            var o: [String: Any] = [:]
            for (i, h) in header.enumerated() where !h.isEmpty {
                let v = i < r.count ? r[i] : ""
                o[h] = typed(v)
            }
            return o
        }
    }

    static func typed(_ v: String) -> Any {
        if let i = Int(v), String(i) == v { return i }
        if let d = Double(v), v.contains(".") { return d }
        switch v.lowercased() { case "true": return true; case "false": return false; default: return v }
    }

    /// Array of objects → rows with a header of all keys in first-seen order.
    static func fromJSON(_ value: Any) throws -> [[String]] {
        let items: [Any] = (value as? [Any]) ?? [value]
        var header: [String] = []
        for case let o as [String: Any] in items {
            for k in o.keys.sorted() where !header.contains(k) { header.append(k) }
        }
        if header.isEmpty {   // array of scalars
            return [["value"]] + items.map { [string($0)] }
        }
        return [header] + items.map { item in
            let o = item as? [String: Any] ?? [:]
            return header.map { o[$0].map(string) ?? "" }
        }
    }

    static func string(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case is NSNull: return ""
        default:
            let data = (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
}

// MARK: - JSON

enum JSON {
    static func read(_ url: URL) throws -> Any {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "jsonl" {
            return try String(decoding: data, as: UTF8.self).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { try JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func write(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        try data.write(to: url)
    }
}

// MARK: - YAML (emitter + parser for the common block subset)

enum YAML {
    static func emit(_ v: Any, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch v {
        case let o as [String: Any]:
            if o.isEmpty { return "{}" }
            return o.keys.sorted().map { k in
                let val = o[k]!
                if isBlock(val) { return "\(pad)\(key(k)):\n" + emit(val, indent: indent + 1) }
                return "\(pad)\(key(k)): \(scalar(val))"
            }.joined(separator: "\n")
        case let a as [Any]:
            if a.isEmpty { return "[]" }
            return a.map { item in
                if let o = item as? [String: Any], !o.isEmpty {
                    let body = emit(o, indent: indent + 1)
                    return "\(pad)- " + body.dropFirst(pad.count + 2)
                }
                if isBlock(item) { return "\(pad)-\n" + emit(item, indent: indent + 1) }
                return "\(pad)- \(scalar(item))"
            }.joined(separator: "\n")
        default:
            return pad + scalar(v)
        }
    }

    private static func isBlock(_ v: Any) -> Bool {
        if let o = v as? [String: Any] { return !o.isEmpty }
        if let a = v as? [Any] { return !a.isEmpty }
        return false
    }

    private static func key(_ k: String) -> String { needsQuotes(k) ? quote(k) : k }

    private static func scalar(_ v: Any) -> String {
        switch v {
        case is NSNull: return "null"
        case let s as String: return needsQuotes(s) ? quote(s) : s
        case let o as [String: Any] where o.isEmpty: return "{}"
        case let a as [Any] where a.isEmpty: return "[]"
        default: return Table.string(v)
        }
    }

    private static func needsQuotes(_ s: String) -> Bool {
        if s.isEmpty || s != s.trimmingCharacters(in: .whitespaces) { return true }
        if ["true", "false", "null", "yes", "no", "~"].contains(s.lowercased()) || Double(s) != nil { return true }
        return s.contains(where: { ":#{}[],&*!|>'\"%@`\n".contains($0) }) || s.hasPrefix("-") || s.hasPrefix("?")
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    // Parser: mappings, sequences, nested by indentation, quoted/plain scalars, flow JSON-ish values.
    private struct Line { let indent: Int; let text: String }

    static func parse(_ text: String) throws -> Any {
        let lines: [Line] = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { raw in
                let s = String(raw)
                let stripped = stripComment(s)
                if stripped.trimmingCharacters(in: .whitespaces).isEmpty || stripped.hasPrefix("---") || stripped.hasPrefix("...") { return nil }
                let indent = stripped.prefix { $0 == " " }.count
                return Line(indent: indent, text: String(stripped.dropFirst(indent)).trimmingCharacters(in: .whitespaces))
            }
        var i = 0
        guard !lines.isEmpty else { return NSNull() }
        return try block(lines, &i, lines[0].indent)
    }

    private static func stripComment(_ s: String) -> String {
        var inS = false, inD = false, prev: Character = " "
        for (idx, c) in s.enumerated() {
            if c == "'" && !inD { inS.toggle() }
            if c == "\"" && !inS { inD.toggle() }
            if c == "#" && !inS && !inD && (prev == " " || idx == 0) { return String(s.prefix(idx)) }
            prev = c
        }
        return s
    }

    private static func block(_ lines: [Line], _ i: inout Int, _ indent: Int) throws -> Any {
        if lines[i].text.hasPrefix("- ") || lines[i].text == "-" {
            var arr: [Any] = []
            while i < lines.count, lines[i].indent == indent, lines[i].text.hasPrefix("-") {
                let rest = String(lines[i].text.dropFirst()).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    i += 1
                    arr.append(i < lines.count && lines[i].indent > indent ? try block(lines, &i, lines[i].indent) : NSNull())
                } else if keyColon(rest) != nil {
                    // "- key: value" starts an inline mapping; following keys are indented by 2.
                    let inner = indent + 2
                    var sub = lines
                    sub[i] = Line(indent: inner, text: rest)
                    arr.append(try mapping(sub, &i, inner))
                } else {
                    arr.append(value(rest)); i += 1
                }
            }
            return arr
        }
        return try mapping(lines, &i, indent)
    }

    private static func keyColon(_ s: String) -> String.Index? {
        var inS = false, inD = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            if c == "'" && !inD { inS.toggle() }
            if c == "\"" && !inS { inD.toggle() }
            if c == ":" && !inS && !inD {
                let next = s.index(after: idx)
                if next == s.endIndex || s[next] == " " { return idx }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    private static func mapping(_ lines: [Line], _ i: inout Int, _ indent: Int) throws -> Any {
        var obj: [String: Any] = [:]
        while i < lines.count, lines[i].indent == indent {
            let t = lines[i].text
            guard let c = keyColon(t) else { throw RondoError("YAML: line \(i + 1): expected “key: value”") }
            let k = unquote(String(t[..<c]).trimmingCharacters(in: .whitespaces))
            let rest = String(t[t.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            i += 1
            if rest.isEmpty || rest == "|" || rest == ">" {
                if rest == "|" || rest == ">" {
                    var parts: [String] = []
                    while i < lines.count, lines[i].indent > indent { parts.append(lines[i].text); i += 1 }
                    obj[k] = parts.joined(separator: rest == "|" ? "\n" : " ")
                } else if i < lines.count, lines[i].indent > indent || (lines[i].indent == indent && lines[i].text.hasPrefix("- ")) {
                    obj[k] = try block(lines, &i, lines[i].indent)
                } else { obj[k] = NSNull() }
            } else {
                obj[k] = value(rest)
            }
        }
        return obj
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return s
    }

    private static func value(_ s: String) -> Any {
        if (s.hasPrefix("[") || s.hasPrefix("{")),
           let v = try? JSONSerialization.jsonObject(with: Data(flowToJSON(s).utf8)) { return v }
        if s.hasPrefix("\"") || s.hasPrefix("'") { return unquote(s) }
        switch s.lowercased() {
        case "null", "~": return NSNull()
        case "true", "yes": return true
        case "false", "no": return false
        default: return Table.typed(s)
        }
    }

    /// `[a, b]` / `{k: v}` → JSON by quoting bare words.
    private static func flowToJSON(_ s: String) -> String {
        let re = try! NSRegularExpression(pattern: #"(?<=[\[{,:]\s?)([A-Za-z_][\w\- ]*?)(?=\s*[,:\]}])"#)
        let ns = s as NSString
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "\"$1\"")
            .replacingOccurrences(of: "\"true\"", with: "true").replacingOccurrences(of: "\"false\"", with: "false")
            .replacingOccurrences(of: "\"null\"", with: "null")
    }
}

// MARK: - XLSX without Office

enum XLSX {
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func column(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }

    static func write(_ rows: [[String]], to dest: URL) throws {
        let tmp = Paths.temp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        func put(_ path: String, _ s: String) throws {
            let u = tmp.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try s.write(to: u, atomically: true, encoding: .utf8)
        }
        var sheet = ""
        for (r, row) in rows.enumerated() {
            sheet += "<row r=\"\(r + 1)\">"
            for (c, v) in row.enumerated() where !v.isEmpty {
                let ref = column(c) + String(r + 1)
                if r > 0, Double(v) != nil, !v.hasPrefix("0") || v == "0" || v.hasPrefix("0.") {
                    sheet += "<c r=\"\(ref)\"><v>\(v)</v></c>"
                } else {
                    sheet += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(esc(v))</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        try put("[Content_Types].xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>"#)
        try put("_rels/.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#)
        try put("xl/workbook.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>"#)
        try put("xl/_rels/workbook.xml.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"#)
        try put("xl/worksheets/sheet1.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"# + sheet + "</sheetData></worksheet>")
        try Tools.run("/usr/bin/zip", ["-q", "-X", "-r", dest.path, "[Content_Types].xml", "_rels", "xl"], cwd: tmp)
    }

    /// Reads the first worksheet (shared strings, inline strings and numbers).
    static func read(_ src: URL) throws -> [[String]] {
        let tmp = Paths.temp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Tools.run("/usr/bin/ditto", ["-x", "-k", src.path, tmp.path])
        var shared: [String] = []
        if let d = try? Data(contentsOf: tmp.appendingPathComponent("xl/sharedStrings.xml")) {
            let p = SharedStrings(); let x = XMLParser(data: d); x.delegate = p; x.parse(); shared = p.items
        }
        let sheets = tmp.appendingPathComponent("xl/worksheets")
        let first = (try? FileManager.default.contentsOfDirectory(atPath: sheets.path))?
            .filter { $0.hasSuffix(".xml") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.first
        guard let first, let d = try? Data(contentsOf: sheets.appendingPathComponent(first)) else {
            throw RondoError(L("В файле нет листов", "No worksheets in the file"))
        }
        let p = Sheet(shared: shared); let x = XMLParser(data: d); x.delegate = p; x.parse()
        return p.rows
    }

    private final class SharedStrings: NSObject, XMLParserDelegate {
        var items: [String] = []
        private var cur = "", inT = false
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if e == "si" { cur = "" }
            if e == "t" { inT = true }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inT { cur += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "t" { inT = false }
            if e == "si" { items.append(cur) }
        }
    }

    private final class Sheet: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: [[String]] = []
        private var row: [Int: String] = [:], col = 0, type = "", text = "", capture = false
        init(shared: [String]) { self.shared = shared }

        private func colIndex(_ ref: String) -> Int {
            ref.prefix { $0.isLetter }.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
        }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch e {
            case "row": row = [:]
            case "c": col = colIndex(a["r"] ?? "A1"); type = a["t"] ?? ""; text = ""
            case "v", "t": capture = true
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if capture { text += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            switch e {
            case "v", "t": capture = false
            case "c": row[col] = type == "s" ? (Int(text).flatMap { $0 < shared.count ? shared[$0] : nil } ?? "") : text
            case "row":
                let n = (row.keys.max() ?? -1) + 1
                rows.append((0..<n).map { row[$0] ?? "" })
            default: break
            }
        }
    }
}

// MARK: - Conversions used by the catalog

enum DataConvert {
    static func value(of src: URL) throws -> Any {
        switch src.pathExtension.lowercased() {
        case "json", "jsonl": return try JSON.read(src)
        case "yaml", "yml": return try YAML.parse(try String(contentsOf: src, encoding: .utf8))
        case "csv", "tsv": return Table.toObjects(CSV.parse(try TextEncoding.decode(Data(contentsOf: src)).0))
        case "xlsx": return Table.toObjects(try XLSX.read(src))
        default: throw RondoError(L("Неподдерживаемый формат данных", "Unsupported data format"))
        }
    }

    static func convert(_ src: URL, to dest: URL) throws {
        let v = try value(of: src)
        switch dest.pathExtension.lowercased() {
        case "json": try JSON.write(v, to: dest)
        case "yaml": try (YAML.emit(v) + "\n").write(to: dest, atomically: true, encoding: .utf8)
        case "csv": try CSV.write(try Table.fromJSON(v)).write(to: dest, atomically: true, encoding: .utf8)
        case "xlsx": try XLSX.write(try Table.fromJSON(v), to: dest)
        default: throw RondoError(L("Неподдерживаемый формат данных", "Unsupported data format"))
        }
    }
}
