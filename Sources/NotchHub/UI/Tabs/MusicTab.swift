import SwiftUI

/// СТАБ вкладки «Music» — заменяется модулем.
struct MusicTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        EmptyHint(icon: "hammer", text: "Music: модуль ещё не реализован")
    }
}
