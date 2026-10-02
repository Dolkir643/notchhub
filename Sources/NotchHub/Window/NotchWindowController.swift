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
    private var lastInsideKey: String?
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
        return entries.first { contains($0.geometry.screenFrame, point) }
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
                    if self.zoneKey(for: NSEvent.mouseLocation) == nil {
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
        guard !AppState.shared.isExpanded,
              entries.contains(where: { $0.geometry.usesEdgeTrigger
                  && EdgeTrigger.contains(point, on: $0.geometry.screenFrame) }) else { return false }
        AppState.shared.expand()
        updateHover()
        return true
    }

    /// Ширина и высота полоски-триггера, заменяющей спрятанный островок.
    /// Полоска низкая намеренно: у самой кромки курсор оказывается и по делу,
    /// и проездом, а четыре точки ловят только упёртый в верх экрана курсор.
    private static let stripHeight: CGFloat = 4
    private static let stripWidth: CGFloat = 200
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
        if state.isHidden, FullScreenWatcher.shared.covers(frame) {
            return CGRect(x: frame.midX - Self.stripWidth / 2,
                          y: frame.maxY - Self.stripHeight,
                          width: Self.stripWidth,
                          height: Self.stripHeight)
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

    /// Попадание курсора в зону — с включённой верхней кромкой.
    ///
    /// Курсор, упёртый в самый верх экрана, имеет y ровно `screen.frame.maxY`,
    /// а `CGRect.contains` верхнюю кромку своей не считает. Из-за этого островок
    /// не раскрывался, пока мышь не опустят на точку ниже — то есть ровно в том
    /// положении, куда курсор приходит естественнее всего.
    private func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY
    }

    /// Подсказка нужна на экранах без выреза и при скрытии настоящей чёлки
    /// поверх полноэкранного приложения.
    private func updateEdgeHint(at point: CGPoint) {
        let state = AppState.shared
        guard !state.isExpanded else {
            state.setEdgeHint(false)
            return
        }
        let near = entries.contains { entry in
            let needsHint = entry.geometry.usesEdgeTrigger
                || (state.isHidden && FullScreenWatcher.shared.covers(entry.geometry.screenFrame))
            return needsHint && contains(hintRect(for: entry.geometry), point)
        }
        state.setEdgeHint(near)
    }

    /// Ключ экрана, в чью активную зону попал курсор, либо nil.
    private func zoneKey(for point: CGPoint) -> String? {
        for e in entries where contains(activeRect(for: e.geometry), point) {
            if AppState.shared.isExpanded && !AppState.shared.isExpanded(on: e.geometry.screenFrame) { continue }
            // На экране без выреза наведение лишь показывает индикатор.
            // Клик и drag & drop обрабатывает компактная вью у самой кромки.
            if e.geometry.usesEdgeTrigger && !AppState.shared.isExpanded { continue }
            return NSStringFromRect(e.geometry.screenFrame)
        }
        return nil
    }

    private func updateHover() {
        let point = NSEvent.mouseLocation
        updateEdgeHint(at: point)
        let key = zoneKey(for: point)

        if key != nil, key == lastInsideKey {
            // Курсор всё в той же зоне: важно только, сдвинулся ли он заметно.
            // Порог отсекает дрожание руки, из-за которого раскрытие
            // откладывалось бы бесконечно.
            if let last = lastPoint, hypot(point.x - last.x, point.y - last.y) < 4 { return }
            lastPoint = point
            AppState.shared.hoverMoved()
            return
        }

        lastPoint = point
        guard key != lastInsideKey else { return }
        lastInsideKey = key
        // Уровень debug: в журнал попадает, только когда за ним следят
        // (`log stream --level debug`), в обычной работе не стоит ничего.
        Log.window.debug("зона \(key == nil ? "покинута" : "занята", privacy: .public) в точке \(point.x, privacy: .public),\(point.y, privacy: .public)")
        if key != nil {
            AppState.shared.hoverBegan()
        } else {
            AppState.shared.hoverEnded()
        }
    }
}
