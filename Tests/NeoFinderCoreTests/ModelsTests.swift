import Foundation
import Testing
@testable import NeoFinderCore

@Suite final class ModelsTests {
    private let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("NeoFinderModelsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    @Test func testNavigationTruncatesForwardHistoryAndStaysIndependent() {
        var left = BrowserTab(path: "/left")
        var right = BrowserTab(path: "/right")
        left.navigate(to: "/left/one")
        left.navigate(to: "/left/two")
        #expect((left.goBack()) == ("/left/one"))
        left.navigate(to: "/left/new")
        #expect(left.goForward() == nil)
        #expect((left.history) == (["/left", "/left/one", "/left/new"]))
        #expect((right.path) == ("/right"))
        #expect(right.goBack() == nil)
        left.navigate(to: "/left/new")
        #expect((left.history.count) == (3))
    }

    @Test func testHistoryBoundPreservesCurrentLocation() {
        var tab = BrowserTab(path: "/0")
        for index in 1...120 { tab.navigate(to: "/\(index)") }
        #expect((tab.history.count) == (BrowserTab.historyLimit))
        #expect((tab.historyIndex) == (BrowserTab.historyLimit - 1))
        #expect((tab.goBack()) == ("/119"))
        #expect((tab.goForward()) == ("/120"))
    }

    @Test func testFilteringNormalizesWidthCaseDiacriticsAndComposedCharacters() {
        let files = ["ＡＢＣ－１２.txt", "Café.pdf", "か\u{3099}く.xlsx", "資料.txt"].map {
            FileEntry(url: scratch.appendingPathComponent($0))
        }
        #expect((FileEntry.filtered(files, query: "abc", sort: .name, ascending: true).count) == (1))
        #expect((FileEntry.filtered(files, query: "cafe", sort: .name, ascending: true).count) == (1))
        #expect((FileEntry.filtered(files, query: "がく", sort: .name, ascending: true).count) == (1))
        #expect((FileEntry.filtered(files, query: "対象なし", sort: .name, ascending: true).count) == (0))
        #expect((files[0].name) == ("ＡＢＣ－１２.txt"))
    }

    @Test func testNaturalSortFolderFirstAndUnknownDateLast() {
        let files = [
            FileEntry(url: scratch.appendingPathComponent("file10"), size: 10, modifiedAt: Date(timeIntervalSince1970: 10)),
            FileEntry(url: scratch.appendingPathComponent("folder"), isDirectory: true),
            FileEntry(url: scratch.appendingPathComponent("file2"), size: 2, modifiedAt: Date(timeIntervalSince1970: 20)),
            FileEntry(url: scratch.appendingPathComponent("unknown"))
        ]
        #expect((FileEntry.filtered(files, query: "", sort: .name, ascending: true).map(\.name)) == (["folder", "file2", "file10", "unknown"]))
        #expect((FileEntry.filtered(files, query: "", sort: .date, ascending: false).map(\.name)) == (["folder", "file2", "file10", "unknown"]))
        #expect((FileEntry.filtered(files, query: "", sort: .size, ascending: false).map(\.name)) == (["folder", "file10", "file2", "unknown"]))
    }

    @Test func testFolderReaderMetadataHiddenFilesPackagesAndSymlinks() throws {
        let visible = scratch.appendingPathComponent("資料.txt")
        try Data("hello".utf8).write(to: visible)
        try Data().write(to: scratch.appendingPathComponent(".hidden"))
        let directory = scratch.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("child".utf8).write(to: directory.appendingPathComponent("child.txt"))
        let package = scratch.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let cycle = scratch.appendingPathComponent("cycle")
        try FileManager.default.createSymbolicLink(at: cycle, withDestinationURL: scratch)
        let broken = scratch.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: scratch.appendingPathComponent("missing"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: visible.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: visible.path) }

        let entries = try FolderReader.contents(of: scratch, showHidden: false)
        #expect((entries.count) == (5))
        #expect(!(entries.contains { $0.name == ".hidden" || $0.name == "child.txt" }))
        #expect((entries.first { $0.name == "資料.txt" }?.size) == (5))
        #expect((entries.first { $0.name == "folder" }?.isDirectory) == (true))
        #expect((entries.first { $0.name == "Example.app" }?.isPackage) == (true))
        #expect((entries.first { $0.name == "cycle" }?.isSymbolicLink) == (true))
        #expect((entries.first { $0.name == "broken" }?.isSymbolicLink) == (true))
        #expect((try FolderReader.contents(of: scratch, showHidden: true).count) == (6))
    }

    @Test func testFolderReaderMissingDirectoryFailsInsteadOfShowingEmpty() {
        #expect(throws: (any Error).self) { try FolderReader.contents(of: scratch.appendingPathComponent("absent"), showHidden: false) }
    }

    @Test func testSessionRoundtripPreservesMissingPathsAndIndependentTabs() throws {
        let store = SessionStore(directory: scratch.appendingPathComponent("Settings"))
        var workspace = WorkspaceState(name: "資料整理", leftPath: "/Volumes/未接続/資料", rightPath: "/right")
        workspace.left.tabs.append(BrowserTab(path: "/left/second", viewMode: .columns, sort: .date, ascending: false))
        workspace.left.selectedTabID = workspace.left.tabs[1].id
        workspace.activeSide = 1
        workspace.dividerRatio = 0.62
        let favorite = Favorite(name: "別名", path: "/original")
        let session = SavedSession(current: workspace, workspaces: [workspace],
                                   favoriteGroups: [FavoriteGroup(name: "仕事", items: [favorite])], showHidden: true)
        try store.save(session)
        let loaded = try #require(SessionStore(directory: store.directory).load())
        #expect((loaded.current.left.tabs[0].path) == ("/Volumes/未接続/資料"))
        #expect((loaded.current.left.selectedTab.path) == ("/left/second"))
        #expect((loaded.current.left.selectedTab.viewMode) == (.columns))
        #expect((loaded.current.right.selectedTab.path) == ("/right"))
        #expect((loaded.current.dividerRatio) == (0.62))
        #expect((loaded.favoriteGroups[0].items[0].path) == ("/original"))
        #expect(loaded.showHidden)
        #expect((try FileManager.default.contentsOfDirectory(atPath: store.directory.path)) == (["session.json"]))
    }

    @Test func testUnknownSchemaCannotLoadOrOverwriteExistingFile() throws {
        let store = SessionStore(directory: scratch)
        let file = scratch.appendingPathComponent("session.json")
        let future = Data("{\"schemaVersion\":999,\"futureField\":\"keep\"}".utf8)
        try future.write(to: file)
        #expect(store.load() == nil)
        let session = SavedSession(current: WorkspaceState(name: "new", leftPath: "/", rightPath: "/"))
        #expect(throws: (any Error).self) { try store.save(session) }
        #expect((try Data(contentsOf: file)) == (future))
    }

    @Test func testEncodingFailureLeavesPreviousAtomicSaveIntact() throws {
        let store = SessionStore(directory: scratch)
        var session = SavedSession(current: WorkspaceState(name: "good", leftPath: "/left", rightPath: "/right"))
        try store.save(session)
        let previous = try Data(contentsOf: scratch.appendingPathComponent("session.json"))
        session.current.dividerRatio = .nan
        #expect(throws: (any Error).self) { try store.save(session) }
        #expect((try Data(contentsOf: scratch.appendingPathComponent("session.json"))) == (previous))
        #expect((store.load()?.current.name) == ("good"))
    }

    @Test func testMalformedSelectionAndHistoryAreRepairedWithoutChangingSavedPath() throws {
        var workspace = WorkspaceState(name: "repair", leftPath: "/not-mounted", rightPath: "/right")
        workspace.left.tabs[0].history = ["/one", "/two"]
        workspace.left.tabs[0].historyIndex = 999
        workspace.left.tabs.append(workspace.left.tabs[0])
        workspace.left.selectedTabID = UUID()
        workspace.right.tabs = []
        workspace.dividerRatio = 5
        workspace.activeSide = -1
        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
        #expect((decoded.left.selectedTab.path) == ("/not-mounted"))
        #expect((decoded.left.selectedTabID) == (decoded.left.tabs[0].id))
        #expect((Set(decoded.left.tabs.map(\.id)).count) == (2))
        #expect((decoded.left.selectedTab.history[decoded.left.selectedTab.historyIndex]) == ("/not-mounted"))
        #expect((decoded.right.tabs.count) == (1))
        #expect((decoded.dividerRatio) == (0.8))
        #expect((decoded.activeSide) == (0))
    }

    @Test func testCorruptSessionAndBookmarksReturnEmptyWithoutRemovingFiles() throws {
        let sessionFile = scratch.appendingPathComponent("session.json")
        let bookmarksFile = scratch.appendingPathComponent("bookmarks.json")
        let invalid = Data("{broken".utf8)
        try invalid.write(to: sessionFile)
        try invalid.write(to: bookmarksFile)
        let store = SessionStore(directory: scratch)
        #expect(store.load() == nil)
        #expect(store.restoreBookmarks().isEmpty)
        #expect((try Data(contentsOf: bookmarksFile)) == (invalid))
    }
}
