import Foundation

// MARK: — состояние трека, собранное из потока адаптера

/// Полное состояние Now Playing на момент строки потока.
/// Диффы адаптера накладываются на него, поэтому здесь всегда «всё, что известно».
struct MediaSnapshot: Sendable {
    var bundleID: String = ""
    var parentBundleID: String = ""
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var duration: TimeInterval = 0
    var elapsed: TimeInterval = 0
    var timestamp: Date?
    var playing: Bool = false
    var playbackRate: Double = 1
    var artwork: Data?

    /// Адаптер гарантирует, что у играющего источника есть title и bundleIdentifier.
    var hasTrack: Bool { !title.isEmpty || !bundleID.isEmpty }
}

extension MediaSnapshot {
    /// Накладывает payload очередной строки. Значение `null` затирает поле,
    /// отсутствующий ключ оставляет прежнее (так работают диффы адаптера).
    mutating func apply(_ payload: [String: Any]) {
        mediaAssign(payload, "bundleIdentifier", &bundleID, "") { $0 as? String }
        mediaAssign(payload, "parentApplicationBundleIdentifier", &parentBundleID, "") { $0 as? String }
        mediaAssign(payload, "title", &title, "") { $0 as? String }
        mediaAssign(payload, "artist", &artist, "") { $0 as? String }
        mediaAssign(payload, "album", &album, "") { $0 as? String }
        mediaAssign(payload, "duration", &duration, 0) { ($0 as? NSNumber)?.doubleValue }
        mediaAssign(payload, "elapsedTime", &elapsed, 0) { ($0 as? NSNumber)?.doubleValue }
        mediaAssign(payload, "playing", &playing, false) { ($0 as? NSNumber)?.boolValue }
        mediaAssign(payload, "playbackRate", &playbackRate, 1) { ($0 as? NSNumber)?.doubleValue }
        mediaAssign(payload, "timestamp", &timestamp, nil) { MediaSnapshot.date(from: $0) }
        mediaAssign(payload, "artworkData", &artwork, nil) { raw in
            guard let text = raw as? String, !text.isEmpty else { return nil }
            return Data(base64Encoded: text, options: [.ignoreUnknownCharacters])
        }
    }

    /// Адаптер сериализует NSDate строкой «2026-08-28T09:15:42Z» (UTC, секундная точность),
    /// но с ключом `--micros` тот же смысл приходит числом. Понимаем оба вида.
    static func date(from raw: Any) -> Date? {
        if let text = raw as? String {
            if let date = utcFormatter.date(from: text) { return date }
            return isoFormatter.date(from: text)
        }
        if let number = raw as? NSNumber {
            let value = number.doubleValue
            guard value > 0 else { return nil }
            // Секунды эпохи столько не весят — значит это микросекунды.
            return Date(timeIntervalSince1970: value > 1e11 ? value / 1e6 : value)
        }
        return nil
    }

    private static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Свободная функция, а не метод: иначе `&self.поле` внутри метода того же объекта
/// даёт пересекающийся доступ.
private func mediaAssign<T>(_ payload: [String: Any],
                            _ key: String,
                            _ target: inout T,
                            _ empty: T,
                            _ convert: (Any) -> T?) {
    guard let raw = payload[key] else { return }
    if raw is NSNull { target = empty; return }
    if let value = convert(raw) { target = value }
}

// MARK: — пути к ресурсам адаптера

/// Абсолютные пути к ресурсам ungive/mediaremote-adapter.
/// Скрипт грузит фреймворк через DynaLoader: относительный путь даёт
/// «Failed to load framework» и молчаливую пустоту, поэтому только абсолютные.
struct MediaAdapterPaths: Sendable {
    static let perl = "/usr/bin/perl"

    let script: String
    let framework: String
    let testClient: String?

    /// Ищем сначала в бандле, потом в дереве репозитория (запуск через `swift run`).
    static func locate() -> MediaAdapterPaths? {
        if let bundled = fromBundle() { return bundled }
        for root in developmentRoots() {
            if let repo = fromRepository(root) { return repo }
        }
        return nil
    }

    private static func fromBundle() -> MediaAdapterPaths? {
        guard let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let bundle = frameworks.appendingPathComponent("MediaRemoteAdapter.framework")
        guard let framework = validFramework(bundle),
              let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              exists(script.standardizedFileURL.path) else { return nil }
        let client = Bundle.main.url(forResource: "MediaRemoteAdapterTestClient", withExtension: nil)
            .map { $0.standardizedFileURL.path }
        return MediaAdapterPaths(script: script.standardizedFileURL.path,
                                 framework: framework,
                                 testClient: client.flatMap { exists($0) ? $0 : nil })
    }

    private static func fromRepository(_ root: String) -> MediaAdapterPaths? {
        let script = root + "/Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl"
        guard exists(script) else { return nil }
        // build.sh кладёт адаптер в build/adapter-<минимальная macOS>;
        // build/adapter — путь старых сборок, оставлен на всякий случай.
        for dir in ["adapter-14.0", "adapter-11.0", "adapter"] {
            let base = root + "/build/" + dir
            guard let framework = validFramework(URL(fileURLWithPath: base + "/MediaRemoteAdapter.framework"))
            else { continue }
            let client = base + "/MediaRemoteAdapterTestClient"
            return MediaAdapterPaths(script: script, framework: framework, testClient: exists(client) ? client : nil)
        }
        return nil
    }

    private static func developmentRoots() -> [String] {
        var roots: [String] = []
        let env = ProcessInfo.processInfo.environment["NOTCHHUB_DEV_ROOT"] ?? ""
        if !env.isEmpty {
            roots.append(URL(fileURLWithPath: env).standardizedFileURL.path)
        }
        // <repo>/Sources/NotchHub/Services/MediaAdapter.swift
        //
        // Только в отладочной сборке: `#filePath` вшивает в бинарник полный путь
        // к исходнику вместе с именем пользователя и деревом папок, а в раздаваемом
        // приложении этот запасной путь всё равно не нужен — там ресурсы лежат
        // в самом бандле.
        #if DEBUG
        var here = URL(fileURLWithPath: #filePath).standardizedFileURL
        for _ in 0..<4 { here.deleteLastPathComponent() }
        roots.append(here.path)
        #endif
        // .build/<конфигурация>/NotchHub — поднимаемся, пока не наткнёмся на репозиторий.
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            var dir = executable.deletingLastPathComponent()
            for _ in 0..<6 {
                roots.append(dir.standardizedFileURL.path)
                dir.deleteLastPathComponent()
            }
        }
        return roots
    }

    private static func validFramework(_ url: URL) -> String? {
        let binary = url.appendingPathComponent("MediaRemoteAdapter")
        guard exists(binary.standardizedFileURL.path) else { return nil }
        return url.standardizedFileURL.path
    }

    private static func exists(_ path: String) -> Bool {
        FileManager.default.isReadableFile(atPath: path)
    }
}

// MARK: — поток и команды

/// Держит `perl … stream`, разбирает строки JSON и умеет слать команды.
/// Всё внутреннее состояние живёт на собственной последовательной очереди.
final class MediaAdapterRunner {
    /// `nil` — сейчас ничего не играет.
    typealias Update = (MediaSnapshot?) -> Void

    /// MRCommand: 0 play, 1 pause, 2 toggle, 4 next, 5 previous.
    enum Command: Int {
        case play = 0, pause = 1, toggle = 2, next = 4, previous = 5
    }

    private let paths: MediaAdapterPaths
    private let update: Update
    private let queue = DispatchQueue(label: "name.notchhub.media.stream")
    private let commands = DispatchQueue(label: "name.notchhub.media.command", qos: .userInitiated)

    private var process: Process?
    private var pipe: Pipe?
    private var errorPipe: Pipe?
    private var buffer = Data()
    private var state = MediaSnapshot()
    private var stopped = false
    private var failures = 0
    private var restart: DispatchWorkItem?
    /// Момент последнего запуска perl — по нему решаем, был ли прогон здоровым.
    private var startedAt = Date.distantPast

    /// Пауза перед перезапуском: 1 → 2 → 5 → 15 → 30 с.
    private static let backoff: [TimeInterval] = [1, 2, 5, 15, 30]
    private static let bufferLimit = 16 * 1024 * 1024

    init(paths: MediaAdapterPaths, update: @escaping Update) {
        self.paths = paths
        self.update = update
    }

    // MARK: жизненный цикл

    func start() {
        queue.async { self.launch() }
    }

    /// Прибить `perl`-потоки, оставшиеся от прошлых запусков.
    ///
    /// Поток переживает смерть приложения: SIGKILL (Force Quit, падение) не даёт
    /// шанса на уборку, а без музыки perl не пишет в закрытую трубу и не узнаёт,
    /// что читателя больше нет. За полчаса перезапусков их набирается десяток,
    /// и каждый продолжает висеть клиентом MediaRemote.
    ///
    /// Ищем строго свой скрипт по абсолютному пути и не трогаем процессы,
    /// запущенные нами же в этом сеансе.
    static func reapStrays(paths: MediaAdapterPaths) {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-x", "-o", "pid=,command="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard let listing = String(data: data, encoding: .utf8) else { return }

        let mine = ProcessInfo.processInfo.processIdentifier
        var killed = 0
        for line in listing.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[trimmed.startIndex..<space]),
                  pid != mine else { continue }
            let command = trimmed[trimmed.index(after: space)...]
            guard command.hasPrefix(MediaAdapterPaths.perl),
                  command.contains(paths.script) else { continue }
            if kill(pid, SIGTERM) == 0 { killed += 1 }
        }
        if killed > 0 {
            Log.media.notice("прибрано осиротевших потоков адаптера: \(killed, privacy: .public)")
        }
    }

    /// Синхронно: вызывается из `applicationWillTerminate`, и к моменту выхода
    /// приложения дочерний perl обязан быть убит.
    func stop() {
        queue.sync {
            stopped = true
            restart?.cancel()
            restart = nil
            teardown()
        }
    }

    /// Проверка допуска к MediaRemote. Блокирует вызывающий поток — только из фона.
    static func probe(paths: MediaAdapterPaths, timeout: TimeInterval) -> Bool {
        var arguments = [paths.script, paths.framework]
        // Путь к тест-клиенту скрипт ждёт вторым аргументом, до имени функции.
        if let client = paths.testClient { arguments.append(client) }
        arguments.append("test")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: MediaAdapterPaths.perl)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            Log.media.error("adapter test не запустился: \(error.localizedDescription, privacy: .public)")
            return false
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            Log.media.error("adapter test завис, считаем его провалившимся")
            return false
        }
        return process.terminationStatus == 0
    }

    /// Та же проверка, но без блокировки потока пула Swift Concurrency:
    /// `probe` ждёт до восьми секунд, а кооперативных потоков всего по числу ядер.
    static func probeAsync(paths: MediaAdapterPaths, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: probe(paths: paths, timeout: timeout))
            }
        }
    }

    // MARK: команды

    func send(_ command: Command) {
        run(["send", String(command.rawValue)])
    }

    func seek(microseconds: Int64) {
        run(["seek", String(max(0, microseconds))])
    }

    private func run(_ arguments: [String]) {
        let paths = self.paths
        commands.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: MediaAdapterPaths.perl)
            process.arguments = [paths.script, paths.framework] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            do {
                try process.run()
            } catch {
                Log.media.error("команда адаптера не ушла: \(error.localizedDescription, privacy: .public)")
                return
            }
            // Ждём с потолком: очередь команд последовательная, и один зависший
            // perl иначе намертво заблокировал бы весь транспорт до конца сеанса.
            guard done.wait(timeout: .now() + 5) == .timedOut else { return }
            Log.media.error("команда адаптера зависла, снимаю процесс")
            process.terminate()
            guard done.wait(timeout: .now() + 2) == .timedOut else { return }
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 1)
        }
    }

    // MARK: поток

    private func launch() {
        guard !stopped, process == nil else { return }
        startedAt = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MediaAdapterPaths.perl)
        // Диффы оставляем включёнными: с --no-diff каждое обновление тащит всю обложку.
        process.arguments = [paths.script, paths.framework, "stream", "--debounce=200"]
        process.standardInput = FileHandle.nullDevice

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Пустая порция — это EOF. Обработчик обязан сняться прямо здесь:
        // иначе источник чтения крутится вхолостую и жжёт ядро до teardown().
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else {
                handle.readabilityHandler = nil
                return
            }
            self.queue.async { self.ingest(chunk) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: chunk, encoding: .utf8) else { return }
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }
            Log.media.error("adapter stderr: \(message, privacy: .public)")
        }
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.queue.async { self.processDied(finished) }
        }

        do {
            try process.run()
        } catch {
            Log.media.error("поток адаптера не запустился: \(error.localizedDescription, privacy: .public)")
            scheduleRestart()
            return
        }
        self.process = process
        self.pipe = out
        self.errorPipe = err
        buffer.removeAll(keepingCapacity: false)
        Log.media.notice("поток MediaRemote запущен")
    }

    private func processDied(_ finished: Process) {
        guard !stopped, finished === process else { return }
        teardown()
        scheduleRestart()
    }

    private func teardown() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        errorPipe = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        buffer.removeAll(keepingCapacity: false)
    }

    private func scheduleRestart() {
        guard !stopped else { return }
        // Счётчик сбрасывает только долгий здоровый прогон. Раньше его обнуляла
        // любая пришедшая строка, а поток печатает её сразу после старта —
        // падающий каждый раз perl переподнимался бы раз в секунду вечно.
        if Date().timeIntervalSince(startedAt) > 60 { failures = 0 }
        let delay = MediaAdapterRunner.backoff[min(failures, MediaAdapterRunner.backoff.count - 1)]
        failures += 1
        Log.media.notice("поток адаптера упал, перезапуск через \(delay, privacy: .public) с")
        let work = DispatchWorkItem { [weak self] in self?.launch() }
        restart = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: разбор строк

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        // Строка с обложкой — сотни килобайт; всё, что сильно больше, — мусор.
        if buffer.count > MediaAdapterRunner.bufferLimit {
            Log.media.error("переполнение буфера потока, сбрасываю")
            buffer.removeAll(keepingCapacity: false)
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard !line.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              root["type"] as? String == "data" else { return }

        let isDiff = (root["diff"] as? NSNumber)?.boolValue ?? false
        let payload = root["payload"] as? [String: Any] ?? [:]
        // Полный payload — это новое «начальное» состояние; пустой означает «ничего не играет».
        if !isDiff { state = MediaSnapshot() }
        state.apply(payload)
        update(state.hasTrack ? state : nil)
    }
}
