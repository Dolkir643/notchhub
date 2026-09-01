import SwiftUI
import UniformTypeIdentifiers

/// Корневое вью окна-чёлки.
///
/// Состояния ровно два: свёрнутый островок и раскрытая панель. Промежуточной
/// карточки нет намеренно — раскрытие должно быть одним движением, а не двумя.
/// В свёрнутом виде на островке не рисуется ничего: ни бейджей, ни счётчиков.
struct RootView: View {
    let geometry: NotchGeometry
    @EnvironmentObject private var state: AppState

    private var notchHeight: CGFloat { geometry.size.height }
    private var open: Bool { state.isExpanded }

    /// Островок спрятан: под ним полноэкранное приложение на этом же экране.
    /// Проверяем именно свой экран — на втором мониторе островок остаётся.
    private var hidden: Bool {
        state.isHidden && state.fullScreen.covers(geometry.screenFrame)
    }

    private var contentWidth: CGFloat { open ? Theme.panelWidth : geometry.size.width }
    private var contentHeight: CGFloat { open ? notchHeight + Theme.panelHeight : notchHeight }

    /// Скругления одинаковые сверху и снизу — островок читается как цельная
    /// карточка. Там, где вырез настоящий, верх обязан вливаться в него
    /// обратными плечами, иначе вокруг камеры остаются светлые щели.
    private var shape: NotchShape {
        let corner = open ? Theme.panelCorner : Theme.islandCorner
        if geometry.isRealNotch {
            return NotchShape(topRadius: 8, bottomRadius: corner, flare: true)
        }
        return NotchShape(topRadius: corner, bottomRadius: corner, flare: false)
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
        // Обводка задана значением, а не замыканием: форма с @ViewBuilder пришла
        // только в macOS 12. Выравнивание по центру — то же, что подставляет
        // замыкающая форма по умолчанию, поэтому кромка островка не сдвигается.
        .overlay(
            shape
                .stroke(Color.white.opacity(open ? 0.10 : 0), lineWidth: 1)
                .allowsHitTesting(false),
            alignment: .center
        )
        .shadow(color: .black.opacity(open ? 0.45 : 0), radius: 18, y: 8)
        // Спрятанный островок именно гаснет, а не исчезает из иерархии:
        // подмена вью дала бы собственный переход поверх пружины раскрытия.
        // Клики он в этом виде не ловит — их принимает язычок.
        .opacity(hidden ? 0 : 1)
        .allowsHitTesting(!hidden)
        .animation(Theme.quick, value: hidden)
        .overlay(alignment: .top) { edgeHint }
        .contentShape(shape)
        // Клик раскрывает только свёрнутый островок: тап по пустому месту
        // раскрытой панели не должен её захлопывать — это делает клик ВНЕ панели.
        .onTapGesture { if !open { state.expand() } }
    }

    /// Язычок у верхней кромки: единственное, что остаётся от островка,
    /// пока приложение занимает весь экран. Появляется, когда курсор подходит
    /// близко, и отвечает на клик — иначе спрятанный хаб нечем было бы открыть,
    /// кроме горячей клавиши.
    @ViewBuilder private var edgeHint: some View {
        if hidden {
            Capsule()
                .fill(Color.white.opacity(state.showsEdgeHint ? 0.35 : 0))
                .frame(width: 64, height: 3)
                .padding(.top, 1)
                .contentShape(Rectangle().size(width: 120, height: 8))
                .onTapGesture { state.expand() }
                .animation(Theme.quick, value: state.showsEdgeHint)
        }
    }

    // MARK: — слои

    /// Свёрнутый островок — сплошной чёрный, чтобы слиться с вырезом и строкой меню.
    /// Раскрытая панель — размытие под полупрозрачным чёрным.
    ///
    /// Слои не подменяются, а перекрёстно гаснут: подмена вью дала бы второй,
    /// собственный переход поверх пружины размера — тот самый «в два этапа».
    private var background: some View {
        ZStack {
            VisualEffectView(material: .hudWindow)
                .opacity(open ? 1 : 0)
            Color.black.opacity(open ? 0.55 : 1)
        }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            // Зона физического выреза: тут ничего рисовать нельзя.
            Color.clear.frame(height: notchHeight)

            if open {
                ExpandedView()
                    .frame(height: Theme.panelHeight)
                    // Содержимое проявляется чуть позже кромки: пока панель
                    // ещё узкая, текст успел бы мелькнуть обрезанным.
                    .transition(.opacity.animation(.easeOut(duration: 0.16).delay(0.05)))
            }
        }
        .frame(width: contentWidth, height: contentHeight, alignment: .top)
        .clipped()
    }

    /// Невидимый ловец перетаскивания поверх выреза.
    ///
    /// Живёт и в раскрытом виде: файл тащат на чёлку, панель под курсором
    /// раскрывается сама — и если отпустить ровно над вырезом, ловить дроп
    /// больше некому (вкладка покрывает только область ниже). Полоса высотой
    /// в вырез ничего не перекрывает: содержимое панели начинается под ней.
    private var dropCatcher: some View {
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

    /// Короткое подтверждение — только внутри раскрытой панели.
    @ViewBuilder private var flash: some View {
        if let text = state.flashText, open {
            VStack {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").hubForeground(.green)
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
