import AppKit
import NeoFinderCore
import Darwin

@MainActor
final class AccessManager {
    private let store: SessionStore
    private var scopes: [URL] = []
    private let defaults: UserDefaults
    private(set) var writeRoots: [URL]

    init(store: SessionStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        writeRoots = (defaults.stringArray(forKey: "localWriteRoots") ?? []).map { URL(fileURLWithPath: $0) }
        scopes = store.restoreBookmarks().filter { $0.startAccessingSecurityScopedResource() }
    }

    func register(_ url: URL, localWrite: Bool) throws {
        if !scopes.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }), url.startAccessingSecurityScopedResource() {
            scopes.append(url)
        }
        try store.saveBookmark(for: url)
        if localWrite {
            try Self.validateLocal(url)
            let root = url.resolvingSymlinksInPath().standardizedFileURL
            if !writeRoots.contains(root) { writeRoots.append(root) }
            defaults.set(writeRoots.map(\.path), forKey: "localWriteRoots")
        }
    }

    func isWriteEnabled(_ directory: URL) -> Bool { (try? requireWrite([directory], directory: true)) != nil }

    func endAccess() {
        for url in scopes { url.stopAccessingSecurityScopedResource() }
        scopes.removeAll()
    }

    func requireWrite(_ urls: [URL], directory: Bool = false) throws {
        for url in urls {
            // Operate on a symbolic link itself, but never trust a symlinked parent.
            let location = directory ? url : url.deletingLastPathComponent()
            try Self.validateLocal(location)
            if !directory {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey])
                if values.isUbiquitousItem == true { throw Self.unsupportedLocation() }
                if values.isDirectory == true && values.isSymbolicLink != true {
                    try Self.validateLocal(url)
                    let canonicalItem = url.resolvingSymlinksInPath().standardizedFileURL
                    if writeRoots.contains(canonicalItem) ||
                        FileManager.default.fileExists(atPath: canonicalItem.appendingPathComponent("Library/CloudStorage").path) ||
                        FileManager.default.fileExists(atPath: canonicalItem.appendingPathComponent("CloudStorage").path) ||
                        FileManager.default.fileExists(atPath: canonicalItem.appendingPathComponent("Library/Mobile Documents").path) ||
                        FileManager.default.fileExists(atPath: canonicalItem.appendingPathComponent("Mobile Documents").path) {
                        throw NSError(domain: "NeoFinder", code: 3, userInfo: [NSLocalizedDescriptionKey: "登録した作業フォルダ自体やクラウド領域を含むフォルダは変更できません。必要な場合はFinderで操作してください。"])
                    }
                }
            }
            let canonical = location.resolvingSymlinksInPath().standardizedFileURL
            guard writeRoots.contains(where: { Self.contains($0, canonical) }) else {
                throw NSError(domain: "NeoFinder", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "「\(location.lastPathComponent)」では編集が有効になっていません。「フォルダを登録」から、クラウド同期されていないローカルフォルダを登録してください。"])
            }
        }
    }

    static func contains(_ root: URL, _ child: URL) -> Bool {
        let parent = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = child.resolvingSymlinksInPath().standardizedFileURL.path
        return path == parent || path.hasPrefix(parent == "/" ? "/" : parent + "/")
    }

    static func validateLocal(_ url: URL) throws {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try canonical.resourceValues(forKeys: [.volumeIsLocalKey, .isUbiquitousItemKey])
        let path = canonical.path
        guard values.volumeIsLocal == true, values.isUbiquitousItem != true,
              !path.contains("/Library/CloudStorage/"), !path.hasSuffix("/Library/CloudStorage"),
              !path.contains("/Library/Mobile Documents/"), !path.hasSuffix("/Library/Mobile Documents") else {
            throw unsupportedLocation()
        }
        var info = statfs()
        guard statfs(path, &info) == 0 else { throw unsupportedLocation() }
        let format = withUnsafePointer(to: &info.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        guard format == "apfs" else { throw unsupportedLocation() }
    }

    private static func unsupportedLocation() -> NSError {
        NSError(domain: "NeoFinder", code: 2, userInfo: [NSLocalizedDescriptionKey:
            "この初期版では、クラウド同期されていないローカルAPFSフォルダで編集できます。この場所はFinderで操作してください。"])
    }
}
