import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where the photographs live.
///
/// Imported files are **copied** into the module's Application Support folder
/// rather than referenced in place. `legacyScreenSaver` — the process that hosts
/// a `.saver` on modern macOS — is sandboxed, so a path the user picked in the
/// configuration sheet is not readable later from the running screensaver.
/// Copying sidesteps bookmark scoping entirely and always works.
enum ImageLibrary {

    static var folder: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Windflow/Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let allowedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp",
    ]

    static func urls() -> [URL] {
        let items =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
        return
            items
            .filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }

    @discardableResult
    static func importImage(from source: URL) -> URL? {
        let fm = FileManager.default
        var destination = folder.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        let stem = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        while fm.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(stem)-\(counter).\(ext)")
            counter += 1
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try fm.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Decode at a bounded size. A 48 MP drone frame downsampled to the character
    /// grid gains nothing over a 2560 px one and costs a lot of memory.
    static func load(_ url: URL, maxPixel: Int = 2560) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}
