import AppKit
import ServiceManagement

/// Автозапуск через SMAppService.mainApp.
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
            return .unavailable("Автозапуск доступен только для собранного .app")
        }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable("Приложение не найдено системой")
        @unknown default: return .disabled
        }
    }

    /// Возвращает состояние после попытки переключения.
    @discardableResult
    static func set(_ on: Bool) -> State {
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
        SMAppService.openSystemSettingsLoginItems()
    }
}
