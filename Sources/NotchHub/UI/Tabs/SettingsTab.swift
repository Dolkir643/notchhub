import AppKit
import SwiftUI

/// Вкладка «Настройки»: автозапуск, полка, буфер, поведение чёлки
/// и служебная строка с версией и кнопкой выхода.
struct SettingsTab: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var settings = Settings.shared

    @State private var loginState: LoginItem.State = .disabled
    @State private var approvalWatch: Task<Void, Never>?
    /// Меняется, когда система отказала: заставляет SwiftUI пересобрать сам
    /// переключатель, а не полагаться на сравнение неизменившегося значения.
    @State private var launchRevision = 0

    private static let retentionOptions = [0, 1, 3, 7, 30]
    private static let clipboardOptions = [20, 50, 100, 200]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TabHeader("Настройки")

            // Столбцы уравновешены по числу строк, ScrollView — страховка
            // на случай подписи про подтверждение автозапуска.
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        launchSection
                        notchSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        shelfSection
                        clipboardSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, 2)
            }
            .hubHideScrollIndicators()

            footer
        }
        .onAppear { refreshLoginState() }
        .onDisappear {
            approvalWatch?.cancel()
            approvalWatch = nil
        }
    }

    // MARK: — автозапуск

    private var launchSection: some View {
        SettingsSection("Автозапуск") {
            SettingsRow("Запускать при входе") {
                HStack(spacing: 5) {
                    if loginState == .enabled {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .hubForeground(Theme.accent)
                            .help("Автозапуск включён")
                    }
                    Toggle("Запускать при входе", isOn: launchBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .hubTint(Theme.accent)
                        .disabled(loginUnavailable)
                        .id(launchRevision)
                }
            }
            if let note = loginState.note {
                HStack(spacing: 6) {
                    Text(note)
                        .font(.system(size: 10))
                        .hubForeground(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if loginState == .requiresApproval {
                        Spacer(minLength: 2)
                        SettingsMiniButton("Открыть настройки") { LoginItem.openSettings() }
                    }
                }
            }
        }
    }

    private var loginUnavailable: Bool {
        if case .unavailable = loginState { return true }
        return false
    }

    private var launchBinding: Binding<Bool> {
        Binding(get: { settings.launchAtLogin }, set: { applyLaunch($0) })
    }

    private func applyLaunch(_ wanted: Bool) {
        let result = LoginItem.set(wanted)
        loginState = result
        // Система может не согласиться — тумблер показывает факт, а не желание.
        let actual: Bool
        switch result {
        case .enabled: actual = true
        case .requiresApproval: actual = wanted
        case .disabled, .unavailable: actual = false
        }
        // Пишем без сравнения: если значение уже равно фактическому, сравнение
        // съело бы единственное уведомление, и переключатель остался бы в том
        // положении, которое пользователь нарисовал мышью.
        settings.launchAtLogin = actual
        // Перерисовки родителя мало, когда SwiftUI считает значение неизменившимся:
        // отказ системы гасим пересозданием самого переключателя.
        if actual != wanted { launchRevision &+= 1 }
        watchApprovalIfNeeded()
    }

    private func refreshLoginState() {
        let fact = LoginItem.state
        loginState = fact
        // `launchAtLogin` — общий @Published: правка прямо в onAppear публикуется
        // внутри прохода отрисовки, поэтому уходим на следующий виток рунлупа.
        Task { @MainActor in syncStoredFlag(with: fact) }
        watchApprovalIfNeeded()
    }

    /// Подтягивает сохранённое значение под факт системы.
    private func syncStoredFlag(with fact: LoginItem.State) {
        let stored: Bool
        switch fact {
        case .enabled, .requiresApproval: stored = true
        case .disabled: stored = false
        case .unavailable: return // фактов нет — сохранённое значение не трогаем
        }
        if settings.launchAtLogin != stored { settings.launchAtLogin = stored }
    }

    /// Подтверждение выдаётся в «Объектах входа», уведомления об этом нет —
    /// пока вкладка открыта, тихо переспрашиваем статус.
    private func watchApprovalIfNeeded() {
        approvalWatch?.cancel()
        guard loginState == .requiresApproval else {
            approvalWatch = nil
            return
        }
        approvalWatch = Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                // Панель могли схлопнуть, а окна — пересоздать (`rebuild()`),
                // и тогда onDisappear не придёт: проверяем видимость сами.
                let shown = AppState.shared.isExpanded && AppState.shared.selectedTab == .settings
                guard shown else { return }
                let fact = LoginItem.state
                guard fact != .requiresApproval else { continue }
                loginState = fact
                syncStoredFlag(with: fact)
                return
            }
        }
    }

    // MARK: — полка

    private var shelfSection: some View {
        SettingsSection("Полка") {
            SettingsRow("Хранить файлы") {
                Picker("Хранить файлы", selection: snapped(\.shelfRetentionDays, Self.retentionOptions)) {
                    ForEach(Self.retentionOptions, id: \.self) { days in
                        Text(retentionTitle(days)).tag(days)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .hubTint(Theme.accent)
                .frame(width: 104)
            }
            SettingsRow("Ловить скриншоты") {
                Toggle("Ловить скриншоты", isOn: $settings.autoScreenshots)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .hubTint(Theme.accent)
            }
        }
    }

    private func retentionTitle(_ days: Int) -> String {
        guard days > 0 else { return "не чистить" }
        return "\(days) \(plural(days, "день", "дня", "дней"))"
    }

    // MARK: — буфер

    private var clipboardSection: some View {
        SettingsSection("Буфер") {
            SettingsRow("Следить за буфером") {
                Toggle("Следить за буфером", isOn: $settings.clipboardEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .hubTint(Theme.accent)
            }
            SettingsRow("Хранить записей") {
                Picker("Хранить записей", selection: snapped(\.clipboardLimit, Self.clipboardOptions)) {
                    ForEach(Self.clipboardOptions, id: \.self) { limit in
                        Text("\(limit)").tag(limit)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .hubTint(Theme.accent)
                .frame(width: 74)
                .disabled(!settings.clipboardEnabled)
            }
        }
    }

    // MARK: — чёлка

    private var notchSection: some View {
        SettingsSection("Чёлка") {
            SettingsRow("Раскрывать при наведении") {
                Toggle("Раскрывать при наведении", isOn: $settings.openOnHover)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .hubTint(Theme.accent)
            }
            SettingsRow("Задержка") {
                HStack(spacing: 6) {
                    Slider(value: $settings.hoverOpenDelay, in: 0...1.0, step: 0.05)
                        .controlSize(.small)
                        .hubTint(Theme.accent)
                        .frame(width: 104)
                    Text(delayLabel)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .hubForeground(Theme.secondaryText)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .disabled(!settings.openOnHover)
            .opacity(settings.openOnHover ? 1 : 0.45)

            SettingsRow("Ждать остановки") {
                Toggle("Ждать остановки", isOn: $settings.waitForStill)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .hubTint(Theme.accent)
            }
            .disabled(!settings.openOnHover)
            .opacity(settings.openOnHover ? 1 : 0.45)

            SettingsRow("Прятать в полноэкранных") {
                Toggle("Прятать в полноэкранных", isOn: $settings.hideInFullScreen)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .hubTint(Theme.accent)
            }

            SettingsRow(hotKeyTitle) {
                Toggle(hotKeyTitle, isOn: hotKeyBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .hubTint(Theme.accent)
            }

            SettingsRow("Отклик тачпада") {
                Toggle("Отклик тачпада", isOn: $settings.hapticsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .hubTint(Theme.accent)
            }
            SettingsRow("Только на встроенном экране") {
                Toggle("Только на встроенном экране", isOn: builtinOnlyBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .hubTint(Theme.accent)
            }
        }
    }

    /// Занятую другим приложением комбинацию честно называем занятой:
    /// молча неработающий переключатель выглядел бы поломкой.
    private var hotKeyTitle: String {
        HotKey.shared.isBlocked ? "⌃⌥Пробел (занят)" : "Клавиша ⌃⌥Пробел"
    }

    private var hotKeyBinding: Binding<Bool> {
        Binding(get: { settings.hotKeyEnabled },
                set: { value in
                    settings.hotKeyEnabled = value
                    HotKey.shared.apply(enabled: value)
                })
    }

    private var delayLabel: String {
        guard settings.hoverOpenDelay > 0 else { return "сразу" }
        return "\(Self.delayText(settings.hoverOpenDelay)) с"
    }

    /// Два знака после запятой в русской локали — «0,30».
    ///
    /// `FormatStyle` появился только в macOS 12, поэтому на Big Sur ту же строку
    /// собирает `NumberFormatter`: та же локаль (запятая), те же два знака и то же
    /// округление «к чётному», что у `.number`, — результат совпадает символ в символ.
    private static func delayText(_ value: Double) -> String {
        if #available(macOS 12.0, *) {
            return value.formatted(.number.precision(.fractionLength(2)).locale(Fmt.ru))
        }
        // Запасная ветка на случай отказа форматтера: разделитель всё равно русский,
        // иначе «0.30» выбилось бы из остальных подписей.
        return delayFormatter.string(from: NSNumber(value: value))
            ?? String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
    }

    private static let delayFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Fmt.ru
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.roundingMode = .halfEven
        return f
    }()

    private var builtinOnlyBinding: Binding<Bool> {
        Binding(get: { settings.builtinScreenOnly }, set: { value in
            settings.builtinScreenOnly = value
            // Пересоздание окон рвёт текущее представление — уходим из обработчика клика.
            Task { @MainActor in NotchWindowController.shared.rebuild() }
        })
    }

    // MARK: — нижняя строка

    private var footer: some View {
        HStack(spacing: 8) {
            Text(statusLine)
                .font(.system(size: 10))
                .hubForeground(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            SettingsMiniButton("Выйти", destructive: true) { NSApp.terminate(nil) }
        }
        .frame(height: 18)
    }

    private var statusLine: String {
        [versionText,
         "музыка: \(state.media.backend.label)",
         "полка: \(shelfText)"].joined(separator: "  ·  ")
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "v\(short) (\(build))"
        case let (short?, nil): return "v\(short)"
        case let (nil, build?): return "сборка \(build)"
        default: return "сборка из исходников"
        }
    }

    private var shelfText: String {
        let count = state.shelf.items.count
        guard count > 0 else { return "пусто" }
        return "\(count) \(plural(count, "файл", "файла", "файлов"))"
    }

    // MARK: — мелочи

    /// Значение из настроек может не совпасть ни с одним пунктом списка —
    /// показываем ближайший, иначе Picker остаётся пустым.
    private func snapped(_ keyPath: ReferenceWritableKeyPath<Settings, Int>, _ options: [Int]) -> Binding<Int> {
        Binding(get: {
            let value = settings[keyPath: keyPath]
            if options.contains(value) { return value }
            return options.min { abs($0 - value) < abs($1 - value) } ?? value
        }, set: { settings[keyPath: keyPath] = $0 })
    }

    private func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let hundred = n % 100
        if (11...14).contains(hundred) { return many }
        switch n % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }
}

// MARK: — кирпичики вкладки

/// Группа настроек: подпись и карточка со строками.
private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .hubForeground(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                content
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hubCard(10)
        }
    }
}

/// Строка «подпись слева — управление справа».
private struct SettingsRow<Control: View>: View {
    let title: String
    let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .hubForeground(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            control
        }
        .frame(height: 19)
    }
}

/// Маленькая кнопка-капсула под тёмную панель.
private struct SettingsMiniButton: View {
    let title: String
    let destructive: Bool
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .hubForeground(destructive ? Color(red: 1.0, green: 0.45, blue: 0.45) : Theme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.18 : 0.10)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
