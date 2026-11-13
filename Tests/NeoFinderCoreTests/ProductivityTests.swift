import Foundation
import Testing
@testable import NeoFinderCore

@Suite final class ProductivityTests {
    private let scratch: URL
    private let calendar: Calendar

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("NeoFinderProductivityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        calendar = gregorian
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test func testFuzzyMatchingRanksContiguousAndLeadingMatchesFirst() throws {
        #expect(FuzzyMatcher.score("Documents", query: "xyz") == nil)
        #expect(FuzzyMatcher.score("Documents", query: "dcm") != nil)
        #expect(FuzzyMatcher.score("ＡＢＣ資料", query: "abc") != nil)
        #expect(FuzzyMatcher.score("anything", query: "  ") == 0)
        let leading = try #require(FuzzyMatcher.score("請求書", query: "請求"))
        let inside = try #require(FuzzyMatcher.score("未請求書類", query: "請求"))
        #expect(leading > inside)
        let contiguous = try #require(FuzzyMatcher.score("abc_def", query: "abc"))
        let scattered = try #require(FuzzyMatcher.score("a_b_c", query: "abc"))
        #expect(contiguous > scattered)
    }

    @Test func testFuzzyMatchingRequiresEveryTerm() {
        #expect(FuzzyMatcher.score("経理 2026 請求", query: "請求 経理") != nil)
        #expect(FuzzyMatcher.score("経理 2026 請求", query: "請求 給与") == nil)
    }

    @Test func testRecentLocationsCountRecencyAndLimit() {
        var list: [RecentLocation] = []
        let now = Date()
        RecentLocations.record("/a", in: &list, now: now.addingTimeInterval(-90 * 86_400))
        RecentLocations.record("/b", in: &list, now: now)
        RecentLocations.record("/b", in: &list, weight: 3, now: now)
        #expect((list.first { $0.path == "/b" }?.count) == (4))
        #expect(RecentLocations.frecency(list[1], now: now) > RecentLocations.frecency(list[0], now: now))
        for index in 0..<(RecentLocations.limit + 20) { RecentLocations.record("/old/\(index)", in: &list, now: now.addingTimeInterval(-400 * 86_400)) }
        #expect((list.count) == (RecentLocations.limit))
        #expect(list.contains { $0.path == "/b" })
    }

    @Test func testPathTemplateExpandsCalendarAndFiscalYear() {
        let november = date(2026, 11, 13)
        #expect((PathTemplate.expand("~/経理/{年度}年度/{MM}月", date: november, calendar: calendar)) == ("~/経理/2026年度/11月"))
        let february = date(2027, 2, 5)
        #expect((PathTemplate.expand("{年度}/{yyyy}/{yy}/{MM}/{M}/{dd}/{d}", date: february, calendar: calendar)) == ("2026/2027/27/02/2/05/5"))
        #expect((PathTemplate.expand("令和{令和年度}年度・令和{令和}年", date: february, calendar: calendar)) == ("令和8年度・令和9年"))
        #expect((PathTemplate.expand("{MM-1}月と{MM+1}月、{yyyy-2}", date: february, calendar: calendar)) == ("01月と03月、2026"))
        #expect((PathTemplate.expand("{年度-12}年度", date: february, calendar: calendar)) == ("2025年度"))
        #expect((PathTemplate.expand("{unknown}と{MM", date: february, calendar: calendar)) == ("{unknown}と{MM"))
        #expect(PathTemplate.containsVariable("/a/{MM}月"))
        #expect(!PathTemplate.containsVariable("/a/{メモ}/b"))
    }

    @Test func testPathTemplateSuggestionReplacesOnlyDateParts() {
        let november = date(2026, 11, 13)
        #expect((PathTemplate.suggest(for: "/Users/a/経理/2026年度/11月", date: november, calendar: calendar)) == ("/Users/a/経理/{年度}年度/{MM}月"))
        #expect(PathTemplate.suggest(for: "/Users/a/資料", date: november, calendar: calendar) == nil)
        let february = date(2027, 2, 5)
        #expect((PathTemplate.suggest(for: "/x/2026年度/2月", date: february, calendar: calendar)) == ("/x/{年度}年度/{M}月"))
        #expect(PathTemplate.suggest(for: "/x/12月", date: february, calendar: calendar) == nil)
        #expect((PathTemplate.suggest(for: "/x/2027-02", date: february, calendar: calendar)) == ("/x/{yyyy}-{MM}"))
        let suggestion = PathTemplate.suggest(for: "/x/2026年度/11月", date: november, calendar: calendar) ?? ""
        #expect((PathTemplate.expand(suggestion, date: november, calendar: calendar)) == ("/x/2026年度/11月"))
    }

    @Test func testTemplatedTabResolvesAndSurvivesSaving() throws {
        var tab = BrowserTab(path: "/work")
        #expect(tab.templatePath() == nil)
        tab.template = "/work/{yyyy}/{MM}"
        #expect((tab.templatePath(on: date(2026, 11, 13))) == ("/work/2026/11"))
        let decoded = try JSONDecoder().decode(BrowserTab.self, from: JSONEncoder().encode(tab))
        #expect((decoded.template) == ("/work/{yyyy}/{MM}"))
    }

    @Test func testSessionKeepsNewFieldsAndReadsOlderFiles() throws {
        let store = SessionStore(directory: scratch.appendingPathComponent("Settings"))
        var session = SavedSession(current: WorkspaceState(name: "月次", leftPath: "/left", rightPath: "/right"))
        #expect((session.triageSlots.count) == (SavedSession.triageSlotCount))
        session.triageSlots[2] = "/経理/請求書"
        session.shelf = ["/left/a.pdf"]
        RecentLocations.record("/right", in: &session.recents)
        try store.save(session)
        let loaded = try #require(store.load())
        #expect((loaded.triageSlots[2]) == ("/経理/請求書"))
        #expect((loaded.shelf) == (["/left/a.pdf"]))
        #expect((loaded.recents.map(\.path)) == (["/right"]))

        // A file written by version 0.1 has none of these keys.
        let legacy = Data("""
        {"schemaVersion":1,"current":{"name":"前回の作業","left":{"tabs":[{"path":"/l"}]},"right":{"tabs":[{"path":"/r"}]}}}
        """.utf8)
        let old = try JSONDecoder().decode(SavedSession.self, from: legacy)
        #expect((old.triageSlots) == (Array(repeating: "", count: SavedSession.triageSlotCount)))
        #expect(old.shelf.isEmpty && old.recents.isEmpty)
        #expect(old.current.left.selectedTab.template == nil)
    }

    @Test func testFolderComparisonMarksMissingNewerAndDifferent() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func entry(_ name: String, size: Int64 = 10, offset: TimeInterval = 0, folder: Bool = false) -> FileEntry {
            FileEntry(url: URL(fileURLWithPath: "/side/" + name), isDirectory: folder, size: size, modifiedAt: base.addingTimeInterval(offset))
        }
        let left = [entry("same.txt"), entry("only.txt"), entry("newer.txt", offset: 60), entry("older.txt"),
                    entry("size.txt", size: 11), entry("rounded.txt", offset: 1), entry("資料", folder: true), entry("kind", folder: true)]
        let right = [entry("same.txt"), entry("newer.txt"), entry("older.txt", offset: 3600),
                     entry("size.txt"), entry("rounded.txt"), entry("資料", offset: 999, folder: true), entry("kind")]
        let marks = FolderComparison.statuses(for: left, against: right)
        #expect((marks["same.txt"]) == (.same))
        #expect((marks["only.txt"]) == (.onlyHere))
        #expect((marks["newer.txt"]) == (.newer))
        #expect((marks["older.txt"]) == (.older))
        #expect((marks["size.txt"]) == (.different))
        #expect((marks["rounded.txt"]) == (.same))
        #expect((marks["資料"]) == (.same))
        #expect((marks["kind"]) == (.different))
        #expect((FolderComparison.statuses(for: right, against: left)["newer.txt"]) == (.older))
    }

    @Test func testFlatListingNamesDescendantsByRelativePath() throws {
        let manager = FileManager.default
        let nested = scratch.appendingPathComponent("a/深い", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: scratch.appendingPathComponent("c.txt"))
        try Data("2".utf8).write(to: nested.appendingPathComponent("b.txt"))
        try Data("3".utf8).write(to: scratch.appendingPathComponent(".hidden"))
        let names = Set(try FolderReader.flatContents(of: scratch, showHidden: false).map(\.name))
        #expect((names) == (["a", "a/深い", "a/深い/b.txt", "c.txt"]))
        #expect(try FolderReader.flatContents(of: scratch, showHidden: true).contains { $0.name == ".hidden" })
        #expect((try FolderReader.flatContents(of: scratch, showHidden: false, limit: 2).count) == (2))
        #expect(throws: (any Error).self) { try FolderReader.flatContents(of: self.scratch.appendingPathComponent("missing"), showHidden: false) }
    }
}
