import AppKit
import SwiftUI

/// Создаёт и держит окна-чёлки на всех подходящих экранах,
/// отслеживает курсор и пересоздаёт окна при смене конфигурации дисплеев.
@MainActor final class NotchWindowController {
    static let shared = NotchWindowController()

    private struct Entry {
        let panel: NotchPanel
        let geometry: NotchGeometry
    }

    private var entries: [Entry] = []
    private var moveMonitors: [Any] = []
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var keyMonitor: Any?
    private var pollTimer: Timer?
    private var lastInsideFrame: CGRect?
    private var lastPoint: CGPoint?
    private var rebuildTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: — жизненный цикл

    func start() {
        FullScreenWatcher.shared.start()
        rebuild()

        let screensChanged: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { NotchWindowController.shared.scheduleRebuild() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main, using: screensChanged))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main, using: screensChanged))

        installMonitors()
    }

    /// Смена разрешения/подключение монитора приходит пачкой — схлопываем в один ребилд.
    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    func rebuild() {
        for e in entries {
            e.panel.orderOut(nil)
            e.panel.contentView = nil
            e.panel.close()
        }
        entries.removeAll()

        for screen in ScreenGeometry.targetScreens() {
            let geo = ScreenGeometry.geometry(of: screen)
            let frame = windowFrame(for: geo, on: screen)
            let panel = NotchPanel(contentRect: frame)
            panel.acceptsKeyInput = AppState.shared.isExpanded(on: geo.screenFrame)
            let host = NotchHostingView(rootView: RootView(geometry: geo)
                .environmentObject(AppState.shared))
            host.frame = CGRect(origin: .zero, size: frame.size)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            entries.append(Entry(panel: panel, geometry: geo))
        }
        if AppState.shared.isExpanded,
           !entries.contains(where: { AppState.shared.isExpanded(on: $0.geometry.screenFrame) }) {
            AppState.shared.expand(screenID: preferredScreenID)
        }
        if AppState.shared.keyboardMode { focusActivePanel() }
        Log.window.info("Чёлок создано: \(self.entries.count, privacy: .public)")
    }

    /// Окно всегда максимального размера: анимируется только содержимое,
    /// а прозрачные пиксели пропускают клики к приложениям под ними.
    private func windowFrame(for geo: NotchGeometry, on screen: NSScreen) -> CGRect {
        let width = max(Theme.panelWidth, geo.size.width) + 80
        let height = geo.size.height + Theme.panelHeight + 60
        let overshoot = geo.usesEdgeTrigger ? EdgeTrigger.overshoot : 0
        return CGRect(x: screen.frame.midX - width / 2,
                      y: screen.frame.maxY - height,
                      width: width,
                      height: height + overshoot)
    }

    /// В панели правят текст: поиск, заготовку или поле переводчика.
    /// Пока идёт ввод, уход курсора не должен захлопывать панель — иначе
    /// строка обрывается на полуслове, стоит потянуться за чашкой.
    var isEditingText: Bool {
        entries.contains { entry in
            guard entry.panel.isKeyWindow, let responder = entry.panel.firstResponder else { return false }
            if let text = responder as? NSTextView { return text.isFieldEditor || text.isEditable }
            return responder is NSTextField
        }
    }

    var preferredScreenID: String? {
        let point = NSEvent.mouseLocation
        return entries.first { $0.geometry.screenFrame.containsIncludingEdges(point) }
            .map { NSStringFromRect($0.geometry.screenFrame) }
            ?? entries.first.map { NSStringFromRect($0.geometry.screenFrame) }
    }

    func focusActivePanel() {
        DispatchQueue.main.async { [weak self] in
            guard let self, AppState.shared.keyboardMode else { return }
            self.entries.first { AppState.shared.isExpanded(on: $0.geometry.screenFrame) }?.panel.makeKey()
        }
    }

    /// Разрешить панели принимать клавиатурный ввод (только в раскрытом виде).
    func setKeyInputAllowed(_ allowed: Bool) {
        for e in entries { e.panel.acceptsKeyInput = allowed && AppState.shared.activeScreenID == NSStringFromRect(e.geometry.screenFrame) }
        if !allowed, let key = NSApp.keyWindow as? NotchPanel {
            key.orderFrontRegardless()
        }
    }

    // MARK: — отслеживание курсора

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.keyWindow is NotchPanel, event.modifierFlags.contains(.command),
                  let character = event.charactersIgnoringModifiers, let number = Int(character) else { return event }
            let tabs = AppState.shared.orderedTabs
            guard (1...tabs.count).contains(number) else { return event }
            AppState.shared.selectedTab = tabs[number - 1]
            return nil
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }) { moveMonitors.append(g) }

        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateHover() }
            return event
        }) { moveMonitors.append(l) }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if event.type == .leftMouseDown, self.openFromEdge(at: NSEvent.mouseLocation) { return }
                    guard AppState.shared.isExpanded else { return }
                    if self.hoverScreen(at: NSEvent.mouseLocation) == nil {
                        AppState.shared.collapse(immediate: true)
                    }
                }
            }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let opened = MainActor.assumeIsolated {
                self?.openFromEdge(at: NSEvent.mouseLocation) == true
            }
            // Поглощаем открывающий клик: он не должен попасть в уже раскрытое содержимое.
            return opened ? nil : event
        }

        // Страховка: курсор может оказаться в зоне без единого события —
        // после перехода между Spaces, из фуллскрина или при программном перемещении.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
    }

    @discardableResult
    private func openFromEdge(at point: CGPoint) -> Bool {
        let state = AppState.shared
        guard !state.isExpanded, let entry = entries.first(where: { entry in
            let geo = entry.geometry
            if geo.usesEdgeTrigger { return EdgeTrigger.contains(point, on: geo.screenFrame) }
            return geo.isRealNotch && state.isHidden(on: geo.screenFrame)
                && geo.hitsHiddenTrigger(at: point, hintVisible: state.edgeHintScreen == geo.screenFrame)
        }) else { return false }
        state.expand(screenID: NSStringFromRect(entry.geometry.screenFrame))
        updateHover()
        return true
    }

    /// Зона, в которой показывается язычок-подсказка.
    private static let hintHeight: CGFloat = 44
    private static let hintWidth: CGFloat = EdgeTrigger.width + 80

    /// Активная зона панели на экране в текущем состоянии.
    private func activeRect(for geo: NotchGeometry) -> CGRect {
        let state = AppState.shared
        let frame = geo.screenFrame
        if state.isExpanded {
            let w = Theme.panelWidth + 12
            let h = geo.size.height + Theme.panelHeight + 12
            return CGRect(x: frame.midX - w / 2, y: frame.maxY - h, width: w, height: h)
        }
        return CGRect(x: frame.midX - geo.size.width / 2,
                      y: frame.maxY - geo.size.height,
                      width: geo.size.width,
                      height: geo.size.height)
    }

    /// Зона подсказки: шире и выше полоски, чтобы язычок успел проявиться,
    /// пока курсор ещё только подъезжает к кромке.
    private func hintRect(for geo: NotchGeometry) -> CGRect {
        let frame = geo.screenFrame
        return CGRect(x: frame.midX - Self.hintWidth / 2,
                      y: frame.maxY - Self.hintHeight,
                      width: Self.hintWidth,
                      height: Self.hintHeight)
    }

    /// Подсказка нужна на экранах без выреза и при скрытии настоящей чёлки
    /// поверх полноэкранного приложения.
    private func updateEdgeHint(at point: CGPoint) {
        let state = AppState.shared
        guard !state.isExpanded else {
            state.setEdgeHint(on: nil)
            return
        }
        let near = entries.first { entry in
            let geo = entry.geometry
            if geo.isRealNotch && state.isHidden(on: geo.screenFrame) {
                return geo.showsCameraHint(at: point, wasVisible: state.edgeHintScreen == geo.screenFrame)
            }
            return (geo.usesEdgeTrigger || state.isHidden(on: geo.screenFrame))
                && hintRect(for: geo).containsIncludingEdges(point)
        }
        state.setEdgeHint(on: near?.geometry.screenFrame)
    }

    /// Экран, в чью активную зону попал курсор.
    private func hoverScreen(at point: CGPoint) -> CGRect? {
        let state = AppState.shared
        for entry in entries {
            let geo = entry.geometry
            if state.isExpanded && !state.isExpanded(on: geo.screenFrame) { continue }
            // На экране без выреза наведение лишь показывает индикатор.
            // Клик и drag & drop обрабатывает компактная вью у самой кромки.
            if geo.usesEdgeTrigger && !state.isExpanded { continue }
            if state.isHidden(on: geo.screenFrame) {
                if geo.hitsHiddenTrigger(at: point, hintVisible: state.edgeHintScreen == geo.screenFrame) {
                    return geo.screenFrame
                }
            } else if activeRect(for: geo).containsIncludingEdges(point) { return geo.screenFrame }
        }
        return nil
    }

    private func updateHover() {
        let point = NSEvent.mouseLocation
        updateEdgeHint(at: point)
        let frame = hoverScreen(at: point)

        if frame != nil, frame == lastInsideFrame {
            // Курсор всё в той же зоне: важно только, сдвинулся ли он заметно.
            // Порог отсекает дрожание руки, из-за которого раскрытие
            // откладывалось бы бесконечно.
            if let last = lastPoint, hypot(point.x - last.x, point.y - last.y) < 4 { return }
            lastPoint = point
            AppState.shared.hoverMoved()
            return
        }

        lastPoint = point
        guard frame != lastInsideFrame else { return }
        lastInsideFrame = frame
        // Уровень debug: в журнал попадает, только когда за ним следят
        // (`log stream --level debug`), в обычной работе не стоит ничего.
        Log.window.debug("зона \(frame == nil ? "покинута" : "занята", privacy: .public) в точке \(point.x, privacy: .public),\(point.y, privacy: .public)")
        if let frame {
            AppState.shared.hoverBegan(on: frame)
        } else {
            AppState.shared.hoverEnded()
        }
    }
}
