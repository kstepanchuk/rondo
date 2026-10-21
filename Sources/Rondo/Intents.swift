import AppIntents
import Foundation

// Shortcuts / Spotlight actions. They run the same operations as the wheel, so a
// folder automation or a Quick Action can convert without dragging anything.

enum TargetFormat: String, AppEnum {
    case jpg, png, heic, avif, tiff, pdf, mp4, mov, gif, mp3, m4a, wav, docx, txt, html

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Format"
    static var caseDisplayRepresentations: [TargetFormat: DisplayRepresentation] = [
        .jpg: "JPEG", .png: "PNG", .heic: "HEIC", .avif: "AVIF", .tiff: "TIFF", .pdf: "PDF",
        .mp4: "MP4", .mov: "MOV", .gif: "GIF", .mp3: "MP3", .m4a: "M4A", .wav: "WAV",
        .docx: "Word (DOCX)", .txt: "Text (TXT)", .html: "HTML",
    ]
}

/// Copies Shortcuts' input files somewhere we can write next to, runs the operation
/// for each, and hands the results back as files.
private func process(_ files: [IntentFile], pick: (Kind) -> Operation?) throws -> [IntentFile] {
    let work = Paths.temp()
    let outDir = work.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    Paths.overrideOutput = outDir
    defer { Paths.overrideOutput = nil }

    var results: [IntentFile] = []
    for (i, file) in files.enumerated() {
        let name = file.filename.isEmpty ? "file-\(i + 1)" : file.filename
        let src: URL
        if let url = file.fileURL, FileManager.default.isReadableFile(atPath: url.path) {
            src = url
        } else {
            src = work.appendingPathComponent(name)
            try file.data.write(to: src)
        }
        guard let op = pick(Kind.of(src)) else {
            throw RondoError(L("Rondo не умеет так обработать «\(name)»", "Rondo can't do that with “\(name)”"))
        }
        for out in try op.perform([src]) {
            results.append(IntentFile(fileURL: out, filename: out.lastPathComponent))
        }
    }
    return results
}

struct ConvertFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Convert Files with Rondo"
    static var description = IntentDescription("Converts files to another format on your Mac, offline.")

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"])
    var files: [IntentFile]

    @Parameter(title: "Format", default: .jpg)
    var format: TargetFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to \(\.$format)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let target = format.rawValue
        let out = try process(files) { CLI.convertOp(for: $0, to: target) }
        return .result(value: out)
    }
}

struct ConvertToJPEGIntent: AppIntent {
    static var title: LocalizedStringResource = "Convert to JPEG with Rondo"
    static var description = IntentDescription("Turns photos (HEIC, PNG, RAW…) into JPEG.")

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.image"])
    var files: [IntentFile]

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try process(files) { CLI.convertOp(for: $0, to: "jpg") })
    }
}

struct ConvertToPDFIntent: AppIntent {
    static var title: LocalizedStringResource = "Convert to PDF with Rondo"
    static var description = IntentDescription("Turns images and documents into PDF.")

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"])
    var files: [IntentFile]

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try process(files) { CLI.convertOp(for: $0, to: "pdf") })
    }
}

struct CompressIntent: AppIntent {
    static var title: LocalizedStringResource = "Compress with Rondo"
    static var description = IntentDescription("Makes photos, videos and PDFs smaller.")

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"])
    var files: [IntentFile]

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let ids = ["web", "v-small", "pdf-small"]
        return .result(value: try process(files) { kind in
            Catalog.operations(kinds: [kind], mode: .tools).first { ids.contains($0.id) }
        })
    }
}

struct RondoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConvertToJPEGIntent(), phrases: ["Convert to JPEG with \(.applicationName)"])
        AppShortcut(intent: CompressIntent(), phrases: ["Compress with \(.applicationName)"])
        AppShortcut(intent: ConvertToPDFIntent(), phrases: ["Convert to PDF with \(.applicationName)"])
    }
}
