import SwiftUI

/// СТАБ вкладки «Snippets» — заменяется модулем.
struct SnippetsTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        EmptyHint(icon: "hammer", text: "Snippets: модуль ещё не реализован")
    }
}
