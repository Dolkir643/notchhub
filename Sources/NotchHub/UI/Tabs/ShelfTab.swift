import SwiftUI

/// СТАБ вкладки «Shelf» — заменяется модулем.
struct ShelfTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        EmptyHint(icon: "hammer", text: "Shelf: модуль ещё не реализован")
    }
}
