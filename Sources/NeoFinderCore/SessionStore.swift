import Foundation

public enum SessionStoreError: LocalizedError {
    case unsupportedSchemaVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "保存データのバージョン \(version) には対応していません。既存データは変更しませんでした。"
        }
    }
}

/// Stores application state, never sidecar files in the user's browsed folders.
public final class SessionStore {
    public static let currentSchemaVersion = 1
    public let directory: URL
    private let lock = NSLock()
    private var sessionURL: URL { directory.appendingPathComponent("session.json") }
    private var bookmarkURL: URL { directory.appendingPathComponent("bookmarks.json") }

    public init(directory: URL) { self.directory = directory }

    public func load() -> SavedSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(SavedSession.self, from: data),
              session.schemaVersion == Self.currentSchemaVersion else { return nil }
        return session
    }

    public func save(_ session: SavedSession) throws {
        lock.lock()
        defer { lock.unlock() }
        guard session.schemaVersion == Self.currentSchemaVersion else {
            throw SessionStoreError.unsupportedSchemaVersion(session.schemaVersion)
        }
        // Loading a newer installation's state must not erase it with default settings.
        if let existing = try? Data(contentsOf: sessionURL),
           let object = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
           let version = object["schemaVersion"] as? Int, version != Self.currentSchemaVersion {
            throw SessionStoreError.unsupportedSchemaVersion(version)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        try prepareDirectory()
        try data.write(to: sessionURL, options: .atomic)
    }

    public func saveBookmark(for url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        var bookmarks = readBookmarks()
        bookmarks[url.standardizedFileURL.path] = try url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        try prepareDirectory()
        try JSONEncoder().encode(bookmarks).write(to: bookmarkURL, options: .atomic)
    }

    /// The application owns startAccessingSecurityScopedResource / stopAccessing pairs.
    /// Unavailable volumes are not mounted and a failed bookmark never falls back to a path.
    public func restoreBookmarks() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        var bookmarks = readBookmarks()
        var refreshed = false
        var results: [URL] = []
        var seen: Set<String> = []
        for path in bookmarks.keys.sorted() {
            guard let bookmark = bookmarks[path] else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark,
                                    options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                    relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if seen.insert(url.standardizedFileURL.path).inserted { results.append(url) }
            if stale, let updated = try? url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
            ) {
                bookmarks[path] = updated
                refreshed = true
            }
        }
        if refreshed, let data = try? JSONEncoder().encode(bookmarks) {
            try? data.write(to: bookmarkURL, options: .atomic)
        }
        return results
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func readBookmarks() -> [String: Data] {
        guard let data = try? Data(contentsOf: bookmarkURL),
              let bookmarks = try? JSONDecoder().decode([String: Data].self, from: data) else { return [:] }
        return bookmarks
    }
}
