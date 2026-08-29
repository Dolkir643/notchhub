import AppKit
import Combine
import UniformTypeIdentifiers

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

    /// Служебный каталог элемента (в нём лежит единственный файл).
    var directory: URL { AppPaths.shelf.appendingPathComponent(id.uuidString, isDirectory: true) }
}

/// Полка: приём drag&drop, перетаскивание наружу, автоподхват скриншотов.
@MainActor final class ShelfService: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]

    var isEmpty: Bool { items.isEmpty }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    /// Размер превью в точках (карточка 104×84, берём с запасом).
    static let thumbnailSize = CGSize(width: 120, height: 90)

    private let store = ShelfStore()
    private let thumbnailer = ShelfThumbnailer()
    private var watcher: ShelfScreenshotWatcher?
    private var thumbnailsInFlight: Set<UUID> = []
    private var maintenance: Timer?
    private var bag = Set<AnyCancellable>()
    private var running = false

    // MARK: — жизненный цикл

    func start() {
        guard !running else { return }
        running = true

        let store = self.store
        Task.detached(priority: .utility) { [weak self] in
            store.clearInbox()
            let loaded = store.load()
            store.pruneOrphans(keeping: loaded)
            guard let service = self else { return }
            await MainActor.run { service.adopt(loaded, replacing: true) }
        }

        // Настройку можно щёлкнуть в любой момент — слушаем её, а не читаем один раз.
        Settings.shared.$autoScreenshots
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor in self?.setScreenshotWatch(enabled) }
            }
            .store(in: &bag)

        // Новый срок хранения применяем сразу, а не в течение часа:
        // человек выбирает «1 день», закрывает панель и ждёт, что старое ушло.
        Settings.shared.$shelfRetentionDays
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.cleanupExpired() }
            }
            .store(in: &bag)

        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cleanupExpired()
                self?.refreshWatchIfDirectoryChanged()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        maintenance = timer
    }

    func stop() {
        running = false
        watcher?.stop()
        watcher = nil
        maintenance?.invalidate()
        maintenance = nil
        bag.removeAll()
        store.save(items)
    }

    // MARK: — приём drag&drop

    /// Приём из SwiftUI `.onDrop`. Возвращает true, если что-то приняли.
    @discardableResult
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let usable = providers.filter { Self.canTake($0) }
        guard !usable.isEmpty else { return false }

        Task { [weak self] in
            var urls: [URL] = []
            for provider in usable {
                if let url = await Self.resolveURL(from: provider) { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            self?.add(urls: urls)
        }
        return true
    }

    /// Скопировать файлы на полку.
    func add(urls: [URL]) {
        add(urls: urls, isScreenshot: false)
    }

    func add(urls: [URL], isScreenshot: Bool) {
        var unique: [URL] = []
        for url in urls where !unique.contains(url.standardizedFileURL) {
            unique.append(url.standardizedFileURL)
        }
        guard !unique.isEmpty else { return }

        let store = self.store
        Task.detached(priority: .userInitiated) { [weak self] in
            let fresh = unique.compactMap { store.copyIn($0, isScreenshot: isScreenshot) }
            guard !fresh.isEmpty, let service = self else { return }
            await MainActor.run {
                service.adopt(fresh, replacing: false)
                if isScreenshot { AppState.shared.flash("Скриншот на полке") }
            }
        }
    }

    // MARK: — удаление

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        store.save(items)
        trash([item])
    }

    func clearAll() {
        let gone = items
        items = []
        thumbnails = [:]
        store.save(items)
        trash(gone)
    }

    /// Открыть в Finder.
    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Открыть в программе по умолчанию.
    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    // MARK: — превью

    /// Запросить превью (кладётся в `thumbnails`).
    func requestThumbnail(_ item: ShelfItem) {
        guard thumbnails[item.id] == nil, !thumbnailsInFlight.contains(item.id) else { return }
        thumbnailsInFlight.insert(item.id)

        let url = item.url
        let id = item.id
        Task { [weak self] in
            guard let self else { return }
            let generated = await self.thumbnailer.thumbnail(for: url,
                                                             size: Self.thumbnailSize,
                                                             scale: 2)
            let image = generated ?? ShelfThumbnailer.icon(for: url, size: CGSize(width: 64, height: 64))
            self.thumbnailsInFlight.remove(id)
            guard self.items.contains(where: { $0.id == id }) else { return }
            self.thumbnails[id] = image
        }
    }

    // MARK: — внутреннее

    private func adopt(_ incoming: [ShelfItem], replacing: Bool) {
        var seen = Set<UUID>()
        let merged = (replacing ? incoming : incoming + items).filter { seen.insert($0.id).inserted }
        items = merged.sorted { $0.added > $1.added }
        store.save(items)
        cleanupExpired()
        for item in items.prefix(24) { requestThumbnail(item) }
    }

    /// Автоуборка по возрасту: 0 в настройках — не чистить.
    private func cleanupExpired() {
        let days = Settings.shared.shelfRetentionDays
        guard days > 0 else { return }
        let deadline = Date().addingTimeInterval(-Double(days) * 86_400)
        let expired = items.filter { $0.added < deadline }
        guard !expired.isEmpty else { return }

        items.removeAll { $0.added < deadline }
        for item in expired { thumbnails[item.id] = nil }
        store.save(items)

        // Просроченное сносим молча: оригиналы файлов остались у пользователя.
        let store = self.store
        Task.detached(priority: .background) {
            for item in expired { store.delete(item) }
        }
        Log.shelf.info("Автоуборка полки: \(expired.count, privacy: .public)")
    }

    private func trash(_ removed: [ShelfItem]) {
        guard !removed.isEmpty else { return }
        let store = self.store
        NSWorkspace.shared.recycle(removed.map(\.url)) { _, error in
            if let error {
                Log.shelf.error("Корзина отказалась: \(error.localizedDescription, privacy: .public)")
            }
            for item in removed { store.delete(item) }
        }
    }

    // MARK: — слежка за скриншотами

    private func setScreenshotWatch(_ enabled: Bool) {
        guard enabled else {
            watcher?.stop()
            watcher = nil
            return
        }
        let directory = ShelfScreenshotWatcher.screenshotDirectory()
        if let watcher, watcher.directory == directory { return }

        watcher?.stop()
        let fresh = ShelfScreenshotWatcher(directory: directory) { [weak self] url in
            MainActor.assumeIsolated { self?.add(urls: [url], isScreenshot: true) }
        }
        fresh.start()
        watcher = fresh
    }

    /// Каталог снимков можно поменять в любой момент — раз в час сверяемся.
    private func refreshWatchIfDirectoryChanged() {
        guard Settings.shared.autoScreenshots else { return }
        setScreenshotWatch(true)
    }

    // MARK: — вытаскивание URL из провайдера

    private nonisolated static func canTake(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || fileType(of: provider) != nil
    }

    /// Тип, который не грех сохранить файлом, если ссылки на файл нет.
    private nonisolated static func fileType(of provider: NSItemProvider) -> String? {
        let allowed: [UTType] = [.image, .movie, .audio, .pdf, .archive, .rtf]
        return provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return allowed.contains { type.conforms(to: $0) }
        }
    }

    private nonisolated static func resolveURL(from provider: NSItemProvider) async -> URL? {
        let identifier = UTType.fileURL.identifier
        if provider.hasItemConformingToTypeIdentifier(identifier) {
            if let url = await withCheckedContinuation({ (continuation: CheckedContinuation<URL?, Never>) in
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { value, _ in
                    continuation.resume(returning: fileURL(from: value))
                }
            }) { return url }

            // Часть приложений отдаёт ссылку только объектом.
            if let url = await withCheckedContinuation({ (continuation: CheckedContinuation<URL?, Never>) in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url?.isFileURL == true ? url : nil)
                }
            }) { return url }
        }

        guard let type = fileType(of: provider) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                // Копия провайдера живёт только до выхода отсюда.
                continuation.resume(returning: url.flatMap { ShelfStore.stash($0) })
            }
        }
    }

    private nonisolated static func fileURL(from value: NSSecureCoding?) -> URL? {
        let url: URL?
        switch value {
        case let data as Data: url = URL(dataRepresentation: data, relativeTo: nil)
        case let string as String: url = URL(string: string)
        case let existing as URL: url = existing
        case let existing as NSURL: url = existing as URL
        default: url = nil
        }
        guard let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
