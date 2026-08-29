import AppKit
import QuickLookThumbnailing

/// Превью для карточек полки: QuickLook, а если он не смог — иконка типа файла.
final class ShelfThumbnailer: Sendable {

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: size,
                                                   scale: scale,
                                                   representationTypes: .thumbnail)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
    }

    @MainActor static func icon(for url: URL, size: CGSize) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = size
        return icon
    }
}
