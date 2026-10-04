import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

/// Запись истории буфера обмена.
struct ClipItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case text(String)
        case url(URL)
        case files([URL])
        case image(NSImage)
    }

    let id: UUID
    let date: Date
    let kind: Kind
    /// Отпечаток содержимого: по нему ловим повторы, не сравнивая мегабайты данных.
    let signature: String
    /// Исходные байты для вставки; NSImage в kind служит только превью.
    let originalImageData: Data?

    init(id: UUID = UUID(), date: Date = Date(), kind: Kind, signature: String? = nil, originalImageData: Data? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.originalImageData = originalImageData
        self.signature = signature ?? kind.defaultSignature
    }

    var searchableText: String {
        switch kind {
        case .text(let text): return text
        case .files(let urls): return urls.map(\.path).joined(separator: "\n")
        case .url(let url): return url.isFileURL ? url.path : url.absoluteString
        case .image: return "Изображение"
        }
    }
    var textValue: String? {
        switch kind {
        case .text(let text): return text
        case .url(let url) where !url.isFileURL: return url.absoluteString
        default: return nil
        }
    }
    var fileURLs: [URL] {
        switch kind {
        case .files(let urls): return urls
        case .url(let url) where url.isFileURL: return [url]
        default: return []
        }
    }
    var isImage: Bool { if case .image = kind { return true }; return false }

    /// Сколько символов показываем. Поиск работает отдельно по полному содержимому. В строку влезает
    /// пара сотен, а скопировать могут и мегабайтный лог: и разбор такого текста,
    /// и вёрстка его в `Text` вешают главный поток на каждой перерисовке.
    static let previewLimit = 500

    var preview: String {
        switch kind {
        case .text(let s):
            // prefix — до чистки: она сама по себе проходит всю строку.
            return s.prefix(Self.previewLimit)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
        case .url(let u):
            // Путь и кириллица читаются лучше, чем file:///…%D0%9F… и /wiki/%D0%9A%D0%BE%D1%82.
            // В буфер при этом вернётся исходный, закодированный адрес.
            let raw = u.isFileURL ? u.path : u.absoluteString
            return raw.removingPercentEncoding ?? raw
        case .files(let urls): return "\(urls.count) файлов · " + urls.map(\.lastPathComponent).joined(separator: ", ")
        case .image: return "Изображение"
        }
    }

    var icon: String {
        switch kind {
        case .text: return "text.alignleft"
        case .url: return "link"
        case .files: return "doc.on.doc"
        case .image: return "photo"
        }
    }

    static func == (a: ClipItem, b: ClipItem) -> Bool { a.id == b.id }
}

extension ClipItem.Kind {
    /// Хэш вместо самого значения: история держит до 50 записей, копий текста хватит и без этого.
    var defaultSignature: String {
        switch self {
        case .text(let s): return "t:\(s.utf8.count):\(ClipSignature.hash(s))"
        case .url(let u): return "u:\(u.absoluteString)"
        case .files(let urls): return "f:" + urls.map(\.absoluteString).joined(separator: "\n")
        case .image(let i): return "i:\(UInt(bitPattern: ObjectIdentifier(i).hashValue))"
        }
    }
}

/// Отпечаток текста по байтам.
///
/// `String.hashValue` и `String.count` нормализуют юникод и обходят строку посимвольно:
/// на мегабайтном тексте это сотни миллисекунд заблокированного главного потока
/// (на строке-мосте из NSPasteboard — секунды). Байты дают тот же ответ в разы дешевле.
enum ClipSignature {
    static func hash(_ s: String) -> Int {
        var hasher = Hasher()
        let done: Bool? = s.utf8.withContiguousStorageIfAvailable { buffer in
            hasher.combine(bytes: UnsafeRawBufferPointer(buffer))
            return true
        }
        if done != true {
            // Строка без сплошного хранилища (мост на NSString) — копируем байты.
            Array(s.utf8).withUnsafeBytes { hasher.combine(bytes: $0) }
        }
        return hasher.finalize()
    }
}

/// История буфера обмена (поллинг changeCount).
///
/// Содержимое читается только когда счётчик изменился: чтение на каждом тике
/// греет систему и заставляет менеджеры паролей считать, что за ними следят.
/// Всё живёт в памяти — на диск история буфера не пишется.
@MainActor final class ClipboardService: ObservableObject {
    @Published private(set) var items: [ClipItem] = [] { didSet { scheduleSearch() } }
    @Published var searchQuery = "" { didSet { scheduleSearch() } }
    @Published private(set) var searchMatches: Set<UUID>?
    @Published private(set) var isSearching = false
    private var searchTask: Task<Void, Never>?
    private var searchRevision = 0
    var searchResults: [ClipItem] {
        guard let matches = searchMatches else { return items }
        return items.filter { matches.contains($0.id) }
    }
    func waitForSearch() async { await searchTask?.value }
    private func scheduleSearch() {
        searchTask?.cancel()
        searchRevision &+= 1
        let revision = searchRevision
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchMatches = nil; isSearching = false; return }
        let documents = items.map { ($0.id, $0.searchableText) }
        searchMatches = [] // A changed query must never expose a stale row to Enter.
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) {
                Set(documents.filter { $0.1.localizedCaseInsensitiveContains(query) }.map { $0.0 })
            }.value
            guard !Task.isCancelled, let self, self.searchRevision == revision else { return }
            self.searchMatches = matches
            self.isSearching = false
        }
    }

    /// Метки Pasteboard, которыми 1Password и другие помечают приватные вставки.
    /// Проверяются до чтения содержимого.
    private static let privateTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType"
    ]

    private static let pollInterval: TimeInterval = 0.3

    private let pasteboard: NSPasteboard
    private var generation = 0
    static let memoryLimit = 64 * 1024 * 1024

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }
    private let settings = Settings.shared

    private var timer: Timer?
    private var lastChangeCount = 0
    private var bag = Set<AnyCancellable>()

    // MARK: — жизненный цикл

    func start() {
        // То, что лежало в буфере до запуска, не забираем: там может быть чужой пароль.
        lastChangeCount = pasteboard.changeCount

        guard bag.isEmpty else { return }
        settings.$clipboardEnabled
            .sink { [weak self] enabled in
                // @Published отдаёт значение до присвоения, поэтому смотрим на пришедшее.
                if enabled { self?.startTimer() } else { self?.stopTimer() }
            }
            .store(in: &bag)
        settings.$clipboardLimit
            .sink { [weak self] limit in self?.trim(to: limit) }
            .store(in: &bag)
    }

    func stop() {
        stopTimer()
        bag.removeAll()
    }

    private func startTimer() {
        guard timer == nil else { return }
        // Скопированное при выключенном слежении в историю не подтягиваем.
        lastChangeCount = pasteboard.changeCount

        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            // Таймер главного цикла — значит, уже на главном акторе.
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1
        // .common — иначе поллинг замирает на время меню и скролла.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.clipboard.info("слежение за буфером включено")
    }

    private func stopTimer() {
        generation &+= 1
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        Log.clipboard.info("слежение за буфером выключено")
    }

    // MARK: — опрос

    private func tick() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard settings.clipboardEnabled else { return }
        capture()
    }

    func capture() {
        guard !isPrivate() else {
            Log.clipboard.debug("запись помечена как приватная — пропущена")
            return
        }

        let urls = fileURLs()
        if !urls.isEmpty {
            push(kind: .files(urls))
            return
        }

        if let raw = pasteboardText() {
            guard raw.utf8.count <= Self.memoryLimit else { return }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if let link = webURL(from: text) {
                push(kind: .url(link))
            } else {
                push(kind: .text(raw))
            }
            return
        }

        if let data = imageData() {
            captureImage(data)
        }
    }

    /// Хоть одна приватная метка на самом Pasteboard или на любом его элементе.
    private func isPrivate() -> Bool {
        if let types = pasteboard.types, types.contains(where: { Self.privateTypes.contains($0.rawValue) }) {
            return true
        }
        guard let items = pasteboard.pasteboardItems else { return false }
        return items.contains { item in
            item.types.contains { Self.privateTypes.contains($0.rawValue) }
        }
    }

    /// Текст буфера обычной swift-строкой.
    ///
    /// `string(forType:)` отдаёт строку-мост на NSString: обрезка мегабайтного текста
    /// такой строки занимает больше полсекунды, а длина — секунду с лишним, и всё это
    /// на главном потоке. Из байтов получается обычная строка, и те же операции —
    /// миллисекунды. `string(forType:)` остаётся запасным путём для нестандартных меток.
    private func pasteboardText() -> String? {
        if let data = pasteboard.data(forType: .string),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return pasteboard.string(forType: .string)
    }

    private func fileURLs() -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .map(\.standardizedFileURL)
    }

    private func webURL(from text: String) -> URL? {
        // utf8.count — O(1) для обычной строки, в отличие от count с его посимвольным обходом.
        guard text.utf8.count <= 2048, !text.contains(" "),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return url.host == nil ? nil : url
        case "file": return url
        default: return nil
        }
    }

    private func imageData() -> Data? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), !data.isEmpty { return data }
        }
        return nil
    }

    /// Скриншот может весить десятки мегабайт — уменьшаем и хэшируем вне главного актора.
    @discardableResult
    func captureImage(_ data: Data) -> Task<Void, Never> {
        let token = generation
        return Task { [weak self] in
            guard data.count <= Self.memoryLimit else { return }
            let thumb = await Task.detached(priority: .utility) {
                ClipThumbnail.make(from: data)
            }.value
            guard let self, let thumb, self.generation == token,
                  self.settings.clipboardEnabled, let image = NSImage(data: thumb.png) else { return }
            self.push(kind: .image(image), signature: thumb.signature, originalImageData: data)
        }
    }

    // MARK: — история

    private func push(kind: ClipItem.Kind, signature: String? = nil, originalImageData: Data? = nil) {
        let sign = signature ?? kind.defaultSignature

        // Повтор того же значения не плодит запись — только освежает дату и поднимает наверх.
        if let index = items.firstIndex(where: { $0.signature == sign }) {
            let old = items[index]
            let refreshed = ClipItem(id: old.id, date: Date(), kind: old.kind, signature: old.signature, originalImageData: old.originalImageData)
            if index == 0 {
                items[0] = refreshed
            } else {
                items.remove(at: index)
                items.insert(refreshed, at: 0)
            }
            return
        }

        items.insert(ClipItem(kind: kind, signature: sign, originalImageData: originalImageData), at: 0)
        trim(to: settings.clipboardLimit)
    }

    private func trim(to limit: Int) {
        let maxCount = max(5, limit)
        if items.count > maxCount { items.removeLast(items.count - maxCount) }
        func byteCount(_ item: ClipItem) -> Int {
            if let data = item.originalImageData { return data.count }
            switch item.kind {
            case .text(let text): return text.utf8.count
            case .url(let url): return url.absoluteString.utf8.count
            case .files(let urls): return urls.reduce(0) { $0 + $1.absoluteString.utf8.count }
            case .image: return 0
            }
        }
        var bytes = items.reduce(0) { $0 + byteCount($1) }
        while bytes > Self.memoryLimit, let oldest = items.last {
            bytes -= byteCount(oldest)
            items.removeLast()
        }
    }

    // MARK: — действия

    /// Положить запись обратно в буфер обмена.
    func copyBack(_ item: ClipItem) {
        switch item.kind {
        case .text(let s):
            pasteboard.clearContents()
            pasteboard.setString(s, forType: .string)
        case .url(let u):
            pasteboard.clearContents()
            // NSURL кладёт только public.url (и file-url с NSFilenamesPboardType) —
            // без текстовой метки Cmd-V в любое текстовое поле вставит пустоту.
            pasteboard.writeObjects([u as NSURL])
            pasteboard.setString(u.isFileURL ? u.path : u.absoluteString, forType: .string)
        case .files(let urls):
            pasteboard.clearContents()
            pasteboard.writeObjects(urls.map { $0 as NSURL })
        case .image(let image):
            // Сначала данные, потом clearContents: иначе на битой картинке
            // мы бы просто стёрли пользователю буфер и ничего не положили взамен.
            if let original = item.originalImageData,
               let source = CGImageSourceCreateWithData(original as CFData, nil),
               let type = CGImageSourceGetType(source) {
                pasteboard.clearContents()
                pasteboard.setData(original, forType: NSPasteboard.PasteboardType(type as String))
            } else {
                guard let tiff = image.tiffRepresentation else { return }
                pasteboard.clearContents()
                pasteboard.setData(tiff, forType: .tiff)
            }
        }
        // Своя же запись не должна вернуться в историю дублем на следующем тике.
        lastChangeCount = pasteboard.changeCount

        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let old = items[index]
            let refreshed = ClipItem(id: old.id, date: Date(), kind: old.kind, signature: old.signature, originalImageData: old.originalImageData)
            items.remove(at: index)
            items.insert(refreshed, at: 0)
        }
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
    }

    func clearAll() {
        generation &+= 1
        items.removeAll()
    }
}

/// Превью картинки: считается в фоне, наружу отдаёт только Sendable-значения.
enum ClipThumbnail {
    /// Максимальная сторона превью, px: держать в памяти исходные скриншоты незачем.
    static let maxPixel: CGFloat = 400

    static func make(from data: Data) -> (png: Data, signature: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }

        var hasher = Hasher()
        hasher.combine(data)
        return (out as Data, "i:\(data.count):\(hasher.finalize())")
    }
}
