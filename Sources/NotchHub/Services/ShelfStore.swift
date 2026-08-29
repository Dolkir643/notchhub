import AppKit

/// Файловая часть полки: копирование в хранилище, индекс на диске, удаление.
/// Класс без состояния — вызывается из фоновых задач, главный актор не блокирует.
final class ShelfStore: Sendable {

    /// Приют для файлов, которые провайдер отдал не ссылкой, а содержимым:
    /// его временную копию нужно забрать до выхода из обработчика.
    static var inbox: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("NotchHubDrop", isDirectory: true)
    }

    // MARK: — индекс

    func load() -> [ShelfItem] {
        guard let data = try? Data(contentsOf: AppPaths.shelfIndex) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([ShelfItem].self, from: data) else {
            Log.shelf.error("Индекс полки не читается — начинаем с пустой")
            return []
        }
        return stored.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    func save(_ items: [ShelfItem]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(items)
            try data.write(to: AppPaths.shelfIndex, options: .atomic)
        } catch {
            Log.shelf.error("Индекс не записан: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Снести каталоги, на которые индекс больше не ссылается.
    func pruneOrphans(keeping items: [ShelfItem]) {
        let alive = Set(items.map(\.id.uuidString))
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: AppPaths.shelf.path) else { return }
        for name in names where UUID(uuidString: name) != nil && !alive.contains(name) {
            try? FileManager.default.removeItem(at: AppPaths.shelf.appendingPathComponent(name, isDirectory: true))
        }
    }

    // MARK: — приём файла

    /// Копия файла в `Shelf/<UUID>/<имя>`. Папка на элемент — чтобы не бились одинаковые имена.
    func copyIn(_ source: URL, isScreenshot: Bool) -> ShelfItem? {
        let origin = source.resolvingSymlinksInPath()
        let name = origin.lastPathComponent.isEmpty ? "Файл" : origin.lastPathComponent
        let id = UUID()
        let folder = AppPaths.shelf.appendingPathComponent(id.uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(name)

        // Файл может лежать в чужой песочнице (Почта, Заметки) — просим доступ явно.
        let scoped = origin.startAccessingSecurityScopedResource()
        defer { if scoped { origin.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: origin, to: destination)
        } catch {
            Log.shelf.error("Не скопировал \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: folder)
            return nil
        }

        // Временную копию из приюта держать больше незачем.
        if origin.path.hasPrefix(Self.inbox.path) {
            try? FileManager.default.removeItem(at: origin.deletingLastPathComponent())
        }

        return ShelfItem(id: id,
                         name: name,
                         size: Self.size(of: destination),
                         added: Date(),
                         relativePath: "\(id.uuidString)/\(name)",
                         isScreenshot: isScreenshot)
    }

    /// Забрать временный файл провайдера, пока система его не удалила.
    static func stash(_ temporary: URL) -> URL? {
        let folder = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = temporary.lastPathComponent.isEmpty ? "Файл" : temporary.lastPathComponent
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: temporary, to: target)
            return target
        } catch {
            Log.shelf.error("Приют не принял \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func clearInbox() {
        try? FileManager.default.removeItem(at: Self.inbox)
    }

    // MARK: — удаление

    /// Каталог элемента (вместе с файлом).
    func delete(_ item: ShelfItem) {
        try? FileManager.default.removeItem(at: item.directory)
    }

    // MARK: — размер

    static func size(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.fileSize ?? 0) }

        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let child = walker?.nextObject() as? URL {
            total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
