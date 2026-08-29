import SwiftUI

/// Общие элементы управления плеером: транспорт и полоса прогресса.
/// Живут отдельно от вкладки, потому что нужны и компактным видам, и «Музыке».

struct TransportButton: View {
    let icon: String
    var size: CGFloat = 12
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .hubForeground(.white.opacity(hovering ? 1 : 0.8))
                .frame(width: size + 12, height: size + 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ProgressLine: View {
    /// 0…1
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white.opacity(0.85))
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
    }
}
