import Foundation

enum Fmt {
    /// 03:41 / 1:03:41
    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()

    static func size(_ value: Int64) -> String { bytes.string(fromByteCount: value) }

    static let ru: Locale = Locale(identifier: "ru_RU")

    /// «пятница, 7 августа»
    static func dayLong(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = ru
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f.string(from: date)
    }

    /// «10:40»
    static func hm(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = ru
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// «сегодня, 10:40 – 11:10» / «пятница, 7 августа · 10:40–11:10»
    static func eventSubtitle(start: Date, end: Date, allDay: Bool) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(start) { day = "сегодня" }
        else if cal.isDateInTomorrow(start) { day = "завтра" }
        else { day = dayLong(start) }
        if allDay { return "\(day) · весь день" }
        return "\(day) · \(hm(start))–\(hm(end))"
    }

    /// «2 мин назад», «вчера»
    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = ru
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
