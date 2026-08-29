import AppKit
import ServiceManagement

/// Автозапуск: на macOS 13+ через `SMAppService.mainApp`,
/// на 11–12 — через собственный LaunchAgent в `~/Library/LaunchAgents`.
enum LoginItem {
    enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable(String)

        var isOn: Bool { self == .enabled }

        var note: String? {
            switch self {
            case .requiresApproval: return "Разрешите NotchHub в «Объекты входа»"
            case .unavailable(let m): return m
            default: return nil
            }
        }
    }

    static var state: State {
        guard Bundle.main.bundleIdentifier != nil else {
            return .unavailable(unbundledNote)
        }
        guard #available(macOS 13.0, *) else { return legacyState }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        // `.notFound` значит лишь «записи об автозапуске ещё нет», а не отказ:
        // проверено живьём — из этого состояния `register()` проходит и статус
        // становится `.enabled`. Раньше здесь стояло «Приложение не найдено
        // системой», и переключатель выглядел сломанным, хотя всё работало.
        case .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    /// Возвращает состояние после попытки переключения.
    @discardableResult
    static func set(_ on: Bool) -> State {
        guard #available(macOS 13.0, *) else { return legacySet(on) }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("Автозапуск: \(error.localizedDescription, privacy: .public)")
            return .unavailable(error.localizedDescription)
        }
        let result = state
        if result == .requiresApproval { openSettings() }
        return result
    }

    static func openSettings() {
        guard #available(macOS 13.0, *) else {
            // До Ventura отдельной панели «Объекты входа» нет, они лежат
            // вкладкой внутри «Пользователи и группы».
            if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.users") {
                _ = NSWorkspace.shared.open(url)
            }
            return
        }
        SMAppService.openSystemSettingsLoginItems()
    }

    private static let unbundledNote = "Автозапуск доступен только для собранного .app"

    // MARK: — запасной путь для macOS 11–12

    /// Метка агента совпадает с идентификатором бандла: так запись видно
    /// в системных списках под тем же именем, что и приложение.
    private static var agentLabel: String {
        Bundle.main.bundleIdentifier ?? "name.notchhub.NotchHub"
    }

    private static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(agentLabel + ".plist")
    }

    /// Путь, который launchd будет запускать, — исполняемый файл внутри бандла.
    /// Не `/usr/bin/open`: тот завершается сразу после передачи заявки
    /// LaunchServices, а на раннем входе ещё и зависит от их готовности.
    /// Прямой exec бандла — ровно то, чем система поднимает хелперы
    /// `SMLoginItemSetEnabled`, так что путь проверен ею самой.
    private static var executablePath: String? {
        Bundle.main.executableURL.map(canonical)
    }

    /// Одна форма записи пути для сравнения: `/tmp` и `/private/tmp`,
    /// хвостовые `..` и симлинки не должны выглядеть разными приложениями.
    private static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static var legacyState: State {
        guard let program = executablePath else { return .unavailable(unbundledNote) }
        // Запись, указывающая на прежнее место приложения, мертва: launchd
        // при входе ничего не запустит. Показывать «включено» в этом случае —
        // врать пользователю, поэтому считаем такую запись выключенной.
        return recordedProgramPath() == program ? .enabled : .disabled
    }

    /// Первый элемент `ProgramArguments` из нашего plist, если он вообще есть.
    private static func recordedProgramPath() -> String? {
        guard let data = try? Data(contentsOf: agentPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                     options: [],
                                                                     format: nil),
              let job = plist as? [String: Any],
              let arguments = job["ProgramArguments"] as? [String],
              let program = arguments.first
        else { return nil }
        return canonical(URL(fileURLWithPath: program))
    }

    private static func legacySet(_ on: Bool) -> State {
        guard Bundle.main.bundleIdentifier != nil, let program = executablePath else {
            Log.app.error("Автозапуск: \(unbundledNote, privacy: .public)")
            return .unavailable(unbundledNote)
        }
        do {
            if on {
                try writeAgent(program: program)
            } else {
                try removeAgent()
            }
        } catch {
            Log.app.error("Автозапуск: \(error.localizedDescription, privacy: .public)")
            return .unavailable(error.localizedDescription)
        }
        return legacyState
    }

    private static func writeAgent(program: String) throws {
        let url = agentPlistURL
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let job: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [program],
            "RunAtLoad": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        // Ни `load -w`, ни `bootstrap` здесь не годятся: оба честно исполняют
        // `RunAtLoad` и подняли бы вторую копию приложения поверх работающей —
        // с ещё одной панелью в чёлке. Для входа в систему достаточно самого
        // файла: launchd разбирает `~/Library/LaunchAgents` при старте сессии.
        // `enable` же снимает запрет, если он остался в базе launchd от прежней
        // сборки или от руки пользователя: файлом такой запрет не снимается,
        // а для метки без запрета команда — пустая операция.
        launchctl("enable")
    }

    private static func removeAgent() throws {
        // `bootout` не используем намеренно: если приложение подняла сама
        // launchd при входе, он прибил бы работающую копию прямо под руками
        // пользователя, хотя тот всего лишь снял галочку «запускать при входе».
        //
        // Парного `disable` тоже нет, хотя симметрия с `enable` напрашивается.
        // Запрет ложится не в наш файл, а в базу launchd (`disabled.<uid>.plist`)
        // и переживает и выход из приложения, и его удаление с диска. Пользы от
        // него нет — plist уже удалён, а без `KeepAlive` загруженная задача сама
        // не оживёт, — зато появляется новый способ сломаться: следующее
        // включение начнёт зависеть от того, снимет ли `enable` этот запрет.
        // Не снимет — plist на месте, тумблер показывает «включено», а launchd
        // при входе молча ничего не поднимает. Без записи запрета такого
        // расхождения не бывает вовсе.
        let url = agentPlistURL
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Служебные команды launchd. Отказ не считаем провалом: источник правды —
    /// сам plist, а без него агент всё равно не поднимется.
    private static func launchctl(_ subcommand: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [subcommand, "gui/\(getuid())/\(agentLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                Log.app.notice("launchctl \(subcommand, privacy: .public): код \(process.terminationStatus, privacy: .public)")
            }
        } catch {
            Log.app.notice("launchctl \(subcommand, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
