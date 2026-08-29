import SwiftUI

extension CalEvent {
    var tint: Color { Color(red: color.r, green: color.g, blue: color.b) }

    /// «сегодня · 10:40–11:10 · Переговорная»
    var subtitle: String {
        let base = Fmt.eventSubtitle(start: start, end: end, allDay: isAllDay)
        guard let location else { return base }
        return base + " · " + location
    }
}

private extension View {
    /// Замена `.task`, которого нет в macOS 11.
    /// Замыкание помечено `@MainActor` осознанно: настоящий `.task` наследует
    /// изоляцию вью, и без этой пометки тело тикера уехало бы с главного потока.
    @ViewBuilder func calendarTask(_ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        if #available(macOS 12.0, *) {
            task { await action() }
        } else {
            modifier(CalendarLegacyTask(action: action))
        }
    }
}

/// У `.task` отмена при исчезновении вью встроена, у `onAppear` её нет: без явного
/// `cancel` вечный цикл тикера пережил бы закрытие панели и продолжал дёргать сервис.
private struct CalendarLegacyTask: ViewModifier {
    let action: @MainActor @Sendable () async -> Void

    @State private var running: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Повторный onAppear без onDisappear (перестроение иерархии) не должен
                // оставлять за собой второй цикл.
                running?.cancel()
                running = Task { await action() }
            }
            .onDisappear {
                running?.cancel()
                running = nil
            }
    }
}

/// Вкладка «Календарь»: ближайшее событие крупно и остальная неделя списком.
struct CalendarTab: View {
    @EnvironmentObject private var state: AppState
    @State private var now = Date()

    private var service: CalendarService { state.calendarService }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TabHeader(title: "Календарь") {
                if service.access == .authorized {
                    Button {
                        service.refresh()
                        Haptics.tap()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .hubForeground(service.isRefreshing ? Color.white.opacity(0.25) : Theme.secondaryText)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(service.isRefreshing)
                    .help("Обновить")
                }
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Тикер живёт только пока панель раскрыта: «через 12 мин» не должно врать.
        .calendarTask {
            service.refreshIfNeeded()
            while !Task.isCancelled {
                now = Date()
                // Закончившаяся встреча не должна висеть наверху до следующего запроса.
                service.pruneFinished()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch service.access {
        case .authorized: schedule
        case .unknown:
            CalAccessNotice(denied: false,
                            onRequest: { service.requestAccess() },
                            onSettings: { service.openSystemSettings() })
        case .denied:
            CalAccessNotice(denied: true,
                            onRequest: { service.requestAccess() },
                            onSettings: { service.openSystemSettings() })
        }
    }

    @ViewBuilder private var schedule: some View {
        if let hero = service.next {
            CalHeroCard(event: hero, now: now) { service.openInCalendar(hero) }
            CalEventList(events: service.rest, now: now) { service.openInCalendar($0) }
        } else if service.hasLoaded {
            EmptyHint(icon: "calendar", text: "На ближайшую неделю встреч нет")
        } else {
            EmptyHint(icon: "calendar", text: "Читаем календарь…")
        }
    }
}

// MARK: — ближайшее событие

private struct CalHeroCard: View {
    let event: CalEvent
    let now: Date
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(event.tint)
                .frame(width: 4, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 15, weight: .semibold))
                    .hubForeground(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(event.subtitle)
                    .font(.system(size: 11))
                    .hubForeground(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)
            CalStatusChip(event: event, now: now)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hubCard(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.2 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .help("Открыть в Календаре")
    }
}

// MARK: — остальная неделя

private struct CalEventList: View {
    let events: [CalEvent]
    let now: Date
    let onOpen: (CalEvent) -> Void

    var body: some View {
        if events.isEmpty {
            Text("Других встреч на неделе нет")
                .font(.system(size: 11))
                .hubForeground(Theme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(events) { event in
                        CalRow(event: event, now: now) { onOpen(event) }
                    }
                }
            }
            .hubHideScrollIndicators()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct CalRow: View {
    let event: CalEvent
    let now: Date
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(event.tint)
                .frame(width: 3, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .hubForeground(.white.opacity(0.92))
                    .lineLimit(1)
                Text(event.subtitle)
                    .font(.system(size: 10))
                    .hubForeground(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)
            CalStatusChip(event: event, now: now)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.07) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
    }
}

// MARK: — мелочи

private struct CalStatusChip: View {
    let event: CalEvent
    let now: Date

    var body: some View {
        if event.isInProgress(at: now) {
            chip("сейчас", strong: true)
        } else if let countdown = event.countdown(at: now) {
            chip(countdown, strong: false)
        }
    }

    private func chip(_ text: String, strong: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .hubForeground(strong ? Color.black : Color.white.opacity(0.75))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(strong ? Theme.accent : Color.white.opacity(0.1)))
            .fixedSize()
    }
}

private struct CalAccessNotice: View {
    let denied: Bool
    let onRequest: () -> Void
    let onSettings: () -> Void

    /// Кнопка ведёт в системные настройки, а рассказать надо, что там нажимать.
    /// В Ventura раздел зовётся «Конфиденциальность и безопасность» и лежит первым уровнем,
    /// а в Big Sur и Monterey это «Защита и безопасность» с вкладкой «Конфиденциальность»:
    /// на них прежняя подсказка вела бы в несуществующий пункт.
    private var deniedHint: String {
        if #available(macOS 13.0, *) {
            return "Включите NotchHub в «Конфиденциальность и безопасность» → «Календари» и раскройте панель снова."
        } else {
            return "Включите NotchHub в «Защита и безопасность» → «Конфиденциальность» → «Календари» и раскройте панель снова."
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 22, weight: .light))
                .hubForeground(.white.opacity(0.35))
            Text(denied ? "Календарь закрыт для NotchHub" : "Нужен доступ к Календарю")
                .font(.system(size: 12, weight: .medium))
                .hubForeground(.white.opacity(0.9))
            Text(denied
                 ? deniedHint
                 : "Покажем ближайшую встречу в чёлке. События только читаются.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .hubForeground(Theme.secondaryText)
                .frame(maxWidth: 400)
            Button(denied ? "Открыть настройки" : "Разрешить доступ") {
                if denied { onSettings() } else { onRequest() }
            }
            .buttonStyle(CalActionButton())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CalActionButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .hubForeground(Color.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.accent.opacity(configuration.isPressed ? 0.7 : 1)))
            .contentShape(Capsule())
    }
}
