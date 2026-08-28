import Foundation
import os

enum Log {
    static let window = Logger(subsystem: subsystem, category: "window")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let shelf = Logger(subsystem: subsystem, category: "shelf")
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let snippets = Logger(subsystem: subsystem, category: "snippets")
    static let calendar = Logger(subsystem: subsystem, category: "calendar")
    static let translate = Logger(subsystem: subsystem, category: "translate")
    static let app = Logger(subsystem: subsystem, category: "app")

    private static let subsystem = "name.notchhub.NotchHub"
}

/// Каталог приложения: ~/Library/Application Support/NotchHub
enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("NotchHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let shelf: URL = {
        let url = root.appendingPathComponent("Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let shelfIndex = root.appendingPathComponent("shelf.json")
    static let snippets = root.appendingPathComponent("snippets.json")
}
