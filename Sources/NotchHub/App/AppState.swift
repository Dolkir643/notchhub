import SwiftUI
import Combine

enum NotchTab: String, CaseIterable, Identifiable, Codable {
    case music, shelf, clipboard, snippets, calendar, translate, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: return "Музыка"
        case .shelf: return "Полка"
        case .clipboard: return "Буфер"
        case .snippets: return "Заготовки"
        case .calendar: return "Календарь"
        case .translate: return "Переводчик"
        case .settings: return "Настройки"
        }
    }

    var icon: String {
        switch self {
        // Не «music.note»: залитая нотка среди контурных соседей читается
        // плотнее и лезет в глаза, хотя закрашивает меньше всех (35 против
        // средних 88 у соседей — дело в плотности, а не в размере).
        // Наушники — такой же контур, как у лотка, календаря и шестерёнки.
        case .music: return "headphones"
        case .shelf: return "tray.full"
        case .clipboard: return "doc.on.clipboard"
        case .snippets: return "text.badge.plus"
        case .calendar: return "calendar"
        case .translate: return "character.bubble"
        case .settings: return "gearshape"
        }
    }

    /// Вкладки, доступные на текущей системе.
    static var available: [NotchTab] {
        allCases.filter { tab in
            tab != .translate || TranslateService.isSupported
        }
    }
}

/// Состояние чёлки: раскрытие, активная вкладка, короткие подтверждения.
/// Один экземпляр на всё приложение — панели на разных экранах его разделяют.
@MainActor final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: — состояние окна

    /// Панель раскрыта. Промежуточной «компактной» ступени нет:
    /// островок либо пустой и молчит, либо раскрыт целиком за одно движение.
    @Published private(set) var isExpanded = false
    /// Над чёлкой тащат файл.
    @Published var isDropTargeted = false
    /// Активная вкладка.
    @Published var selectedTab: NotchTab = .music
    /// Короткое подтверждение поверх панели («Скопировано»).
    @Published private(set) var flashText: String?

    // MARK: — сервисы

    let settings = Settings.shared
    let media = MediaService()
    let shelf = ShelfService()
    let clipboard = ClipboardService()
    let snippets = SnippetStore()
    let calendarService = CalendarService()
    let translate = TranslateService()

    /// Курсор в зоне чёлки. Больше не состояние вида, а только защита
    /// от повторного хаптика и от раскрытия, когда курсор уже ушёл.
    private var isInside = false
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    private init() {
        // Панель перерисовывается, когда сервисы меняют своё состояние.
        for object in [media.objectWillChange, shelf.objectWillChange, clipboard.objectWillChange,
                       snippets.objectWillChange, calendarService.objectWillChange,
                       translate.objectWillChange, settings.objectWillChange] {
            object.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
    }

    func startServices() {
        media.start()
        shelf.start()
        clipboard.start()
        snippets.start()
        calendarService.start()
        translate.start()
    }

    func stopServices() {
        media.stop()
        shelf.stop()
        clipboard.stop()
    }

    // MARK: — раскрытие / схлопывание

    /// Курсор вошёл в зону чёлки.
    func hoverBegan() {
        closeTask?.cancel(); closeTask = nil
        guard !isInside else { return }
        isInside = true
        Haptics.tap()

        guard settings.openOnHover, !isExpanded else { return }
        openTask?.cancel()
        let delay = settings.hoverOpenDelay
        openTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self, self.isInside else { return }
            self.expand()
        }
    }

    /// Курсор покинул зону: чёлку в свёрнутом виде, всю панель — в раскрытом.
    func hoverEnded() {
        isInside = false
        openTask?.cancel(); openTask = nil
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000) // дебаунс 100 мс
            guard !Task.isCancelled, let self else { return }
            // Пока в панели правят текст, ждём: захлопнуть её на полуслове хуже,
            // чем оставить открытой. Клик вне панели закроет её и во время ввода.
            while NotchWindowController.shared.isEditingText {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
            }
            self.collapse()
        }
    }

    func expand(to tab: NotchTab? = nil) {
        openTask?.cancel(); openTask = nil
        closeTask?.cancel(); closeTask = nil
        if let tab, NotchTab.available.contains(tab) { selectedTab = tab }
        guard !isExpanded else { return }
        // Календарь просим ДО анимации: раскрытие и запрос к EventKit
        // не должны конкурировать за главный поток на одном кадре.
        calendarService.refreshIfNeeded()
        NotchWindowController.shared.setKeyInputAllowed(true)
        withAnimation(Theme.openSpring) { isExpanded = true }
    }

    func collapse(immediate: Bool = false) {
        openTask?.cancel(); openTask = nil
        if immediate { closeTask?.cancel(); closeTask = nil }
        guard isExpanded || isDropTargeted else { return }
        NotchWindowController.shared.setKeyInputAllowed(false)
        withAnimation(Theme.closeSpring) {
            isExpanded = false
            isDropTargeted = false
        }
    }

    func toggleExpanded() {
        isExpanded ? collapse(immediate: true) : expand()
    }

    /// Файл затащили на свёрнутую чёлку — раскрываемся на «Полке».
    func dropEntered() {
        isDropTargeted = true
        expand(to: .shelf)
    }

    func dropExited() {
        isDropTargeted = false
    }

    // MARK: — подтверждения

    func flash(_ text: String) {
        flashTask?.cancel()
        withAnimation(Theme.quick) { flashText = text }
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled, let self else { return }
            withAnimation(Theme.quick) { self.flashText = nil }
        }
    }
}
