import SwiftUI

/// СТАБ вкладки «Clipboard» — заменяется модулем.
struct ClipboardTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        EmptyHint(icon: "hammer", text: "Clipboard: модуль ещё не реализован")
    }
}
