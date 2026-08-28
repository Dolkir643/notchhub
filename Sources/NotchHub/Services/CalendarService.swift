import AppKit
import Combine

struct CalEvent: Identifiable, Equatable {
    let id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var colorHex: String?
    var location: String?

    var color: Color2 { Color2(hex: colorHex) }
}

/// Мостик к цвету календаря без импорта SwiftUI в модель.
struct Color2: Equatable {
    var r: Double = 0.4, g: Double = 0.72, b: Double = 1.0

    init(hex: String?) {
        guard let hex, hex.count >= 6 else { return }
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard let v = UInt32(s.prefix(6), radix: 16) else { return }
        r = Double((v >> 16) & 0xFF) / 255
        g = Double((v >> 8) & 0xFF) / 255
        b = Double(v & 0xFF) / 255
    }
}

enum CalendarAccess: Equatable {
    case unknown, denied, authorized
}

/// Ближайшие события из EventKit.
/// СТАБ: реализация — модуль «Календарь».
@MainActor final class CalendarService: ObservableObject {
    @Published private(set) var access: CalendarAccess = .unknown
    @Published private(set) var events: [CalEvent] = []

    var next: CalEvent? { events.first }

    func start() {}
    func requestAccess() {}
    func refresh() {}
    /// Обновить, если данные устарели (вызывается при раскрытии панели).
    func refreshIfNeeded() {}
    func openSystemSettings() {}
}
