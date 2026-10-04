import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Вкладка «Полка»: карточки файлов, приём drag&drop, вытаскивание наружу.
struct ShelfTab: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var selection = ShelfSelection()
    @State private var targeted = false

    private var shelf: ShelfService { state.shelf }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TabHeader(title: "Полка") {
                if selection.page == .saved, !shelf.isEmpty {
                    Text("\(shelf.items.count) · \(Fmt.size(shelf.totalSize))")
                        .font(.system(size: 11))
                        .hubForeground(Theme.secondaryText)
                    Button {
                        shelf.clearAll()
                    } label: {
                        Text("Очистить")
                            .font(.system(size: 11, weight: .medium))
                            .hubForeground(.white.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .disabled(shelf.items.allSatisfy(\.isPinned))
                    .help("В Корзину всё, кроме закреплённых")
                }
            }
            HStack(spacing: 10) {
                Picker("Раздел полки", selection: $selection.page) {
                    ForEach(ShelfPage.allCases) { page in
                        Text(page.title).tag(page)
                    }
                }
                .labelsHidden()
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 220)
                if selection.page == .saved, !selection.ids.isEmpty {
                    Text("Выбрано: \(selection.ids.count)")
                        .font(.system(size: 10))
                        .hubForeground(Theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            if selection.page == .saved {
                content
            } else {
                ShelfDownloadsView(downloads: shelf.downloads, shelf: shelf)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ShelfWindowReader(selection: selection))
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .item], isTargeted: $targeted) { providers in
            shelf.handleDrop(providers)
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .onReceive(shelf.$items) { selection.prune(to: $0.map(\.id)) }
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
                                      selected: selection.ids.contains(item.id),
                                      onSelect: { modifiers, preservingGroup in
                                          selection.select(item.id, orderedIDs: shelf.items.map(\.id),
                                                           modifiers: modifiers,
                                                           preservingGroup: preservingGroup)
                                      },
                                      onOpen: { selectedItems.forEach { shelf.open($0) } },
                                      onReveal: {
                                          NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url))
                                      },
                                      onDelete: { delete(selectedItems) },
                                      onDeleteSingle: { delete([item]) },
                                      onPin: { togglePinSelection() },
                                      onCopy: { shelf.copyToClipboard(items: selectedItems) },
                                      files: {
                                          selectedItems.map {
                                              ShelfDragFile(url: $0.url, preview: shelf.thumbnails[$0.id])
                                          }
                                      },
                                      pinTitle: {
                                          selectedItems.allSatisfy(\.isPinned) ? "Открепить" : "Закрепить"
                                      })
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

    private var selectedItems: [ShelfItem] {
        shelf.items.filter { selection.ids.contains($0.id) }
    }

    private func delete(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        withAnimation(Theme.quick) { shelf.remove(items: items) }
        Haptics.tap()
    }

    private func togglePinSelection() {
        let items = selectedItems
        let pinned = !items.allSatisfy(\.isPinned)
        for item in items where item.isPinned != pinned { shelf.togglePin(item) }
    }

    /// Локальные сочетания не должны перехватывать ввод в диалогах, других
    /// панелях или текстовых полях. Привязка к окну также исключает двойную
    /// обработку, когда чёлка показана на нескольких мониторах.
    private func installKeyMonitor() {
        let shelf = state.shelf
        let selection = self.selection
        let state = self.state
        selection.keepMonitor {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak selection, weak state] event in
                let code = event.keyCode
                var swallowed = false
                // Событие наружу из assumeIsolated не выносим: NSEvent несендабельный.
                MainActor.assumeIsolated {
                    guard let selection, let state,
                          state.isExpanded, state.selectedTab == .shelf,
                          selection.page == .saved,
                          let window = selection.window,
                          NSApp.keyWindow === window, event.window === window,
                          NSApp.modalWindow == nil, window.attachedSheet == nil,
                          !(window.firstResponder is NSTextView),
                          !(window.firstResponder is NSTextField) else { return }
                    selection.prune(to: shelf.items.map(\.id))
                    let items = shelf.items.filter { selection.ids.contains($0.id) }
                    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        .subtracting([.capsLock, .numericPad, .function])
                    if modifiers == .command {
                        // Сохраняем преобразование ⌘ текущей раскладкой
                        // (например, русская раскладка или Dvorak–QWERTY).
                        let command = event.characters?.lowercased()
                            ?? event.charactersIgnoringModifiers?.lowercased()
                        switch command {
                        case "a":
                            guard !shelf.isEmpty else { return }
                            selection.selectAll(shelf.items.map(\.id))
                            swallowed = true
                        case "c":
                            guard !items.isEmpty else { return }
                            shelf.copyToClipboard(items: items)
                            swallowed = true
                        default: break
                        }
                        return
                    }
                    guard modifiers.isEmpty, !items.isEmpty else { return }
                    switch code {
                    case 51, 117:   // ⌫ и ⌦
                        withAnimation(Theme.quick) { shelf.remove(items: items) }
                        Haptics.tap()
                        swallowed = true
                    case 36, 76:    // ⏎ на основной клавиатуре и на цифровой
                        items.forEach { shelf.open($0) }
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
    let onSelect: (NSEvent.ModifierFlags, Bool) -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    let onDeleteSingle: () -> Void
    let onPin: () -> Void
    let onCopy: () -> Void
    let files: () -> [ShelfDragFile]
    let pinTitle: () -> String

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
                          onClick: { onSelect([], false) },
                          onOpen: onOpen,
                          onReveal: onReveal,
                          onDelete: onDelete,
                          onSelection: onSelect,
                          onDeleteSingle: onDeleteSingle,
                          onCopy: onCopy,
                          onPin: onPin,
                          pinTitle: pinTitle,
                          files: files)
        )
        .overlay(deleteBadge, alignment: .topTrailing)
        .overlay(pinBadge, alignment: .topLeading)
        .animation(Theme.quick, value: hovering)
        .animation(Theme.quick, value: selected)
    }

    @ViewBuilder private var pinBadge: some View {
        if item.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 10, weight: .semibold))
                .hubForeground(Theme.accent)
                .padding(5)
                .background(Circle().fill(Color.black.opacity(0.65)))
                .padding(4)
                .allowsHitTesting(false)
                .help("Закреплён: остаётся при очистке")
        }
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
