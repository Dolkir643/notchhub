import XCTest
import AppKit
import ImageIO
@testable import NotchHub

final class ShelfRecoveryTests: XCTestCase {
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
        let source = root.appendingPathComponent(name)
        try Data("valuable content".utf8).write(to: source)
        return try XCTUnwrap(store.copyIn(source, isScreenshot: false))
    }

    func testCorruptIndexRecoversFilesAndPreservesOriginalIndex() throws {
        let item = try file("document.txt")
        let broken = Data("{broken".utf8)
        try broken.write(to: store.indexURL)
        let loaded = try store.loadRecovering()
        XCTAssertEqual(loaded.map(\.id), [item.id])
        XCTAssertEqual(try Data(contentsOf: store.url(for: item)), Data("valuable content".utf8))
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains("broken-") })
        XCTAssertEqual(try Data(contentsOf: backup), broken)
    }

    func testMissingIndexRecoversUnindexedCopy() throws {
        let item = try file("orphan.txt")
        XCTAssertEqual(try store.loadRecovering().map(\.id), [item.id])
    }

    func testUnreadableIndexThrowsInsteadOfReturningEmptyShelf() throws {
        _ = try file("safe.txt")
        try FileManager.default.createDirectory(at: store.indexURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.loadRecovering())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.shelfURL.path).count, 1)
    }

    func testIncompleteCopyIsNotRecoveredAndOrphanCleanupKeepsFiles() throws {
        let item = try file("complete.txt")
        let staging = store.shelfURL.appendingPathComponent(".incoming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data("partial".utf8).write(to: staging.appendingPathComponent("partial.txt"))
        store.pruneOrphans(keeping: [])
        XCTAssertEqual(try store.loadRecovering().map(\.id), [item.id])
    }

    @MainActor
    func testAddImmediatelyAfterStartPreservesLoadedAndNewFiles() async throws {
        let existing = try file("existing.txt")
        store.save([existing])
        let source = root.appendingPathComponent("new.txt")
        try Data("new content".utf8).write(to: source)
        let service = ShelfService(store: store)
        service.start()
        defer { service.stop() }
        service.add(urls: [source])
        await service.waitUntilReady()
        for _ in 0..<200 where service.items.count != 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(Set(service.items.map(\.name)), ["existing.txt", "new.txt"])
        XCTAssertEqual(try store.loadRecovering().count, 2)
    }

    @MainActor
    func testRecycleFailureKeepsFileAndIndex() async throws {
        let item = try file("keep.txt")
        store.save([item])
        let service = ShelfService(store: store, recycle: { _, complete in
            complete([:], NSError(domain: "Test", code: 1))
        })
        service.start()
        defer { service.stop() }
        await service.waitUntilReady()
        service.clearAll()
        // Completion is delivered on the main actor on the following turn.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.items.map(\.id), [item.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: item).path))
        XCTAssertEqual(try store.loadRecovering().map(\.id), [item.id])
    }

    @MainActor
    func testPartialRecycleOnlyRemovesSuccessfullyMovedFile() async throws {
        let first = try file("first.txt")
        let second = try file("second.txt")
        store.save([first, second])
        let destination = root.appendingPathComponent("recycled.txt")
        let firstURL = store.url(for: first)
        let service = ShelfService(store: store, recycle: { _, complete in
            do {
                try FileManager.default.moveItem(at: firstURL, to: destination)
                complete([firstURL: destination], NSError(domain: "Test", code: 2))
            } catch { XCTFail("\(error)"); complete([:], error) }
        })
        service.start()
        defer { service.stop() }
        await service.waitUntilReady()
        service.clearAll()
        for _ in 0..<200 where service.items.count != 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(service.items.map(\.id), [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: second).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try store.loadRecovering().map(\.id), [second.id])
    }
}

final class ClipboardRegressionTests: XCTestCase {
    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 900,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @MainActor
    func testCopyBackPreservesOriginalPNGBytesAndDimensions() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let service = ClipboardService(pasteboard: board)
        let original = try png()
        await service.captureImage(original).value
        let item = try XCTUnwrap(service.items.first)
        service.copyBack(item)
        XCTAssertEqual(board.data(forType: .png), original)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(board.data(forType: .png)) as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1600)
        XCTAssertEqual(image.height, 900)
    }

    @MainActor
    func testImagePayloadBudgetEvictsOldestOriginal() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let service = ClipboardService(pasteboard: board)
        var first = try png()
        first.append(Data(count: 34 * 1024 * 1024))
        await service.captureImage(first).value
        XCTAssertEqual(service.items.count, 1)
        let firstID = try XCTUnwrap(service.items.first?.id)
        var second = first
        second.append(1)
        await service.captureImage(second).value
        XCTAssertEqual(service.items.count, 1)
        XCTAssertNotEqual(service.items.first?.id, firstID)
        XCTAssertEqual(service.items.first?.originalImageData, second)
    }

    @MainActor
    func testOversizedTextDoesNotEvictExistingHistory() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let service = ClipboardService(pasteboard: board)
        await service.captureImage(try png()).value
        let originalID = try XCTUnwrap(service.items.first?.id)
        board.setString(String(repeating: "x", count: ClipboardService.memoryLimit + 1), forType: .string)
        service.capture()
        XCTAssertEqual(service.items.map(\.id), [originalID])
    }

    @MainActor
    func testClearRejectsPendingImageResult() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let service = ClipboardService(pasteboard: board)
        let task = service.captureImage(try png())
        service.clearAll()
        await task.value
        XCTAssertTrue(service.items.isEmpty)
    }

    @MainActor
    func testStopRejectsPendingImageResult() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let service = ClipboardService(pasteboard: board)
        let task = service.captureImage(try png())
        service.stop()
        await task.value
        XCTAssertTrue(service.items.isEmpty)
    }
}

final class EdgeTriggerTests: XCTestCase {
    func testTopEdgeAndFullWidthAreClickable() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for point in [CGPoint(x: 720, y: 900), CGPoint(x: 560, y: 900),
                      CGPoint(x: 880, y: 900), CGPoint(x: 720, y: 892)] {
            XCTAssertTrue(EdgeTrigger.contains(point, on: screen))
        }
    }

    func testMenuBelowTriggerAndOutsideWidthRemainAvailable() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for point in [CGPoint(x: 720, y: 891), CGPoint(x: 559, y: 900),
                      CGPoint(x: 881, y: 900), CGPoint(x: 720, y: 901)] {
            XCTAssertFalse(EdgeTrigger.contains(point, on: screen))
        }
    }

    func testOffsetExternalDisplayUsesItsOwnTopEdge() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        XCTAssertTrue(EdgeTrigger.contains(CGPoint(x: -960, y: 880), on: screen))
        XCTAssertFalse(EdgeTrigger.contains(CGPoint(x: 720, y: 900), on: screen))
    }
}

final class VariantTests: XCTestCase {
    func testModernProfilesHaveDifferentBehaviorOnScreensWithoutNotch() {
        XCTAssertFalse(HubVariant.notch.usesEdgeTrigger(hasRealNotch: false))
        XCTAssertTrue(HubVariant.noNotch.usesEdgeTrigger(hasRealNotch: false))
        XCTAssertTrue(HubVariant.legacy.usesEdgeTrigger(hasRealNotch: false))
    }

    func testRealCameraCutoutNeverBecomesAClickTarget() {
        for variant in HubVariant.allCases {
            XCTAssertFalse(variant.usesEdgeTrigger(hasRealNotch: true))
        }
    }
}
