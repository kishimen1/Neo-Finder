import Testing
import Foundation
import Darwin
@testable import NeoFinderCore

@Suite(.serialized)
final class FileOperationsTests {
    private var root: URL!
    private var source: URL!
    private var destination: URL!
    private var trashDirectory: URL!
    private var engine: FileOperationEngine!
    private let manager = FileManager.default

    init() throws {
        root = manager.temporaryDirectory.appendingPathComponent("NeoFinder-tests-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        trashDirectory = root.appendingPathComponent("test-trash", isDirectory: true)
        for url in [source!, destination!, trashDirectory!] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let trash = trashDirectory!
        engine = FileOperationEngine(journalURL: root.appendingPathComponent("journal.json"), trashHandler: { item in
            let result = trash.appendingPathComponent(UUID().uuidString + "-" + item.lastPathComponent)
            try FileManager.default.moveItem(at: item, to: result)
            return result
        })
    }

    deinit {
        if let root { try? manager.removeItem(at: root) }
    }

    @discardableResult
    private func file(_ name: String, in directory: URL? = nil, content: String = "original") throws -> URL {
        let url = (directory ?? source).appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    private func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func testCopyPreservesOriginalAndUndoMovesCopyToTrash() throws {
        let item = try file("請求書.txt")
        let report = try engine.copy([item], to: destination)
        #expect((report.completed) == (1))
        #expect(report.failures.isEmpty)
        #expect((try contents(destination.appendingPathComponent(item.lastPathComponent))) == ("original"))
        #expect(engine.canUndo)
        let undo = try engine.undoLast()
        #expect((undo.completed) == (1))
        #expect((try contents(item)) == ("original"))
        #expect(!(manager.fileExists(atPath: destination.appendingPathComponent(item.lastPathComponent).path)))
        #expect((try manager.contentsOfDirectory(atPath: trashDirectory.path).count) == (1))
        #expect(!(engine.canUndo))
    }

    @Test func testKeepBothAndSkipNeverOverwrite() throws {
        let item = try file("report.txt")
        let existing = try file("report.txt", in: destination, content: "keep me")
        let kept = try engine.copy([item], to: destination)
        #expect((kept.completed) == (1))
        #expect((try contents(existing)) == ("keep me"))
        #expect((try contents(destination.appendingPathComponent("report (2).txt"))) == ("original"))
        let skipped = try engine.copy([item], to: destination, conflict: .skip)
        #expect((skipped.completed) == (0))
        #expect(skipped.failures.isEmpty)
        #expect((try manager.contentsOfDirectory(atPath: destination.path).count) == (2))
    }

    @Test func testConflictCancelRetainsEarlierSuccess() throws {
        let first = try file("first.txt")
        let conflict = try file("conflict.txt")
        let last = try file("last.txt")
        try file("conflict.txt", in: destination, content: "keep")
        let report = try engine.copy([first, conflict, last], to: destination, conflict: .cancel)
        #expect((report.completed) == (1))
        #expect(report.cancelled)
        #expect(!(manager.fileExists(atPath: destination.appendingPathComponent("last.txt").path)))
        #expect((try contents(destination.appendingPathComponent("conflict.txt"))) == ("keep"))
        #expect((try engine.undoLast().completed) == (1))
    }

    @Test func testMissingItemDoesNotHidePartialSuccess() throws {
        let missing = source.appendingPathComponent("missing")
        let existing = try file("existing")
        let report = try engine.copy([missing, existing], to: destination)
        #expect((report.completed) == (1))
        #expect((report.failures.count) == (1))
        #expect((try contents(destination.appendingPathComponent("existing"))) == ("original"))
    }

    @Test func testSelfAndDescendantTransfersAreRejectedIncludingSymlinkParent() throws {
        let folder = source.appendingPathComponent("folder", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: nested)
        let copy = try engine.copy([folder], to: link)
        #expect((copy.completed) == (0))
        #expect((copy.failures.count) == (1))
        let move = try engine.move([folder], to: nested)
        #expect((move.completed) == (0))
        #expect(manager.fileExists(atPath: folder.path))
        let same = try engine.copy([folder], to: source)
        #expect((same.completed) == (0))
    }

    @Test func testDanglingSymlinkCopiesTheLinkItself() throws {
        let link = source.appendingPathComponent("dangling")
        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: "missing-target")
        let report = try engine.copy([link], to: destination)
        #expect((report.completed) == (1))
        #expect((try manager.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("dangling").path)) == ("missing-target"))
        #expect((try engine.undoLast().completed) == (1))
    }

    @Test func testMoveAndRenameUndoPreserveData() throws {
        let original = try file("original.txt")
        let moved = destination.appendingPathComponent("original.txt")
        let result = try engine.move([original], to: destination)
        #expect((result.completed) == (1))
        #expect(!(manager.fileExists(atPath: original.path)))
        #expect((try engine.rename(moved, to: "変更.txt").completed) == (1))
        #expect((try engine.undoLast().completed) == (1))
        #expect((try contents(moved)) == ("original"))
        #expect((try engine.undoLast().completed) == (1))
        #expect((try contents(original)) == ("original"))
    }

    @Test func testRenameCollisionDoesNotReplaceEitherItem() throws {
        let first = try file("first.txt")
        let second = try file("second.txt", content: "second")
        let result = try engine.rename(first, to: "second.txt")
        #expect((result.completed) == (0))
        #expect((result.failures.count) == (1))
        #expect((try contents(first)) == ("original"))
        #expect((try contents(second)) == ("second"))
        #expect(throws: (any Error).self) { try engine.rename(first, to: "../escape") }
    }

    @Test func testUndoRefusesContentChangeEvenWhenSizeAndDateRestored() throws {
        let item = try file("item", content: "AAAA")
        #expect((try engine.copy([item], to: destination).completed) == (1))
        let copied = destination.appendingPathComponent("item")
        let date = try #require(manager.attributesOfItem(atPath: copied.path)[.modificationDate] as? Date)
        let handle = try FileHandle(forWritingTo: copied)
        try handle.write(contentsOf: Data("BBBB".utf8))
        try handle.close()
        try manager.setAttributes([.modificationDate: date], ofItemAtPath: copied.path)
        let undo = try engine.undoLast()
        #expect((undo.completed) == (0))
        #expect((undo.failures.count) == (1))
        #expect((try contents(copied)) == ("BBBB"))
        #expect(engine.canUndo)
    }

    @Test func testUndoFolderRefusesAddedDescendants() throws {
        let folder = source.appendingPathComponent("bundle.app", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        try file("original", in: folder)
        #expect((try engine.copy([folder], to: destination).completed) == (1))
        let copied = destination.appendingPathComponent("bundle.app")
        try file("new-user-file", in: copied)
        let undo = try engine.undoLast()
        #expect((undo.completed) == (0))
        #expect(manager.fileExists(atPath: copied.appendingPathComponent("new-user-file").path))
    }

    @Test func testUndoFolderDetectsChangedDescendantContents() throws {
        let folder = source.appendingPathComponent("folder", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        try file("child", in: folder, content: "AAAA")
        #expect((try engine.copy([folder], to: destination).completed) == (1))
        let copiedChild = destination.appendingPathComponent("folder/child")
        let attributes = try manager.attributesOfItem(atPath: copiedChild.path)
        let date = try #require(attributes[.modificationDate] as? Date)
        let handle = try FileHandle(forWritingTo: copiedChild)
        try handle.write(contentsOf: Data("BBBB".utf8))
        try handle.close()
        try manager.setAttributes([.modificationDate: date], ofItemAtPath: copiedChild.path)
        let undo = try engine.undoLast()
        #expect(undo.completed == 0)
        #expect(try contents(copiedChild) == "BBBB")
    }

    @Test func testUndoDoesNotFollowReplacedSymbolicLink() throws {
        let item = try file("item")
        #expect(try engine.copy([item], to: destination).completed == 1)
        let copied = destination.appendingPathComponent("item")
        try manager.removeItem(at: copied)
        try manager.createSymbolicLink(at: copied, withDestinationURL: item)
        #expect(try engine.undoLast().completed == 0)
        #expect(try contents(item) == "original")
        #expect(try manager.destinationOfSymbolicLink(atPath: copied.path) == item.path)
    }

    @Test func testEmptyFolderUndo() throws {
        #expect(try engine.createFolder(in: destination, name: "empty").completed == 1)
        #expect(try engine.undoLast().completed == 1)
        #expect(!manager.fileExists(atPath: destination.appendingPathComponent("empty").path))
    }

    @Test func testUndoMoveRejectsOccupiedOriginalPath() throws {
        let item = try file("item")
        #expect((try engine.move([item], to: destination).completed) == (1))
        try file("item", content: "new file")
        let report = try engine.undoLast()
        #expect((report.completed) == (0))
        #expect((try contents(item)) == ("new file"))
        #expect((try contents(destination.appendingPathComponent("item"))) == ("original"))
    }

    @Test func testCreateFolderDoesNotAdoptExistingFolderAndUndoRequiresEmpty() throws {
        #expect((try engine.createFolder(in: destination, name: "new").completed) == (1))
        #expect((try engine.createFolder(in: destination, name: "new").completed) == (0))
        try file("user-data", in: destination.appendingPathComponent("new"))
        #expect((try engine.undoLast().completed) == (0))
        #expect(manager.fileExists(atPath: destination.appendingPathComponent("new/user-data").path))
    }

    @Test func testTrashUndoUsesReturnedLocation() throws {
        let item = try file("item")
        let report = try engine.trash([item])
        #expect((report.completed) == (1))
        #expect(!(manager.fileExists(atPath: item.path)))
        let undo = try engine.undoLast()
        #expect((undo.completed) == (1))
        #expect((try contents(item)) == ("original"))
    }

    @Test func testTrashFailureNeverDeletesSource() throws {
        let item = try file("item")
        let failingEngine = FileOperationEngine(trashHandler: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) })
        let report = try failingEngine.trash([item])
        #expect((report.completed) == (0))
        #expect((report.failures.count) == (1))
        #expect((try contents(item)) == ("original"))
        #expect(!(failingEngine.canUndo))
    }

    @Test func testTrashWaitsForMetadataToSettleWithoutWeakeningUndo() throws {
        let item = try file("metadata-settles", content: "")
        let trashed = trashDirectory.appendingPathComponent("metadata-settles")
        let metadataDone = DispatchSemaphore(value: 0)
        let settlingEngine = FileOperationEngine(trashHandler: { url in
            try FileManager.default.moveItem(at: url, to: trashed)
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: 0.015)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: trashed.path)
                metadataDone.signal()
            }
            return trashed
        })
        let report = try settlingEngine.trash([item])
        #expect(metadataDone.wait(timeout: .now() + 1) == .success)
        #expect(report.completed == 1)
        #expect(report.failures.isEmpty)
        #expect(settlingEngine.canUndo)
        let undo = try settlingEngine.undoLast()
        #expect(undo.completed == 1)
        #expect(undo.failures.isEmpty)
        #expect(try contents(item) == "")
    }

    @Test func testTrashDoesNotAdoptContentChangedDuringMove() throws {
        let item = try file("changed-during-trash", content: "AAAA")
        let trashed = trashDirectory.appendingPathComponent("changed-during-trash")
        let changingEngine = FileOperationEngine(trashHandler: { url in
            try FileManager.default.moveItem(at: url, to: trashed)
            let handle = try FileHandle(forWritingTo: trashed)
            try handle.write(contentsOf: Data("BBBB".utf8))
            try handle.close()
            return trashed
        })
        let report = try changingEngine.trash([item])
        #expect(report.completed == 1)
        #expect(report.failures.count == 1)
        #expect(!changingEngine.canUndo)
        #expect(try contents(trashed) == "BBBB")
    }

    @Test func testTrashDoesNotAdoptReplacementWithIdenticalContents() throws {
        let item = try file("replaced-during-trash")
        let trashed = trashDirectory.appendingPathComponent("replacement")
        let originalInTrash = trashDirectory.appendingPathComponent("original")
        let replacingEngine = FileOperationEngine(trashHandler: { url in
            try FileManager.default.moveItem(at: url, to: originalInTrash)
            try Data("original".utf8).write(to: trashed)
            return trashed
        })
        let report = try replacingEngine.trash([item])
        #expect(report.completed == 1)
        #expect(report.failures.count == 1)
        #expect(!replacingEngine.canUndo)
        #expect(try contents(originalInTrash) == "original")
        #expect(try contents(trashed) == "original")
    }

    // Opt-in integration check. Only this suite's disposable fixture visits the real Trash.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEOFINDER_REAL_TRASH_TEST"] == "1"))
    func testRealTrashAndRestoreEmptyFile() throws {
        let item = try file("NeoFinder-disposable-real-trash-\(UUID().uuidString).txt", content: "")
        let actualEngine = FileOperationEngine()
        let report = try actualEngine.trash([item])
        #expect(report.completed == 1)
        #expect(report.failures.isEmpty)
        #expect(actualEngine.canUndo)
        let undo = try actualEngine.undoLast()
        #expect(undo.completed == 1)
        #expect(undo.failures.isEmpty)
        #expect(try contents(item) == "")
    }

    @Test func testCancellationStopsAtItemBoundary() throws {
        let first = try file("first")
        let second = try file("second")
        let trash = trashDirectory!
        var cancellable: FileOperationEngine!
        cancellable = FileOperationEngine(trashHandler: { item in
            let result = trash.appendingPathComponent(item.lastPathComponent)
            try FileManager.default.moveItem(at: item, to: result)
            cancellable.cancel()
            return result
        })
        let report = try cancellable.trash([first, second])
        #expect((report.completed) == (1))
        #expect(report.cancelled)
        #expect(manager.fileExists(atPath: second.path))
    }

    @Test func testJournalIsSavedButUndoIsNotRestoredAfterRestart() throws {
        let item = try file("item")
        #expect((try engine.copy([item], to: destination).completed) == (1))
        let journalURL = root.appendingPathComponent("journal.json")
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [[String: Any]])
        #expect((json.last?["state"] as? String) == ("完了"))
        #expect((json.last?["completed"] as? Int) == (1))
        #expect(!(FileOperationEngine(journalURL: journalURL).canUndo))
    }

    @Test func testUnfinishedJournalShowsRecoveryNoticeWithoutResuming() throws {
        let item = try file("item")
        #expect(try engine.copy([item], to: destination).completed == 1)
        let journalURL = root.appendingPathComponent("journal.json")
        var entries = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [[String: Any]])
        entries[0]["state"] = "実行中"
        entries[0]["activeItem"] = item.path
        try JSONSerialization.data(withJSONObject: entries).write(to: journalURL)
        let restarted = FileOperationEngine(journalURL: journalURL)
        #expect(restarted.recoveryNotice?.contains(item.path) == true)
        #expect(!restarted.canUndo)
        #expect(restarted.historyLines().first?.contains("実行中") == true)
        #expect(try contents(item) == "original")
        #expect(try contents(destination.appendingPathComponent("item")) == "original")
    }

    @Test func testCorruptJournalPreventsUnrecordedWrites() throws {
        let journal = root.appendingPathComponent("corrupt.json")
        try Data("invalid".utf8).write(to: journal)
        let item = try file("item")
        #expect(throws: (any Error).self) { try FileOperationEngine(journalURL: journal).copy([item], to: destination) }
        #expect(!(manager.fileExists(atPath: destination.appendingPathComponent("item").path)))
    }

    @Test func testCopyPreservesModificationDatePermissionsAndExtendedAttribute() throws {
        let item = try file("metadata")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try manager.setAttributes([.posixPermissions: 0o640, .modificationDate: timestamp], ofItemAtPath: item.path)
        let marker = Data("NeoFinder fixture".utf8)
        let status = marker.withUnsafeBytes { bytes in
            item.withUnsafeFileSystemRepresentation { setxattr($0!, "org.neofinder.test", bytes.baseAddress, marker.count, 0, 0) }
        }
        #expect((status) == (0))
        let report = try engine.copy([item], to: destination)
        #expect((report.completed) == (1))
        let copied = destination.appendingPathComponent("metadata")
        let attrs = try manager.attributesOfItem(atPath: copied.path)
        #expect((attrs[.posixPermissions] as? Int) == (0o640))
        #expect((attrs[.modificationDate] as? Date) == (timestamp))
        var buffer = Data(count: marker.count)
        let read = buffer.withUnsafeMutableBytes { bytes in
            copied.withUnsafeFileSystemRepresentation { getxattr($0!, "org.neofinder.test", bytes.baseAddress, marker.count, 0, 0) }
        }
        #expect((read) == (marker.count))
        #expect((buffer) == (marker))
    }
}
