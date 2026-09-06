import CoreGraphics

/// Единая геометрия компактного триггера: UI и обработчик событий используют одну зону.
enum EdgeTrigger {
    static let width: CGFloat = 320
    static let height: CGFloat = 8
    // Верх окна чуть выше экрана: упёртый курсор оказывается внутри, а не на границе вью.
    static let overshoot: CGFloat = 2

    static func contains(_ point: CGPoint, on screen: CGRect) -> Bool {
        point.x >= screen.midX - width / 2 && point.x <= screen.midX + width / 2
            && point.y >= screen.maxY - height && point.y <= screen.maxY
    }
}
