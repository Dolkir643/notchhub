import AppKit
import Combine

/// Текущий трек.
struct NowPlaying: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var duration: TimeInterval = 0
    var bundleID: String = ""
    /// Ключ, по которому кэшируется обложка (title+artist+album).
    var trackKey: String { "\(title)|\(artist)|\(album)" }
    /// «Артист — Альбом» или имя приложения, если метаданных нет.
    var subtitle: String {
        let parts = [artist, album].filter { !$0.isEmpty }
        if parts.isEmpty { return appName }
        return parts.joined(separator: " — ")
    }
    var appName: String {
        guard !bundleID.isEmpty else { return "" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }
}

enum MediaBackend: Equatable {
    case none
    case adapter
    case appleScript

    var label: String {
        switch self {
        case .none: return "нет источника"
        case .adapter: return "MediaRemote"
        case .appleScript: return "AppleScript"
        }
    }
}

/// Now Playing из любого проигрывателя, включая Chrome/YouTube.
/// СТАБ: реализация — модуль «Музыка».
@MainActor final class MediaService: ObservableObject {
    @Published private(set) var track: NowPlaying?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var artwork: NSImage?
    @Published private(set) var backend: MediaBackend = .none

    /// 0…1 для прогресс-бара.
    var progress: Double {
        guard let d = track?.duration, d > 0 else { return 0 }
        return min(1, max(0, elapsed / d))
    }

    func start() {}
    func stop() {}
    func toggle() {}
    func next() {}
    func previous() {}
    /// Перемотка в секундах от начала трека.
    func seek(to seconds: TimeInterval) {}
}
