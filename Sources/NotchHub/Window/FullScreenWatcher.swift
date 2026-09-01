import AppKit
import Combine

/// Следит за тем, на каких экранах приложение занимает весь экран целиком —
/// то есть строка меню спрятана и наш островок закрывал бы собой чужой интерфейс
/// (в браузере это ровно полоса вкладок).
///
/// Как определяется. `currentSystemPresentationOptions` не годится: для чужого
/// приложения в фуллскрине она остаётся нулевой — проверено замером. Исчезновение
/// окна строки меню из списка тоже ненадёжно: macOS выдвигает её обратно, стоит
/// подвести курсор к верхней кромке, и признак пропал бы ровно в тот момент,
/// когда он нужен. Поэтому смотрим на сами окна: окно обычного уровня, чей
/// прямоугольник совпал с прямоугольником экрана, и есть полноэкранное.
/// Под то же условие попадают игры и плееры, прячущие строку меню без
/// системного фуллскрина, — и это желаемое поведение. Окно, растянутое на весь
/// экран вручную, под него не попадает: оно начинается под строкой меню.
@MainActor final class FullScreenWatcher: ObservableObject {
    static let shared = FullScreenWatcher()

    /// Ключи экранов (`NSStringFromRect` их frame), занятых полноэкранным окном.
    @Published private(set) var coveredScreens: Set<String> = []

    private var timer: Timer?
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

            for screen in screens where matches(rect, screen.frame) {
                covered.insert(screen.key)
            }
        }

        guard covered != coveredScreens else { return }
        Log.window.info("полноэкранных экранов: \(covered.count, privacy: .public)")
        coveredScreens = covered
    }

    /// CGWindowList отдаёт координаты сверху вниз, экраны AppKit — снизу вверх.
    /// Сравниваем размер и отступ от верхнего края общего пространства дисплеев,
    /// поэтому переворачивать ничего не нужно: у главного экрана верх — ноль,
    /// у остальных — их смещение в той же системе.
    private func rectFrom(_ bounds: [String: Any]) -> CGRect? {
        guard let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
              let w = bounds["Width"] as? CGFloat, let h = bounds["Height"] as? CGFloat
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func matches(_ windowRect: CGRect, _ screenFrame: CGRect) -> Bool {
        guard let main = NSScreen.screens.first else { return false }
        // Экран в координатах CGWindowList: начало отсчёта — верхний левый угол
        // главного экрана, ось Y вниз.
        let flippedY = main.frame.maxY - screenFrame.maxY
        return abs(windowRect.origin.x - screenFrame.origin.x) < 2
            && abs(windowRect.origin.y - flippedY) < 2
            && abs(windowRect.width - screenFrame.width) < 2
            && abs(windowRect.height - screenFrame.height) < 2
    }
}
