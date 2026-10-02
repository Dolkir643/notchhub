import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Выделение живёт объектом: на него ссылается монитор клавиатуры,
/// который переживает перерисовку вкладки. Монитор хранится здесь же —
/// `onDisappear` приходит не всегда (панели пересоздаются при смене конфигурации
/// дисплеев), а брошенный локальный монитор молча глотал бы ⌫ у всего приложения.
@MainActor final class ShelfSelection: ObservableObject {
    @Published var id: UUID?
    @Published var ids = Set<UUID>()

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
    @State private var query = ""
    private var shown: [ShelfItem] {
        shelf.items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.isPinned && !$1.isPinned }
    }
    private var selected: [ShelfItem] { shown.filter { selection.ids.contains($0.id) } }

    private func select(_ item: ShelfItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if !selection.ids.insert(item.id).inserted { selection.ids.remove(item.id) }
        } else if flags.contains(.shift), let anchor = shown.firstIndex(where: { $0.id == selection.id }),
                  let target = shown.firstIndex(where: { $0.id == item.id }) {
            selection.ids = Set(shown[min(anchor, target)...max(anchor, target)].map(\.id))
        } else { selection.ids = [item.id] }
        selection.id = item.id
    }
    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let index = shown.firstIndex { $0.id == selection.id } ?? 0
        let item = shown[max(0, min(shown.count - 1, index + delta))]
        selection.id = item.id
        selection.ids = [item.id]
    }
    private func previewSelection() {
        let urls = (selected.isEmpty ? Array(shown.prefix(1)) : selected).map(\.url)
        ShelfPreview.shared.show(urls)
    }

    private var shelf: ShelfService { state.shelf }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TabHeader(title: "Полка") {
                if !selected.isEmpty {
                    Button("Удалить (\(selected.count))") { shelf.remove(ids: selection.ids); selection.ids.removeAll() }
                        .buttonStyle(.plain)
                }
                if !shelf.isEmpty {
                    Text("\(shelf.items.count) · \(Fmt.size(shelf.totalSize))")
                        .font(.system(size: 11))
                        .hubForeground(Theme.secondaryText)
                    Button {
                        shelf.clearAll()
                        selection.id = nil
                        selection.ids.removeAll()
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
            HubSearchField(text: $query, placeholder: "Поиск файлов · ⌘клик — выбрать несколько",
                           autofocus: state.keyboardMode, onMove: { move($0); NSApp.keyWindow?.makeFirstResponder(NSApp.keyWindow) },
                           onSubmit: { if let item = selected.first ?? shown.first { shelf.open(item) } })
                .padding(.horizontal, 8).frame(height: 22).hubCard(7)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .item], isTargeted: $targeted) { providers in
            shelf.handleDrop(providers)
        }
        .onAppear {
            if state.keyboardMode, let first = shown.first { selection.id = first.id; selection.ids = [first.id] }
            installKeyMonitor()
        }
        .hubOnChange(of: query) { _ in selection.ids.removeAll(); selection.id = nil }
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
                ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(shown) { item in
                            ShelfCard(item: item,
                                      image: shelf.thumbnails[item.id],
                                      selected: selection.ids.contains(item.id),
                                      onSelect: { select(item) },
                                      dragURLs: { selected.contains(where: { $0.id == item.id }) ? selected.map(\.url) : [item.url] },
                                      onPin: { shelf.togglePin(item) },
                                      onPreview: { ShelfPreview.shared.show([item.url]) },
                                      onOpen: { shelf.open(item) },
                                      onReveal: { shelf.reveal(item) },
                                      onDelete: { delete(item) })
                                .id(item.id)
                                .onAppear { shelf.requestThumbnail(item) }
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(maxHeight: .infinity)
                }
                .hubOnChange(of: selection.id) { id in if let id { proxy.scrollTo(id) } }
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
        selection.ids.remove(item.id)
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
                    guard NSApp.keyWindow is NotchPanel,
                          !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
                    switch code {
                    case 123, 126: move(-1); swallowed = true
                    case 124, 125: move(1); swallowed = true
                    case 49: previewSelection(); swallowed = true
                    case 0 where event.modifierFlags.contains(.command):
                        selection.ids = Set(shown.map(\.id)); swallowed = true
                    case 51, 117:
                        shelf.remove(ids: selection.ids)
                        selection.ids.removeAll(); selection.id = nil; swallowed = true
                    case 36, 76:
                        if let item = selected.first ?? shown.first { shelf.open(item) }
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
    let dragURLs: () -> [URL]
    let onPin: () -> Void
    let onPreview: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private static let width: CGFloat = 104
    private static let previewHeight: CGFloat = 84

    var body: some View {
        cardContent
            .overlay(dragArea)
            .overlay(deleteBadge, alignment: .topTrailing)
            .animation(Theme.quick, value: hovering)
            .animation(Theme.quick, value: selected)
            .help(expiryLabel)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name + ", " + expiryLabel)
            .accessibilityAction { onOpen() }
            .accessibilityAction(named: Text("Быстрый просмотр")) { onPreview() }
            .accessibilityAction(named: Text(item.isPinned ? "Открепить" : "Закрепить")) { onPin() }
    }

    private var cardContent: some View {
        VStack(spacing: 0) { preview; footer }
            .frame(width: Self.width)
            .hubCard(12)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                selected ? Theme.accent : (hovering ? Color.white.opacity(0.22) : .clear),
                lineWidth: selected ? 1.5 : 1))
    }
    private var dragArea: some View {
        ShelfDragArea(url: item.url, dragURLs: dragURLs, isPinned: item.isPinned,
                      onPin: onPin, onPreview: onPreview, preview: image,
                      deleteCornerActive: hovering || selected,
                      onHover: { hovering = $0 }, onClick: onSelect,
                      onOpen: onOpen, onReveal: onReveal, onDelete: onDelete)
    }

    private var expiryLabel: String {
        if item.isPinned { return "Закреплён — не удаляется автоматически" }
        let days = Settings.shared.shelfRetentionDays
        guard days > 0 else { return "Без автоочистки" }
        let left = max(0, Int(ceil(item.added.addingTimeInterval(Double(days) * 86400).timeIntervalSinceNow / 86400)))
        return left == 0 ? "Ожидает переноса в Корзину" : (left == 1 ? "В Корзину в течение суток" : "В Корзину через \(left) дн.")
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
                if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 8)) }
                if item.isScreenshot {
                    Image(systemName: "camera.viewfinder").font(.system(size: 8, weight: .semibold))
                }
                Text("\(Fmt.size(item.size)) · \(Fmt.relative(item.added))")
                    .font(.system(size: 9))
                    .lineLimit(1)
            }
            .hubForeground(Theme.secondaryText)
            Text(expiryLabel).font(.system(size: 8)).hubForeground(Theme.secondaryText).lineLimit(1)
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
