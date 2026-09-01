import AppKit
import Combine

/// Следит за тем, на каких экранах чужое окно занимает верхнюю полосу экрана —
/// ту самую, где живёт островок. Там строка меню скрыта, и островок ложится
/// поверх чужого интерфейса: в браузере ровно на полосу вкладок.
///
/// Как определяется. Вопрос ставится прямо: накрывает ли обычное окно место
/// островка. Совпадение размеров окна с экраном как признак не годится —
/// браузер в полноэкранном режиме оставляет себе не ровно весь экран.
/// В оконном режиме окно начинается под строкой меню, верхняя полоса
/// свободна, и островок никому не мешает.
///
/// `currentSystemPresentationOptions` не годится вовсе: для чужого приложения
/// она остаётся нулевой — проверено замером. Исчезновение окна строки меню
/// из списка тоже ненадёжно: macOS выдвигает её обратно, стоит подвести курсор
/// к верхней кромке, и признак пропал бы ровно тогда, когда он нужен.
@MainActor final class FullScreenWatcher: ObservableObject {
    static let shared = FullScreenWatcher()

    /// Ключи экранов (`NSStringFromRect` их frame), занятых полноэкранным окном.
    @Published private(set) var coveredScreens: Set<String> = []

    private var timer: Timer?
    /// NOTCHHUB_DIAG=fullscreen — подробный след в журнале: чьё окно накрыло верх.
    private let diagnostics = ProcessInfo.processInfo.environment["NOTCHHUB_DIAG"] == "fullscreen"
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func covers(_ screenFrame: CGRect) -> Bool {
        coveredScreens.contains(NSStringFromRect(screenFrame))
    }

    func start() {
        refresh()

        let poke: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { FullScreenWatcher.shared.refreshSoon() }
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main, using: poke))
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main, using: poke))

        // Страховка. Уведомления приходят не всегда: `activeSpaceDidChange` при
        // входе в фуллскрин может и не прийти, а плеер, прячущий строку меню без
        // смены Space, не подаёт вообще никакого сигнала. Раз в секунду — потолок:
        // один замер стоит около пяти миллисекунд, чаще опрашивать расточительно.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { FullScreenWatcher.shared.refresh() }
        }
    }

    /// Уведомление приходит в момент, когда окна ещё не переехали, —
    /// замеряем после короткой паузы, а не по самому событию.
    private func refreshSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.refresh()
        }
    }

    private func refresh() {
        let screens = NSScreen.screens.map { (key: NSStringFromRect($0.frame), frame: $0.frame) }
        guard !screens.isEmpty else { return }

        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var covered: Set<String> = []

        for window in info {
            // Уровень 0 — обычные окна приложений. Всё, что выше (строка меню,
            // Dock, наша собственная панель), к перекрытию отношения не имеет.
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = rectFrom(bounds) else { continue }

            for screen in screens where coversIsland(rect, screen.frame) {
                covered.insert(screen.key)
                if diagnostics {
                    let owner = (window[kCGWindowOwnerName as String] as? String) ?? "?"
                    Log.window.info("верх экрана занял \(owner, privacy: .public): \(NSStringFromRect(rect), privacy: .public)")
                }
            }
        }

        guard covered != coveredScreens else { return }
        Log.window.info("экранов с занятым верхом: \(covered.count, privacy: .public)")
        coveredScreens = covered
    }

    /// CGWindowList отдаёт координаты сверху вниз, экраны AppKit — снизу вверх.
    private func rectFrom(_ bounds: [String: Any]) -> CGRect? {
        guard let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
              let w = bounds["Width"] as? CGFloat, let h = bounds["Height"] as? CGFloat
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Накрывает ли окно место островка: центральную часть верхней полосы экрана.
    private func coversIsland(_ window: CGRect, _ screenFrame: CGRect) -> Bool {
        guard let main = NSScreen.screens.first else { return false }
        // Верхний край экрана в координатах CGWindowList (ось Y вниз).
        let screenTop = main.frame.maxY - screenFrame.maxY
        let islandHalfWidth = ScreenGeometry.pseudoNotchWidth / 2

        // Окно должно доставать до самого верха экрана: обычное окно начинается
        // под строкой меню и на два пункта выше не поднимается.
        guard window.minY <= screenTop + 2, window.maxY > screenTop + 20 else { return false }
        // ...и перекрывать центр по горизонтали, где сидит островок.
        let center = screenFrame.midX - main.frame.minX
        return window.minX <= center - islandHalfWidth + 2
            && window.maxX >= center + islandHalfWidth - 2
    }
}
