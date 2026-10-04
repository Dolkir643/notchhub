import AppKit
import Combine
import Darwin

/// Одна сессия доступа может пережить смену папки: её удерживают импорт и drag/share.
final class ShelfDownloadsAccess: @unchecked Sendable {
    let url: URL
    private let started: Bool

    init(_ url: URL) {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
    }

    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}

/// Просмотр выбранной пользователем папки. До выбора папки файловую систему не читает.
@MainActor final class ShelfDownloadsService: ObservableObject {
    @Published private(set) var items: [ShelfDownload] = []
    @Published private(set) var folderURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var saving: Set<URL> = []
    var hasFolderSelection: Bool { defaults.data(forKey: Self.bookmarkKey) != nil }

    private static let bookmarkKey = "shelfDownloadsFolderBookmark"
    private let defaults: UserDefaults
    private var running = false
    private var generation = 0
    private var revision = 0
    private var readiness = ShelfDownloadsReadiness()
    private var directoryWatch: DispatchSourceFileSystemObject?
    private var fileWatches: [URL: (number: UInt64, source: DispatchSourceFileSystemObject)] = [:]
    private var watchClosures = DispatchGroup()
    private(set) var transferAccess: ShelfDownloadsAccess?
    private var scanTask: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var scheduledDeadline: TimeInterval?
    private var fullScanNeeded = false
    private var rescanNeeded = false
    private var folderPanel: NSOpenPanel?
    private var panelKeeper: Timer?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    deinit {
        scheduled?.cancel()
        directoryWatch?.cancel()
        fileWatches.values.forEach { $0.source.cancel() }
        panelKeeper?.invalidate()
    }

    func start() {
        guard !running else { return }
        running = true
        restoreFolder()
    }

    func stop() {
        running = false
        folderPanel?.cancel(nil)
        folderPanel = nil
        panelKeeper?.invalidate()
        panelKeeper = nil
        endSession()
    }

    func chooseFolder() {
        guard running, folderPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Папка загрузок"
        panel.message = "Выберите папку, из которой брать последние загрузки."
        panel.prompt = "Выбрать"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        folderPanel = panel
        AppState.shared.expand()
        let keeper = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { AppState.shared.expand() }
        }
        RunLoop.main.add(keeper, forMode: .common)
        panelKeeper = keeper
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self, weak panel] response in
            MainActor.assumeIsolated {
                guard let self, let panel, self.folderPanel === panel else { return }
                let chosenURL = panel.url
                self.panelKeeper?.invalidate()
                self.panelKeeper = nil
                self.folderPanel = nil
                guard self.running, response == .OK, let url = chosenURL else { return }
                do {
                    let bookmark = try url.bookmarkData(options: [.withSecurityScope],
                                                        includingResourceValuesForKeys: nil, relativeTo: nil)
                    self.defaults.set(bookmark, forKey: Self.bookmarkKey)
                    self.endSession()
                    self.restoreFolder()
                } catch {
                    self.errorMessage = "Не удалось сохранить доступ. Выберите папку ещё раз."
                }
            }
        }
    }

    func forgetFolder() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        endSession()
        errorMessage = nil
    }

    func refresh() {
        guard running else { return }
        if folderURL == nil { restoreFolder() }
        else { schedule(full: true, after: 0) }
    }

    func reveal(_ item: ShelfDownload) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Проверка свежести перед копированием; доступ живёт до окончания настоящего импорта.
    func save(_ item: ShelfDownload, on shelf: ShelfService) async -> Bool {
        guard running, item.isReady, let folder = folderURL, let access = transferAccess,
              items.contains(item), !saving.contains(item.id) else { return false }
        let token = generation
        saving.insert(item.id)
        defer {
            withExtendedLifetime(access) {}
            saving.remove(item.id)
        }
        let current = await Task.detached(priority: .userInitiated) {
            (try? ShelfDownloadsScanner.isCurrent(item.snapshot, in: folder)) == true
        }.value
        guard running, token == generation, current, items.contains(item) else {
            if token == generation {
                errorMessage = "Файл изменился или исчез. Дождитесь обновления."
                changed(item.url)
            }
            return false
        }
        let imported = await shelf.importFiles(urls: [item.url])
        guard !imported.isEmpty else {
            if token == generation { errorMessage = "Не удалось сохранить файл на полке." }
            return false
        }
        return true
    }

    private func restoreFolder() {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data,
                              options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale).standardizedFileURL
            transferAccess = ShelfDownloadsAccess(url)
            folderURL = url
            if stale {
                let updated = try url.bookmarkData(options: [.withSecurityScope],
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(updated, forKey: Self.bookmarkKey)
            }
            let token = generation
            directoryWatch = watch(url) { [weak self] in
                guard let self, self.running, self.generation == token else { return }
                self.revision &+= 1
                self.schedule(full: true, after: 0.25)
            }
            guard directoryWatch != nil else {
                endSession()
                errorMessage = "Папка недоступна. Подключите диск или выберите папку заново."
                return
            }
            errorMessage = nil
            schedule(full: true, after: 0)
        } catch {
            endSession()
            errorMessage = "Доступ к папке потерян. Выберите её ещё раз."
        }
    }

    /// Снятие доступа ждёт и фонового чтения, и закрытия дескрипторов слежения.
    private func endSession() {
        generation &+= 1
        scheduled?.cancel()
        scheduled = nil
        scheduledDeadline = nil
        fullScanNeeded = false
        rescanNeeded = false
        directoryWatch?.cancel()
        directoryWatch = nil
        fileWatches.values.forEach { $0.source.cancel() }
        fileWatches.removeAll()
        let closing = watchClosures
        watchClosures = DispatchGroup()
        let finishing = scanTask
        scanTask = nil
        let previousAccess = transferAccess
        transferAccess = nil
        folderURL = nil
        items = []
        readiness = ShelfDownloadsReadiness()
        Task {
            await finishing?.value
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                closing.notify(queue: .main) { continuation.resume() }
            }
            withExtendedLifetime(previousAccess) {}
        }
    }

    private func schedule(full: Bool, after delay: TimeInterval) {
        guard running, folderURL != nil else { return }
        fullScanNeeded = fullScanNeeded || full
        let deadline = ProcessInfo.processInfo.systemUptime + delay
        if let existing = scheduledDeadline, existing <= deadline { return }
        scheduled?.cancel()
        scheduledDeadline = deadline
        let token = generation
        scheduled = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, self.running, self.generation == token else { return }
            self.scheduled = nil
            self.scheduledDeadline = nil
            self.scan()
        }
    }

    private func scan() {
        guard let folder = folderURL, running else { return }
        guard scanTask == nil else { rescanNeeded = true; return }
        let token = generation
        let observedRevision = revision
        let full = fullScanNeeded
        fullScanNeeded = false
        rescanNeeded = false
        let previous = items.map(\.snapshot)
        let scanAccess = transferAccess
        scanTask = Task { [weak self] in
            defer { withExtendedLifetime(scanAccess) {} }
            let result = await Task.detached(priority: .utility) {
                Result { () throws -> [ShelfDownloadSnapshot] in
                    if full { return try ShelfDownloadsScanner.read(directory: folder) }
                    // Стабильность проверяем только у уже найденных файлов; весь каталог
                    // перечисляется лишь после событий каталога или ручного обновления.
                    return previous.compactMap { try? ShelfDownloadSnapshot.read($0.url) }
                }
            }.value
            guard let self, self.running, self.generation == token else { return }
            self.scanTask = nil
            guard self.revision == observedRevision else {
                self.schedule(full: full, after: 0.05)
                return
            }
            switch result {
            case .success(let snapshots):
                let watched = self.updateWatches(snapshots)
                let available = snapshots.filter { watched.contains($0.url) }
                let ready = self.readiness.update(available, at: ProcessInfo.processInfo.systemUptime)
                let byURL = Dictionary(uniqueKeysWithValues: ready.map { ($0.url, $0) })
                self.items = snapshots.map { byURL[$0.url] ?? ShelfDownload(snapshot: $0, isReady: false) }
                self.errorMessage = watched.count == snapshots.count ? nil
                    : "Не удалось следить за частью файлов. Обновите папку."
                if self.rescanNeeded { self.schedule(full: false, after: 0.05) }
                else if self.readiness.hasPendingFiles { self.schedule(full: false, after: 1.05) }
            case .failure:
                self.endSession()
                self.errorMessage = "Папка недоступна. Подключите диск или выберите папку заново."
            }
        }
    }

    private func changed(_ url: URL) {
        revision &+= 1
        readiness.invalidate(url)
        items = items.map { $0.url == url ? ShelfDownload(snapshot: $0.snapshot, isReady: false) : $0 }
        schedule(full: false, after: 0.25)
    }

    private func updateWatches(_ snapshots: [ShelfDownloadSnapshot]) -> Set<URL> {
        let numbers = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.url, $0.fileNumber) })
        for (url, existing) in fileWatches where numbers[url] != existing.number {
            existing.source.cancel()
            fileWatches[url] = nil
        }
        let token = generation
        for snapshot in snapshots where fileWatches[snapshot.url] == nil {
            let url = snapshot.url
            if let source = watch(url, onChange: { [weak self] in
                guard let self, self.running, self.generation == token else { return }
                self.changed(url)
            }) {
                fileWatches[url] = (snapshot.fileNumber, source)
            }
        }
        return Set(fileWatches.keys)
    }

    private func watch(_ url: URL, onChange: @escaping @MainActor () -> Void) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        let group = watchClosures
        group.enter()
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        let access = transferAccess
        source.setCancelHandler {
            close(descriptor)
            withExtendedLifetime(access) {}
            group.leave()
        }
        source.resume()
        return source
    }
}
