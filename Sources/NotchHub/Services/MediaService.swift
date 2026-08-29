import AppKit
import Combine

/// Текущий трек.
struct NowPlaying: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var duration: TimeInterval = 0
    var bundleID: String = ""
    /// Ключ, по которому кэшируется обложка (title+artist+album).
    var trackKey: String { "\(title)|\(artist)|\(album)" }
    /// «Артист — Альбом» или имя приложения, если метаданных нет.
    var subtitle: String {
        let parts = [artist, album].filter { !$0.isEmpty }
        if parts.isEmpty { return appName }
        return parts.joined(separator: " — ")
    }
    var appName: String {
        guard !bundleID.isEmpty else { return "" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }
}

enum MediaBackend: Equatable {
    case none
    case adapter
    case appleScript

    var label: String {
        switch self {
        case .none: return "нет источника"
        case .adapter: return "MediaRemote"
        case .appleScript: return "AppleScript"
        }
    }
}

/// Обложку декодируем в фоне, а NSImage через границу актора не Sendable.
private struct MediaImageBox: @unchecked Sendable {
    let image: NSImage?
}

/// Now Playing из любого проигрывателя, включая Chrome/YouTube.
///
/// Основной путь — ungive/mediaremote-adapter: `MRMediaRemoteGetNowPlayingInfo`
/// для сторонних процессов закрыт с macOS 15.4, а `/usr/bin/perl` с bundle id
/// `com.apple.perl` к MediaRemote по-прежнему допущен. Если адаптера нет или он
/// не проходит проверку — остаются Spotify и «Музыка» через Apple Events.
@MainActor final class MediaService: ObservableObject {
    @Published private(set) var track: NowPlaying?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var artwork: NSImage?
    @Published private(set) var backend: MediaBackend = .none
    /// Имя приложения-источника. Считается один раз на смену bundle id:
    /// поиск в LaunchServices слишком дорог для тела вью.
    @Published private(set) var sourceName: String = ""
    /// Иконка приложения-источника. Считается один раз на смену bundle id.
    @Published private(set) var sourceIcon: NSImage?

    /// Играет десктопная Яндекс Музыка.
    var isYandexApp: Bool { YandexMusic.isApp(track?.bundleID ?? "") }

    /// 0…1 для прогресс-бара.
    var progress: Double {
        guard let d = track?.duration, d > 0 else { return 0 }
        return min(1, max(0, elapsed / d))
    }

    private var adapter: MediaAdapterRunner?
    private var script: MediaAppleScriptBridge?
    private var probe: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var running = false

    /// Опора локального счётчика времени: позиция и момент, когда она была верна.
    private var anchor: TimeInterval = 0
    private var anchorAt = Date()
    private var rate: Double = 0
    /// Трек, для которого уже показана обложка.
    private var artworkKey: String?
    /// Кэш разрешения bundle id → человекочитаемое имя.
    private var resolvedSource: (id: String, parent: String, name: String, bundle: String, icon: NSImage?)?
    /// Номер запуска: проба, начатая до `stop()`, не должна поднять второй бэкенд.
    private var generation = 0
    /// До этого момента входящую позицию игнорируем — мы только что перемотали сами.
    private var positionGuardUntil = Date.distantPast

    /// Насколько может разъехаться локальный счётчик, прежде чем мы дёрнем прогресс.
    /// Адаптер отдаёт timestamp с точностью до секунды — без этого запаса
    /// полоса дёргалась бы на каждом обновлении.
    private static let resyncThreshold: TimeInterval = 1.5
    /// Сколько ждать, пока плеер догонит нашу перемотку. Пока идёт это окно,
    /// поток ещё отдаёт позицию «до», и без окна полоса прыгала бы назад и обратно.
    private static let seekGuard: TimeInterval = 1.2
    /// Сколько раз пытаемся пройти `test`, прежде чем уйти в AppleScript.
    private static let probeAttempts = 3

    // MARK: — жизненный цикл

    func start() {
        guard !running else { return }
        running = true
        generation &+= 1
        let token = generation

        guard let paths = MediaAdapterPaths.locate() else {
            Log.media.notice("ресурсы MediaRemote-адаптера не найдены, работаем через AppleScript")
            startScript()
            return
        }
        // Проверка не должна тормозить запуск приложения.
        probe = Task { [weak self] in
            // Сначала уносим мусор от прошлых запусков, иначе на каждом
            // падении/Force Quit в системе оседает лишний клиент MediaRemote.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    MediaAdapterRunner.reapStrays(paths: paths)
                    continuation.resume()
                }
            }
            // Проба срывается и на исправной машине: тест-клиенту даётся 3 с на
            // ответ, и под нагрузкой он не всегда успевает. Один такой срыв
            // навсегда увёл бы нас в AppleScript, который Chrome не видит вовсе,
            // поэтому пробуем трижды.
            var ok = false
            for attempt in 1...MediaService.probeAttempts {
                ok = await MediaAdapterRunner.probeAsync(paths: paths, timeout: 8)
                if ok || Task.isCancelled || attempt == MediaService.probeAttempts { break }
                Log.media.notice("adapter test не прошёл (попытка \(attempt, privacy: .public)), повторяю")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { break }
            }
            guard let self, self.running, self.generation == token else { return }
            if ok {
                self.startAdapter(paths)
            } else {
                Log.media.notice("adapter test не прошёл, переходим на AppleScript")
                self.startScript()
            }
        }
    }

    func stop() {
        running = false
        generation &+= 1
        probe?.cancel()
        probe = nil
        adapter?.stop()
        adapter = nil
        script?.stop()
        script = nil
        ticker?.cancel()
        ticker = nil
        backend = .none
    }

    private func startAdapter(_ paths: MediaAdapterPaths) {
        let runner = MediaAdapterRunner(paths: paths) { [weak self] snapshot in
            // main.async, а не Task: порядок доставки снимков обязан сохраниться.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(snapshot) }
            }
        }
        adapter = runner
        backend = .adapter
        runner.start()
    }

    private func startScript() {
        let bridge = MediaAppleScriptBridge { [weak self] snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(snapshot) }
            }
        }
        script = bridge
        backend = .appleScript
        bridge.start()
    }

    // MARK: — управление

    func toggle() {
        command(.toggle)
        // Кнопка не должна ждать ответа потока: сразу переключаем вид,
        // поток через полсекунды подтвердит или поправит.
        guard track != nil else { return }
        isPlaying.toggle()
        rate = isPlaying ? 1 : 0
        setPosition(elapsed)
        syncTicker()
    }

    func next() {
        command(.next)
        setPosition(0)
    }

    func previous() {
        command(.previous)
        setPosition(0)
    }

    /// Перемотка в секундах от начала трека.
    func seek(to seconds: TimeInterval) {
        let duration = track?.duration ?? 0
        var target = max(0, seconds)
        if duration > 0 { target = min(target, duration) }
        switch backend {
        case .adapter: adapter?.seek(microseconds: Int64((target * 1_000_000).rounded()))
        case .appleScript: script?.seek(to: target)
        case .none: return
        }
        setPosition(target)
        positionGuardUntil = Date().addingTimeInterval(MediaService.seekGuard)
    }

    private func command(_ command: MediaAdapterRunner.Command) {
        switch backend {
        case .adapter: adapter?.send(command)
        case .appleScript: script?.send(command)
        case .none: break
        }
    }

    // MARK: — приём состояния

    private func apply(_ snapshot: MediaSnapshot?) {
        guard running else { return }
        guard let snapshot, snapshot.hasTrack else {
            if track != nil { track = nil }
            if isPlaying { isPlaying = false }
            if elapsed != 0 { elapsed = 0 }
            if artwork != nil { artwork = nil }
            rate = 0
            artworkKey = nil
            positionGuardUntil = .distantPast
            if !sourceName.isEmpty { sourceName = "" }
            if sourceIcon != nil { sourceIcon = nil }
            resolvedSource = nil
            syncTicker()
            return
        }

        var next = NowPlaying()
        next.title = snapshot.title.isEmpty ? "Без названия" : snapshot.title
        next.artist = snapshot.artist
        next.album = snapshot.album
        next.duration = max(0, snapshot.duration)
        next.bundleID = source(for: snapshot)

        let changed = track?.trackKey != next.trackKey
        let wasPlaying = isPlaying
        let previousRate = rate
        if track != next { track = next }
        if isPlaying != snapshot.playing { isPlaying = snapshot.playing }
        rate = snapshot.playing ? effectiveRate(snapshot) : 0

        let position = self.position(from: snapshot, duration: next.duration)
        // Пока часы не разъехались, ведём время локально — иначе полоса дёргается
        // на каждом обновлении: timestamp адаптера точен только до секунды.
        // Но на паузе, старте, смене трека и смене скорости опору надо переставить.
        let hardResync = changed || wasPlaying != isPlaying || previousRate != rate
        if hardResync { positionGuardUntil = .distantPast }
        // Сразу после нашей перемотки поток ещё какое-то время отдаёт старую
        // позицию: без окна ожидания полоса откатилась бы назад и прыгнула обратно.
        let guarded = Date() < positionGuardUntil
        if hardResync || (!guarded && (!snapshot.playing
                                       || abs(position - elapsed) > MediaService.resyncThreshold)) {
            setPosition(position)
        }

        updateArtwork(snapshot.artwork, key: next.trackKey, trackChanged: changed)
        syncTicker()
    }

    private func effectiveRate(_ snapshot: MediaSnapshot) -> Double {
        snapshot.playbackRate > 0.01 ? snapshot.playbackRate : 1
    }

    /// `elapsedTime` верен на момент `timestamp`, а строка приходит позже.
    private func position(from snapshot: MediaSnapshot, duration: TimeInterval) -> TimeInterval {
        var value = snapshot.elapsed
        if snapshot.playing, let timestamp = snapshot.timestamp {
            value += Date().timeIntervalSince(timestamp) * effectiveRate(snapshot)
        }
        if duration > 0 { value = min(value, duration) }
        return max(0, value)
    }

    private func setPosition(_ value: TimeInterval) {
        anchor = max(0, value)
        anchorAt = Date()
        if elapsed != anchor { elapsed = anchor }
    }

    // MARK: — локальный ход времени

    private func syncTicker() {
        let needed = isPlaying && track != nil && rate > 0
        if needed {
            guard ticker == nil else { return }
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.tick()
                }
            }
        } else {
            ticker?.cancel()
            ticker = nil
        }
    }

    private func tick() {
        guard isPlaying, rate > 0, let track else { return }
        var value = anchor + Date().timeIntervalSince(anchorAt) * rate
        if track.duration > 0 { value = min(value, track.duration) }
        value = max(0, value)
        if abs(value - elapsed) > 0.05 { elapsed = value }
    }

    // MARK: — обложка и источник

    /// Обложка приходит лениво и пропадает на перемотке — держим её,
    /// пока играет тот же трек.
    private func updateArtwork(_ data: Data?, key: String, trackChanged: Bool) {
        if trackChanged { artworkKey = nil }
        guard artworkKey != key else { return }
        guard let data, !data.isEmpty else {
            if trackChanged { artwork = nil }
            return
        }
        artworkKey = key
        Task.detached(priority: .utility) {
            let box = MediaImageBox(image: NSImage(data: data))
            await MainActor.run { [weak self] in
                guard let self, self.artworkKey == key else { return }
                if let image = box.image {
                    self.artwork = image
                } else {
                    // Байты не разобрались — пусть следующая порция попробует снова.
                    self.artworkKey = nil
                }
            }
        }
    }

    /// Для веб-плееров MediaRemote отдаёт процесс-помощник; родительский bundle id
    /// показывает настоящее приложение.
    private func source(for snapshot: MediaSnapshot) -> String {
        if let cached = resolvedSource, cached.id == snapshot.bundleID, cached.parent == snapshot.parentBundleID {
            if sourceName != cached.name { sourceName = cached.name }
            if sourceIcon !== cached.icon { sourceIcon = cached.icon }
            return cached.bundle
        }
        var bundle = snapshot.bundleID
        var name = displayName(for: bundle)
        if name.isEmpty || name == bundle, !snapshot.parentBundleID.isEmpty {
            let parentName = displayName(for: snapshot.parentBundleID)
            if !parentName.isEmpty, parentName != snapshot.parentBundleID {
                bundle = snapshot.parentBundleID
                name = parentName
            }
        }
        // Иконку тянем только на смене источника: LaunchServices на каждой
        // перерисовке — это диск дважды в секунду, пока идёт трек.
        let icon = YandexMusic.icon(forBundleID: bundle)
        resolvedSource = (snapshot.bundleID, snapshot.parentBundleID, name, bundle, icon)
        sourceName = name
        sourceIcon = icon
        return bundle
    }

    private func displayName(for bundleID: String) -> String {
        guard !bundleID.isEmpty else { return "" }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }
}
