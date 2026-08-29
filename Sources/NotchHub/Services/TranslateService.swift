import Foundation
import Combine

enum TranslateDirection: String, Equatable {
    case ruToEn, enToRu

    var sourceCode: String { self == .ruToEn ? "ru" : "en" }
    var targetCode: String { self == .ruToEn ? "en" : "ru" }
    var sourceLabel: String { self == .ruToEn ? "RU" : "EN" }
    var targetLabel: String { self == .ruToEn ? "EN" : "RU" }
    var flipped: TranslateDirection { self == .ruToEn ? .enToRu : .ruToEn }
}

enum TranslateStatus: Equatable {
    case unsupported
    case idle
    case preparing
    case translating
    case failed(String)

    var message: String? {
        switch self {
        case .unsupported: return "Переводчик доступен с macOS 15"
        case .preparing: return "Готовлю языковой пакет…"
        case .translating: return "Перевожу…"
        case .failed(let m): return m
        case .idle: return nil
        }
    }
}

/// Переводчик EN ⇄ RU на системном фреймворке Translation (macOS 15+).
/// Сессию нельзя создать напрямую — её отдаёт `.translationTask`,
/// поэтому сервис только копит текст и дёргает `requestToken`,
/// а сам перевод выполняет вью в `TranslateTab.swift`.
@MainActor final class TranslateService: ObservableObject {
    nonisolated static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    @Published var input: String = ""
    @Published private(set) var output: String = ""
    @Published private(set) var status: TranslateStatus = .idle
    /// nil — направление определяется автоматически по первому кириллическому символу.
    @Published var pinnedDirection: TranslateDirection?
    /// Счётчик запросов: инкремент после дебаунса — сигнал вью перевести заново.
    @Published private(set) var requestToken: Int = 0

    /// Пауза после последнего нажатия клавиши.
    private static let debounce: UInt64 = 400_000_000
    private var debounceTask: Task<Void, Never>?
    /// Панель живёт на каждом экране, а переводить должен ровно один движок:
    /// иначе на двух мониторах диалог докачки пакета выскочит дважды.
    private var engineOwner: UUID?

    /// Эффективное направление перевода.
    var direction: TranslateDirection {
        if let pinnedDirection { return pinnedDirection }
        return TranslateService.detect(input)
    }

    /// Текст без краевых пробелов — то, что реально уходит в перевод.
    var query: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func detect(_ text: String) -> TranslateDirection {
        text.unicodeScalars.contains { $0.properties.isAlphabetic && ($0.value >= 0x0400 && $0.value <= 0x04FF) }
            ? .ruToEn : .enToRu
    }

    func start() {
        guard TranslateService.isSupported else {
            status = .unsupported
            return
        }
        status = .idle
    }

    /// Текст изменился — запустить дебаунс 400 мс.
    func inputChanged() {
        debounceTask?.cancel()
        debounceTask = nil

        guard TranslateService.isSupported else {
            status = .unsupported
            return
        }

        guard !query.isEmpty else {
            output = ""
            status = .idle
            // Очистили поле — снимаем и ручную фиксацию языков: дальше снова автоопределение.
            pinnedDirection = nil
            return
        }

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: TranslateService.debounce)
            guard !Task.isCancelled, let self, !self.query.isEmpty else { return }
            self.status = .translating
            self.requestToken += 1
        }
    }

    /// Поменять языки местами (текст перевода становится исходным).
    func swap() {
        guard TranslateService.isSupported else { return }
        debounceTask?.cancel()
        debounceTask = nil

        let next = direction.flipped
        let carried = output.isEmpty ? input : output
        pinnedDirection = next
        input = carried
        output = ""

        guard !query.isEmpty else {
            status = .idle
            return
        }
        status = .translating
        requestToken += 1
    }

    /// Повторить перевод: после ошибки или отказа от докачки языкового пакета.
    func retry() {
        guard TranslateService.isSupported, !query.isEmpty else { return }
        debounceTask?.cancel()
        debounceTask = nil
        status = .translating
        requestToken += 1
    }

    /// Занять право на перевод. `true` — движок с этим `id` теперь ведущий.
    func claimEngine(_ id: UUID) -> Bool {
        if engineOwner == nil { engineOwner = id }
        return engineOwner == id
    }

    func releaseEngine(_ id: UUID) {
        if engineOwner == id { engineOwner = nil }
    }

    /// Результат от TranslationSession.
    func receive(_ text: String) {
        output = text
        status = .idle
    }

    func fail(_ message: String) {
        // Старый перевод больше не соответствует вводу — убираем, чтобы не выдавать его за свежий.
        output = ""
        status = .failed(message)
        Log.translate.error("\(message, privacy: .public)")
    }

    func setStatus(_ status: TranslateStatus) {
        self.status = status
    }
}
