import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Вкладка «Заготовки»: поиск, клик-копирование, правка прямо в строке.
struct SnippetsTab: View {
    @EnvironmentObject private var state: AppState

    /// Строка, открытая на правку. Черновик живёт здесь, в хранилище уходит при сохранении.
    @State private var draft: Draft?
    @State private var copiedID: UUID?
    @State private var copyTask: Task<Void, Never>?

    private struct Draft: Equatable {
        let id: UUID
        var title: String
        var value: String
        /// Новая строка: если её так и не заполнили, при выходе удаляем.
        var isNew: Bool
        var focusValue: Bool
        /// Как строка выглядела до правки: потеря фокуса пишет на диск, а Esc возвращает это.
        var original: Snippet?
    }

    private static let dragPrefix = "notchhub.snippet:"

    /// Свой тип перетаскивания вместо простого текста: с ним строка не «роняет»
    /// служебный маркер `notchhub.snippet:<uuid>» в Telegram или редактор —
    /// вместе с `.ownProcess` перетаскивание вообще не видно другим приложениям.
    /// Тип объявлен в Info.plist (UTExportedTypeDeclarations).
    static let dragType = UTType(exportedAs: "name.notchhub.snippet-row")

    private var store: SnippetStore { state.snippets }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TabHeader(title: "Заготовки") {
                Button(action: addNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .hubForeground(.white.opacity(0.85))
                        .frame(width: 24, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Новая заготовка")
            }
            search
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Клик мимо строк во время правки сохраняет её, а не схлопывает панель.
        .background(outsideCatcher)
        .onDisappear {
            copyTask?.cancel()
            commit(closing: true)
        }
    }

    // MARK: — поиск

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .hubForeground(.white.opacity(0.4))
            SnippetField(
                text: Binding(get: { store.query }, set: { store.query = $0 }),
                placeholder: "Поиск по названию и значению",
                fontSize: 11,
                resignsOnEscape: true,
                onCancel: { store.query = "" }
            )
            if !store.query.isEmpty {
                Button {
                    store.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .hubForeground(.white.opacity(0.45))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Очистить поиск")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .hubCard(7)
    }

    // MARK: — список

    /// Отфильтрованный список плюс строка, которую сейчас правят: после переименования
    /// она может перестать отвечать поиску, но исчезать из-под курсора не должна.
    private var visible: [Snippet] {
        var keep = Set(store.filtered.map(\.id))
        if let editing = draft?.id { keep.insert(editing) }
        return store.snippets.filter { keep.contains($0.id) }
    }

    @ViewBuilder private var list: some View {
        let rows = visible
        if rows.isEmpty {
            EmptyHint(icon: store.snippets.isEmpty ? "text.badge.plus" : "magnifyingglass",
                      text: store.snippets.isEmpty ? "Пусто. Нажмите «+», чтобы добавить" : "Ничего не найдено")
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 4) {
                        ForEach(rows) { snippet in
                            row(snippet).id(snippet.id)
                        }
                    }
                    .padding(.bottom, 2)
                }
                .hubHideScrollIndicators()
                .snippetsOnChange(of: draft?.id) { id in
                    guard let id else { return }
                    withAnimation(Theme.quick) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder private func row(_ snippet: Snippet) -> some View {
        if draft?.id == snippet.id {
            editor(snippet)
        } else {
            SnippetRow(
                snippet: snippet,
                copied: copiedID == snippet.id,
                reorderable: store.query.isEmpty && draft == nil,
                onTap: { tap(snippet) },
                onEdit: { edit(snippet, focusValue: true) },
                onDelete: { remove(snippet) },
                dragPayload: { Self.dragPrefix + snippet.id.uuidString },
                onDrop: { providers in accept(providers, onto: snippet) }
            )
        }
    }

    // MARK: — редактор строки

    private func editor(_ snippet: Snippet) -> some View {
        HStack(spacing: 8) {
            SnippetField(
                text: bind(\.title),
                placeholder: "Название",
                fontSize: 12,
                bold: true,
                autofocus: draft?.focusValue == false,
                onSubmit: { commit(closing: true) },
                onCancel: cancel,
                onBlur: { commit(closing: false) }
            )
            .frame(width: 150)

            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 14)

            SnippetField(
                text: bind(\.value),
                placeholder: "Значение",
                fontSize: 11,
                autofocus: draft?.focusValue == true,
                onSubmit: { commit(closing: true) },
                onCancel: cancel,
                onBlur: { commit(closing: false) }
            )
            .frame(maxWidth: .infinity)

            iconButton("checkmark", hint: "Сохранить") { commit(closing: true) }
            iconButton("trash", hint: "Удалить") { remove(snippet) }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1))
    }

    private func iconButton(_ icon: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .hubForeground(.white.opacity(0.75))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint)
    }

    @ViewBuilder private var outsideCatcher: some View {
        if draft != nil {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { commit(closing: true) }
        }
    }

    // MARK: — действия

    private func tap(_ snippet: Snippet) {
        commit(closing: true)
        guard !snippet.value.isEmpty else {
            edit(snippet, focusValue: true)
            return
        }
        store.copy(snippet)
        copyTask?.cancel()
        withAnimation(Theme.quick) { copiedID = snippet.id }
        copyTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Theme.quick) { copiedID = nil }
        }
    }

    private func addNew() {
        commit(closing: true)
        store.query = ""
        let snippet = store.addBlank()
        withAnimation(Theme.quick) {
            draft = Draft(id: snippet.id, title: "", value: "",
                          isNew: true, focusValue: false, original: nil)
        }
    }

    private func edit(_ snippet: Snippet, focusValue: Bool) {
        commit(closing: true)
        withAnimation(Theme.quick) {
            draft = Draft(id: snippet.id, title: snippet.title, value: snippet.value,
                          isNew: false, focusValue: focusValue, original: snippet)
        }
    }

    private func remove(_ snippet: Snippet) {
        if draft?.id == snippet.id { draft = nil }
        withAnimation(Theme.quick) { store.delete(snippet) }
    }

    /// `closing == false` — просто дописали изменения на диск (потеря фокуса),
    /// строка остаётся в правке: иначе переход из названия в значение закрывал бы редактор.
    private func commit(closing: Bool) {
        guard let current = draft else { return }
        let title = current.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = current.value.trimmingCharacters(in: .whitespacesAndNewlines)

        if closing, title.isEmpty, value.isEmpty {
            if let stored = store.snippets.first(where: { $0.id == current.id }) { store.delete(stored) }
            withAnimation(Theme.quick) { draft = nil }
            return
        }
        store.update(Snippet(id: current.id, title: title, value: value))
        if closing { withAnimation(Theme.quick) { draft = nil } }
    }

    /// Esc: строка обязана вернуться в то состояние, в котором её открыли.
    /// Потеря фокуса (переход из названия в значение) уже могла записать половину правки,
    /// поэтому мало бросить черновик — надо вернуть снимок.
    private func cancel() {
        guard let current = draft else { return }
        if current.isNew {
            // Строка появилась только ради этой правки — отменяем вместе с ней.
            if let stored = store.snippets.first(where: { $0.id == current.id }) { store.delete(stored) }
        } else if let original = current.original {
            store.update(original)
        }
        withAnimation(Theme.quick) { draft = nil }
    }

    private func bind(_ key: WritableKeyPath<Draft, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: key] ?? "" },
                set: { draft?[keyPath: key] = $0 })
    }

    /// Перетаскивание строки на строку — перенос на её место.
    private func accept(_ providers: [NSItemProvider], onto target: Snippet) -> Bool {
        let type = Self.dragType.identifier
        guard store.query.isEmpty, draft == nil,
              let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type) })
        else { return false }

        let store = self.store
        let targetID = target.id
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data, let raw = String(data: data, encoding: .utf8),
                  raw.hasPrefix(Self.dragPrefix),
                  let source = UUID(uuidString: String(raw.dropFirst(Self.dragPrefix.count)))
            else { return }
            Task { @MainActor in
                guard let index = store.snippets.firstIndex(where: { $0.id == targetID }) else { return }
                withAnimation(Theme.quick) { store.move(id: source, to: index) }
            }
        }
        return true
    }
}

// MARK: — совместимость

private extension View {
    /// Реакция на смену значения.
    ///
    /// Обе формы `onChange` ведут себя здесь одинаково — вызов после смены,
    /// без стартового прогона, — но на macOS 14+ оставлен именно новый API:
    /// старая форма там объявлена устаревшей, а сводить свежую систему на
    /// совместимостную обёртку ради Big Sur незачем.
    @ViewBuilder
    func snippetsOnChange<Value: Equatable>(of value: Value,
                                            perform action: @escaping (Value) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value) { _, updated in action(updated) }
        } else {
            onChange(of: value) { updated in action(updated) }
        }
    }
}

// MARK: — строка списка

private struct SnippetRow: View {
    let snippet: Snippet
    let copied: Bool
    let reorderable: Bool
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let dragPayload: () -> String
    let onDrop: ([NSItemProvider]) -> Bool

    @State private var hovering = false
    @State private var targeted = false

    private var isEmptyValue: Bool { snippet.value.isEmpty }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Text(snippet.title.isEmpty ? "Без названия" : snippet.title)
                        .font(.system(size: 12, weight: .semibold))
                        .hubForeground(.white.opacity(snippet.title.isEmpty ? 0.4 : 0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 150, alignment: .leading)

                    Text(isEmptyValue ? "не заполнено" : snippet.value)
                        .font(.system(size: 11))
                        .hubForeground(isEmptyValue ? .white.opacity(0.3) : Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 10)
                .padding(.trailing, 62)
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isEmptyValue ? "Открыть правку" : "Скопировать значение")

            trailing
                .padding(.trailing, 8)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.09 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(targeted ? Theme.accent.opacity(0.7) : Color.clear, lineWidth: 1))
        .onHover { hovering = $0 }
        .modifier(ReorderDrag(enabled: reorderable, payload: dragPayload,
                              targeted: $targeted, onDrop: onDrop))
    }

    @ViewBuilder private var trailing: some View {
        if copied {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .hubForeground(.green)
                .frame(width: 22, height: 22)
                .transition(.scale.combined(with: .opacity))
        } else {
            HStack(spacing: 2) {
                rowButton("pencil", hint: "Править", action: onEdit)
                rowButton("trash", hint: "Удалить", action: onDelete)
            }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
    }

    private func rowButton(_ icon: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .hubForeground(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint)
    }
}

/// Перетаскивание строк включается только в «спокойном» состоянии списка:
/// при поиске и во время правки порядок трогать нечем.
private struct ReorderDrag: ViewModifier {
    let enabled: Bool
    let payload: () -> String
    @Binding var targeted: Bool
    let onDrop: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    let provider = NSItemProvider()
                    let text = payload()
                    provider.registerDataRepresentation(
                        forTypeIdentifier: SnippetsTab.dragType.identifier,
                        visibility: .ownProcess
                    ) { completion in
                        completion(Data(text.utf8), nil)
                        return nil
                    }
                    return provider
                }
                .onDrop(of: [SnippetsTab.dragType], isTargeted: $targeted, perform: onDrop)
        } else {
            content
        }
    }
}

// MARK: — поле ввода

/// Панель не активирует приложение, поэтому обычное поле съело бы первый клик
/// на «сделать окно ключевым» и курсор в него не встал бы.
private final class FirstMouseTextField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Однострочное поле на AppKit. Своё, потому что Esc обязан гаснуть здесь:
/// у SwiftUI-поля он уходит в окно и схлопывает всю панель.
private struct SnippetField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 11
    var bold: Bool = false
    var autofocus: Bool = false
    var resignsOnEscape: Bool = false
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onBlur: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let field = FirstMouseTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.font = .systemFont(ofSize: fontSize, weight: bold ? .semibold : .regular)
        field.textColor = .white
        field.placeholderString = placeholder
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }

        guard autofocus, !context.coordinator.focusRequested else { return }
        context.coordinator.focusRequested = true
        context.coordinator.grabFocus(field)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SnippetField
        var focusRequested = false

        init(_ parent: SnippetField) { self.parent = parent }

        /// Фокус ставим следующим тактом: во время построения вью окно ещё не назначено.
        /// Если окна нет и на следующем такте — несколько коротких попыток, иначе поле
        /// останется без курсора и человек будет печатать в пустоту.
        func grabFocus(_ field: NSTextField, attempt: Int = 0) {
            let step = { [weak field] in
                guard let field else { return }
                guard let window = field.window else {
                    guard attempt < 5 else { return }
                    self.grabFocus(field, attempt: attempt + 1)
                    return
                }
                if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                window.makeFirstResponder(field)
            }
            if attempt == 0 {
                DispatchQueue.main.async(execute: step)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: step)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // Уведомление прилетает и при разборке вью — откладываем, чтобы не менять
            // состояние SwiftUI посреди его же обновления.
            let blur = parent.onBlur
            DispatchQueue.main.async { blur() }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = control.stringValue
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
                parent.onCancel()
                if parent.resignsOnEscape { control.window?.makeFirstResponder(nil) }
                return true
            default:
                return false
            }
        }
    }
}
