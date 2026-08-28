import AppKit
import Combine

/// Запись истории буфера обмена.
struct ClipItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case text(String)
        case url(URL)
        case image(NSImage)
    }

    let id: UUID
    let date: Date
    let kind: Kind

    var isImage: Bool { if case .image = kind { return true }; return false }

    var preview: String {
        switch kind {
        case .text(let s):
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
        case .url(let u): return u.absoluteString
        case .image: return "Изображение"
        }
    }

    var icon: String {
        switch kind {
        case .text: return "text.alignleft"
        case .url: return "link"
        case .image: return "photo"
        }
    }

    static func == (a: ClipItem, b: ClipItem) -> Bool { a.id == b.id }
}

/// История буфера обмена (поллинг changeCount).
/// СТАБ: реализация — модуль «Буфер».
@MainActor final class ClipboardService: ObservableObject {
    @Published private(set) var items: [ClipItem] = []

    func start() {}
    func stop() {}

    /// Положить запись обратно в буфер обмена.
    func copyBack(_ item: ClipItem) {}
    func remove(_ item: ClipItem) {}
    func clearAll() {}
}
