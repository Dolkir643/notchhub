import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Выделение живёт объектом: на него ссылается монитор клавиатуры,
/// который переживает перерисовку вкладки. Монитор хранится здесь же —
/// `onDisappear` приходит не всегда (панели пересоздаются при смене конфигурации
/// дисплеев), а брошенный локальный монитор молча глотал бы ⌫ у всего приложения.
@MainActor final class ShelfSelection: ObservableObject {
    @Published var id: UUID?

    private var monitor: Any?

    func keepMonitor(_ make: () -> Any?) {
        guard monitor == nil else { return }
        monitor = make()
    }

    func dropMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// Вкладка «Полка»: карточки файлов, приём drag&drop, вытаскивание наружу.
struct ShelfTab: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var selection = ShelfSelection()
    @State private var targeted = false

    private var shelf: ShelfService { state.shelf }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TabHeader(title: "Полка") {
                if !shelf.isEmpty {
                    Text("\(shelf.items.count) · \(Fmt.size(shelf.totalSize))")
                        .font(.system(size: 11))
                        .hubForeground(Theme.secondaryText)
                    Button {
                        shelf.clearAll()
                        selection.id = nil
                    } label: {
                        Text("Очистить")
                            .font(.system(size: 11, weight: .medium))
                            .hubForeground(.white.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .help("Убрать все файлы в Корзину")
                }
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .item], isTargeted: $targeted) { providers in
            shelf.handleDrop(providers)
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: — содержимое

    @ViewBuilder private var content: some View {
        ZStack {
            if shelf.isEmpty {
                EmptyHint(icon: "tray.and.arrow.down",
                          text: targeted
                          ? "Отпускайте — заберу"
                          : "Бросьте файлы сюда.\nСкриншоты попадают сами")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(shelf.items) { item in
                            ShelfCard(item: item,
                                      image: shelf.thumbnails[item.id],
                                      selected: selection.id == item.id,
                                      onSelect: { selection.id = item.id },
                                      onOpen: { shelf.open(item) },
                                      onReveal: { shelf.reveal(item) },
                                      onDelete: { delete(item) })
                                .onAppear { shelf.requestThumbnail(item) }
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(targeted ? Theme.accent : .clear,
                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .animation(Theme.quick, value: targeted)
        )
    }

    // MARK: — действия

    private func delete(_ item: ShelfItem) {
        if selection.id == item.id { selection.id = nil }
        withAnimation(Theme.quick) { shelf.remove(item) }
        Haptics.tap()
    }

    /// ⌫ убирает выделенный файл, ⏎ открывает. Панель ключевая только в раскрытом
    /// виде, поэтому монитор локальный и живёт ровно столько, сколько вкладка.
    private func installKeyMonitor() {
        let shelf = state.shelf
        let selection = self.selection
        selection.keepMonitor {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let code = event.keyCode
                var swallowed = false
                // Событие наружу из assumeIsolated не выносим: NSEvent несендабельный.
                MainActor.assumeIsolated {
                    guard let id = selection.id,
                          let item = shelf.items.first(where: { $0.id == id }) else { return }
                    switch code {
                    case 51, 117:   // ⌫ и ⌦
                        selection.id = nil
                        withAnimation(Theme.quick) { shelf.remove(item) }
                        Haptics.tap()
                        swallowed = true
                    case 36, 76:    // ⏎ на основной клавиатуре и на цифровой
                        shelf.open(item)
                        swallowed = true
                    default:
                        break
                    }
                }
                return swallowed ? nil : event
            }
        }
    }

    private func removeKeyMonitor() {
        selection.dropMonitor()
    }
}

/// Карточка файла. Всё мышиное отдано AppKit-слою `ShelfDragArea`:
/// иначе перетаскивание наружу и клики спорят за одни и те же события.
private struct ShelfCard: View {
    let item: ShelfItem
    let image: NSImage?
    let selected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private static let width: CGFloat = 104
    private static let previewHeight: CGFloat = 84

    var body: some View {
        VStack(spacing: 0) {
            preview
            footer
        }
        .frame(width: Self.width)
        .hubCard(12)
        // Наложения заданы значением, а не замыканием: форма с @ViewBuilder
        // появилась только в macOS 12, а эта есть с самого SwiftUI.
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.accent : (hovering ? Color.white.opacity(0.22) : .clear),
                              lineWidth: selected ? 1.5 : 1)
        )
        .overlay(
            ShelfDragArea(url: item.url,
                          preview: image,
                          deleteCornerActive: hovering || selected,
                          onHover: { hovering = $0 },
                          onClick: onSelect,
                          onOpen: onOpen,
                          onReveal: onReveal,
                          onDelete: onDelete)
        )
        .overlay(deleteBadge, alignment: .topTrailing)
        .animation(Theme.quick, value: hovering)
        .animation(Theme.quick, value: selected)
    }

    private var preview: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 20, weight: .light))
                    .hubForeground(.white.opacity(0.35))
            }
        }
        .frame(width: Self.width - 8, height: Self.previewHeight)
        .padding(.top, 4)
        .clipped()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .hubForeground(.white.opacity(0.9))
            HStack(spacing: 3) {
                if item.isScreenshot {
                    Image(systemName: "camera.viewfinder").font(.system(size: 8, weight: .semibold))
                }
                Text("\(Fmt.size(item.size)) · \(Fmt.relative(item.added))")
                    .font(.system(size: 9))
                    .lineLimit(1)
            }
            .hubForeground(Theme.secondaryText)
        }
        .frame(width: Self.width - 12, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var deleteBadge: some View {
        if hovering || selected {
            if #available(macOS 12.0, *) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .font(.system(size: 13, weight: .semibold))
                    // Двухцветный `foregroundStyle` — родная пара к .palette;
                    // обёртка hubForeground принимает ровно один Color и сюда не годится.
                    .foregroundStyle(Color.white.opacity(0.95), Color.black.opacity(0.6))
                    .padding(5)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            } else {
                // На Big Sur палитры нет, символ красится целиком. Но `xmark.circle.fill`
                // рисует диск с ВЫРЕЗАННЫМ крестиком, поэтому светлая подложка под тёмным
                // диском возвращает белый крест.
                // Подложка — именно `circle.fill`, а не `Circle()`: у геометрической фигуры
                // диаметр равен стороне бокса символа (замер на 13 pt: бокс 16 pt, диск 13,25 pt),
                // и она вылезала бы из-под диска светлым ободком. У соседа по семейству
                // `*.circle.fill` диск в точности тот же, поэтому кайма не появляется
                // ни при каком кегле и ни при какой версии SF Symbols.
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .hubForeground(Color.black.opacity(0.6))
                    .background(
                        // Кегль задаём заново: содержимое `.background` — сосед, а не потомок
                        // модификатора `.font`, и шрифт из строки выше до него не доходит.
                        Image(systemName: "circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .hubForeground(Color.white.opacity(0.95))
                    )
                    .padding(5)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }
}
