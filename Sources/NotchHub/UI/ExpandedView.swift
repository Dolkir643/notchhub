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
        VStack(spacing: 4) {
            ForEach(NotchTab.available) { tab in
                TabButton(tab: tab, selected: state.selectedTab == tab, badge: badge(for: tab)) {
                    withAnimation(Theme.quick) { state.selectedTab = tab }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(width: Theme.sidebarWidth)
    }

    private func badge(for tab: NotchTab) -> Int {
        switch tab {
        case .shelf: return state.shelf.items.count
        case .clipboard: return 0
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
                    .foregroundStyle(selected ? .white : .white.opacity(0.6))
                if badge > 0 {
                    Text("\(min(badge, 99))")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent))
                        .offset(x: 12, y: -10)
                }
            }
            .frame(width: 36, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .onHover { hovering = $0 }
    }
}
