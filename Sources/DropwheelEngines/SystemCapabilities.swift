import DropwheelCore
import ImageIO

/// Uniform Type Identifiers ImageIO uses for each raster format.
enum ImageTypes {
    static let identifiers: [FileFormat: String] = [
        .png: "public.png", .jpg: "public.jpeg", .heic: "public.heic", .tiff: "public.tiff",
        .avif: "public.avif", .bmp: "com.microsoft.bmp", .webp: "org.webmproject.webp",
    ]
}

extension FormatCapabilities {
    /// What this Mac's ImageIO can decode and encode. Other formats go
    /// through ffmpeg, AppKit, cwebp or the system archivers; those report a
    /// clear error if a tool is missing, so they stay on the wheel.
    public static let system: FormatCapabilities = {
        let readable = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
        let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        return FormatCapabilities(
            canRead: { format in
                guard format.family == .image, format != .svg, let type = ImageTypes.identifiers[format] else { return true }
                return readable.contains(type)
            },
            canWrite: { format in
                // WebP is written by cwebp, not ImageIO.
                guard format.family == .image, format != .webp, let type = ImageTypes.identifiers[format] else { return true }
                return writable.contains(type)
            }
        )
    }()
}
