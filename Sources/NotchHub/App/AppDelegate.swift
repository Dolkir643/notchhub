import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {

    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        installSignalHandlers()
        AppState.shared.startServices()
        NotchWindowController.shared.start()
        Log.app.info("NotchHub запущен из \(Bundle.main.bundlePath, privacy: .public)")
        Log.app.info("автозапуск: \(String(describing: LoginItem.state), privacy: .public)")
        startDemoIfRequested()
    }

    // ВРЕМЕННОЕ: держит панель раскрытой для снятия скриншотов при доводке вида.
    private func startDemoIfRequested() {
        guard let name = ProcessInfo.processInfo.environment["NOTCHHUB_DEMO"],
              let tab = NotchTab(rawValue: name) else { return }
        Task { @MainActor in
            while !Task.isCancelled {
                AppState.shared.expand(to: tab)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    /// `pkill NotchHub` и прочий SIGTERM убивают процесс мимо
    /// `applicationWillTerminate`, а вместе с ним осиротел бы `perl`-поток адаптера.
    /// Перехватываем сигнал и выходим по-человечески.
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    Log.app.notice("получен сигнал \(number, privacy: .public), выходим")
                    AppState.shared.stopServices()
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.stopServices()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Минимальное меню: нужно, чтобы работали ⌘Q, ⌘C/⌘V и правка текста в панели.
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "О NotchHub", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Скрыть панель", action: #selector(hidePanel), keyEquivalent: "w")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Выйти из NotchHub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    @objc private func hidePanel() {
        AppState.shared.collapse(immediate: true)
    }

    @objc private func showAbout() {
        AppState.shared.expand(to: .settings)
    }
}
