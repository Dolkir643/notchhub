import Combine
import SwiftUI

/// Вкладка «Буфер»: история копирований, клик — вернуть значение в буфер.
struct ClipboardTab: View {
    @EnvironmentObject private var state: AppState
    @State private var query = ""
    /// Опора для TimelineView: не пересчитываем расписание на каждой перерисовке.
    @State private var anchor = Date()

    private var all: [ClipItem] { state.clipboard.items }

    private var shown: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { $0.preview.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 6) {
            TabHeader(title: "Буфер") {
                HStack(spacing: 10) {
                    if !state.settings.clipboardEnabled {
                        Image(systemName: "pause.circle")
                            .font(.system(size: 11))
                            .hubForeground(Theme.secondaryText)
                            .help("Слежение за буфером выключено")
                    }
                    Text(ClipText.count(all.count))
                        .font(.system(size: 11))
                        .hubForeground(Theme.secondaryText)
                    if !all.isEmpty {
                        ClipTextButton(title: "Очистить", icon: "trash") {
                            withAnimation(Theme.quick) {
                                state.clipboard.clearAll()
                                query = ""
                            }
                        }
                    }
                }
            }

            if !all.isEmpty { search }
            content
        }
    }

    // MARK: — части

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .hubForeground(Theme.secondaryText)
            TextField("Поиск", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .hubForeground(.white)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .hubForeground(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Очистить поиск")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .hubCard(7)
    }

    @ViewBuilder private var content: some View {
        if !state.settings.clipboardEnabled && all.isEmpty {
            EmptyHint(icon: "pause.circle", text: "Слежение за буфером выключено\nВключить — в «Настройках»")
        } else if all.isEmpty {
            EmptyHint(icon: "doc.on.clipboard", text: "История пуста\nСкопируйте что-нибудь")
        } else if shown.isEmpty {
            EmptyHint(icon: "magnifyingglass", text: "Ничего не найдено")
        } else {
            list
        }
    }

    private var list: some View {
        // Каждые 20 с обновляется подпись «3 мин назад» у всех строк.
        ClipTicker(anchor: anchor, every: 20) { now in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(shown) { item in
                        ClipRow(item: item, now: now) {
                            state.clipboard.copyBack(item)
                            Haptics.tap()
                            state.flash("Скопировано")
                        } onDelete: {
                            withAnimation(Theme.quick) { state.clipboard.remove(item) }
                        }
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: — часы вкладки

/// Отдаёт содержимому текущее время и перерисовывает его с заданным шагом —
/// иначе подписи «3 мин назад» застыли бы на моменте появления списка.
/// На macOS 12+ это `TimelineView`, на Big Sur — запасной путь на таймере.
///
/// Развилка обязана остаться внутри `@ViewBuilder`: только там сборщик
/// подставляет `buildLimitedAvailability` и прячет `TimelineView` за `AnyView`.
/// Стоит вынести её в обычное свойство — `TimelineView` вернётся в тип `body`,
/// а его метаданные слинкованы слабо и на Big Sur равны нулю: вместо запасного
/// пути получим падение при первой же отрисовке вкладки.
private struct ClipTicker<Content: View>: View {
    let anchor: Date
    let interval: TimeInterval
    let content: (Date) -> Content

    init(anchor: Date, every interval: TimeInterval,
         @ViewBuilder content: @escaping (Date) -> Content) {
        self.anchor = anchor
        self.interval = interval
        self.content = content
    }

    @ViewBuilder var body: some View {
        if #available(macOS 12.0, *) {
            TimelineView(.periodic(from: anchor, by: interval)) { tick in
                content(tick.date)
            }
        } else {
            ClipTickerFallback(interval: interval, content: content)
        }
    }
}

/// Запас для macOS 11.
///
/// Выбран Combine-таймер, а не `Timer.scheduledTimer`: подписку через `onReceive`
/// SwiftUI сам гасит вместе с вью, тогда как ручной таймер пришлось бы хранить и
/// не забывать инвалидировать — забытый повторяющийся таймер держал бы замыкание
/// и тикал после закрытия панели.
private struct ClipTickerFallback<Content: View>: View {
    private let content: (Date) -> Content
    /// Публикатор живёт в @State, потому что структура вью пересоздаётся на каждой
    /// перерисовке: собранный прямо в `body` таймер каждый раз подписывался бы
    /// заново и отсчёт стартовал бы с нуля, так и не дойдя до тика.
    @State private var ticks: Publishers.Autoconnect<Timer.TimerPublisher>
    @State private var now = Date()

    init(interval: TimeInterval, content: @escaping (Date) -> Content) {
        self.content = content
        // .common — иначе подписи замрут, пока пользователь тащит скролл списка.
        _ticks = State(initialValue: Timer.publish(every: interval, on: .main, in: .common).autoconnect())
    }

    var body: some View {
        content(now)
            .onReceive(ticks) { now = $0 }
    }
}

// MARK: — строка истории

private struct ClipRow: View {
    let item: ClipItem
    let now: Date
    let onCopy: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            thumbnail

            Text(item.preview)
                .font(.system(size: 11))
                .hubForeground(.white.opacity(0.92))
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(ClipText.ago(item.date, now: now))
                .font(.system(size: 10))
                .hubForeground(Theme.secondaryText)
                .lineLimit(1)
                .fixedSize()

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .hubForeground(.white.opacity(0.75))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Удалить")
            .opacity(hovering ? 1 : 0)
            // Невидимый крестик не должен перехватывать клик «вернуть в буфер».
            .allowsHitTesting(hovering)
            .frame(width: 16)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.12) : Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture(perform: onCopy)
        .onHover { hovering = $0 }
        .help("Вернуть в буфер")
    }

    @ViewBuilder private var thumbnail: some View {
        switch item.kind {
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
        case .url(let u):
            Image(systemName: u.isFileURL ? "doc" : "link")
                .font(.system(size: 11, weight: .medium))
                .hubForeground(Theme.accent)
                .frame(width: 18)
        default:
            Image(systemName: item.icon)
                .font(.system(size: 11, weight: .medium))
                .hubForeground(.white.opacity(0.55))
                .frame(width: 18)
        }
    }
}

// MARK: — мелочи вкладки

/// Кнопка-текст в шапке.
private struct ClipTextButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9, weight: .medium))
                Text(title).font(.system(size: 11))
            }
            .hubForeground(hovering ? .white : Color.white.opacity(0.6))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(hovering ? Color.white.opacity(0.14) : Color.white.opacity(0.07))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private enum ClipText {
    static func count(_ n: Int) -> String {
        let tail = n % 100, last = n % 10
        let word: String
        if (11...14).contains(tail) { word = "записей" }
        else if last == 1 { word = "запись" }
        else if (2...4).contains(last) { word = "записи" }
        else { word = "записей" }
        return "\(n) \(word)"
    }

    /// «только что» / «3 мин назад» — RelativeDateTimeFormatter у самой свежей записи
    /// выдаёт «0 с назад», что выглядит нелепо.
    static func ago(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 45 ? "только что" : relative.localizedString(for: date, relativeTo: now)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Fmt.ru
        // .abbreviated по-русски выдаёт «-3 мин» (минус, без «назад») — короткий стиль
        // даёт человеческое «3 мин. назад», а .named — «вчера» вместо «-1 дн.».
        f.unitsStyle = .short
        f.dateTimeStyle = .named
        return f
    }()
}
