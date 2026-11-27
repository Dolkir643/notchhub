import AppKit
import Darwin

/// Файловая часть полки: копирование в хранилище, индекс на диске, удаление.
/// Класс без состояния — вызывается из фоновых задач, главный актор не блокирует.
final class ShelfStore: Sendable {
    let shelfURL: URL
    let indexURL: URL
    private let expectedShelfPath: String

    init(shelfURL: URL = AppPaths.shelf, indexURL: URL = AppPaths.shelfIndex) {
        self.shelfURL = shelfURL
        self.indexURL = indexURL
        // Системные /var и /tmp могут быть ссылками. Сами NotchHub/ и Shelf/
        // должны оставаться настоящими каталогами внутри их исходного родителя.
        let parent = shelfURL.deletingLastPathComponent()
        expectedShelfPath = parent.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(parent.lastPathComponent)
            .appendingPathComponent(shelfURL.lastPathComponent).path
    }

    /// Только адрес из индекса. Для файловых действий нужен existingURL(for:).
    func url(for item: ShelfItem) -> URL {
        shelfURL.appendingPathComponent(item.relativePath)
    }

    private var hasSafeRoot: Bool {
        shelfURL.resolvingSymlinksInPath().path == expectedShelfPath
    }

    private func fileType(at url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    private func existingFolder(named name: String) -> URL? {
        guard UUID(uuidString: name) != nil, !name.utf8.contains(0), hasSafeRoot else { return nil }
        let url = shelfURL.appendingPathComponent(name, isDirectory: true)
        return fileType(at: url) == .typeDirectory ? url : nil
    }

    /// При каждом обращении проверяем оба компонента: карточка могла остаться
    /// на экране после того, как файл или его каталог заменили ссылкой.
    func existingURL(for item: ShelfItem) -> URL? {
        let parts = item.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) == item.id,
              !item.name.isEmpty, item.name != ".", item.name != "..",
              !item.relativePath.utf8.contains(0), parts[1] == item.name,
              existingFolder(named: String(parts[0])) != nil else { return nil }
        let url = self.url(for: item)
        switch fileType(at: url) {
        case .typeRegular, .typeDirectory: return url
        default: return nil
        }
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
        try loadInventory().items
    }

    func loadInventory() throws -> (items: [ShelfItem], retainedFolders: Set<String>) {
        let fm = FileManager.default
        guard hasSafeRoot else { throw CocoaError(.fileReadNoPermission) }
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
        stored = stored.filter { existingURL(for: $0) != nil }
        var known = Set(stored.map(\.id))
        var retainedFolders = Set<String>()
        let folders = try fm.contentsOfDirectory(at: shelfURL, includingPropertiesForKeys: nil)
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent), !known.contains(id),
                  fileType(at: folder) == .typeDirectory else { continue }
            let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent != ".DS_Store" }
            guard !files.isEmpty else { continue }
            guard files.count == 1, let file = files.first else {
                retainedFolders.insert(folder.lastPathComponent)
                continue
            }
            // Потерянный индекс мог содержать закрепление. Единственный файл
            // также мог быть оставлен редактором рядом с уже удалённой карточкой.
            var recovered = ShelfItem(id: id, name: file.lastPathComponent, size: 0, added: Date(),
                                      relativePath: "\(folder.lastPathComponent)/\(file.lastPathComponent)",
                                      isScreenshot: false, pinned: true)
            guard let url = existingURL(for: recovered) else {
                retainedFolders.insert(folder.lastPathComponent)
                continue
            }
            recovered.size = Self.size(of: url)
            stored.append(recovered)
            known.insert(id)
        }
        return (stored, retainedFolders)
    }

    @discardableResult
    func save(_ items: [ShelfItem]) -> Bool {
        guard hasSafeRoot else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(items)
            try data.write(to: indexURL, options: .atomic)
            return true
        } catch {
            Log.shelf.error("Индекс не записан: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Убирать можно только пустые каталоги: файлы без индекса подлежат восстановлению.
    func pruneOrphans(keeping items: [ShelfItem]) {
        let alive = Set(items.map(\.id))
        guard hasSafeRoot, let names = try? FileManager.default.contentsOfDirectory(atPath: shelfURL.path) else { return }
        for name in names {
            guard let id = UUID(uuidString: name), !alive.contains(id) else { continue }
            removeEmptyFolder(named: name)
        }
    }

    // MARK: — приём файла

    /// Копия файла в `Shelf/<UUID>/<имя>`. Папка на элемент — чтобы не бились одинаковые имена.
    func copyIn(_ source: URL, isScreenshot: Bool) -> ShelfItem? {
        guard hasSafeRoot else { return nil }
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
            let before = try FileManager.default.attributesOfItem(atPath: origin.path)
            try FileManager.default.copyItem(at: origin, to: staging.appendingPathComponent(name))
            // Загрузка могла возобновиться уже после нажатия «Сохранить».
            // Не публикуем обрезанную копию изменившегося обычного файла.
            if before[.type] as? FileAttributeType == .typeRegular {
                let after = try FileManager.default.attributesOfItem(atPath: origin.path)
                for key in [FileAttributeKey.size, .modificationDate, .systemFileNumber] {
                    guard let original = before[key] as? NSObject,
                          let current = after[key] as? NSObject, original == current else {
                        throw CocoaError(.fileReadUnknown)
                    }
                }
            }
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

    /// rmdir атомарно откажется удалять непустой каталог, включая файлы,
    /// появившиеся во время асинхронного перемещения карточки в Корзину.
    @discardableResult
    func removeEmptyFolder(named name: String) -> Bool {
        guard UUID(uuidString: name) != nil, !name.utf8.contains(0), hasSafeRoot else { return false }
        let root = open(expectedShelfPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return false }
        defer { close(root) }
        return unlinkat(root, name, AT_REMOVEDIR) == 0
    }

    func folderWithRetainedFiles(named name: String) -> URL? {
        guard let folder = existingFolder(named: name),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              names.contains(where: { $0 != ".DS_Store" }) else { return nil }
        return folder
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
