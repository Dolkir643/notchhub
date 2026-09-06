import Foundation

/// Профиль поставки хранится в бандле, а не в пользовательских настройках:
/// установка другого образа сразу меняет поведение, сохраняя данные пользователя.
enum HubVariant: String, CaseIterable {
    case legacy, notch
    case noNotch = "no-notch"

    static let current = HubVariant(rawValue: Bundle.main.object(forInfoDictionaryKey: "NotchHubVariant") as? String ?? "") ?? .noNotch

    var title: String {
        switch self {
        case .legacy: return "macOS 11–13"
        case .notch: return "С чёлкой"
        case .noNotch: return "Без чёлки"
        }
    }

    func usesEdgeTrigger(hasRealNotch: Bool) -> Bool {
        !hasRealNotch && self != .notch
    }
}
