import AppKit

/// Яндекс Музыка — основной плеер этого хаба.
///
/// Десктопное приложение собрано на Electron, а Chromium внутри отдаёт трек
/// системе через Media Session → MPNowPlayingInfoCenter. Поэтому отдельного
/// кода для него не нужно: тот же поток MediaRemote, что и для всех остальных.
/// Здесь только опознание источника, иконка и способ открыть плеер.
enum YandexMusic {
    static let appBundleID = "ru.yandex.desktop.music"
    static let webURL = URL(string: "https://music.yandex.ru")!

    /// Браузеры, в которых веб-плеер отдаётся системе под своим именем.
    /// Отличить в них Яндекс Музыку от любой другой вкладки нечем: MediaRemote
    /// сообщает bundle id браузера, а не сайта. Поэтому — только для подсказки.
    private static let browserBundleIDs: Set<String> = [
        "ru.yandex.desktop.yandex-browser",
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "company.thebrowser.Browser"
    ]

    /// Путь к приложению ищется один раз за сеанс: `urlForApplication` лезет
    /// в LaunchServices и на диск, а заглушка вкладки читает его при каждой
    /// перерисовке. Приложение посреди сеанса не переустанавливают.
    static let appURL: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID)

    static var isInstalled: Bool { appURL != nil }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty
    }

    /// Играет именно десктопное приложение Яндекс Музыки.
    static func isApp(_ bundleID: String) -> Bool { bundleID == appBundleID }

    static func isBrowser(_ bundleID: String) -> Bool { browserBundleIDs.contains(bundleID) }

    /// Открыть плеер: приложение, если оно установлено, иначе сайт.
    static func open() {
        if let appURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    Log.media.error("Яндекс Музыка не открылась: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            NSWorkspace.shared.open(webURL)
        }
    }

    /// Что написать на кнопке.
    static var openTitle: String {
        guard isInstalled else { return "Открыть music.yandex.ru" }
        return isRunning ? "Показать Яндекс Музыку" : "Открыть Яндекс Музыку"
    }

    /// Иконка приложения-источника. Дорогая операция (LaunchServices + диск),
    /// поэтому зовётся только при смене источника, а не из тела вью.
    static func icon(forBundleID bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 32, height: 32)
        return image
    }

    /// Иконка самой Яндекс Музыки — для заглушки, когда ничего не играет.
    static var appIcon: NSImage? { icon(forBundleID: appBundleID) }
}
