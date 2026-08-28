import AppKit

enum Haptics {
    /// Лёгкий отклик трекпада при попадании курсора в чёлку.
    @MainActor static func tap() {
        guard Settings.shared.hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    @MainActor static func level() {
        guard Settings.shared.hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
