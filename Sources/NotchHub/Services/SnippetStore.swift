import AppKit
import Combine

struct Snippet: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var value: String

    var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Заготовки «название → значение».
/// Хранятся списком в JSON (`AppPaths.snippets`), чтение и запись — вне главного потока.
@MainActor final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []
    /// Строка поиска сверху.
    @Published var query: String = ""

    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?
    private let url: URL
    private var initialization: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var pending: [(inout [Snippet]) -> Void] = []
    private var started = false

    init(url: URL = AppPaths.snippets) { self.url = url }
    func waitUntilReady() async { await initialization?.value }
    func waitUntilSaved() async { await saveTask?.value }
    /// Последовательная очередь: чтение и все записи идут строго по порядку.
    private let io = DispatchQueue(label: "name.notchhub.snippets.io", qos: .utility)

    var filtered: [Snippet] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return snippets }
        return snippets.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.value.localizedCaseInsensitiveContains(needle)
        }
    }

    // MARK: — жизненный цикл

    func start() {
        guard !started else { return }
        started = true
        let url = self.url
        let io = self.io
        initialization = Task { [weak self] in
            let result: Result<[Snippet]?, Error> = await withCheckedContinuation { continuation in
                io.async {
                    continuation.resume(returning: Result {
                        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                        let data = try Data(contentsOf: url)
                        do { return try JSONDecoder().decode([Snippet].self, from: data) }
                        catch {
                            // Only a successful backup permits replacing a corrupt file.
                            let backup = url.appendingPathExtension("broken-\(UUID().uuidString).json")
                            try FileManager.default.copyItem(at: url, to: backup)
                            return nil
                        }
                    })
                }
            }
            guard let self else { return }
            switch result {
            case .success(let loaded):
                var values = Self.sanitized(loaded ?? Self.starter)
                for mutation in self.pending { mutation(&values) }
                let hadPending = !self.pending.isEmpty
                self.pending.removeAll()
                self.snippets = values
                self.isReady = true
                self.errorMessage = nil
                if loaded == nil || hadPending || loaded != values { self.save() }
            case .failure:
                self.errorMessage = "Не удалось загрузить заготовки. Исходный файл сохранён."
                self.started = false
            }
        }
    }

    private func mutate(_ operation: @escaping (inout [Snippet]) -> Void) {
        guard isReady else {
            pending.append(operation)
            start()
            return
        }
        operation(&snippets)
        save()
    }

    /// Выкидывает совсем пустые строки (осиротевшая «новая заготовка») и повторные id:
    /// одинаковые id ломают списки SwiftUI.
    private static func sanitized(_ list: [Snippet]) -> [Snippet] {
        var seen = Set<UUID>()
        return list.filter { snippet in
            guard !snippet.isBlank else { return false }
            return seen.insert(snippet.id).inserted
        }
    }

    /// Набор при первом запуске: названия готовы, значения человек заполняет сам.
    private static var starter: [Snippet] {
        [
            // Значения пустые: любое из них уехало бы в раздаваемую сборку
            // вшитым в бинарник — и досталось бы каждому, кто её поставит.
            Snippet(title: "Почта", value: ""),
            Snippet(title: "Телефон", value: ""),
            Snippet(title: "GitHub", value: ""),
            Snippet(title: "Telegram", value: ""),
            Snippet(title: "Рабочая почта", value: "")
        ]
    }

    // MARK: — правка

    func add(title: String, value: String) {
        let snippet = Snippet(title: title, value: value)
        mutate { $0.append(snippet) }
    }

    @discardableResult
    func addBlank() -> Snippet {
        let snippet = Snippet(title: "", value: "")
        mutate { $0.append(snippet) }
        return snippet
    }

    func update(_ snippet: Snippet) {
        mutate { values in
            if let index = values.firstIndex(where: { $0.id == snippet.id }) { values[index] = snippet }
        }
    }

    func delete(_ snippet: Snippet) {
        mutate { $0.removeAll { $0.id == snippet.id } }
    }

    func move(id: UUID, to index: Int) {
        mutate { values in
            guard let from = values.firstIndex(where: { $0.id == id }) else { return }
            let item = values.remove(at: from)
            values.insert(item, at: max(0, min(index, values.count)))
        }
    }

    func importData(_ data: Data) throws {
        let incoming = Self.sanitized(try JSONDecoder().decode([Snippet].self, from: data))
        mutate { values in
            for item in incoming where !values.contains(where: { $0.title == item.title && $0.value == item.value }) {
                values.append(Snippet(title: item.title, value: item.value))
            }
        }
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snippets)
    }

    /// Значение в буфер + подтверждение.
    func copy(_ snippet: Snippet) {
        let value = snippet.value
        guard !value.isEmpty else {
            AppState.shared.flash("Заготовка пуста")
            return
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(value, forType: .string)
        AppState.shared.flash("Скопировано")
        Haptics.tap()
    }

    // MARK: — диск

    func save() {
        guard isReady else { return }
        let snapshot = snippets
        let url = self.url
        let io = self.io
        let previous = saveTask
        saveTask = Task { [weak self] in
            await previous?.value
            let error: String? = await withCheckedContinuation { continuation in
                io.async {
                    do {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(snapshot).write(to: url, options: .atomic)
                        continuation.resume(returning: nil)
                    } catch { continuation.resume(returning: error.localizedDescription) }
                }
            }
            self?.errorMessage = error.map { "Заготовки не сохранены: \($0)" }
        }
    }
}
