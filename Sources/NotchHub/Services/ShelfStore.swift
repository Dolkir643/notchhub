import AppKit

/// Файловая часть полки: копирование в хранилище, индекс на диске, удаление.
/// Класс без состояния — вызывается из фоновых задач, главный актор не блокирует.
final class ShelfStore: Sendable {
    let shelfURL: URL
    let indexURL: URL

    init(shelfURL: URL = AppPaths.shelf, indexURL: URL = AppPaths.shelfIndex) {
        self.shelfURL = shelfURL
        self.indexURL = indexURL
    }

    func url(for item: ShelfItem) -> URL {
        shelfURL.appendingPathComponent(item.relativePath)
    }

    /// Приют для файлов, которые провайдер отдал не ссылкой, а содержимым:
    /// его временную копию нужно забрать до выхода из обработчика.
    static var inbox: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("NotchHubDrop", isDirectory: true)
    }

    // MARK: — индекс

    func load() -> [ShelfItem] {
        (try? loadRecovering()) ?? []
    }

    /// Ошибка доступа не равна пустой полке. Повреждённый индекс сохраняем,
    /// а файлы без записи в индексе восстанавливаем (в том числе после сбоя копирования).
    func loadRecovering() throws -> [ShelfItem] {
        let fm = FileManager.default
        var stored: [ShelfItem] = []
        if fm.fileExists(atPath: indexURL.path) {
            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                stored = try decoder.decode([ShelfItem].self, from: data)
            } catch {
                let backup = indexURL.appendingPathExtension("broken-\(UUID().uuidString).json")
                try fm.copyItem(at: indexURL, to: backup)
                Log.shelf.error("Индекс повреждён; копия сохранена, восстанавливаю файлы")
            }
        }
        stored = stored.filter { fm.fileExists(atPath: url(for: $0).path) }
        var known = Set(stored.map(\.id))
        let folders = try fm.contentsOfDirectory(at: shelfURL, includingPropertiesForKeys: nil)
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent), !known.contains(id) else { continue }
            let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent != ".DS_Store" }
            guard files.count == 1, let file = files.first else { continue }
            stored.append(ShelfItem(id: id, name: file.lastPathComponent,
                                    size: Self.size(of: file), added: Date(),
                                    relativePath: "\(id.uuidString)/\(file.lastPathComponent)",
                                    isScreenshot: false))
            known.insert(id)
        }
        return stored
    }

    func save(_ items: [ShelfItem]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(items)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            Log.shelf.error("Индекс не записан: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Убирать можно только пустые каталоги: файлы без индекса подлежат восстановлению.
    func pruneOrphans(keeping items: [ShelfItem]) {
        let alive = Set(items.map(\.id.uuidString))
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: shelfURL.path) else { return }
        for name in names where UUID(uuidString: name) != nil && !alive.contains(name) {
            let folder = shelfURL.appendingPathComponent(name, isDirectory: true)
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
                  contents.isEmpty else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: — приём файла

    /// Копия файла в `Shelf/<UUID>/<имя>`. Папка на элемент — чтобы не бились одинаковые имена.
    func copyIn(_ source: URL, isScreenshot: Bool) -> ShelfItem? {
        let origin = source.resolvingSymlinksInPath()
        let name = origin.lastPathComponent.isEmpty ? "Файл" : origin.lastPathComponent
        let id = UUID()
        let folder = shelfURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(name)
        // Незавершённую копию нельзя восстановить как готовый файл при следующем запуске.
        let staging = shelfURL.appendingPathComponent(".incoming-\(id.uuidString)", isDirectory: true)

        // Файл может лежать в чужой песочнице (Почта, Заметки) — просим доступ явно.
        let scoped = origin.startAccessingSecurityScopedResource()
        defer { if scoped { origin.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: origin, to: staging.appendingPathComponent(name))
            try FileManager.default.moveItem(at: staging, to: folder)
        } catch {
            Log.shelf.error("Не скопировал \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: staging)
            return nil
        }

        // Временную копию из приюта держать больше незачем.
        if origin.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == Self.inbox.standardizedFileURL {
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
        try? FileManager.default.removeItem(at: shelfURL.appendingPathComponent(item.id.uuidString, isDirectory: true))
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
