import XCTest
@testable import NotchHub

final class ShelfDownloadsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func write(_ name: String, content: String = "download", modified: Date? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    func testTemporaryFilesAndTheirFinalNamesAreExcluded() throws {
        for suffix in [".crdownload", ".part", ".partial", ".tmp", ".aria2", ".!qB"] {
            let name = "report\(suffix).pdf"
            try write(name)
            try write(name + suffix)
        }
        try write("safari.pdf")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("safari.pdf.download"),
                                                 withIntermediateDirectories: false)
        try write("ready.pdf")
        XCTAssertEqual(try ShelfDownloadsScanner.read(directory: directory).map { $0.url.lastPathComponent },
                       ["ready.pdf"])
    }

    func testOnlyRegularVisibleFilesAreListedAndNewestHundredAreKept() throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder"),
                                                 withIntermediateDirectories: false)
        let hidden = try write(".hidden")
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias"),
                                                   withDestinationURL: hidden)
        for index in 0..<103 {
            try write("\(index).txt", modified: Date(timeIntervalSince1970: Double(index)))
        }
        let files = try ShelfDownloadsScanner.read(directory: directory)
        XCTAssertEqual(files.count, 100)
        XCTAssertEqual(files.first?.url.lastPathComponent, "102.txt")
        XCTAssertEqual(files.last?.url.lastPathComponent, "3.txt")
    }

    func testThreeIndependentSamplesAreRequiredAndWritingResetsReadiness() throws {
        let url = try write("writing.bin")
        let first = try XCTUnwrap(ShelfDownloadSnapshot.read(url))
        var tracker = ShelfDownloadsReadiness()
        XCTAssertFalse(try XCTUnwrap(tracker.update([first], at: 0).first).isReady)
        for time in [0.1, 0.2, 0.3, 0.4] {
            XCTAssertFalse(try XCTUnwrap(tracker.update([first], at: time).first).isReady)
        }
        XCTAssertFalse(try XCTUnwrap(tracker.update([first], at: 1).first).isReady)
        try write("writing.bin", content: "a larger payload")
        let changed = try XCTUnwrap(ShelfDownloadSnapshot.read(url))
        XCTAssertFalse(try XCTUnwrap(tracker.update([changed], at: 2).first).isReady)
        XCTAssertFalse(try XCTUnwrap(tracker.update([changed], at: 3).first).isReady)
        XCTAssertTrue(try XCTUnwrap(tracker.update([changed], at: 4).first).isReady)
        XCTAssertFalse(tracker.hasPendingFiles)
    }

    func testInPlaceWriteEventInvalidatesEvenUnchangedMetadata() throws {
        let snapshot = try XCTUnwrap(ShelfDownloadSnapshot.read(write("same-size.bin")))
        var tracker = ShelfDownloadsReadiness()
        _ = tracker.update([snapshot], at: 0)
        _ = tracker.update([snapshot], at: 1)
        XCTAssertTrue(try XCTUnwrap(tracker.update([snapshot], at: 2).first).isReady)
        tracker.invalidate(snapshot.url)
        XCTAssertFalse(try XCTUnwrap(tracker.update([snapshot], at: 3).first).isReady)
        XCTAssertTrue(tracker.hasPendingFiles)
    }

    func testRemovedThenReappearingFileMustStabilizeAgain() throws {
        let snapshot = try XCTUnwrap(ShelfDownloadSnapshot.read(write("reappeared.txt")))
        var tracker = ShelfDownloadsReadiness()
        _ = tracker.update([snapshot], at: 0)
        _ = tracker.update([snapshot], at: 1)
        XCTAssertTrue(try XCTUnwrap(tracker.update([snapshot], at: 2).first).isReady)
        XCTAssertTrue(tracker.update([], at: 3).isEmpty)
        XCTAssertFalse(try XCTUnwrap(tracker.update([snapshot], at: 4).first).isReady)
    }

    func testActionValidationRejectsChangedMissingAndNowPartialSources() throws {
        let url = try write("original.pdf")
        let original = try XCTUnwrap(ShelfDownloadSnapshot.read(url))
        XCTAssertTrue(try ShelfDownloadsScanner.isCurrent(original, in: directory))
        let temporary = try write("original.pdf.crdownload")
        XCTAssertFalse(try ShelfDownloadsScanner.isCurrent(original, in: directory))
        try FileManager.default.removeItem(at: temporary)
        try write("original.pdf", content: "changed data")
        XCTAssertFalse(try ShelfDownloadsScanner.isCurrent(original, in: directory))
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(try ShelfDownloadsScanner.isCurrent(original, in: directory))
    }

    func testUnavailableDirectoryIsAnErrorRatherThanAnEmptySuccess() throws {
        let absent = directory.appendingPathComponent("not-mounted")
        XCTAssertThrowsError(try ShelfDownloadsScanner.read(directory: absent))
    }

    func testReplacementIsDetectedEvenWhenSizeAndModificationDateMatch() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let url = try write("document.txt", content: "old", modified: date)
        let original = try XCTUnwrap(ShelfDownloadSnapshot.read(url))
        let replacement = try write("replacement.txt", content: "new", modified: date)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        let changed = try XCTUnwrap(ShelfDownloadSnapshot.read(url))
        XCTAssertEqual(original.size, changed.size)
        XCTAssertEqual(original.modified, changed.modified)
        XCTAssertNotEqual(original.fileNumber, changed.fileNumber)
        XCTAssertFalse(try ShelfDownloadsScanner.isCurrent(original, in: directory))
    }

    @MainActor
    func testStoppedSessionCannotPublishDelayedScanResults() async throws {
        try write("pending.txt")
        let suite = "ShelfDownloadsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmark = try directory.bookmarkData(options: [.withSecurityScope],
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: "shelfDownloadsFolderBookmark")
        let service = ShelfDownloadsService(defaults: defaults)
        service.start()
        await Task.yield()
        service.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(service.items.isEmpty)
        XCTAssertNil(service.folderURL)
    }
}
