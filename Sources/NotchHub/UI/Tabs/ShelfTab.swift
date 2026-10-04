import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Вкладка «Полка»: карточки файлов, приём drag&drop, вытаскивание наружу.
struct ShelfTab: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var selection = ShelfSelection()
    @State private var targeted = false

    private var shelf: ShelfService { state.shelf }
    private var shown: [ShelfItem] { selection.visibleItems(from: shelf.items) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TabHeader(title: "Полка") {
                if selection.page == .saved, !selectedItems.isEmpty {
                    Button("Удалить (\(selectedItems.count))") { delete(selectedItems) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                }
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
                HubSearchField(text: $selection.query,
                               placeholder: "Поиск файлов · ⌘клик — выбрать несколько",
                               autofocus: state.keyboardMode,
                               onMove: { delta in
                                   selection.move(delta, orderedIDs: shown.map(\.id))
                                   if let window = selection.window { window.makeFirstResponder(window) }
                               },
                               onSubmit: {
                                   (selectedItems.isEmpty ? Array(shown.prefix(1)) : selectedItems)
                                       .forEach { shelf.open($0) }
                               })
                    .padding(.horizontal, 8).frame(height: 22).hubCard(7)
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
        .onAppear {
            if state.keyboardMode, let first = shown.first {
                selection.select(first.id, orderedIDs: shown.map(\.id))
            }
            installKeyMonitor()
        }
        .hubOnChange(of: selection.query) { _ in selection.prune(to: []) }
        .onDisappear { removeKeyMonitor() }
        .onReceive(shelf.$items) { selection.prune(to: selection.visibleItems(from: $0).map(\.id)) }
    }

    // MARK: — содержимое

    @ViewBuilder private var content: some View {
        ZStack {
            if shelf.isEmpty {
                EmptyHint(icon: "tray.and.arrow.down",
                          text: targeted
                          ? "Отпускайте — заберу"
                          : "Бросьте файлы сюда.\nСкриншоты попадают сами")
            } else if shown.isEmpty {
                EmptyHint(icon: "magnifyingglass", text: "Файлы не найдены")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(shown) { item in
                                card(item)
                                    .id(item.id)
                                    .onAppear { shelf.requestThumbnail(item) }
                            }
                        }
                        .padding(.horizontal, 2)
                        .frame(maxHeight: .infinity)
                    }
                    .hubOnChange(of: selection.focusedID) { id in
                        if let id { proxy.scrollTo(id) }
                    }
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

    private func card(_ item: ShelfItem) -> some View {
        ShelfCard(item: item,
                  image: shelf.thumbnails[item.id],
                  selected: selection.ids.contains(item.id),
                  onSelect: { modifiers, preservingGroup in
                      selection.select(item.id, orderedIDs: shown.map(\.id),
                                       modifiers: modifiers, preservingGroup: preservingGroup)
                  },
                  onOpen: { actionItems(for: item).forEach { shelf.open($0) } },
                  onReveal: {
                      NSWorkspace.shared.activateFileViewerSelecting(actionItems(for: item).map(\.url))
                  },
                  onDelete: { delete(actionItems(for: item)) },
                  onDeleteSingle: { delete([item]) },
                  onPin: { togglePin(actionItems(for: item)) },
                  onPreview: { ShelfPreview.shared.show(actionItems(for: item).map(\.url)) },
                  onCopy: { shelf.copyToClipboard(items: actionItems(for: item)) },
                  files: {
                      actionItems(for: item).map {
                          ShelfDragFile(url: $0.url, preview: shelf.thumbnails[$0.id])
                      }
                  },
                  pinTitle: {
                      actionItems(for: item).allSatisfy(\.isPinned) ? "Открепить" : "Закрепить"
                  })
    }

    // MARK: — действия

    private var selectedItems: [ShelfItem] {
        shown.filter { selection.ids.contains($0.id) }
    }

    private func actionItems(for item: ShelfItem) -> [ShelfItem] {
        let selected = selectedItems
        return selected.contains(where: { $0.id == item.id }) ? selected : [item]
    }

    private func delete(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        withAnimation(Theme.quick) { shelf.remove(items: items) }
        Haptics.tap()
    }

    private func togglePin(_ items: [ShelfItem]) {
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
                          !state.isPresentingDialog,
                          !(window.firstResponder is NSTextView),
                          !(window.firstResponder is NSTextField) else { return }
                    let shown = selection.visibleItems(from: shelf.items)
                    let orderedIDs = shown.map(\.id)
                    selection.prune(to: orderedIDs)
                    let items = shown.filter { selection.ids.contains($0.id) }
                    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        .subtracting([.capsLock, .numericPad, .function])
                    if modifiers == .command {
                        // Сохраняем преобразование ⌘ текущей раскладкой
                        // (например, русская раскладка или Dvorak–QWERTY).
                        let command = event.characters?.lowercased()
                            ?? event.charactersIgnoringModifiers?.lowercased()
                        switch command {
                        case "a":
                            guard !shown.isEmpty else { return }
                            selection.selectAll(orderedIDs)
                            swallowed = true
                        case "c":
                            guard !items.isEmpty else { return }
                            shelf.copyToClipboard(items: items)
                            swallowed = true
                        default: break
                        }
                        return
                    }
                    if modifiers.isEmpty || modifiers == .shift {
                        switch code {
                        case 123, 126:
                            guard !shown.isEmpty else { return }
                            selection.move(-1, orderedIDs: orderedIDs, modifiers: modifiers)
                            swallowed = true
                        case 124, 125:
                            guard !shown.isEmpty else { return }
                            selection.move(1, orderedIDs: orderedIDs, modifiers: modifiers)
                            swallowed = true
                        default: break
                        }
                        if swallowed { return }
                    }
                    guard modifiers.isEmpty else { return }
                    switch code {
                    case 51, 117:   // ⌫ и ⌦
                        guard !items.isEmpty else { return }
                        withAnimation(Theme.quick) { shelf.remove(items: items) }
                        Haptics.tap()
                        swallowed = true
                    case 36, 76:    // ⏎ на основной клавиатуре и на цифровой
                        guard !shown.isEmpty else { return }
                        (items.isEmpty ? Array(shown.prefix(1)) : items).forEach { shelf.open($0) }
                        swallowed = true
                    case 49:        // пробел — системный Quick Look
                        guard !shown.isEmpty else { return }
                        ShelfPreview.shared.show((items.isEmpty ? Array(shown.prefix(1)) : items).map(\.url))
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
    let onPreview: () -> Void
    let onCopy: () -> Void
    let files: () -> [ShelfDragFile]
    let pinTitle: () -> String

    @State private var hovering = false

    private static let width: CGFloat = 104
    private static let previewHeight: CGFloat = 84

    var body: some View {
        cardContent
            .overlay(dragArea)
            .overlay(deleteBadge, alignment: .topTrailing)
            .overlay(pinBadge, alignment: .topLeading)
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
        VStack(spacing: 0) {
            preview
            footer
        }
        .frame(width: Self.width)
        .hubCard(12)
        // Наложение значением совместимо с macOS 11.
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.accent : (hovering ? Color.white.opacity(0.22) : .clear),
                              lineWidth: selected ? 1.5 : 1)
        )
    }

    private var dragArea: some View {
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
                      onPreview: onPreview,
                      pinTitle: pinTitle,
                      files: files)
    }

    private var expiryLabel: String {
        if item.isPinned { return "Закреплён — не удаляется автоматически" }
        let days = Settings.shared.shelfRetentionDays
        guard days > 0 else { return "Без автоочистки" }
        let left = max(0, Int(ceil(item.added.addingTimeInterval(Double(days) * 86400).timeIntervalSinceNow / 86400)))
        return left == 0 ? "Ожидает переноса в Корзину" : (left == 1 ? "В Корзину в течение суток" : "В Корзину через \(left) дн.")
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
            Text(expiryLabel)
                .font(.system(size: 8))
                .hubForeground(Theme.secondaryText)
                .lineLimit(1)
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
