import SwiftUI

/// Полная панель: слева колонка вкладок, справа содержимое.
struct ExpandedView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            TabColumn()
            Divider().overlay(Color.white.opacity(0.08))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch state.selectedTab {
        case .music: MusicTab()
        case .shelf: ShelfTab()
        case .clipboard: ClipboardTab()
        case .snippets: SnippetsTab()
        case .calendar: CalendarTab()
        case .translate: TranslateTab()
        case .settings: SettingsTab()
        }
    }
}

/// Вертикальная колонка вкладок-иконок.
struct TabColumn: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        // Ни распорки, ни вертикальных отступов: колонку по высоте центрует
        // сам HStack панели. С распоркой внизу иконки прижимались к верху.
        VStack(spacing: Theme.tabSpacing) {
            ForEach(NotchTab.available) { tab in
                TabButton(tab: tab, selected: state.selectedTab == tab, badge: badge(for: tab)) {
                    withAnimation(Theme.quick) { state.selectedTab = tab }
                }
            }
        }
        .frame(width: Theme.sidebarWidth)
    }

    private func badge(for tab: NotchTab) -> Int {
        switch tab {
        case .shelf: return state.shelf.items.count
        case .clipboard: return state.clipboard.items.count
        default: return 0
        }
    }
}

private struct TabButton: View {
    let tab: NotchTab
    let selected: Bool
    let badge: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.16) : (hovering ? Color.white.opacity(0.08) : .clear))
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: .medium))
                    .hubForeground(selected ? .white : .white.opacity(0.6))
                    // Символы разной ширины (нотка — 8 pt, шестерёнка — 16 pt)
                    // сами по себе центруются по своей рамке, а не по оптическому
                    // центру ряда. Общая рамка выравнивает их между собой.
                    .frame(width: 18, height: 18)
                if badge > 0 {
                    Text("\(min(badge, 99))")
                        .font(.system(size: 8, weight: .bold))
                        .hubForeground(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent))
                        .offset(x: 12, y: -10)
                }
            }
            .frame(width: Theme.tabButton, height: Theme.tabButton)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .onHover { hovering = $0 }
    }
}
