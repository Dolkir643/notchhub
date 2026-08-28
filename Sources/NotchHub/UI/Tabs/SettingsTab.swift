import SwiftUI

/// СТАБ вкладки «Settings» — заменяется модулем.
struct SettingsTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        EmptyHint(icon: "hammer", text: "Settings: модуль ещё не реализован")
    }
}
