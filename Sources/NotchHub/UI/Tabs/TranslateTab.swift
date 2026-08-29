import SwiftUI
import AppKit
import Translation

/// Вкладка «Переводчик»: два поля EN ⇄ RU поверх системного фреймворка Translation.
struct TranslateTab: View {
    var body: some View {
        if #available(macOS 15.0, *) {
            TranslateEditor()
        } else {
            EmptyHint(icon: Self.hintIcon, text: TranslateStatus.unsupported.message ?? "")
        }
    }

    /// Развилка вынесена в обычное свойство, а не в `if #available` внутри body:
    /// в ViewBuilder такая ветка обернулась бы ещё одним `AnyView` и поменяла бы
    /// дерево вью на всех системах. Здесь же меняется только строка.
    ///
    /// `character.bubble` появился в SF Symbols лишь в macOS 11.3, а цель сборки —
    /// 11.0: на 11.0–11.2 иконка молча отрисовалась бы пустотой.
    private static var hintIcon: String {
        if #available(macOS 11.3, *) { return "character.bubble" }
        return "text.bubble"
    }
}

/// Редактор вынесен в отдельный тип не ради вёрстки: `@FocusState` — обёртка
/// уровня структуры, она появилась в macOS 12 и её нельзя спрятать за
/// `if #available` внутри body. Сама вкладка обязана компилироваться под Big Sur,
/// поэтому фокус живёт здесь, а сюда исполнение доходит только на macOS 15+.
@available(macOS 15.0, *)
private struct TranslateEditor: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var inputFocused: Bool

    private var service: TranslateService { state.translate }

    // MARK: — раскладка

    var body: some View {
        VStack(spacing: 6) {
            TabHeader(title: "Переводчик") {
                HStack(spacing: 6) {
                    chip("Очистить", icon: "xmark.circle",
                         enabled: !(service.input.isEmpty && service.output.isEmpty)) { clear() }
                    chip("Копировать", icon: "doc.on.doc",
                         enabled: !service.output.isEmpty) { copyOutput() }
                }
            }
            inputCard
            languageRow
            outputCard
        }
        .background { TranslatorEngine(service: service) }
        .onAppear { inputFocused = true }
    }

    private var inputCard: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: inputBinding)
                .font(.system(size: 12))
                .hubForeground(.white)
                // Без этого TextEditor остаётся белым прямоугольником на тёмной панели.
                .hubClearScrollBackground()
                .focused($inputFocused)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
            if service.input.isEmpty {
                Text("Текст")
                    .font(.system(size: 12))
                    .hubForeground(Theme.secondaryText)
                    .padding(.leading, 11)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hubCard(10)
    }

    private var languageRow: some View {
        HStack(spacing: 8) {
            Text(service.direction.sourceLabel)
                .font(.system(size: 11, weight: .semibold))
                .hubForeground(.white.opacity(0.8))
            Button(action: swap) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .hubForeground(Theme.accent)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Поменять языки местами")
            Text(service.direction.targetLabel)
                .font(.system(size: 11, weight: .semibold))
                .hubForeground(.white.opacity(0.8))

            if let message = service.status.message {
                Text(message)
                    .font(.system(size: 10))
                    .hubForeground(isFailed ? Color.orange.opacity(0.9) : Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if isFailed {
                chip("Повторить", icon: "arrow.clockwise") { service.retry() }
            }
        }
        .frame(height: 20)
    }

    private var outputCard: some View {
        ScrollView(.vertical) {
            Text(service.output.isEmpty ? "Перевод" : service.output)
                .font(.system(size: 12))
                .hubForeground(service.output.isEmpty ? Theme.secondaryText : Color.white)
                .hubSelectableText()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .hubHideScrollIndicators()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hubCard(10)
    }

    // MARK: — детали

    private var isFailed: Bool {
        if case .failed = service.status { return true }
        return false
    }

    /// Своё связывание вместо `onChange`: программная правка текста (свап, очистка)
    /// не должна заново запускать дебаунс.
    private var inputBinding: Binding<String> {
        Binding(
            get: { service.input },
            set: { text in
                guard text != service.input else { return }
                service.input = text
                service.inputChanged()
            }
        )
    }

    /// `enabled` гасит кнопку явно: у `.plain` с заданным `foregroundStyle`
    /// системное затемнение отключённого состояния не применяется — кнопка
    /// выглядела бы рабочей, но ничего не делала.
    private func chip(_ title: String, icon: String, enabled: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .hubForeground(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
    }

    private func swap() {
        service.swap()
        Haptics.tap()
    }

    private func clear() {
        service.input = ""
        service.inputChanged()
        inputFocused = true
    }

    private func copyOutput() {
        let text = service.output
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.flash("Скопировано")
        Haptics.tap()
    }
}

/// Невидимый движок перевода: только он держит `TranslationSession.Configuration`
/// и получает сессию из `.translationTask` — создать её вручную нельзя.
@available(macOS 15.0, *)
private struct TranslatorEngine: View {
    @ObservedObject var service: TranslateService
    @State private var configuration: TranslationSession.Configuration?
    @State private var id = UUID()

    var body: some View {
        // Вью растягивается на фон вкладки, а не схлопывается в нулевой размер:
        // системному диалогу докачки пакета нужен живой якорь в окне.
        Color.clear
            .allowsHitTesting(false)
            .translationTask(configuration) { session in
                await run(session)
            }
            .onChange(of: service.requestToken) { _, _ in reload() }
            .onAppear {
                // Панель пересоздаётся при каждом раскрытии. Перевод нужен, если результата
                // ещё нет либо запрос повис: дебаунс мог сработать уже после того, как
                // панель схлопнули, и тогда статус навсегда застрял бы на «Перевожу…».
                guard service.claimEngine(id) else { return }
                if service.output.isEmpty || isPending { reload() }
            }
            .onDisappear {
                service.releaseEngine(id)
                configuration = nil
            }
    }

    /// Запрос уже выдан, но ответа ещё не было.
    private var isPending: Bool {
        switch service.status {
        case .translating, .preparing: return true
        default: return false
        }
    }

    private func reload() {
        guard service.claimEngine(id), !service.query.isEmpty else {
            configuration = nil
            return
        }
        let source = Locale.Language(identifier: service.direction.sourceCode)
        let target = Locale.Language(identifier: service.direction.targetCode)
        if var current = configuration, current.source == source, current.target == target {
            // Смена текста сама по себе translationTask не перезапускает — нужен invalidate().
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func run(_ session: TranslationSession) async {
        let text = service.query
        guard !text.isEmpty else { return }
        let direction = service.direction
        let source = Locale.Language(identifier: direction.sourceCode)
        let target = Locale.Language(identifier: direction.targetCode)
        let pair = "\(direction.sourceLabel) → \(direction.targetLabel)"
        // Пока ждали систему, текст могли сменить — тогда ответ и ошибка уже не наши
        // и затирать ими свежее состояние нельзя.
        func isCurrent() -> Bool { !Task.isCancelled && service.query == text }

        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            break
        case .supported:
            // Пакета нет на диске: prepareTranslation покажет системный диалог докачки.
            guard isCurrent() else { return }
            service.setStatus(.preparing)
            do {
                try await session.prepareTranslation()
            } catch is CancellationError {
                return
            } catch {
                Log.translate.error("пакет \(pair, privacy: .public): \(error.localizedDescription, privacy: .public)")
                guard isCurrent() else { return }
                service.fail("Нужен языковой пакет \(pair)")
                return
            }
        case .unsupported:
            guard isCurrent() else { return }
            service.fail("Пара \(pair) недоступна")
            return
        @unknown default:
            break
        }

        guard isCurrent() else { return }
        service.setStatus(.translating)
        do {
            let response = try await session.translate(text)
            // Пока переводили, текст мог смениться или исчезнуть — ответ уже неактуален.
            guard isCurrent() else { return }
            service.receive(response.targetText)
        } catch is CancellationError {
            // Отменено новым вводом — это нормальный ход, молчим.
        } catch {
            Log.translate.error("перевод \(pair, privacy: .public): \(error.localizedDescription, privacy: .public)")
            guard isCurrent() else { return }
            service.fail("Не удалось перевести")
        }
    }
}
