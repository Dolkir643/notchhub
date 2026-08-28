import Foundation
import Combine

/// Настройки приложения. Хранятся в UserDefaults, каждая пишется сразу при изменении.
@MainActor final class Settings: ObservableObject {
    static let shared = Settings()

    private let d = UserDefaults.standard
    private var loading = true

    /// Автозапуск (SMAppService.mainApp). По умолчанию выключен.
    @Published var launchAtLogin: Bool = false { didSet { persist(\.launchAtLogin, "launchAtLogin", launchAtLogin) } }

    /// Сколько дней держать файлы на полке. 0 — не чистить.
    @Published var shelfRetentionDays: Int = 3 { didSet { persist(\.shelfRetentionDays, "shelfRetentionDays", shelfRetentionDays) } }

    /// Ловить свежие скриншоты и класть их на полку.
    @Published var autoScreenshots: Bool = true { didSet { persist(\.autoScreenshots, "autoScreenshots", autoScreenshots) } }

    /// Максимум записей в истории буфера обмена.
    @Published var clipboardLimit: Int = 50 { didSet { persist(\.clipboardLimit, "clipboardLimit", clipboardLimit) } }

    /// Следить за буфером обмена.
    @Published var clipboardEnabled: Bool = true { didSet { persist(\.clipboardEnabled, "clipboardEnabled", clipboardEnabled) } }

    /// Задержка перед раскрытием при наведении, сек.
    @Published var hoverOpenDelay: Double = 0.3 { didSet { persist(\.hoverOpenDelay, "hoverOpenDelay", hoverOpenDelay) } }

    /// Хаптик при попадании в чёлку.
    @Published var hapticsEnabled: Bool = true { didSet { persist(\.hapticsEnabled, "hapticsEnabled", hapticsEnabled) } }

    /// Показывать хаб только на встроенном дисплее.
    @Published var builtinScreenOnly: Bool = false { didSet { persist(\.builtinScreenOnly, "builtinScreenOnly", builtinScreenOnly) } }

    /// Раскрывать панель при наведении (иначе — только по клику).
    @Published var openOnHover: Bool = true { didSet { persist(\.openOnHover, "openOnHover", openOnHover) } }

    private init() {
        if d.object(forKey: "launchAtLogin") != nil { launchAtLogin = d.bool(forKey: "launchAtLogin") }
        if d.object(forKey: "shelfRetentionDays") != nil { shelfRetentionDays = d.integer(forKey: "shelfRetentionDays") }
        if d.object(forKey: "autoScreenshots") != nil { autoScreenshots = d.bool(forKey: "autoScreenshots") }
        if d.object(forKey: "clipboardLimit") != nil { clipboardLimit = max(5, d.integer(forKey: "clipboardLimit")) }
        if d.object(forKey: "clipboardEnabled") != nil { clipboardEnabled = d.bool(forKey: "clipboardEnabled") }
        if d.object(forKey: "hoverOpenDelay") != nil { hoverOpenDelay = d.double(forKey: "hoverOpenDelay") }
        if d.object(forKey: "hapticsEnabled") != nil { hapticsEnabled = d.bool(forKey: "hapticsEnabled") }
        if d.object(forKey: "builtinScreenOnly") != nil { builtinScreenOnly = d.bool(forKey: "builtinScreenOnly") }
        if d.object(forKey: "openOnHover") != nil { openOnHover = d.bool(forKey: "openOnHover") }
        loading = false
    }

    private func persist<T>(_ key: KeyPath<Settings, T>, _ name: String, _ value: T) {
        guard !loading else { return }
        d.set(value, forKey: name)
    }
}
