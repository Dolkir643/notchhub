import SwiftUI

/// Форма чёлки: сверху прямые углы (уходят под рамку экрана),
/// снизу — скруглённые, плюс «обратные» скругления на верхних плечах,
/// чтобы форма плавно вливалась в чёрную рамку.
///
/// Радиусы анимируются через `animatableData`, поэтому морф компакт → панель
/// проходит без рывка на углах.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    init(topRadius: CGFloat = 8, bottomRadius: CGFloat = 14) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let top = max(0, min(topRadius, rect.height / 2))
        let bottom = max(0, min(bottomRadius, min(rect.height / 2, rect.width / 2)))

        p.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Верхний левый «обратный» уголок.
        p.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                       control: CGPoint(x: rect.minX + top * 0.55, y: rect.minY))

        // Левая стенка вниз.
        p.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))

        // Нижний левый скруглённый угол.
        p.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                       control: CGPoint(x: rect.minX + top, y: rect.maxY))

        // Низ.
        p.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))

        // Нижний правый скруглённый угол.
        p.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                       control: CGPoint(x: rect.maxX - top, y: rect.maxY))

        // Правая стенка вверх.
        p.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))

        // Верхний правый «обратный» уголок.
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - top * 0.55, y: rect.minY))

        p.closeSubpath()
        return p
    }
}
