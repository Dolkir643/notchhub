import CoreServices
import Foundation

/// Слежение за каталогом скриншотов через FSEvents.
///
/// Экземпляр одноразовый: `start()` → работа → `stop()`. Каталог и точка отсчёта
/// фиксируются при создании, поэтому обращаться к ним с очереди событий безопасно.
/// Вся внутренняя кухня живёт на собственной очереди `queue`.
final class ShelfScreenshotWatcher: @unchecked Sendable {

    /// Готовый скриншот. Вызывается на главном потоке.
    private let onFound: (URL) -> Void
    let directory: URL

    private let queue = DispatchQueue(label: "name.notchhub.shelf.screenshots", qos: .utility)
    private var stream: FSEventStreamRef?
    private var startedAt = Date.distantFuture
    /// Файлы в работе и уже разобранные — только с `queue`.
    private var pending = Set<String>()
    private var handled = Set<String>()
    /// Взведён после `stop()` — только с `queue`. Дозревание файла и опросы Spotlight
    /// живут в отложенных блоках на этой же очереди, и без флага снимок доехал бы
    /// на полку через несколько секунд после того, как слежку выключили.
    private var stopped = false

    init(directory: URL, onFound: @escaping (URL) -> Void) {
        self.directory = directory
        self.onFound = onFound
    }

    deinit { tearDown() }

    // MARK: — запуск

    func start() {
        guard stream == nil else { return }
        startedAt = Date()

        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagIgnoreSelf
                           // Без этого флага пути приходят массивом char* — и разбор их как CFArray роняет процесс.
                           | kFSEventStreamCreateFlagUseCFTypes)

        guard let created = FSEventStreamCreate(kCFAllocatorDefault,
                                                shelfScreenshotEventCallback,
                                                &context,
                                                [directory.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                0.3,
                                                flags) else {
            Log.shelf.error("FSEvents не создался для \(self.directory.path, privacy: .public)")
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            Log.shelf.error("FSEvents не стартовал для \(self.directory.path, privacy: .public)")
            return
        }
        stream = created
        Log.shelf.info("Слежу за скриншотами: \(self.directory.path, privacy: .public)")
    }

    func stop() {
        tearDown()
        // Барьер: ждём, пока очередь дожуёт колбэк, который мог начаться до Invalidate
        // (контекст потока держит нас без retain — иначе dealloc обогнал бы колбэк),
        // и заодно гасим всё отложенное.
        queue.sync {
            stopped = true
            pending.removeAll()
            handled.removeAll()
        }
    }

    private func tearDown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: — разбор событий (всё ниже — на очереди FSEvents)

    fileprivate func noticed(path: String, flags: FSEventStreamEventFlags) {
        guard !stopped else { return }
        let interesting = UInt32(kFSEventStreamEventFlagItemCreated
                                 | kFSEventStreamEventFlagItemRenamed
                                 | kFSEventStreamEventFlagItemModified
                                 // Именно этим xattr система помечает свежий снимок экрана.
                                 | kFSEventStreamEventFlagItemXattrMod
                                 | kFSEventStreamEventFlagItemFinderInfoMod)
        guard flags & interesting != 0 else { return }
        guard flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 else { return }
        guard Self.hasImageExtension(path) else { return }
        guard !pending.contains(path), !handled.contains(path) else { return }

        pending.insert(path)
        awaitStableFile(path: path, previous: nil, attempt: 0)
    }

    /// Ловушка первая: снимок пишется постепенно. Ждём, пока размер и mtime
    /// не совпадут два замера подряд.
    private func awaitStableFile(path: String, previous: (Int64, Date)?, attempt: Int) {
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.stopped else { return }
            guard let now = Self.stamp(of: path) else {
                self.pending.remove(path)   // файл исчез (переименовали, удалили)
                return
            }
            if let previous, previous == now, now.0 > 0 {
                self.confirmScreenshot(path: path, attempt: 0)
                return
            }
            guard attempt < 24 else {
                self.pending.remove(path)
                return
            }
            self.awaitStableFile(path: path, previous: now, attempt: attempt + 1)
        }
    }

    /// Ловушка вторая: Spotlight проставляет `kMDItemIsScreenCapture` с задержкой,
    /// поэтому спрашиваем трижды — сразу, через секунду и через две.
    private func confirmScreenshot(path: String, attempt: Int) {
        guard !stopped else { return }
        if Self.spotlightSaysScreenshot(path) {
            deliver(path: path)
            return
        }
        guard attempt >= 2 else {
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.confirmScreenshot(path: path, attempt: attempt + 1)
            }
            return
        }
        // Spotlight мог быть отключён для тома — остаётся имя от `screencapture`.
        if Self.nameLooksLikeScreenshot(path) {
            deliver(path: path)
        } else {
            pending.remove(path)
        }
    }

    private func deliver(path: String) {
        pending.remove(path)
        guard !stopped, !handled.contains(path) else { return }
        if handled.count > 500 { handled.removeAll() }
        handled.insert(path)

        let url = URL(fileURLWithPath: path)
        guard Self.isFresh(url, since: startedAt) else { return }
        let callback = onFound
        DispatchQueue.main.async { callback(url) }
    }

    // MARK: — признаки снимка

    private static func stamp(of path: String) -> (Int64, Date)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        return (size, modified)
    }

    private static func hasImageExtension(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix(".") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "bmp", "pdf"].contains(ext)
    }

    private static func spotlightSaysScreenshot(_ path: String) -> Bool {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return false }
        // Константы kMDItemIsScreenCapture в MDItem.h нет — имя атрибута строкой.
        guard let value = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private static func nameLooksLikeScreenshot(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        guard (name as NSString).pathExtension == "png" else { return false }
        return ["снимок экрана", "screenshot", "screen shot"].contains { name.hasPrefix($0) }
    }

    /// Старые файлы каталога (их трогают Finder и облака) на полку не тащим.
    private static func isFresh(_ url: URL, since: Date) -> Bool {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        let born = values.creationDate ?? values.contentModificationDate ?? .distantPast
        return born > since.addingTimeInterval(-5)
    }

    // MARK: — каталог скриншотов

    /// `defaults read com.apple.screencapture location` с оглядкой на `~`,
    /// относительный путь и отсутствие ключа.
    static func screenshotDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)

        // Значения чужого домена кешируются в процессе: без синхронизации мы до
        // самого перезапуска видели бы каталог, который был на момент старта.
        let domain = "com.apple.screencapture" as CFString
        CFPreferencesAppSynchronize(domain)
        let stored = CFPreferencesCopyAppValue("location" as CFString, domain) as? String
        var path = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return desktop }

        if path.hasPrefix("file://"), let url = URL(string: path) { path = url.path }
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = home.appendingPathComponent(path).path }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return desktop
        }
        return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
    }
}

/// C-колбэк FSEvents: без захвата контекста, поэтому владелец приходит через `info`.
private let shelfScreenshotEventCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    guard let info else { return }
    let watcher = Unmanaged<ShelfScreenshotWatcher>.fromOpaque(info).takeUnretainedValue()
    guard let list = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
    for index in 0..<min(count, list.count) {
        watcher.noticed(path: list[index], flags: flags[index])
    }
}
