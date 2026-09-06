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

    private let store: ShelfStore
    private var initialization: Task<Void, Never>?
    private var ready = false
    private var generation = 0
    private var removing: Set<UUID> = []
    private let recycle: ([URL], @escaping @Sendable ([URL: URL], Error?) -> Void) -> Void

    init(store: ShelfStore = ShelfStore(),
         recycle: @escaping ([URL], @escaping @Sendable ([URL: URL], Error?) -> Void) -> Void = {
             NSWorkspace.shared.recycle($0, completionHandler: $1)
         }) {
        self.store = store
        self.recycle = recycle
    }

    func waitUntilReady() async { await initialization?.value }
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

        generation &+= 1
        let token = generation
        let store = self.store
        initialization = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try store.loadRecovering() }
            }.value
            guard let self, self.running, self.generation == token else { return }
            switch result {
            case .success(let loaded):
                self.ready = true
                self.adopt(loaded, replacing: true)
            case .failure(let error):
                Log.shelf.error("Полка не загружена: \(error.localizedDescription, privacy: .public)")
                AppState.shared.flash("Не удалось загрузить полку")
            }
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
        generation &+= 1
        initialization?.cancel()
        initialization = nil
        watcher?.stop()
        watcher = nil
        maintenance?.invalidate()
        maintenance = nil
        bag.removeAll()
        if ready { store.save(items) }
        ready = false
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

        let token = generation
        Task { [weak self] in
            guard let self else { return }
            await self.waitUntilReady()
            guard self.running, self.ready, self.generation == token else { return }
            let store = self.store
            let fresh = await Task.detached(priority: .userInitiated) {
                unique.compactMap { store.copyIn($0, isScreenshot: isScreenshot) }
            }.value
            guard self.running, self.generation == token, !fresh.isEmpty else { return }
            self.adopt(fresh, replacing: false)
            if isScreenshot { AppState.shared.flash("Скриншот на полке") }
        }
    }

    // MARK: — удаление

    func remove(_ item: ShelfItem) {
        guard ready else { return }
        trash([item])
    }

    func clearAll() {
        guard ready else { return }
        trash(items)
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
        guard ready, running else { return }
        let days = Settings.shared.shelfRetentionDays
        guard days > 0 else { return }
        let deadline = Date().addingTimeInterval(-Double(days) * 86_400)
        let expired = items.filter { $0.added < deadline && !removing.contains($0.id) }
        guard !expired.isEmpty else { return }

        let expiredIDs = Set(expired.map(\.id))
        items.removeAll { expiredIDs.contains($0.id) }
        for item in expired { thumbnails[item.id] = nil }
        store.save(items)

        // Просроченное сносим молча: оригиналы файлов остались у пользователя.
        let store = self.store
        Task.detached(priority: .background) {
            for item in expired { store.delete(item) }
        }
        Log.shelf.info("Автоуборка полки: \(expired.count, privacy: .public)")
    }

    private func trash(_ requested: [ShelfItem]) {
        let removed = requested.filter { !removing.contains($0.id) }
        guard !removed.isEmpty else { return }
        removing.formUnion(removed.map(\.id))
        recycle(removed.map { store.url(for: $0) }) { [weak self] moved, error in
            Task { @MainActor in
                guard let self else { return }
                let succeeded = removed.filter { moved[self.store.url(for: $0)] != nil }
                let ids = Set(succeeded.map(\.id))
                self.removing.subtract(removed.map(\.id))
                self.items.removeAll { ids.contains($0.id) }
                for item in succeeded {
                    self.thumbnails[item.id] = nil
                    self.store.delete(item)
                }
                self.store.save(self.items)
                if error != nil || succeeded.count != removed.count {
                    Log.shelf.error("Не все файлы перемещены в Корзину")
                    AppState.shared.flash("Не удалось удалить часть файлов")
                }
            }
        }
    }

    // MARK: — слежка за скриншотами

    private func setScreenshotWatch(_ enabled: Bool) {
        guard running else { return }
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
