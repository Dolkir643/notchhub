import SwiftUI

/// СТАБ вкладки «Calendar» — заменяется модулем.
struct CalendarTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        EmptyHint(icon: "hammer", text: "Calendar: модуль ещё не реализован")
    }
}
