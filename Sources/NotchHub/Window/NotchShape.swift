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

    /// Верх «вливается» в физический вырез обратными плечами.
    ///
    /// Нужно только там, где вырез действительно есть. На экране без него
    /// островок просто висит на кромке, и обратные плечи выглядят чужеродно:
    /// снизу скругления, сверху — вывернутые уголки. Тогда рисуем обычную
    /// скруглённую карточку с одинаковыми углами.
    var flare: Bool

    init(topRadius: CGFloat = 8, bottomRadius: CGFloat = 14, flare: Bool = true) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
        self.flare = flare
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        flare ? flaredPath(in: rect) : cardPath(in: rect)
    }

    /// Обычная карточка: сверху и снизу одинаковые скругления.
    private func cardPath(in rect: CGRect) -> Path {
        let limit = min(rect.width / 2, rect.height / 2)
        let top = max(0, min(topRadius, limit))
        let bottom = max(0, min(bottomRadius, limit))

        // Углы одинаковые — берём системную «непрерывную» кривую: на радиусе
        // в двадцать с лишним точек она заметно мягче квадратичной и совпадает
        // с тем, как macOS скругляет окна и подложки вкладок.
        if abs(top - bottom) < 0.01 {
            return Path(roundedRect: rect, cornerRadius: top, style: .continuous)
        }

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + top))
        p.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + top),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - bottom),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }

    private func flaredPath(in rect: CGRect) -> Path {
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
