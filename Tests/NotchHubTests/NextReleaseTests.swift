import AppKit
import Testing
@testable import NotchHub

@Suite @MainActor
struct DataSafetyTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func addingDuringLoadKeepsBothListsOnDisk() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("snippets.json")
        try JSONEncoder().encode([Snippet(title: "Existing", value: "Keep")]).write(to: url)
        let store = SnippetStore(url: url)
        store.start()
        store.add(title: "New", value: "  line 1\nline 2\n")
        await store.waitUntilReady()
        await store.waitUntilSaved()
        let saved = try JSONDecoder().decode([Snippet].self, from: Data(contentsOf: url))
        #expect(saved.map(\.title) == ["Existing", "New"])
        #expect(saved == store.snippets)
        #expect(saved.last?.value == "  line 1\nline 2\n")
    }

    @Test func unreadableSnippetsNeverOverwritten() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("snippets.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let store = SnippetStore(url: url)
        store.start()
        store.add(title: "New", value: "Queued")
        await store.waitUntilReady()
        #expect(!store.isReady)
        #expect(store.errorMessage != nil)
        #expect((try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
    }

    @Test func corruptSnippetsBackedUpBeforeRecovery() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("snippets.json")
        let broken = Data("{broken".utf8)
        try broken.write(to: url)
        let store = SnippetStore(url: url)
        store.start()
        await store.waitUntilReady()
        await store.waitUntilSaved()
        let backup = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains("broken-") })
        #expect(try Data(contentsOf: backup) == broken)
        #expect(store.isReady)
    }

    @Test func importPreservesMultilineAndDeduplicatesContent() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnippetStore(url: root.appendingPathComponent("snippets.json"))
        let incoming = [Snippet(title: "Address", value: "  A\nB\n")]
        let data = try JSONEncoder().encode(incoming)
        try store.importData(data)
        await store.waitUntilReady()
        try store.importData(data)
        await store.waitUntilSaved()
        #expect(store.snippets.filter { $0.title == "Address" }.count == 1)
        #expect(store.snippets.last?.value == incoming.first?.value)
    }

    @Test func editedTranslationCannotBeCopiedOrSwappedAsFresh() throws {
        guard TranslateService.isSupported else { return }
        let service = TranslateService()
        service.input = "Hello"
        service.receive("Привет")
        service.input = "New text"
        service.inputChanged()
        #expect(service.output.isEmpty)
        #expect(service.status == .translating)
        service.swap()
        #expect(service.input == "New text")
    }

    @Test func multipleFilesRoundTrip() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let files = [URL(fileURLWithPath: "/tmp/one.txt"), URL(fileURLWithPath: "/tmp/two.txt")]
        #expect(board.writeObjects(files.map { $0 as NSURL }))
        let service = ClipboardService(pasteboard: board)
        service.capture()
        let item = try #require(service.items.first)
        #expect(item.fileURLs == files.map(\.standardizedFileURL))
        service.copyBack(item)
        #expect((board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.count == 2)
    }

    @Test func searchUsesFullTextAndLatestQuery() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let service = ClipboardService(pasteboard: board)
        board.setString(String(repeating: "a", count: 800) + " needle", forType: .string)
        service.capture()
        service.searchQuery = "needle"
        await service.waitForSearch()
        #expect(service.searchResults.count == 1)
        service.searchQuery = "needle"
        service.searchQuery = "absent"
        #expect(service.searchResults.isEmpty)
        await service.waitForSearch()
        #expect(service.searchResults.isEmpty)
        service.searchQuery = ""
        #expect(service.searchResults.count == 1)
    }

    @Test func versionComparisonAndMeetingLinks() {
        #expect(UpdateService.isNewer("v1.10", than: "1.9"))
        #expect(!UpdateService.isNewer("1.3.0", than: "1.3"))
        #expect(!UpdateService.isNewer("v1.4-beta", than: "1.3"))
        #expect(MeetingLink.find(url: nil, text: "Join https://meet.google.com/abc-defg-hij")?.host == "meet.google.com")
        #expect(MeetingLink.find(url: nil, text: "https://zoom.us.evil.test/j/123") == nil)
        #expect(MeetingLink.find(url: URL(string: "file:///tmp/private"), text: "") == nil)
    }

    @Test func expiryUsesTrashAndKeepsPinnedAndFailedFiles() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let shelfURL = root.appendingPathComponent("Shelf")
        try FileManager.default.createDirectory(at: shelfURL, withIntermediateDirectories: true)
        let store = ShelfStore(shelfURL: shelfURL, indexURL: root.appendingPathComponent("shelf.json"))
        let source = root.appendingPathComponent("source.txt")
        try Data("important".utf8).write(to: source)
        let unpinned = try #require(store.copyIn(source, isScreenshot: false))
        var pinned = try #require(store.copyIn(source, isScreenshot: false))
        pinned.pinned = true
        store.save([unpinned, pinned])
        var requested: [URL] = []
        let service = ShelfService(store: store, recycle: { urls, complete in
            requested = urls
            complete([:], NSError(domain: "Recycle failure", code: 1))
        })
        service.start()
        defer { service.stop() }
        await service.waitUntilReady()
        service.cleanupExpired(now: Date().addingTimeInterval(5 * 86400), retentionDays: 3)
        #expect(requested == [store.url(for: unpinned)])
        #expect(FileManager.default.fileExists(atPath: store.url(for: unpinned).path))
        #expect(service.items.count == 2)
        #expect(try store.loadRecovering().first { $0.id == pinned.id }?.isPinned == true)
    }
}
