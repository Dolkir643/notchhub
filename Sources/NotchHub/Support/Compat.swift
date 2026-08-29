import SwiftUI

/// Обёртки над модификаторами, которых нет в macOS 11.
///
/// Приложение поддерживает Big Sur, а половина привычных модификаторов SwiftUI
/// появилась в 12–13. Писать `if #available` в каждом месте — значит утопить
/// вёрстку в лесах, поэтому развилки собраны здесь. Заодно снимается вторая
/// беда: старые варианты (`foregroundColor`, `accentColor`) в свежих системах
/// помечены устаревшими и сыпали бы предупреждениями.
extension View {

    /// Цвет текста и символов. `foregroundStyle` — с macOS 12.
    @ViewBuilder func hubForeground(_ color: Color) -> some View {
        if #available(macOS 12.0, *) {
            foregroundStyle(color)
        } else {
            foregroundColor(color)
        }
    }

    /// Акцент элемента управления. `tint` — с macOS 13.
    @ViewBuilder func hubTint(_ color: Color) -> some View {
        if #available(macOS 13.0, *) {
            tint(color)
        } else {
            accentColor(color)
        }
    }

    /// Спрятать полосы прокрутки. `scrollIndicators` — с macOS 13,
    /// на Big Sur остаются системные.
    @ViewBuilder func hubHideScrollIndicators() -> some View {
        if #available(macOS 13.0, *) {
            scrollIndicators(.never)
        } else {
            self
        }
    }

    /// Убрать подложку прокрутки. `scrollContentBackground` — с macOS 13.
    @ViewBuilder func hubClearScrollBackground() -> some View {
        if #available(macOS 13.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    /// Монохромная отрисовка символа. `symbolRenderingMode` — с macOS 12.
    @ViewBuilder func hubMonochromeSymbol() -> some View {
        if #available(macOS 12.0, *) {
            symbolRenderingMode(.monochrome)
        } else {
            self
        }
    }

    /// Разрешить выделение текста мышью. `textSelection` — с macOS 12.
    @ViewBuilder func hubSelectableText() -> some View {
        if #available(macOS 12.0, *) {
            textSelection(.enabled)
        } else {
            self
        }
    }

    /// Наложение с выравниванием: форма с замыканием пришла в macOS 12,
    /// а вариант со значением есть с самого начала.
    func hubOverlay<Overlay: View>(alignment: Alignment,
                                   @ViewBuilder _ content: () -> Overlay) -> some View {
        overlay(content(), alignment: alignment)
    }
}
