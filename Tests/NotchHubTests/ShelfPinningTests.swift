import XCTest
import AppKit
@testable import NotchHub

final class ShelfPinningTests: XCTestCase {
    private var root: URL!
    private var store: ShelfStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shelf = root.appendingPathComponent("Shelf")
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        store = ShelfStore(shelfURL: shelf, indexURL: root.appendingPathComponent("shelf.json"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String) throws -> ShelfItem {
        let url = root.appendingPathComponent(name)
        try Data("original \(name)".utf8).write(to: url)
        return try XCTUnwrap(store.copyIn(url, isScreenshot: false))
    }

    func testLegacyIndexRetainsItemsWithoutPinField() throws {
        let item = try file("old.txt")
        XCTAssertTrue(store.save([item]))
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.indexURL))
            as? [[String: Any]])
        entries[0].removeValue(forKey: "isPinned")
        entries[0].removeValue(forKey: "pinned")
        try JSONSerialization.data(withJSONObject: entries).write(to: store.indexURL)
        let restored = try XCTUnwrap(store.loadRecovering().first)
        XCTAssertEqual(restored.id, item.id)
        XCTAssertFalse(restored.isPinned)
        XCTAssertEqual(restored.added.timeIntervalSince1970, item.added.timeIntervalSince1970, accuracy: 1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains(where: { $0.contains("broken-") }))
    }

    func testPinFieldsFromBothIndexVersionsSurviveUpgrade() throws {
        let item = try file("keep.txt")
        for field in ["isPinned", "pinned"] {
            XCTAssertTrue(store.save([item]))
            var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.indexURL))
                as? [[String: Any]])
            entries[0].removeValue(forKey: "isPinned")
            entries[0].removeValue(forKey: "pinned")
            entries[0][field] = true
            try JSONSerialization.data(withJSONObject: entries).write(to: store.indexURL)

            let restored = try XCTUnwrap(store.loadRecovering().first)
            XCTAssertEqual(restored.id, item.id, field)
            XCTAssertTrue(restored.isPinned, "The \(field) index must keep its pin during upgrade")
            XCTAssertEqual(restored.added.timeIntervalSince1970, item.added.timeIntervalSince1970,
                           accuracy: 1, field)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains(where: { $0.contains("broken-") }))
    }

    func testPinWritesCanonicalReleasedIndexField() throws {
        var item = try file("canonical.txt")
        item.isPinned = true
        XCTAssertTrue(store.save([item]))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.indexURL))
            as? [[String: Any]])
        XCTAssertEqual(entries[0]["pinned"] as? Bool, true)
        XCTAssertNil(entries[0]["isPinned"])
        let restored = try XCTUnwrap(store.loadRecovering().first)
        XCTAssertEqual(restored.id, item.id)
        XCTAssertTrue(restored.isPinned)
    }

    @MainActor
    func testPinIsPersistedAndBulkClearLeavesPinnedFile() async throws {
        let pinned = try file("keep.txt")
        let loose = try file("loose.txt")
        XCTAssertTrue(store.save([pinned, loose]))
        let pinnedURL = store.url(for: pinned)
        let looseURL = store.url(for: loose)
        let destination = root.appendingPathComponent("recycled.txt")
        let service = ShelfService(store: store, recycle: { urls, complete in
            XCTAssertEqual(urls, [looseURL])
            do {
                try FileManager.default.moveItem(at: looseURL, to: destination)
                complete([looseURL: destination], nil)
            } catch { XCTFail("\(error)"); complete([:], error) }
        })
        service.start()
        defer { service.stop() }
        await service.waitUntilReady()
        service.togglePin(pinned)
        XCTAssertTrue(try XCTUnwrap(store.loadRecovering().first { $0.id == pinned.id }).isPinned)
        service.clearAll()
        for _ in 0..<100 where service.items.count != 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(service.items.map(\.id), [pinned.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("loose.txt").path))
    }

    @MainActor
    func testPinnedFileSurvivesExpiration() async throws {
        var pinned = try file("old-pinned.txt")
        pinned.added = Date(timeIntervalSince1970: 1)
        pinned.isPinned = true
        XCTAssertTrue(store.save([pinned]))
        let priorRetention = Settings.shared.shelfRetentionDays
        Settings.shared.shelfRetentionDays = 1
        let service = ShelfService(store: store)
        service.start()
        defer {
            service.stop()
            Settings.shared.shelfRetentionDays = priorRetention
        }
        await service.waitUntilReady()
        XCTAssertEqual(service.items.map(\.id), [pinned.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: pinned).path))
    }

    @MainActor
    func testAwaitedImportReportsOnlyCopiesThatExist() async throws {
        let source = root.appendingPathComponent("download.txt")
        let bytes = Data("finished download".utf8)
        try bytes.write(to: source)
        let service = ShelfService(store: store)
        service.start()
        defer { service.stop() }
        let copied = await service.importFiles(urls: [source, source, root.appendingPathComponent("missing.txt")])
        XCTAssertEqual(copied.count, 1)
        let item = try XCTUnwrap(copied.first)
        XCTAssertEqual(try Data(contentsOf: store.url(for: item)), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(service.items.map(\.id), [item.id])
        XCTAssertEqual(try store.loadRecovering().map(\.id), [item.id])
    }

    @MainActor
    func testFailedPinSaveDoesNotPretendPinWasSaved() async throws {
        let item = try file("document.txt")
        XCTAssertTrue(store.save([item]))
        let service = ShelfService(store: store)
        service.start()
        defer { service.stop() }
        await service.waitUntilReady()
        try FileManager.default.removeItem(at: store.indexURL)
        try FileManager.default.createDirectory(at: store.indexURL, withIntermediateDirectories: false)
        service.togglePin(item)
        XCTAssertFalse(try XCTUnwrap(service.items.first).isPinned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: item).path))
    }

    @MainActor
    func testSlowBatchCannotUndoPinOnAlreadyImportedFile() async throws {
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let gate = DispatchSemaphore(value: 0)
        let store = try XCTUnwrap(self.store)
        let service = ShelfService(store: store, copyFile: { url, screenshot in
            if url == second, gate.wait(timeout: .now() + 5) == .timedOut { return nil }
            return store.copyIn(url, isScreenshot: screenshot)
        })
        service.start()
        defer { service.stop(); gate.signal() }
        let batch = Task { await service.importFiles(urls: [first, second]) }
        for _ in 0..<100 where service.items.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let item = service.items.first(where: { $0.name == "first.txt" }) else {
            gate.signal()
            _ = await batch.value
            XCTFail("A completed file should be available while the next file is copying")
            return
        }
        service.togglePin(item)
        gate.signal()
        let copied = await batch.value
        XCTAssertEqual(copied.count, 2)
        XCTAssertTrue(try XCTUnwrap(service.items.first(where: { $0.id == item.id })).isPinned)
        XCTAssertTrue(try XCTUnwrap(store.loadRecovering().first(where: { $0.id == item.id })).isPinned)
    }

    @MainActor
    func testRestartWaitsForInFlightCopyBeforeRecoveringIndex() async throws {
        let source = root.appendingPathComponent("slow.txt")
        try Data("complete file".utf8).write(to: source)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let store = try XCTUnwrap(self.store)
        let service = ShelfService(store: store, copyFile: { url, screenshot in
            entered.signal()
            guard release.wait(timeout: .now() + 5) != .timedOut else { return nil }
            return store.copyIn(url, isScreenshot: screenshot)
        })
        service.start()
        defer { service.stop(); release.signal() }
        let importing = Task { await service.importFiles(urls: [source]) }
        var copying = false
        for _ in 0..<100 {
            if entered.wait(timeout: .now()) == .success { copying = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(copying)
        service.stop()
        service.start()
        release.signal()
        await service.waitUntilReady()
        _ = await importing.value
        XCTAssertEqual(service.items.map(\.name), ["slow.txt"])
        XCTAssertEqual(try store.loadRecovering().count, 1)
    }
}
