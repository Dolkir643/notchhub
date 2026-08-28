import AppKit
import Combine

struct Snippet: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var value: String
}

/// Заготовки «название → значение».
/// СТАБ: реализация — модуль «Заготовки».
@MainActor final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []
    /// Строка поиска сверху.
    @Published var query: String = ""

    var filtered: [Snippet] { snippets }

    func start() {}
    func add(title: String, value: String) {}
    func update(_ snippet: Snippet) {}
    func delete(_ snippet: Snippet) {}
    /// Значение в буфер + подтверждение.
    func copy(_ snippet: Snippet) {}
    func save() {}
}
