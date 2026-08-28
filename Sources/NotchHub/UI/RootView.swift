import SwiftUI
import UniformTypeIdentifiers

/// Корневое вью окна-чёлки. Рисует форму, морфит её между тремя состояниями
/// и держит содержимое: компактную карточку трека или полную панель.
struct RootView: View {
    let geometry: NotchGeometry
    @EnvironmentObject private var state: AppState

    private var notchHeight: CGFloat { geometry.size.height }

    private var contentWidth: CGFloat {
        if state.isExpanded { return Theme.panelWidth }
        if state.isHovering { return max(geometry.size.width, Theme.compactWidth) }
        return geometry.size.width
    }

    private var contentHeight: CGFloat {
        if state.isExpanded { return notchHeight + Theme.panelHeight }
        if state.isHovering { return notchHeight + Theme.compactHeight }
        return notchHeight
    }

    private var bottomRadius: CGFloat {
        state.isExpanded ? Theme.panelCorner : (state.isHovering ? 18 : 12)
    }

    private var topRadius: CGFloat {
        geometry.isRealNotch ? 8 : (state.isHovering || state.isExpanded ? 8 : 0)
    }

    private var shape: NotchShape {
        NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
    }

    var body: some View {
        VStack(spacing: 0) {
            notch
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    private var notch: some View {
        ZStack(alignment: .top) {
            background
            content
            dropCatcher
            flash
        }
        .frame(width: contentWidth, height: contentHeight)
        .clipShape(shape)
        .overlay {
            shape
                .stroke(Color.white.opacity(state.isExpanded ? 0.10 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(state.isExpanded ? 0.45 : 0), radius: 18, y: 8)
        .contentShape(shape)
        .onTapGesture { state.toggleExpanded() }
    }

    // MARK: — слои

    private var background: some View {
        ZStack {
            if state.isHovering || state.isExpanded {
                VisualEffectView(material: .hudWindow)
                Color.black.opacity(0.55)
            } else {
                // В свёрнутом виде — чистый чёрный, чтобы слиться с вырезом/строкой меню.
                Color.black
            }
        }
        .animation(Theme.quick, value: state.isHovering)
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            // Зона физического выреза: тут ничего рисовать нельзя.
            Color.clear.frame(height: notchHeight)

            if state.isExpanded {
                ExpandedView()
                    .frame(height: Theme.panelHeight)
                    .transition(.opacity)
            } else if state.isHovering {
                CompactView()
                    .frame(height: Theme.compactHeight)
                    .transition(.opacity)
            }
        }
        .frame(width: contentWidth, height: contentHeight, alignment: .top)
        .clipped()
    }

    /// Невидимый ловец перетаскивания поверх свёрнутой чёлки.
    @ViewBuilder private var dropCatcher: some View {
        if !state.isExpanded {
            Color.black.opacity(0.001)
                .frame(width: contentWidth, height: max(notchHeight, 22))
                .onDrop(of: [.fileURL, .item], isTargeted: Binding(
                    get: { state.isDropTargeted },
                    set: { targeted in
                        if targeted { state.dropEntered() } else { state.dropExited() }
                    })) { providers in
                        state.shelf.handleDrop(providers)
                    }
        }
    }

    @ViewBuilder private var flash: some View {
        if let text = state.flashText, state.isHovering || state.isExpanded {
            VStack {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(text).font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.75)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                .padding(.bottom, 8)
            }
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
}
