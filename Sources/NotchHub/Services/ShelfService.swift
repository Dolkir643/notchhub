import AppKit
import Combine

/// Файл на полке.
struct ShelfItem: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var size: Int64
    var added: Date
    /// Подпапка внутри Shelf/: <UUID>/<имя файла>
    var relativePath: String
    var isScreenshot: Bool

    var url: URL { AppPaths.shelf.appendingPathComponent(relativePath) }
}

/// Полка: приём drag&drop, перетаскивание наружу, автоподхват скриншотов.
/// СТАБ: реализация — модуль «Полка».
@MainActor final class ShelfService: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]

    var isEmpty: Bool { items.isEmpty }

    func start() {}
    func stop() {}

    /// Приём из SwiftUI `.onDrop`. Возвращает true, если что-то приняли.
    @discardableResult
    func handleDrop(_ providers: [NSItemProvider]) -> Bool { false }

    /// Скопировать файлы на полку.
    func add(urls: [URL]) {}

    func remove(_ item: ShelfItem) {}
    func clearAll() {}

    /// Открыть в Finder.
    func reveal(_ item: ShelfItem) {}

    /// Запросить превью (кладётся в `thumbnails`).
    func requestThumbnail(_ item: ShelfItem) {}
}
