import AppKit

/// `Rondo --self-test <dir> [--office]`: runs every operation on every file in <dir>
/// and prints the result. Speech and Office operations are skipped unless asked for.
enum SelfTest {
    static func run(dir: URL, office: Bool) {
        _ = NSApplication.shared
        let skip: Set<String> = ["path", "reveal", "stt", "airdrop", "v-edit", "a-edit"]
        let officeIDs: (String) -> Bool = { $0.hasPrefix("w-") || $0.hasPrefix("x-") || $0 == "ppt-pdf" || $0 == "md-pdf" }
        var failures = 0

        DispatchQueue.global().async {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let inputs = files.filter { !$0.hasDirectoryPath }.sorted { $0.path < $1.path }
            for file in inputs {
                for mode in Mode.allCases {
                    for op in Catalog.operations(kinds: [Kind.of(file)], mode: mode) {
                        if skip.contains(op.id) || op.id.hasPrefix("sc-") { continue }
                        if officeIDs(op.id) && !office { continue }
                        if op.id == "explode" && Kind.of(file) == .presentation && !office { continue }
                        do {
                            let out = try op.perform([file])
                            print("ok   \(file.lastPathComponent) · \(mode) · \(op.id) → \(out.map(\.lastPathComponent))")
                        } catch {
                            failures += 1
                            print("FAIL \(file.lastPathComponent) · \(mode) · \(op.id): \(error.localizedDescription)")
                        }
                    }
                }
            }
            // Trim/crop export without the editor window.
            for file in inputs where [.video, .audio].contains(Kind.of(file)) {
                let video = Kind.of(file) == .video
                let r = EditResult(start: 0.5, end: 2.0, crop: video ? CGRect(x: 10, y: 10, width: 200, height: 200) : nil)
                let d = Paths.out(for: file, ext: video ? "mp4" : file.pathExtension, suffix: " trim")
                do { try Editor.export(file, r, to: d, isVideo: video); print("ok   \(file.lastPathComponent) · trim → \(d.lastPathComponent)") }
                catch { failures += 1; print("FAIL \(file.lastPathComponent) · trim: \(error.localizedDescription)") }
            }
            if inputs.count > 1 {
                let images = inputs.filter { [.image, .pdf].contains(Kind.of($0)) }
                let pics = inputs.filter { Kind.of($0) == .image }
                for op in Catalog.operations(kinds: pics.map(Kind.of), mode: .tools) where op.id == "collage" {
                    do { print("ok   collage → \(try op.perform(pics).map(\.lastPathComponent))") }
                    catch { failures += 1; print("FAIL collage: \(error.localizedDescription)") }
                }
                for op in Catalog.operations(kinds: images.map(Kind.of), mode: .tools) where op.id == "merge" {
                    do { print("ok   merge → \(try op.perform(images).map(\.lastPathComponent))") }
                    catch { failures += 1; print("FAIL merge: \(error.localizedDescription)") }
                }
            }
            print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
        RunLoop.main.run()
    }
}
