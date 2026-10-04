import SwiftUI

struct KeepAwakeControls: View {
    @ObservedObject var service: KeepAwakeService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: service.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .hubForeground(Theme.accent)
                Text(service.isActive ? service.remainingTitle : "Разрешать Mac работать без сна")
                    .font(.system(size: 11))
                Spacer(minLength: 4)
                Button(service.isActive ? "Выключить" : "Включить") {
                    if service.isActive { service.endSession() }
                    else { service.beginSession() }
                }
                .controlSize(.small)
                .disabled(service.pendingRestoration)
            }

            HStack {
                Text("Продолжительность").font(.system(size: 11))
                Spacer()
                Picker("Продолжительность", selection: $service.duration) {
                    ForEach(KeepAwakeDuration.allCases) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 145)
            }
            .disabled(service.isActive || service.pendingRestoration)

            VStack(alignment: .leading, spacing: 5) {
                Toggle("Не гасить экран", isOn: $service.keepDisplayAwake)
                Toggle("Только при подключённом питании", isOn: $service.powerOnly)
                Toggle("Продолжать работу с закрытой крышкой", isOn: $service.allowClosedLid)
            }
            .font(.system(size: 11))
            .toggleStyle(.checkbox)
            .disabled(service.isActive || service.pendingRestoration)

            Text("На батарее режим выключается при заряде 15%. После перезапуска приложения его нужно включить заново.")
                .font(.system(size: 10))
                .hubForeground(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if service.allowClosedLid {
                Text("Закрытая крышка: macOS запросит пароль администратора на этот сеанс, максимум на 8 часов. Оставляйте Mac на открытой поверхности: в сумке он может перегреться.")
                    .font(.system(size: 10))
                    .hubForeground(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let phaseText {
                Text(phaseText)
                    .font(.system(size: 10, weight: .medium))
                    .hubForeground(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = service.statusMessage {
                Text(message)
                    .font(.system(size: 10))
                    .hubForeground(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var phaseText: String? {
        switch service.lidPhase {
        case .authorizing: return "Подтвердите системный запрос. Закрывайте крышку после появления статуса «включён»."
        case .active: return "Режим закрытой крышки включён."
        case .restoring: return "Восстанавливаем обычный системный сон…"
        case .idle, .failed: return nil
        }
    }
}
