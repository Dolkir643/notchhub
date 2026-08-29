import AppKit
import Foundation

/// Запасной путь, когда MediaRemote недоступен: Spotify и «Музыка» через Apple Events.
/// Браузеры сюда не попадают — у них нет словаря AppleScript для плеера.
final class MediaAppleScriptBridge {
    typealias Update = (MediaSnapshot?) -> Void

    private enum Player: CaseIterable {
        case spotify, music

        var bundleID: String {
            switch self {
            case .spotify: return "com.spotify.client"
            case .music: return "com.apple.Music"
            }
        }

        /// Spotify отдаёт длительность в миллисекундах, «Музыка» — в секундах.
        var durationExpression: String {
            switch self {
            case .spotify: return "(duration of tr)"
            case .music: return "((duration of tr) * 1000)"
            }
        }

        /// Обложку Spotify отдаёт ссылкой, «Музыка» — байтами (отдельным запросом).
        var artworkExpression: String {
            switch self {
            case .spotify: return "(artwork url of tr)"
            case .music: return "\"\""
            }
        }
    }

    private let update: Update
    private let queue = DispatchQueue(label: "name.notchhub.media.applescript")
    private var timer: DispatchSourceTimer?
    private var scripts: [String: NSAppleScript] = [:]
    /// Плееры, которым отказано в Automation: дальше их не дёргаем.
    private var denied: Set<String> = []
    private var active: Player?
    private var artworkKey = ""
    private var artwork: Data?
    private var last: MediaSnapshot?

    init(update: @escaping Update) {
        self.update = update
    }

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.1, repeating: 1.5, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
            Log.media.notice("опрос Spotify и «Музыки» через AppleScript запущен")
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    // MARK: команды

    func send(_ command: MediaAdapterRunner.Command) {
        switch command {
        case .play: perform("play")
        case .pause: perform("pause")
        case .toggle: perform("playpause")
        case .next: perform("next track")
        case .previous: perform("previous track")
        }
    }

    func seek(to seconds: TimeInterval) {
        // В исходнике AppleScript разделитель дробной части всегда точка.
        // Кэшировать нечего: позиция в каждом вызове своя.
        perform("set player position to " + String(format: "%.2f", max(0, seconds)), cacheable: false)
    }

    private func perform(_ command: String, cacheable: Bool = true) {
        queue.async {
            guard let player = self.active ?? self.firstAvailable() else { return }
            _ = self.execute("tell application id \"\(player.bundleID)\" to \(command)",
                             cacheKey: cacheable ? "\(player.bundleID)|\(command)" : nil,
                             player: player)
        }
    }

    // MARK: опрос

    private func poll() {
        var chosen: (Player, MediaSnapshot, String)?
        for player in Player.allCases {
            guard isRunning(player), let result = read(player) else { continue }
            if result.0.playing { chosen = (player, result.0, result.1); break }
            if chosen == nil { chosen = (player, result.0, result.1) }
        }

        guard let (player, snapshot, artworkURL) = chosen else {
            active = nil
            artworkKey = ""
            artwork = nil
            last = nil
            update(nil)
            return
        }

        active = player
        let key = "\(player.bundleID)|\(snapshot.title)|\(snapshot.artist)|\(snapshot.album)"
        if key != artworkKey {
            artworkKey = key
            artwork = nil
            loadArtwork(player: player, url: artworkURL, key: key)
        }

        var out = snapshot
        out.artwork = artwork
        last = out
        update(out)
    }

    private func read(_ player: Player) -> (MediaSnapshot, String)? {
        let source = """
        tell application id "\(player.bundleID)"
        \ttry
        \t\tset tr to current track
        \t\tif player state is playing then
        \t\t\tset st to "1"
        \t\telse
        \t\t\tset st to "0"
        \t\tend if
        \t\tset du to (round \(player.durationExpression))
        \t\tset po to (round ((player position) * 1000))
        \t\treturn st & tab & (name of tr) & tab & (artist of tr) & tab & (album of tr) & tab & (du as text) & tab & (po as text) & tab & \(player.artworkExpression)
        \ton error
        \t\treturn "none"
        \tend try
        end tell
        """
        guard let descriptor = execute(source, cacheKey: "\(player.bundleID)|info", player: player),
              let text = descriptor.stringValue, text != "none" else { return nil }

        let parts = text.components(separatedBy: "\t")
        guard parts.count >= 6 else { return nil }

        var snapshot = MediaSnapshot()
        snapshot.bundleID = player.bundleID
        snapshot.playing = parts[0] == "1"
        snapshot.title = parts[1]
        snapshot.artist = parts[2]
        snapshot.album = parts[3]
        snapshot.duration = (Double(parts[4]) ?? 0) / 1000
        snapshot.elapsed = (Double(parts[5]) ?? 0) / 1000
        snapshot.playbackRate = 1
        snapshot.timestamp = Date()
        guard snapshot.hasTrack else { return nil }
        return (snapshot, parts.count > 6 ? parts[6] : "")
    }

    // MARK: обложка

    private func loadArtwork(player: Player, url: String, key: String) {
        switch player {
        case .music:
            let source = "tell application id \"\(player.bundleID)\"\n\ttry\n\t\treturn (raw data of artwork 1 of current track)\n\ton error\n\t\treturn \"\"\n\tend try\nend tell"
            let data = execute(source, cacheKey: "\(player.bundleID)|artwork", player: player)?.data
            guard let data, data.count > 16 else { return }
            store(data, for: key)
        case .spotify:
            guard let link = URL(string: url), link.scheme?.hasPrefix("http") == true else { return }
            var request = URLRequest(url: link)
            request.timeoutInterval = 8
            URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
                guard let self, let data, !data.isEmpty else { return }
                self.queue.async { self.store(data, for: key) }
            }.resume()
        }
    }

    private func store(_ data: Data, for key: String) {
        guard artworkKey == key else { return }
        artwork = data
        guard var snapshot = last else { return }
        snapshot.artwork = data
        last = snapshot
        update(snapshot)
    }

    // MARK: примитивы

    private func isRunning(_ player: Player) -> Bool {
        guard !denied.contains(player.bundleID) else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    private func firstAvailable() -> Player? {
        Player.allCases.first { isRunning($0) }
    }

    private func execute(_ source: String, cacheKey: String?, player: Player) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cacheKey, let cached = scripts[cacheKey] {
            script = cached
        } else {
            guard let built = NSAppleScript(source: source) else { return nil }
            if let cacheKey { scripts[cacheKey] = built }
            script = built
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            // -1743 — пользователь не выдал Automation; дальше стучаться бессмысленно.
            if code == -1743 {
                denied.insert(player.bundleID)
                Log.media.error("нет разрешения Automation для \(player.bundleID, privacy: .public)")
            }
            return nil
        }
        return result
    }
}
