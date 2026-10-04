import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Добро пожаловать в NotchHub").font(.system(size: 18, weight: .semibold))
            Text("Всё нужное — у верхнего края экрана.").font(.system(size: 12)).hubForeground(Theme.secondaryText)
            tip("keyboard", "⌃⌥Пробел — открыть. ⌘1–7 — вкладки. Esc — закрыть.")
            tip("tray", "Перетащите файлы сюда. Закреплённые файлы не очищаются.")
            tip("doc.on.clipboard", "История буфера хранится до выхода. Правый клик — быстрые действия.")
            HStack {
                Spacer()
                Button("Начать") {
                    state.settings.onboardingComplete = true
                    state.expand(to: .clipboard, keyboard: true)
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .hubForeground(.white)
    }
    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).hubForeground(Theme.accent)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
