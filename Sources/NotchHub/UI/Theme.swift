import SwiftUI

enum Theme {
    static let panelWidth: CGFloat = 640
    static let panelHeight: CGFloat = 232
    static let panelCorner: CGFloat = 22

    static let compactWidth: CGFloat = 300
    static let compactHeight: CGFloat = 52

    static let sidebarWidth: CGFloat = 52

    static let openSpring: Animation = .spring(response: 0.42, dampingFraction: 0.8)
    static let closeSpring: Animation = .spring(response: 0.45, dampingFraction: 1.0)
    static let quick: Animation = .spring(response: 0.28, dampingFraction: 0.9)

    static let accent = Color(red: 0.40, green: 0.72, blue: 1.0)
    static let panelFill = Color.black.opacity(0.86)
    static let cardFill = Color.white.opacity(0.08)
    static let cardStroke = Color.white.opacity(0.10)
    static let secondaryText = Color.white.opacity(0.55)
}

extension View {
    /// Карточка внутри панели.
    func hubCard(_ corner: CGFloat = 12) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
}

/// Заголовок вкладки + опциональное действие справа.
struct TabHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: 20)
    }
}

extension TabHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title, trailing: { EmptyView() })
    }
}

/// Пустое состояние вкладки.
struct EmptyHint: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text(text)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
