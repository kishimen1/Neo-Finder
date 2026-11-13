import Foundation

/// Metadata for a single directory entry. Enumerating a folder never reads file contents.
public struct FileEntry: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymbolicLink: Bool
    public let size: Int64
    public let modifiedAt: Date?
    public let tags: [String]

    public init(url: URL, name: String? = nil, isDirectory: Bool = false,
                isPackage: Bool = false, isSymbolicLink: Bool = false,
                size: Int64 = 0, modifiedAt: Date? = nil, tags: [String] = []) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.size = max(0, size)
        self.modifiedAt = modifiedAt
        self.tags = tags
    }

    /// Folders remain first; packages are ordinary items. Ties have a deterministic order.
    public static func filtered(_ entries: [FileEntry], query: String,
                                sort: FileSort, ascending: Bool) -> [FileEntry] {
        let key = comparisonKey(query.trimmingCharacters(in: .whitespacesAndNewlines))
        // Normalize once per entry, rather than once per sort comparison on large folders.
        let matches = entries.map { (entry: $0, key: comparisonKey($0.name)) }
            .filter { key.isEmpty || $0.key.contains(key) }
        return matches.sorted { first, second in
            let left = first.entry
            let right = second.entry
            let leftFolder = left.isDirectory && !left.isPackage
            let rightFolder = right.isDirectory && !right.isPackage
            if leftFolder != rightFolder { return leftFolder }
            let order: ComparisonResult
            switch sort {
            case .name:
                order = compareNames(first, second)
            case .date:
                // Unknown dates stay last regardless of direction.
                if (left.modifiedAt == nil) != (right.modifiedAt == nil) { return left.modifiedAt != nil }
                if let first = left.modifiedAt, let second = right.modifiedAt, first != second {
                    order = first < second ? .orderedAscending : .orderedDescending
                } else { order = compareNames(first, second) }
            case .size:
                if left.size != right.size {
                    order = left.size < right.size ? .orderedAscending : .orderedDescending
                } else { order = compareNames(first, second) }
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }.map(\.entry)
    }

    static func comparisonKey(_ string: String) -> String {
        string.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "ja_JP")
        ).precomposedStringWithCanonicalMapping
    }

    private static func compareNames(_ left: (entry: FileEntry, key: String),
                                     _ right: (entry: FileEntry, key: String)) -> ComparisonResult {
        let result = left.key.localizedStandardCompare(right.key)
        if result != .orderedSame { return result }
        return left.entry.id.compare(right.entry.id)
    }
}

public enum FolderReader {
    /// Requests only URL resource metadata, without opening files, hashing, or recursing.
    public static func contents(of url: URL, showHidden: Bool) throws -> [FileEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                                       .fileSizeKey, .contentModificationDateKey, .tagNamesKey]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: options
        )
        return urls.map { child in
            // An entry may disappear between enumeration and metadata lookup. Keeping its name
            // lets the caller refresh without making one transient entry hide the whole folder.
            let values = try? child.resourceValues(forKeys: keys)
            return FileEntry(url: child, isDirectory: values?.isDirectory ?? false,
                             isPackage: values?.isPackage ?? false,
                             isSymbolicLink: values?.isSymbolicLink ?? false,
                             size: Int64(values?.fileSize ?? 0),
                             modifiedAt: values?.contentModificationDate, tags: values?.tagNames ?? [])
        }
    }
}

extension FolderReader {
    /// Lists every descendant, named by its path relative to `url`. Packages are single items and
    /// are not entered. Enumeration stops at `limit` entries so a huge tree cannot stall the app.
    public static func flatContents(of url: URL, showHidden: Bool, limit: Int = 20_000) throws -> [FileEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                                       .fileSizeKey, .contentModificationDateKey, .tagNamesKey]
        // Report an unreadable root the same way the ordinary listing does.
        _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: options, errorHandler: { _, _ in true }
        ) else { return [] }
        let prefix = url.standardizedFileURL.path == "/" ? "/" : url.standardizedFileURL.path + "/"
        var result: [FileEntry] = []
        while result.count < limit, let child = enumerator.nextObject() as? URL {
            let values = try? child.resourceValues(forKeys: keys)
            let path = child.standardizedFileURL.path
            let name = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : child.lastPathComponent
            result.append(FileEntry(url: child, name: name, isDirectory: values?.isDirectory ?? false,
                                    isPackage: values?.isPackage ?? false,
                                    isSymbolicLink: values?.isSymbolicLink ?? false,
                                    size: Int64(values?.fileSize ?? 0),
                                    modifiedAt: values?.contentModificationDate, tags: values?.tagNames ?? []))
        }
        return result
    }
}

public enum FileSort: String, Codable, CaseIterable, Sendable { case name, date, size }
public enum BrowserViewMode: String, Codable, Sendable { case list, columns }

public struct BrowserTab: Codable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    public var viewMode: BrowserViewMode
    public var sort: FileSort
    public var ascending: Bool
    public var history: [String]
    public var historyIndex: Int
    /// A calendar-following path such as 「~/経理/{年度}年度/{MM}月」. See `PathTemplate`.
    public var template: String?
    public var canGoBack: Bool { historyIndex > 0 && historyIndex < history.count }
    public var canGoForward: Bool { historyIndex >= 0 && historyIndex + 1 < history.count }
    public static let historyLimit = 100

    public init(path: String, id: UUID = UUID(), viewMode: BrowserViewMode = .list,
                sort: FileSort = .name, ascending: Bool = true) {
        self.id = id
        self.path = Self.cleanPath(path)
        self.viewMode = viewMode
        self.sort = sort
        self.ascending = ascending
        history = [self.path]
        historyIndex = 0
    }

    public mutating func navigate(to path: String) {
        repairHistory()
        let destination = Self.cleanPath(path)
        guard destination != self.path else { return }
        history = Array(history.prefix(historyIndex + 1))
        history.append(destination)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        historyIndex = history.count - 1
        self.path = destination
    }

    @discardableResult public mutating func goBack() -> String? {
        repairHistory()
        guard canGoBack else { return nil }
        historyIndex -= 1
        path = history[historyIndex]
        return path
    }

    @discardableResult public mutating func goForward() -> String? {
        repairHistory()
        guard canGoForward else { return nil }
        historyIndex += 1
        path = history[historyIndex]
        return path
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, viewMode, sort, ascending, history, historyIndex, template
    }

    /// The folder this tab's template points to on `date`; nil for an ordinary tab.
    public func templatePath(on date: Date = Date()) -> String? {
        guard let template, !template.isEmpty else { return nil }
        return Self.cleanPath(PathTemplate.expand(template, date: date))
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = Self.cleanPath(try values.decode(String.self, forKey: .path))
        viewMode = (try? values.decode(BrowserViewMode.self, forKey: .viewMode)) ?? .list
        sort = (try? values.decode(FileSort.self, forKey: .sort)) ?? .name
        ascending = try values.decodeIfPresent(Bool.self, forKey: .ascending) ?? true
        history = try values.decodeIfPresent([String].self, forKey: .history) ?? [path]
        historyIndex = try values.decodeIfPresent(Int.self, forKey: .historyIndex) ?? 0
        template = try values.decodeIfPresent(String.self, forKey: .template)
        repairHistory()
    }

    fileprivate mutating func repairHistory() {
        path = Self.cleanPath(path)
        history = history.filter { !$0.isEmpty }.map(Self.cleanPath)
        if history.isEmpty { history = [path] }
        historyIndex = min(max(0, historyIndex), history.count - 1)
        if history[historyIndex] != path {
            if let matching = history.lastIndex(of: path) { historyIndex = matching }
            else {
                history = Array(history.prefix(historyIndex + 1)) + [path]
                historyIndex = history.count - 1
            }
        }
        if history.count > Self.historyLimit {
            // Keep the current position even when the malformed history has a long forward tail.
            let start = max(0, historyIndex - Self.historyLimit + 1)
            let end = min(history.count, start + Self.historyLimit)
            history = Array(history[start..<end])
            historyIndex -= start
        }
    }

    fileprivate static func cleanPath(_ path: String) -> String {
        guard !path.isEmpty else { return FileManager.default.homeDirectoryForCurrentUser.path }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}

public struct PaneState: Codable, Sendable {
    public var tabs: [BrowserTab]
    public var selectedTabID: UUID

    public init(path: String) {
        let tab = BrowserTab(path: path)
        tabs = [tab]
        selectedTabID = tab.id
    }

    public var selectedTabIndex: Int { tabs.firstIndex { $0.id == selectedTabID } ?? 0 }
    public var selectedTab: BrowserTab {
        get { tabs.isEmpty ? BrowserTab(path: FileManager.default.homeDirectoryForCurrentUser.path) : tabs[selectedTabIndex] }
        set {
            if tabs.isEmpty { tabs = [newValue] }
            else { tabs[selectedTabIndex] = newValue }
            selectedTabID = newValue.id
        }
    }

    private enum CodingKeys: String, CodingKey { case tabs, selectedTabID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try values.decodeIfPresent([BrowserTab].self, forKey: .tabs) ?? []
        selectedTabID = try values.decodeIfPresent(UUID.self, forKey: .selectedTabID) ?? UUID()
        repair()
    }

    fileprivate mutating func repair() {
        if tabs.isEmpty { tabs = [BrowserTab(path: FileManager.default.homeDirectoryForCurrentUser.path)] }
        var ids: Set<UUID> = []
        for index in tabs.indices {
            tabs[index].repairHistory()
            if !ids.insert(tabs[index].id).inserted { tabs[index].id = UUID() }
        }
        if !tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = tabs[0].id }
    }
}

public struct WorkspaceState: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var left: PaneState
    public var right: PaneState
    public var activeSide: Int
    public var dividerRatio: Double
    public var verticalSplit: Bool

    public init(name: String, leftPath: String, rightPath: String, id: UUID = UUID(),
                activeSide: Int = 0, dividerRatio: Double = 0.5, verticalSplit: Bool = true) {
        self.id = id
        self.name = name
        left = PaneState(path: leftPath)
        right = PaneState(path: rightPath)
        self.activeSide = activeSide == 1 ? 1 : 0
        self.dividerRatio = dividerRatio.isFinite ? min(0.8, max(0.2, dividerRatio)) : 0.5
        self.verticalSplit = verticalSplit
    }

    private enum CodingKeys: String, CodingKey { case id, name, left, right, activeSide, dividerRatio, verticalSplit }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "前回の作業"
        left = try values.decode(PaneState.self, forKey: .left)
        right = try values.decode(PaneState.self, forKey: .right)
        activeSide = (try values.decodeIfPresent(Int.self, forKey: .activeSide)) == 1 ? 1 : 0
        let ratio = try values.decodeIfPresent(Double.self, forKey: .dividerRatio) ?? 0.5
        dividerRatio = ratio.isFinite ? min(0.8, max(0.2, ratio)) : 0.5
        verticalSplit = try values.decodeIfPresent(Bool.self, forKey: .verticalSplit) ?? true
    }
}

public struct Favorite: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public init(name: String, path: String, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.path = BrowserTab.cleanPath(path)
    }
}

public struct FavoriteGroup: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [Favorite]
    public init(name: String, items: [Favorite] = [], id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.items = items
    }
}

public struct SavedSession: Codable, Sendable {
    public var schemaVersion: Int
    public var current: WorkspaceState
    public var workspaces: [WorkspaceState]
    public var favoriteGroups: [FavoriteGroup]
    public var showHidden: Bool
    public var relativeDates: Bool
    /// Visited folders and transfer destinations, ranked by `RecentLocations.frecency`.
    public var recents: [RecentLocation]
    /// Destinations for the number keys 1–9 in triage mode; an empty string is an unassigned key.
    public var triageSlots: [String]
    /// Items collected on the shelf, as paths.
    public var shelf: [String]
    public static let triageSlotCount = 9

    public init(schemaVersion: Int = 1, current: WorkspaceState,
                workspaces: [WorkspaceState] = [], favoriteGroups: [FavoriteGroup] = [],
                showHidden: Bool = false, relativeDates: Bool = true) {
        recents = []
        triageSlots = Array(repeating: "", count: Self.triageSlotCount)
        shelf = []
        self.schemaVersion = schemaVersion
        self.current = current
        self.workspaces = workspaces
        self.favoriteGroups = favoriteGroups
        self.showHidden = showHidden
        self.relativeDates = relativeDates
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, current, workspaces, favoriteGroups, showHidden, relativeDates
        case recents, triageSlots, shelf
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        current = try values.decode(WorkspaceState.self, forKey: .current)
        workspaces = try values.decodeIfPresent([WorkspaceState].self, forKey: .workspaces) ?? []
        favoriteGroups = try values.decodeIfPresent([FavoriteGroup].self, forKey: .favoriteGroups) ?? []
        showHidden = try values.decodeIfPresent(Bool.self, forKey: .showHidden) ?? false
        relativeDates = try values.decodeIfPresent(Bool.self, forKey: .relativeDates) ?? true
        recents = (try? values.decodeIfPresent([RecentLocation].self, forKey: .recents)) ?? []
        var slots = (try? values.decodeIfPresent([String].self, forKey: .triageSlots)) ?? []
        slots = Array(slots.prefix(Self.triageSlotCount))
        slots += Array(repeating: "", count: Self.triageSlotCount - slots.count)
        triageSlots = slots
        shelf = (try? values.decodeIfPresent([String].self, forKey: .shelf)) ?? []
        var workspaceIDs: Set<UUID> = []
        for index in workspaces.indices {
            if !workspaceIDs.insert(workspaces[index].id).inserted { workspaces[index].id = UUID() }
        }
        var groupIDs: Set<UUID> = []
        var favoriteIDs: Set<UUID> = []
        for group in favoriteGroups.indices {
            if !groupIDs.insert(favoriteGroups[group].id).inserted { favoriteGroups[group].id = UUID() }
            for item in favoriteGroups[group].items.indices {
                if !favoriteIDs.insert(favoriteGroups[group].items[item].id).inserted {
                    favoriteGroups[group].items[item].id = UUID()
                }
            }
        }
    }
}
