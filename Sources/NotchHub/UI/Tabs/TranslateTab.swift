import SwiftUI

/// СТАБ вкладки «Translate» — заменяется модулем.
struct TranslateTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        EmptyHint(icon: "hammer", text: "Translate: модуль ещё не реализован")
    }
}
