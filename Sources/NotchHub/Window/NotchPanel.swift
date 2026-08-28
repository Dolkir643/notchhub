import AppKit
import SwiftUI

/// Окно-чёлка. Плавает над строкой меню и фуллскрин-приложениями,
/// не активирует приложение и по умолчанию не забирает фокус клавиатуры.
final class NotchPanel: NSPanel {

    /// Разрешить окну становиться key. Включается только когда панель раскрыта,
    /// иначе текстовые поля (поиск, переводчик) не смогут принимать ввод.
    var acceptsKeyInput: Bool = false {
        didSet {
            guard acceptsKeyInput != oldValue else { return }
            if !acceptsKeyInput, isKeyWindow { resignKeyGracefully() }
        }
    }

    override var canBecomeKey: Bool { acceptsKeyInput }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { acceptsKeyInput }

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        worksWhenModal = true

        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)

        // Тени и подсветки AppKit нам не нужны — всё рисует SwiftUI.
        appearance = NSAppearance(named: .darkAqua)
    }

    /// Esc закрывает раскрытую панель, не пробрасывая событие дальше.
    override func cancelOperation(_ sender: Any?) {
        AppState.shared.collapse(immediate: true)
    }

    private func resignKeyGracefully() {
        // Возвращаем фокус тому, кто был активен: просто отпускаем key-статус.
        orderFrontRegardless()
        NSApp.deactivate()
    }
}

/// Хост-вью, который не даёт AppKit «съедать» первый клик и не активирует приложение.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
