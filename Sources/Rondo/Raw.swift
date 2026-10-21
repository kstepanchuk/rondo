import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Camera RAW (CR2/CR3, NEF, ARW, DNG, RAF, ORF, RW2…) via Apple's RAW engine.
enum Raw {
    /// Develops the RAW with the camera's default settings (white balance, lens
    /// corrections, orientation applied).
    static func develop(_ url: URL, sixteenBit: Bool = false) throws -> CGImage {
        guard let filter = CIRAWFilter(imageURL: url), let image = filter.outputImage else {
            throw RondoError(L("Этот RAW не поддерживается macOS", "This RAW isn't supported by macOS"))
        }
        let space = CGColorSpace(name: sixteenBit ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        guard let cg = ctx.createCGImage(image, from: image.extent,
                                         format: sixteenBit ? .RGBA16 : .RGBA8, colorSpace: space)
        else { throw RondoError(L("Не удалось проявить RAW", "Could not develop RAW")) }
        return cg
    }

    /// EXIF/TIFF/GPS metadata of the original, minus orientation (already applied).
    static func metadata(_ url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              var p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        p[kCGImagePropertyOrientation] = nil
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            p[kCGImagePropertyTIFFDictionary] = tiff
        }
        for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth] { p[k] = nil }
        return p
    }

    static func convert(_ src: URL, to dest: URL, type: UTType) throws {
        let sixteen = type == .tiff || type == .png
        let img = try develop(src, sixteenBit: sixteen)
        var props = metadata(src)
        props[kCGImageDestinationLossyCompressionQuality] = Settings.imageQuality
        guard let dst = CGImageDestinationCreateWithURL(dest as CFURL, type.identifier as CFString, 1, nil)
        else { throw RondoError(L("Формат не поддерживается", "Format not supported")) }
        CGImageDestinationAddImage(dst, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw RondoError(L("Ошибка записи", "Write failed")) }
    }

    /// The camera's embedded JPEG preview: instant, no developing.
    static func embeddedPreview(_ src: URL, to dest: URL) throws {
        guard let s = CGImageSourceCreateWithURL(src as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(s, 0, [
                  kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 8192,
              ] as CFDictionary)
        else { throw RondoError(L("В RAW нет превью", "No embedded preview")) }
        try Images.write(img, to: dest, type: .jpeg, properties: metadata(src))
    }

    /// "Canon EOS R6 · RF24-70mm · 1/250 s · f/2.8 · ISO 400 · 50 mm", copied to the clipboard.
    static func shotInfo(_ url: URL) throws -> String {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any]
        else { throw RondoError(L("Нет данных о съёмке", "No shooting data")) }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var parts: [String] = []
        let make = tiff[kCGImagePropertyTIFFMake] as? String ?? ""
        let model = tiff[kCGImagePropertyTIFFModel] as? String ?? ""
        let camera = model.hasPrefix(make) ? model : [make, model].filter { !$0.isEmpty }.joined(separator: " ")
        if !camera.isEmpty { parts.append(camera) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { parts.append(lens) }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            parts.append(t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s")
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { parts.append(String(format: "f/%.1f", f)) }
        // Older cameras fill ISOSpeedRatings; newer ones (e.g. Canon CR3) only ISOSpeed / RecommendedExposureIndex.
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first
            ?? exif[kCGImagePropertyExifISOSpeed] as? NSNumber
            ?? exif[kCGImagePropertyExifRecommendedExposureIndex] as? NSNumber
        if let iso { parts.append("ISO \(iso.intValue)") }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double { parts.append("\(Int(fl.rounded())) mm") }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String { parts.append(date) }
        guard !parts.isEmpty else { throw RondoError(L("Нет данных о съёмке", "No shooting data")) }
        return parts.joined(separator: " · ")
    }
}
