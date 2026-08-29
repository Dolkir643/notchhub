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

    private var started = false
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

        let url = AppPaths.snippets
        io.async { [weak self] in
            var loaded: [Snippet]?
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                if let data = try? Data(contentsOf: url) {
                    loaded = try? JSONDecoder().decode([Snippet].self, from: data)
                }
                if loaded == nil {
                    // Файл есть, но не читается: отложим его в сторону, а не затрём молча.
                    let backup = url.deletingPathExtension().appendingPathExtension("broken.json")
                    try? fm.removeItem(at: backup)
                    try? fm.moveItem(at: url, to: backup)
                    Log.snippets.error("Файл заготовок не прочитан, отложен рядом")
                }
            }
            Task { @MainActor in self?.apply(loaded) }
        }
    }

    private func apply(_ loaded: [Snippet]?) {
        guard let loaded else {
            snippets = Self.starter
            save()
            Log.snippets.info("Заготовки созданы заново: \(self.snippets.count, privacy: .public)")
            return
        }
        let clean = Self.sanitized(loaded)
        snippets = clean
        Log.snippets.info("Заготовок загружено: \(clean.count, privacy: .public)")
        // Файл мог пережить прерванную правку: пустые огрызки и дубли чиним на месте.
        if clean.count != loaded.count { save() }
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
        snippets.append(Snippet(title: title, value: value))
        save()
    }

    /// Пустая заготовка в конце списка — её сразу открывает редактор.
    @discardableResult
    func addBlank() -> Snippet {
        let snippet = Snippet(title: "", value: "")
        snippets.append(snippet)
        save()
        return snippet
    }

    func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        guard snippets[index] != snippet else { return }
        snippets[index] = snippet
        save()
    }

    func delete(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets.remove(at: index)
        save()
    }

    /// Перенос строки на позицию `index` (перетаскивание внутри списка).
    func move(id: UUID, to index: Int) {
        guard let from = snippets.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(index, snippets.count - 1))
        guard from != target else { return }
        let item = snippets.remove(at: from)
        snippets.insert(item, at: target)
        save()
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
        let snapshot = snippets
        let url = AppPaths.snippets
        io.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                Log.snippets.error("Не удалось сохранить заготовки: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
