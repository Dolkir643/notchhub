import XCTest
@testable import NotchHub

final class ShelfFileSafetyTests: XCTestCase {
    private var root: URL!
    private var store: ShelfStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shelf = root.appendingPathComponent("Shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        store = ShelfStore(shelfURL: shelf, indexURL: root.appendingPathComponent("shelf.json"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func addFile() throws -> ShelfItem {
        let source = root.appendingPathComponent("document.txt")
        try Data("one".utf8).write(to: source)
        return try XCTUnwrap(store.copyIn(source, isScreenshot: false))
    }

    func testRecoveryMatchesTheFolderIDAndPreservesUnindexedFiles() throws {
        let item = try addFile()
        var wrongID = item
        wrongID.id = UUID()
        XCTAssertTrue(store.save([wrongID]))
        XCTAssertNil(store.existingURL(for: wrongID))
        let recovered = try store.loadRecovering()
        XCTAssertEqual(recovered.map(\.id), [item.id])
        XCTAssertTrue(try XCTUnwrap(recovered.first).isPinned)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.existingURL(for: item))), Data("one".utf8))
    }

    func testLinkedFileAndLinkedItemDirectoryAreNotRecovered() throws {
        let item = try addFile()
        XCTAssertTrue(store.save([item]))
        let file = try XCTUnwrap(store.existingURL(for: item))
        let folder = file.deletingLastPathComponent()
        let moved = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
        XCTAssertNil(store.existingURL(for: item))
        XCTAssertTrue(try store.loadRecovering().isEmpty)
        store.pruneOrphans(keeping: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent(item.name).path))

        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: moved.appendingPathComponent(item.name))
        XCTAssertNil(store.existingURL(for: item))
        XCTAssertTrue(try store.loadRecovering().isEmpty)
    }

    func testRootReplacementStopsRecoveryAndAccess() throws {
        let item = try addFile()
        let moved = root.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.moveItem(at: store.shelfURL, to: moved)
        try FileManager.default.createSymbolicLink(at: store.shelfURL, withDestinationURL: moved)
        XCTAssertThrowsError(try store.loadRecovering())
        XCTAssertNil(store.existingURL(for: item))
        XCTAssertFalse(store.save([]))
    }

    @MainActor
    func testRemovalRechecksDirectoryAfterTheCardWasLoaded() async throws {
        let item = try addFile()
        XCTAssertTrue(store.save([item]))
        let service = ShelfService(store: store, recycle: { _, _ in
            XCTFail("A replaced item directory must not be sent to the recycler")
        })
        service.start()
        defer { service.stop() }
        await service.waitUntilReady()
        let folder = try XCTUnwrap(service.fileURL(for: item)).deletingLastPathComponent()
        let moved = root.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)

        service.clearAll()
        XCTAssertNil(service.fileURL(for: item))
        XCTAssertEqual(service.items.map(\.id), [item.id])
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(item.name)), Data("one".utf8))
    }

    @MainActor
    func testManualRemovalAndExpiryPreserveSiblingCreatedDuringRecycle() async throws {
        for expires in [false, true] {
            let item = try addFile()
            XCTAssertTrue(store.save([item]))
            let file = try XCTUnwrap(store.existingURL(for: item))
            let folder = file.deletingLastPathComponent()
            let sibling = folder.appendingPathComponent("Edited copy.txt")
            let destination = root.appendingPathComponent(UUID().uuidString)
            let service = ShelfService(store: store, recycle: { urls, complete in
                XCTAssertEqual(urls, [file])
                do {
                    try FileManager.default.moveItem(at: file, to: destination)
                    try Data("keep".utf8).write(to: sibling)
                    complete([file: destination], nil)
                } catch { XCTFail("\(error)"); complete([:], error) }
            })
            service.start()
            await service.waitUntilReady()
            if expires {
                service.cleanupExpired(now: Date().addingTimeInterval(7 * 86400), retentionDays: 1)
            } else {
                service.remove(item)
            }
            for _ in 0..<100 where service.items.contains(where: { $0.id == item.id }) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            service.stop()
            XCTAssertEqual(try Data(contentsOf: sibling), Data("keep".utf8))
            XCTAssertEqual(try Data(contentsOf: destination), Data("one".utf8))
            let recovered = try XCTUnwrap(store.loadRecovering().first { $0.id == item.id })
            XCTAssertEqual(recovered.name, sibling.lastPathComponent)
            XCTAssertTrue(recovered.isPinned)
        }
    }

    @MainActor
    func testSeveralRetainedFilesCanBeFoundFromTheShelfAfterRestart() async throws {
        let item = try addFile()
        XCTAssertTrue(store.save([item]))
        let file = try XCTUnwrap(store.existingURL(for: item))
        let folder = file.deletingLastPathComponent()
        for name in ["First draft.txt", "Second draft.txt"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
        let destination = root.appendingPathComponent("Recycled.txt")
        let service = ShelfService(store: store, recycle: { urls, complete in
            XCTAssertEqual(urls, [file])
            do {
                try FileManager.default.moveItem(at: file, to: destination)
                complete([file: destination], nil)
            } catch { XCTFail("\(error)"); complete([:], error) }
        })
        service.start()
        await service.waitUntilReady()
        service.clearAll()
        for _ in 0..<100 where service.retainedFolders.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(service.retainedFolders, [folder.lastPathComponent])
        service.stop()

        service.start()
        defer { service.stop() }
        await service.waitUntilReady()
        XCTAssertTrue(service.items.isEmpty)
        let retained = try XCTUnwrap(service.retainedFolders.first)
        XCTAssertEqual(store.folderWithRetainedFiles(named: retained)?.path, folder.path)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)),
                       ["First draft.txt", "Second draft.txt"])
    }
}
