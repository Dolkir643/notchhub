import AppKit
import Combine
import EventKit
import os

struct CalEvent: Identifiable, Equatable {
    let id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var colorHex: String?
    var location: String?
    /// Идентификатор EventKit для ссылки `ical://ekevent/…`; nil, если стор его не отдал.
    var eventID: String?

    var color: Color2 { Color2(hex: colorHex) }

    init(id: String, title: String, start: Date, end: Date, isAllDay: Bool,
         colorHex: String? = nil, location: String? = nil, eventID: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.colorHex = colorHex
        self.location = location
        self.eventID = eventID
    }
}

extension CalEvent {
    /// Событие идёт прямо сейчас.
    func isInProgress(at moment: Date) -> Bool {
        !isAllDay && start <= moment && moment < end
    }

    /// «через 12 мин» — только для того, что начнётся в ближайшие три часа.
    func countdown(at moment: Date) -> String? {
        guard !isAllDay else { return nil }
        let left = start.timeIntervalSince(moment)
        guard left > 0, left <= 3 * 3600 else { return nil }
        let minutes = max(1, Int((left / 60).rounded(.up)))
        if minutes < 60 { return "через \(minutes) мин" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "через \(hours) ч" : "через \(hours) ч \(rest) мин"
    }
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

// MARK: — фоновая выборка

private let calendarQueue = DispatchQueue(label: "name.notchhub.calendar", qos: .userInitiated)

/// Горизонт показа — неделя вперёд.
private let calendarHorizon: TimeInterval = 7 * 24 * 3600
/// Данные считаются свежими минуту: панель раскрывают часто, EventKit дёргать зря не нужно.
private let calendarStaleAfter: TimeInterval = 60

/// EKEventStore не Sendable, но выбирать события в фоне на том же сторе EventKit
/// позволяет — переносим его в очередь через явную обёртку.
private struct StoreBox: @unchecked Sendable {
    let store: EKEventStore
}

private func loadEvents(_ box: StoreBox, from: Date, to: Date, reset: Bool) async -> [CalEvent] {
    await withCheckedContinuation { continuation in
        calendarQueue.async {
            continuation.resume(returning: fetchEvents(store: box.store, from: from, to: to, reset: reset))
        }
    }
}

private func fetchEvents(store: EKEventStore, from: Date, to: Date, reset: Bool) -> [CalEvent] {
    // После EKEventStoreChanged стор обязан перечитать базу, иначе вернёт своё старое.
    if reset { store.reset() }
    let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
    let raw = store.events(matching: predicate)

    var result: [CalEvent] = []
    result.reserveCapacity(raw.count)
    var seenKeys = Set<String>()

    for event in raw {
        guard let start = event.startDate else { continue }
        let end = event.endDate ?? start
        guard end > from else { continue }          // уже закончилось
        guard event.status != .canceled else { continue }

        let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = event.eventIdentifier
        let ekID = (identifier?.isEmpty == false) ? identifier : nil

        // У повторяющегося события все вхождения делят один eventIdentifier,
        // поэтому ключ строки списка — идентификатор плюс начало вхождения.
        let base = ekID ?? title
        var key = "\(base)|\(Int(start.timeIntervalSinceReferenceDate))"
        // Два неразличимых события (стор не дал идентификатор, название и время совпали)
        // не должны делить id: по нему ForEach различает строки списка.
        if !seenKeys.insert(key).inserted {
            var suffix = 2
            while !seenKeys.insert("\(key)#\(suffix)").inserted { suffix += 1 }
            key += "#\(suffix)"
        }

        result.append(CalEvent(id: key,
                               title: title.isEmpty ? "Без названия" : title,
                               start: start,
                               end: end,
                               isAllDay: event.isAllDay,
                               colorHex: calendarHex(event.calendar),
                               location: cleanLocation(event.location),
                               eventID: ekID))
    }

    return sortForFeed(result, now: from)
}

/// Порядок ленты: по дню, внутри дня сначала встречи, а «весь день» — следом.
/// Иначе многодневное «весь день» (отпуск, праздник) навсегда занимало бы место
/// ближайшей встречи наверху вкладки.
private func sortForFeed(_ list: [CalEvent], now: Date) -> [CalEvent] {
    let calendar = Calendar.current
    return list
        .map { event -> (day: Date, kind: Int, start: Date, id: String, event: CalEvent) in
            (calendar.startOfDay(for: max(event.start, now)), event.isAllDay ? 1 : 0, event.start, event.id, event)
        }
        .sorted { a, b in
            if a.day != b.day { return a.day < b.day }
            if a.kind != b.kind { return a.kind < b.kind }
            if a.start != b.start { return a.start < b.start }
            return a.id < b.id
        }
        .map(\.event)
}

/// Цвет календаря → «RRGGBB». sRGB-перевод может не получиться (например, у паттерн-цвета).
private func calendarHex(_ calendar: EKCalendar?) -> String? {
    guard let cgColor = calendar?.cgColor,
          let color = NSColor(cgColor: cgColor),
          let srgb = color.usingColorSpace(.sRGB) else { return nil }
    func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
    return String(format: "%02X%02X%02X", byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent))
}

private func cleanLocation(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let flat = raw.replacingOccurrences(of: "\n", with: ", ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return flat.isEmpty ? nil : flat
}

/// Выданный доступ на чтение событий называется по-разному: с macOS 14 это `.fullAccess`,
/// до неё — `.authorized`. Смотреть только на `.fullAccess` нельзя: на Big Sur разрешение
/// уже выдано, а вкладка молча показывала бы «нужен доступ».
/// `writeOnly` и `restricted` для нас равны отказу — читать события они не дают.
private func calendarStatusAllowsReading(_ status: EKAuthorizationStatus) -> Bool {
    if #available(macOS 14.0, *) {
        return status == .fullAccess
    } else {
        return status == .authorized
    }
}

// MARK: — сервис

/// Ближайшие события из EventKit.
@MainActor final class CalendarService: ObservableObject {
    @Published private(set) var access: CalendarAccess = .unknown
    @Published private(set) var events: [CalEvent] = []
    /// Идёт ли запрос к EventKit прямо сейчас.
    @Published private(set) var isRefreshing = false
    /// Была ли хотя бы одна завершённая выборка — чтобы не мигать «встреч нет» на старте.
    @Published private(set) var hasLoaded = false

    var next: CalEvent? { events.first }
    /// Остальные события недели.
    var rest: [CalEvent] { Array(events.dropFirst()) }

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var accessTask: Task<Void, Never>?
    private var needsAnotherPass = false
    private var storeIsStale = false
    private var lastRefresh = Date.distantPast

    func start() {
        syncAccess()

        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleChangeRefresh() }
        }

        // «Ближайшее событие» протухает само по себе: раз в пять минут пересчитываем.
        let tick = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        tick.tolerance = 30
        timer = tick

        if access == .authorized { refresh() }
    }

    deinit {
        timer?.invalidate()
        changeTask?.cancel()
        accessTask?.cancel()
        refreshTask?.cancel()
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    /// Во время синхронизации аккаунта EKEventStoreChanged прилетает пачками —
    /// собираем их в один запрос.
    private func scheduleChangeRefresh() {
        storeIsStale = true
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.changeTask = nil
            self.refresh()
        }
    }

    /// Системный диалог показываем только по кнопке во вкладке, не на старте приложения.
    func requestAccess() {
        // Второй тык по кнопке, пока висит системный диалог, ничего не должен запускать.
        guard accessTask == nil else { return }
        accessTask = Task { [weak self] in
            guard let self else { return }
            defer { self.accessTask = nil }
            do {
                let granted: Bool
                if #available(macOS 14.0, *) {
                    granted = try await self.store.requestFullAccessToEvents()
                } else {
                    // Деления на «полный» и «только запись» до macOS 14 нет,
                    // а requestAccess(to:) там ещё не устарел — потому он именно в этой ветке.
                    granted = try await self.store.requestAccess(to: .event)
                }
                Log.calendar.info("полный доступ к событиям: \(granted, privacy: .public)")
            } catch {
                Log.calendar.error("запрос доступа не удался: \(error.localizedDescription, privacy: .public)")
            }
            self.syncAccess()
            if self.access == .authorized {
                // Стор создан до выдачи доступа — заставим его перечитать базу,
                // иначе первая выборка вернёт пустоту.
                self.storeIsStale = true
                self.refresh()
            } else {
                self.hasLoaded = true
            }
        }
    }

    func refresh() {
        syncAccess()
        guard access == .authorized else {
            hasLoaded = true
            if !events.isEmpty { events = [] }
            return
        }
        guard refreshTask == nil else { needsAnotherPass = true; return }
        startFetch()
    }

    /// Обновить, если данные устарели (вызывается при раскрытии панели).
    func refreshIfNeeded() {
        syncAccess()
        guard access == .authorized else { return }
        // Раскрытие панели дёргает и каркас, и сама вкладка: пока запрос в полёте,
        // второй такой же не нужен (иначе EventKit опрашивается дважды на каждое открытие).
        guard refreshTask == nil else { return }
        if Date().timeIntervalSince(lastRefresh) > calendarStaleAfter {
            refresh()
        } else {
            pruneFinished()
        }
    }

    /// Дешёвая подчистка без похода в EventKit: убрать то, что уже закончилось,
    /// чтобы наверху не висела завершившаяся встреча.
    func pruneFinished() {
        let now = Date()
        let alive = events.filter { $0.end > now }
        if alive.count != events.count { events = alive }
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        _ = NSWorkspace.shared.open(url)
    }

    /// Открыть событие в Календаре; если ссылка не сработала — просто сам Календарь.
    func openInCalendar(_ event: CalEvent) {
        if let identifier = event.eventID,
           let escaped = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(escaped)?method=show&options=more"),
           NSWorkspace.shared.open(url) {
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else {
            Log.calendar.error("Календарь не найден")
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: — внутреннее

    private func syncAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        let value: CalendarAccess
        if status == .notDetermined {
            value = .unknown
        } else {
            value = calendarStatusAllowsReading(status) ? .authorized : .denied
        }
        if access != value { access = value }
    }

    private func startFetch() {
        isRefreshing = true
        let box = StoreBox(store: store)
        let from = Date()
        let to = from.addingTimeInterval(calendarHorizon)
        let reset = storeIsStale
        storeIsStale = false
        refreshTask = Task { [weak self] in
            let list = await loadEvents(box, from: from, to: to, reset: reset)
            guard let self else { return }
            self.finish(list, at: from)
        }
    }

    private func finish(_ list: [CalEvent], at moment: Date) {
        refreshTask = nil
        lastRefresh = moment
        hasLoaded = true
        if events != list { events = list }
        Log.calendar.debug("событий на неделю: \(list.count, privacy: .public)")

        if needsAnotherPass {
            needsAnotherPass = false
            startFetch()
        } else {
            isRefreshing = false
        }
    }
}
