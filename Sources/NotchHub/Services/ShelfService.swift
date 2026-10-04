import AppKit
import Combine
import UniformTypeIdentifiers

/// Файл на полке.
struct ShelfItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var size: Int64
    var added: Date
    /// Подпапка внутри Shelf/: <UUID>/<имя файла>
    var relativePath: String
    var isScreenshot: Bool
    var pinned: Bool? = nil
    var isPinned: Bool {
        get { pinned == true }
        set { pinned = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, size, added, relativePath, isScreenshot, pinned, isPinned
    }

    var url: URL { AppPaths.shelf.appendingPathComponent(relativePath) }

    /// Служебный каталог элемента (в нём лежит единственный файл).
    var directory: URL { AppPaths.shelf.appendingPathComponent(id.uuidString, isDirectory: true) }
}

extension ShelfItem {
    /// Читаем закрепление из обеих версий индекса; у старых файлов его нет.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        size = try values.decode(Int64.self, forKey: .size)
        added = try values.decode(Date.self, forKey: .added)
        relativePath = try values.decode(String.self, forKey: .relativePath)
        isScreenshot = try values.decode(Bool.self, forKey: .isScreenshot)
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned)
            ?? values.decodeIfPresent(Bool.self, forKey: .isPinned)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(size, forKey: .size)
        try values.encode(added, forKey: .added)
        try values.encode(relativePath, forKey: .relativePath)
        try values.encode(isScreenshot, forKey: .isScreenshot)
        try values.encodeIfPresent(pinned, forKey: .pinned)
    }
}

/// Полка: приём drag&drop, перетаскивание наружу, автоподхват скриншотов.
@MainActor final class ShelfService: ObservableObject {
    @Published private(set) var screenshotStatus = "Скриншоты: подключение…"
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    let downloads = ShelfDownloadsService()

    var isEmpty: Bool { items.isEmpty }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    /// Размер превью в точках (карточка 104×84, берём с запасом).
    static let thumbnailSize = CGSize(width: 120, height: 90)

    private let store: ShelfStore
    private let copyFile: @Sendable (URL, Bool) -> ShelfItem?
    private var initialization: Task<Void, Never>?
    private var ready = false
    private var generation = 0
    private var removing: Set<UUID> = []
    private var imports: [URL: Task<ShelfItem?, Never>] = [:]
    private let recycle: ([URL], @escaping @Sendable ([URL: URL], Error?) -> Void) -> Void

    init(store: ShelfStore = ShelfStore(),
         copyFile: (@Sendable (URL, Bool) -> ShelfItem?)? = nil,
         recycle: @escaping ([URL], @escaping @Sendable ([URL: URL], Error?) -> Void) -> Void = {
             NSWorkspace.shared.recycle($0, completionHandler: $1)
         }) {
        self.store = store
        self.copyFile = copyFile ?? { store.copyIn($0, isScreenshot: $1) }
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
        downloads.start()

        generation &+= 1
        let token = generation
        let store = self.store
        let pendingImports = Array(imports.values)
        imports.removeAll()
        initialization = Task { [weak self] in
            // Копирование нельзя прервать посередине системного copyItem.
            // После перезапуска сначала дожидаемся его и затем восстанавливаем
            // готовые каталоги, иначе поздняя копия осталась бы невидимой.
            for pending in pendingImports { _ = await pending.value }
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
        downloads.stop()
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
        let token = generation
        Task { [weak self] in
            var urls: [URL] = []
            for provider in usable {
                if let url = await Self.resolveURL(from: provider) { urls.append(url) }
            }
            guard !urls.isEmpty, let self, self.running, self.generation == token else { return }
            self.add(urls: urls)
        }
        return true
    }

    /// Скопировать файлы на полку.
    func add(urls: [URL]) {
        add(urls: urls, isScreenshot: false)
    }

    func add(urls: [URL], isScreenshot: Bool) {
        let token = generation
        Task { [weak self] in
            guard let self, self.running, self.generation == token else { return }
            await self.addAndWait(urls: urls, isScreenshot: isScreenshot)
        }
    }

    func addAndWait(urls: [URL], isScreenshot: Bool = false) async {
        let fresh = await importFiles(urls: urls, isScreenshot: isScreenshot)
        if isScreenshot, !fresh.isEmpty { AppState.shared.flash("Скриншот на полке") }
    }

    /// Возвращаем только сохранённые элементы: кнопка загрузок может честно
    /// показать результат и держать доступ к исходной папке до конца копирования.
    @discardableResult
    func importFiles(urls: [URL], isScreenshot: Bool = false) async -> [ShelfItem] {
        let token = generation
        await waitUntilReady()
        guard running, ready, generation == token, !Task.isCancelled else { return [] }
        var seen = Set<URL>()
        let unique = urls.filter(\.isFileURL).map(\.standardizedFileURL)
            .filter { seen.insert($0).inserted }
        var copied: [ShelfItem] = []
        var failed = false
        for url in unique {
            guard running, generation == token, !Task.isCancelled else { break }
            let task: Task<ShelfItem?, Never>
            let ownsImport = imports[url] == nil
            if let existing = imports[url] {
                task = existing
            } else {
                let copyFile = self.copyFile
                // Единственная задача коммитит копию до пробуждения всех
                // ожидающих. Поздний пакет не перезапишет закрепление и не
                // вернёт файл, который пользователь уже убрал с полки.
                task = Task { [weak self] in
                    let item = await Task.detached(priority: .userInitiated) {
                        copyFile(url, isScreenshot)
                    }.value
                    guard let self, self.running, self.generation == token, let item else { return nil }
                    self.adopt([item], replacing: false)
                    return item
                }
                imports[url] = task
            }
            let item = await task.value
            if ownsImport, generation == token { imports[url] = nil }
            // Скопированный файл переживает остановку сервиса и восстановится
            // из каталога при следующем старте; поздний callback не меняет UI.
            guard running, generation == token else { break }
            if let item { copied.append(item) } else { failed = true }
        }
        guard running, generation == token else { return [] }
        if failed, !Task.isCancelled {
            AppState.shared.flash("Не удалось сохранить часть файлов")
        }
        let copiedIDs = Set(copied.map(\.id))
        return items.filter { copiedIDs.contains($0.id) }
    }

    // MARK: — удаление

    func remove(_ item: ShelfItem) {
        guard ready else { return }
        trash([item])
    }

    func remove(items: [ShelfItem]) {
        guard ready else { return }
        let ids = Set(items.map(\.id))
        trash(self.items.filter { ids.contains($0.id) })
    }

    func clearAll() {
        guard ready else { return }
        trash(items.filter { !$0.isPinned })
    }

    func togglePin(_ item: ShelfItem) {
        guard ready, !removing.contains(item.id),
              let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = items
        updated[index].isPinned.toggle()
        guard store.save(updated) else {
            AppState.shared.flash("Не удалось сохранить закрепление")
            return
        }
        items = updated
    }

    func copyToClipboard(items: [ShelfItem]) {
        let ids = Set(items.map(\.id))
        let urls = self.items.filter { ids.contains($0.id) }.map { store.url(for: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects(urls.map { $0 as NSURL }) {
            AppState.shared.flash("Файлы скопированы")
        }
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
    func cleanupExpired(now: Date = Date(), retentionDays: Int? = nil) {
        guard ready, running else { return }
        let days = retentionDays ?? Settings.shared.shelfRetentionDays
        guard days > 0 else { return }
        let deadline = now.addingTimeInterval(-Double(days) * 86_400)
        trash(items.filter { !$0.isPinned && $0.added < deadline })
    }

    func remove(ids: Set<UUID>) {
        guard ready else { return }
        trash(items.filter { ids.contains($0.id) })
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
            screenshotStatus = "Автоподхват скриншотов выключен"
            return
        }
        let directory = ShelfScreenshotWatcher.screenshotDirectory()
        if let watcher, watcher.directory == directory { return }

        watcher?.stop()
        let fresh = ShelfScreenshotWatcher(directory: directory) { [weak self] url in
            MainActor.assumeIsolated { self?.add(urls: [url], isScreenshot: true) }
        }
        if fresh.start() {
            screenshotStatus = "Скриншоты: папка «\(directory.lastPathComponent)». Снимок только в буфере добавляется через «На полку»."
            watcher = fresh
        } else {
            screenshotStatus = "Не удалось следить за папкой скриншотов. Проверьте доступ к ней."
            watcher = nil
        }
    }

    /// Каталог снимков можно поменять в любой момент — раз в час сверяемся.
    func refreshScreenshotWatch() {
        watcher?.stop(); watcher = nil
        setScreenshotWatch(Settings.shared.autoScreenshots)
    }

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
