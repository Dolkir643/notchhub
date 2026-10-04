import Foundation

/// Метаданные оригинала: полка получает копию только по явному действию.
struct ShelfDownloadSnapshot: Equatable, Sendable {
    let url: URL
    let size: Int64
    let modified: Date
    let fileNumber: UInt64

    static func read(_ url: URL) throws -> ShelfDownloadSnapshot? {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let size = values[.size] as? NSNumber,
              let modified = values[.modificationDate] as? Date,
              let number = values[.systemFileNumber] as? NSNumber else { return nil }
        return ShelfDownloadSnapshot(url: url.standardizedFileURL, size: size.int64Value,
                                     modified: modified, fileNumber: number.uint64Value)
    }
}

enum ShelfDownloadsScanner {
    /// Также учитываем служебные каталоги Safari и sidecar-файлы aria2.
    private static let unfinishedSuffixes = [
        ".crdownload", ".download", ".part", ".partial", ".tmp", ".temp",
        ".opdownload", ".filepart", ".aria2", ".!qb", ".!ut"
    ]

    static func unfinishedOriginalName(_ name: String) -> String? {
        guard let suffix = unfinishedSuffixes.first(where: { name.lowercased().hasSuffix($0) }) else {
            return nil
        }
        let original = String(name.dropLast(suffix.count))
        return unfinishedOriginalName(original) ?? original
    }

    static func read(directory: URL, limit: Int = 100) throws -> [ShelfDownloadSnapshot] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: nil)
        // На стандартном нечувствительном к регистру APFS имена совпадают и с разным регистром.
        let unfinished = Set(urls.compactMap { unfinishedOriginalName($0.lastPathComponent)?.lowercased() })
        let candidates = urls.compactMap { url -> ShelfDownloadSnapshot? in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), unfinishedOriginalName(name) == nil,
                  !unfinished.contains(name.lowercased()) else { return nil }
            // Файл мог исчезнуть между перечислением каталога и чтением метаданных.
            return try? ShelfDownloadSnapshot.read(url)
        }
        return Array(candidates.sorted {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.url.path < $1.url.path
        }.prefix(max(0, limit)))
    }

    static func isCurrent(_ snapshot: ShelfDownloadSnapshot, in directory: URL) throws -> Bool {
        // Перепроверяем и временный сосед: он может появиться до доставки события слежения.
        try read(directory: directory, limit: Int.max).contains(snapshot)
    }
}

struct ShelfDownload: Identifiable, Equatable {
    let snapshot: ShelfDownloadSnapshot
    let isReady: Bool
    var id: URL { snapshot.url }
    var url: URL { snapshot.url }
    var name: String { url.lastPathComponent }
    var size: Int64 { snapshot.size }
    var modified: Date { snapshot.modified }
}

/// Без общего непрерывного опроса: повторные выборки нужны только ещё меняющимся файлам.
/// Стабильность — эвристика для произвольных писателей, не обещание окончания загрузки.
struct ShelfDownloadsReadiness {
    private struct Observation {
        let snapshot: ShelfDownloadSnapshot
        let since: TimeInterval
        var sampledAt: TimeInterval
        var samples: Int
    }

    private var observations: [URL: Observation] = [:]
    private(set) var hasPendingFiles = false

    mutating func invalidate(_ url: URL) { observations[url] = nil }

    mutating func update(_ snapshots: [ShelfDownloadSnapshot], at time: TimeInterval) -> [ShelfDownload] {
        let existing = Set(snapshots.map(\.url))
        observations = observations.filter { existing.contains($0.key) }
        hasPendingFiles = false
        return snapshots.map { snapshot in
            var current: Observation
            if let previous = observations[snapshot.url], previous.snapshot == snapshot {
                current = previous
                // Частые события каталога не заменяют независимые замеры во времени.
                if time - current.sampledAt >= 0.9 {
                    current.samples += 1
                    current.sampledAt = time
                }
            } else {
                current = Observation(snapshot: snapshot, since: time, sampledAt: time, samples: 1)
            }
            observations[snapshot.url] = current
            let ready = current.samples >= 3 && time - current.since >= 2
            if !ready { hasPendingFiles = true }
            return ShelfDownload(snapshot: snapshot, isReady: ready)
        }
    }
}
