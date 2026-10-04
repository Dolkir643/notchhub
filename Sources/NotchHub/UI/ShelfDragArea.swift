import AppKit
import SwiftUI

struct ShelfDragFile {
    let url: URL
    let preview: NSImage?
}

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
    var onSelection: ((NSEvent.ModifierFlags, Bool) -> Void)? = nil
    var onDeleteSingle: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onPin: (() -> Void)? = nil
    var pinTitle: (() -> String)? = nil
    var files: (() -> [ShelfDragFile])? = nil
    var canDelete = true

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
        view.stopKeepingPanelOpenIfIdle()
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
        view.deleteCornerActive = deleteCornerActive && canDelete
        view.canDelete = canDelete
        view.onHover = onHover
        view.onClick = onClick
        view.onOpen = onOpen
        view.onReveal = onReveal
        view.onDelete = onDelete
        view.onSelection = onSelection
        view.onDeleteSingle = onDeleteSingle
        view.onCopy = onCopy
        view.onPin = onPin
        view.pinTitle = pinTitle
        view.files = files
    }
}

/// Источник перетаскивания. Всё мышиное внутри карточки проходит через него,
/// поэтому он же отвечает за наведение и за крестик в углу.
final class ShelfDragSourceView: NSView, NSDraggingSource, NSSharingServicePickerDelegate,
                                 NSSharingServiceDelegate, NSMenuDelegate {
    var url: URL?
    var preview: NSImage?
    var deleteCornerActive = false
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSelection: ((NSEvent.ModifierFlags, Bool) -> Void)?
    var onDeleteSingle: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPin: (() -> Void)?
    var pinTitle: (() -> String)?
    var files: (() -> [ShelfDragFile])?
    var canDelete = true

    private static let cornerSide: CGFloat = 24

    private var pressPoint: NSPoint?
    private var pressModifiers: NSEvent.ModifierFlags = []
    private var pressedDeleteCorner = false
    private var dragging = false
    private var tracking: NSTrackingArea?
    private var panelKeeper: Timer?
    /// Самоудержание на время сессии: SwiftUI вправе снести карточку прямо посреди
    /// перетаскивания, а AppKit шлёт `endedAt` источнику — по мёртвой ссылке это крэш.
    private var sessionHold: ShelfDragSourceView?
    private var sharingPicker: NSSharingServicePicker?
    private var sharingHold: ShelfDragSourceView?
    private var contextMenuOpen = false
    private var menuHold: ShelfDragSourceView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    deinit { panelKeeper?.invalidate() }

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
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        window?.makeKey()
        window?.makeFirstResponder(self)
        pressPoint = event.locationInWindow
        pressModifiers = event.modifierFlags
        dragging = false
        pressedDeleteCorner = deleteCornerActive && deleteCorner.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, !pressedDeleteCorner, let start = pressPoint, url != nil else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        select(modifiers: pressModifiers, preservingGroup: true)
        let payload = currentFiles.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !payload.isEmpty else { return }
        dragging = true
        onHover?(false)
        beginDrag(of: payload, with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressPoint = nil; pressedDeleteCorner = false }
        guard !dragging, pressPoint != nil else { return }
        if pressedDeleteCorner, deleteCorner.contains(convert(event.locationInWindow, from: nil)) {
            if let onDeleteSingle { onDeleteSingle() } else { onDelete?() }
        } else {
            select(modifiers: pressModifiers, preservingGroup: false)
            if event.clickCount >= 2 { onOpen?() }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard url != nil else { return nil }
        window?.makeKey()
        window?.makeFirstResponder(self)
        select(modifiers: [], preservingGroup: true)
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item(title: "Открыть", action: #selector(menuOpen)))
        menu.addItem(item(title: "Показать в Finder", action: #selector(menuReveal)))
        if onCopy != nil {
            menu.addItem(item(title: "Копировать", action: #selector(menuCopy)))
        }
        menu.addItem(item(title: "Поделиться…", action: #selector(menuShare)))
        if onPin != nil {
            menu.addItem(.separator())
            menu.addItem(item(title: pinTitle?() ?? "Закрепить", action: #selector(menuPin)))
        }
        if canDelete {
            menu.addItem(.separator())
            menu.addItem(item(title: "Убрать с полки", action: #selector(menuDelete)))
        }
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        contextMenuOpen = true
        menuHold = self
        keepPanelOpen()
    }

    func menuDidClose(_ menu: NSMenu) {
        contextMenuOpen = false
        stopKeepingPanelOpenIfIdle()
        collapseAfterInteractionIfNeeded()
        let hold = menuHold
        menuHold = nil
        RunLoop.main.perform(inModes: [.common]) { _ = hold }
    }

    private func item(title: String, action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func menuOpen() { onOpen?() }
    @objc private func menuReveal() { onReveal?() }
    @objc private func menuDelete() { onDelete?() }
    @objc private func menuCopy() { onCopy?() }
    @objc private func menuPin() { onPin?() }

    private func select(modifiers: NSEvent.ModifierFlags, preservingGroup: Bool) {
        if let onSelection { onSelection(modifiers, preservingGroup) } else { onClick?() }
    }

    private var currentFiles: [ShelfDragFile] {
        if let files { return files() }
        guard let url else { return [] }
        return [ShelfDragFile(url: url, preview: preview)]
    }

    /// Системный список сервисов привязан к реальной карточке AppKit.
    /// Держим источник живым, пока системный сервис не закончит читать файлы.
    @objc private func menuShare() {
        let urls = currentFiles.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        keepPanelOpen()
        sharingHold = self
        let picker = NSSharingServicePicker(items: urls)
        sharingPicker = picker
        picker.delegate = self
        picker.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        if service == nil { finishSharing() }
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        self
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finishSharing()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        AppState.shared.flash("Не удалось поделиться файлами")
        finishSharing()
    }

    private func finishSharing() {
        sharingPicker = nil
        let hold = sharingHold
        sharingHold = nil
        stopKeepingPanelOpenIfIdle()
        collapseAfterInteractionIfNeeded()
        RunLoop.main.perform(inModes: [.common]) { _ = hold }
    }

    private func collapseAfterInteractionIfNeeded() {
        // Действие меню может открыть Share Picker после menuDidClose:
        // проверяем занятость следующим тактом, когда действие уже выполнено.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.dragging, self.sharingHold == nil,
                      !self.contextMenuOpen else { return }
                if !self.pointerOverPanel() { AppState.shared.collapse() }
            }
        }
    }

    private var deleteCorner: NSRect {
        NSRect(x: bounds.maxX - Self.cornerSide, y: 0, width: Self.cornerSide, height: Self.cornerSide)
    }

    // MARK: — перетаскивание наружу

    private func beginDrag(of files: [ShelfDragFile], with event: NSEvent) {
        // Один writer на файл: Finder и формы загрузки получают всю группу,
        // а не несколько ссылок, склеенных в один элемент буфера обмена.
        let dragItems = files.enumerated().map { index, file in
            let dragItem = NSDraggingItem(pasteboardWriter: file.url as NSURL)
            let image = file.preview ?? Self.fileIcon(for: file.url)
            let offset = CGFloat(min(index, 4)) * 3
            dragItem.setDraggingFrame(fitted(image).offsetBy(dx: offset, dy: offset), contents: image)
            return dragItem
        }

        // Держим панель раскрытой ДО старта сессии: курсор уходит из чёлки в первые
        // же миллисекунды, а схлопывание там заряжено на 100 мс — на `willBeginAt`
        // с таймером в 0,1 с это была гонка, и панель успевала унести источник.
        keepPanelOpen()
        sessionHold = self

        let session = beginDraggingSession(with: dragItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
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

    func stopKeepingPanelOpenIfIdle() {
        if !dragging, sharingHold == nil, !contextMenuOpen { stopKeepingPanelOpen() }
    }
}
