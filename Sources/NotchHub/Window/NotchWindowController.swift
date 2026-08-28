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
    private var pollTimer: Timer?
    private var lastInsideKey: String?
    private var rebuildTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: — жизненный цикл

    func start() {
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
            let host = NotchHostingView(rootView: RootView(geometry: geo)
                .environmentObject(AppState.shared))
            host.frame = CGRect(origin: .zero, size: frame.size)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            entries.append(Entry(panel: panel, geometry: geo))
        }
        Log.window.info("Чёлок создано: \(self.entries.count, privacy: .public)")
    }

    /// Окно всегда максимального размера: анимируется только содержимое,
    /// а прозрачные пиксели пропускают клики к приложениям под ними.
    private func windowFrame(for geo: NotchGeometry, on screen: NSScreen) -> CGRect {
        let width = max(Theme.panelWidth, geo.size.width) + 80
        let height = geo.size.height + Theme.panelHeight + 60
        return CGRect(x: screen.frame.midX - width / 2,
                      y: screen.frame.maxY - height,
                      width: width,
                      height: height)
    }

    /// Разрешить панели принимать клавиатурный ввод (только в раскрытом виде).
    func setKeyInputAllowed(_ allowed: Bool) {
        for e in entries { e.panel.acceptsKeyInput = allowed }
        if !allowed, let key = NSApp.keyWindow as? NotchPanel {
            key.orderFrontRegardless()
        }
    }

    // MARK: — отслеживание курсора

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }) { moveMonitors.append(g) }

        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateHover() }
            return event
        }) { moveMonitors.append(l) }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AppState.shared.isExpanded else { return }
                    if self.zoneKey(for: NSEvent.mouseLocation) == nil {
                        AppState.shared.collapse(immediate: true)
                    }
                }
            }

        // Страховка: курсор может оказаться в зоне без единого события —
        // после перехода между Spaces, из фуллскрина или при программном перемещении.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
    }

    /// Активная зона панели на экране в текущем состоянии.
    private func activeRect(for geo: NotchGeometry) -> CGRect {
        let state = AppState.shared
        let frame = geo.screenFrame
        if state.isExpanded {
            let w = Theme.panelWidth + 12
            let h = geo.size.height + Theme.panelHeight + 12
            return CGRect(x: frame.midX - w / 2, y: frame.maxY - h, width: w, height: h)
        }
        if state.isHovering {
            let w = max(geo.size.width, Theme.compactWidth) + 12
            let h = geo.size.height + Theme.compactHeight + 10
            return CGRect(x: frame.midX - w / 2, y: frame.maxY - h, width: w, height: h)
        }
        return CGRect(x: frame.midX - geo.size.width / 2,
                      y: frame.maxY - geo.size.height,
                      width: geo.size.width,
                      height: geo.size.height)
    }

    /// Ключ экрана, в чью активную зону попал курсор, либо nil.
    private func zoneKey(for point: CGPoint) -> String? {
        for e in entries where activeRect(for: e.geometry).contains(point) {
            return NSStringFromRect(e.geometry.screenFrame)
        }
        return nil
    }

    private func updateHover() {
        let key = zoneKey(for: NSEvent.mouseLocation)
        guard key != lastInsideKey else { return }
        lastInsideKey = key
        if key != nil {
            AppState.shared.hoverBegan()
        } else {
            AppState.shared.hoverEnded()
        }
    }
}
