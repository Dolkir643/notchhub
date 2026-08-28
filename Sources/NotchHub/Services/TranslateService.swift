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
/// СТАБ: реализация — модуль «Переводчик».
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

    /// Эффективное направление перевода.
    var direction: TranslateDirection {
        if let pinnedDirection { return pinnedDirection }
        return TranslateService.detect(input)
    }

    static func detect(_ text: String) -> TranslateDirection {
        text.unicodeScalars.contains { $0.properties.isAlphabetic && ($0.value >= 0x0400 && $0.value <= 0x04FF) }
            ? .ruToEn : .enToRu
    }

    func start() {}
    /// Текст изменился — запустить дебаунс 400 мс.
    func inputChanged() {}
    /// Поменять языки местами (текст перевода становится исходным).
    func swap() {}
    /// Результат от TranslationSession.
    func receive(_ text: String) {}
    func fail(_ message: String) {}
    func setStatus(_ status: TranslateStatus) {}
}
