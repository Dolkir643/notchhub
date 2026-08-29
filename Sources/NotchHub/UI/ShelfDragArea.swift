import AppKit
import SwiftUI

/// Прозрачный слой поверх карточки полки: наведение, клики и — главное —
/// вытаскивание файла наружу. SwiftUI `.draggable` для файлов на macOS
/// срабатывает через раз, поэтому всё держим на AppKit.
struct ShelfDragArea: NSViewRepresentable {
    let url: URL
    let preview: NSImage?
    /// Показан ли крестик удаления: только тогда угол карточки работает на удаление.
    let deleteCornerActive: Bool
    let onHover: (Bool) -> Void
    let onClick: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    func makeNSView(context: Context) -> ShelfDragSourceView {
        let view = ShelfDragSourceView()
        if #available(macOS 13.0, *) {
            // Размер приходит из sizeThatFits ниже — автолэйаут в него не вмешивается.
        } else {
            view.prepareLegacySizing()
        }
        apply(to: view)
        return view
    }

    func updateNSView(_ view: ShelfDragSourceView, context: Context) {
        apply(to: view)
    }

    static func dismantleNSView(_ view: ShelfDragSourceView, coordinator: Void) {
        view.stopKeepingPanelOpen()
    }

    /// Своего размера у слоя нет — он обязан занять всю карточку,
    /// иначе SwiftUI схлопнет его в ноль и мышь до него не дойдёт.
    /// Сам крючок вместе с `ProposedViewSize` появился только в macOS 13;
    /// до неё размер выпрашивается через приоритеты автолэйаута (`prepareLegacySizing`).
    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShelfDragSourceView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    private func apply(to view: ShelfDragSourceView) {
        view.url = url
        view.preview = preview
        view.deleteCornerActive = deleteCornerActive
        view.onHover = onHover
        view.onClick = onClick
        view.onOpen = onOpen
        view.onReveal = onReveal
        view.onDelete = onDelete
    }
}

/// Источник перетаскивания. Всё мышиное внутри карточки проходит через него,
/// поэтому он же отвечает за наведение и за крестик в углу.
final class ShelfDragSourceView: NSView, NSDraggingSource {
    var url: URL?
    var preview: NSImage?
    var deleteCornerActive = false
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onDelete: (() -> Void)?

    private static let cornerSide: CGFloat = 24

    private var pressPoint: NSPoint?
    private var pressedDeleteCorner = false
    private var dragging = false
    private var tracking: NSTrackingArea?
    private var panelKeeper: Timer?
    /// Самоудержание на время сессии: SwiftUI вправе снести карточку прямо посреди
    /// перетаскивания, а AppKit шлёт `endedAt` источнику — по мёртвой ссылке это крэш.
    private var sessionHold: ShelfDragSourceView?

    override var isFlipped: Bool { true }

    /// Страховка для macOS 11–12, где у `NSViewRepresentable` ещё нет `sizeThatFits`
    /// и размер выводится из intrinsicContentSize с приоритетами автолэйаута.
    /// Ставка низкая: у голого NSView intrinsicContentSize уже (-1, -1), hugging уже 250,
    /// так что реально снижается только сопротивление сжатию. Замер запасного пути
    /// (`sizeThatFits` → nil) показал, что слой и без этого получает всю карточку,
    /// но проверить настоящую ветку до macOS 13 не на чем, а цена страховки нулевая:
    /// если слой схлопнется в ноль, мышь пойдёт мимо и пропадут и клики, и перетаскивание.
    func prepareLegacySizing() {
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.defaultLow, for: axis)
            setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
    }

    /// Панель не активна: без этого первый клик уходит на активацию приложения.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: — наведение

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    // MARK: — клики

    override func mouseDown(with event: NSEvent) {
        pressPoint = event.locationInWindow
        dragging = false
        pressedDeleteCorner = deleteCornerActive && deleteCorner.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, !pressedDeleteCorner, let start = pressPoint, let url else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        dragging = true
        onHover?(false)
        beginDrag(of: url, with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressPoint = nil; pressedDeleteCorner = false }
        guard !dragging else { return }
        if pressedDeleteCorner, deleteCorner.contains(convert(event.locationInWindow, from: nil)) {
            onDelete?()
        } else if event.clickCount >= 2 {
            onOpen?()
        } else {
            onClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard url != nil else { return nil }
        onClick?()
        let menu = NSMenu()
        menu.addItem(item(title: "Открыть", action: #selector(menuOpen)))
        menu.addItem(item(title: "Показать в Finder", action: #selector(menuReveal)))
        menu.addItem(.separator())
        menu.addItem(item(title: "Убрать с полки", action: #selector(menuDelete)))
        return menu
    }

    private func item(title: String, action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func menuOpen() { onOpen?() }
    @objc private func menuReveal() { onReveal?() }
    @objc private func menuDelete() { onDelete?() }

    private var deleteCorner: NSRect {
        NSRect(x: bounds.maxX - Self.cornerSide, y: 0, width: Self.cornerSide, height: Self.cornerSide)
    }

    // MARK: — перетаскивание наружу

    private func beginDrag(of url: URL, with event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(url.absoluteString, forType: .fileURL)

        let dragItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        // Без картинки за курсором тащится пустота.
        let image = preview ?? Self.fileIcon(for: url)
        dragItem.setDraggingFrame(fitted(image), contents: image)

        // Держим панель раскрытой ДО старта сессии: курсор уходит из чёлки в первые
        // же миллисекунды, а схлопывание там заряжено на 100 мс — на `willBeginAt`
        // с таймером в 0,1 с это была гонка, и панель успевала унести источник.
        keepPanelOpen()
        sessionHold = self

        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    private static func fileIcon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }

    private func fitted(_ image: NSImage) -> NSRect {
        let box = bounds.insetBy(dx: 2, dy: 2)
        guard image.size.width > 0, image.size.height > 0, box.width > 0, box.height > 0 else { return bounds }
        let scale = min(box.width / image.size.width, box.height / image.size.height, 1)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// Пока тащим — не даём панели схлопнуться вместе с источником. Режим .common:
    /// во время перетаскивания главный runloop крутится в .eventTracking, и обычный
    /// таймер молчит. Шаг 0,05 с — вдвое короче отложенного схлопывания.
    private func keepPanelOpen() {
        panelKeeper?.invalidate()
        AppState.shared.expand()
        let keeper = Timer(timeInterval: 0.05, repeats: true) { _ in
            // Вкладку не переставляем: `expand(to:)` каждый тик перепубликовывал бы
            // selectedTab и заставлял всю панель перерисовываться во время drag'а.
            MainActor.assumeIsolated { AppState.shared.expand() }
        }
        RunLoop.main.add(keeper, forMode: .common)
        panelKeeper = keeper
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        stopKeepingPanelOpen()
        dragging = false
        pressPoint = nil
        pressedDeleteCorner = false
        onHover?(false)
        // Курсор остался вне нарисованной панели — она больше не нужна. Проверяем
        // именно попадание в контент: окно намеренно шире панели и по краям прозрачно,
        // а сторож наведения после ухода курсора второй раз уже не сработает.
        if !pointerOverPanel() { AppState.shared.collapse() }

        // Отпускаем себя следующим тактом: последняя ссылка не должна умирать
        // прямо внутри собственного метода.
        let hold = sessionHold
        sessionHold = nil
        RunLoop.main.perform(inModes: [.common]) { _ = hold }
    }

    private func pointerOverPanel() -> Bool {
        guard let window, let content = window.contentView else { return false }
        return content.hitTest(window.convertPoint(fromScreen: NSEvent.mouseLocation)) != nil
    }

    func stopKeepingPanelOpen() {
        panelKeeper?.invalidate()
        panelKeeper = nil
    }
}
