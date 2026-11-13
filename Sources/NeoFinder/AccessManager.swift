import AppKit
import NeoFinderCore

/// Decides where Neo-Finder may change files. The app is not sandboxed, so macOS privacy
/// settings (Full Disk Access and the per-folder prompts) decide what can be read at all.
/// Safety comes from undoable operations rather than from a list of registered folders.
@MainActor
final class AccessManager {
    private let defaults: UserDefaults
    private static let remoteKey = "allowRemoteWrites"

    /// Cloud-synced and network locations stay read-only until the user opts in.
    var allowRemoteWrites: Bool {
        get { defaults.bool(forKey: Self.remoteKey) }
        set { defaults.set(newValue, forKey: Self.remoteKey) }
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// `directory: true` checks a folder that will receive items; otherwise each URL is an item
    /// that will itself be moved, renamed or trashed.
    func requireWrite(_ urls: [URL], directory: Bool = false) throws {
        for url in urls {
            // Operate on a symbolic link itself, but judge the location by its real parent.
            let location = directory ? url : url.deletingLastPathComponent()
            if Self.isRemote(location) && !allowRemoteWrites {
                throw NSError(domain: "NeoFinder", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "「\(location.lastPathComponent)」はクラウド同期またはネットワーク上の場所です。編集するには、Neo-Finderメニューの「クラウド・ネットワーク上の編集を許可（実験的）」を有効にしてください。"])
            }
            if !directory && Self.isProtected(url) {
                throw NSError(domain: "NeoFinder", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "「\(url.lastPathComponent)」はシステムやホームの基本フォルダのため、Neo-Finderでは移動・名前変更・削除しません。必要な場合はFinderで操作してください。"])
            }
        }
    }

    func isWriteEnabled(_ directory: URL) -> Bool { (try? requireWrite([directory], directory: true)) != nil }

    /// iCloud Drive, File Provider storage (OneDrive, Dropbox, Google Drive …) and non-local volumes.
    static func isRemote(_ url: URL) -> Bool {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let path = canonical.path + "/"
        if path.contains("/Library/CloudStorage/") || path.contains("/Library/Mobile Documents/") { return true }
        guard let values = try? canonical.resourceValues(forKeys: [.volumeIsLocalKey, .isUbiquitousItemKey]) else {
            return false
        }
        return values.volumeIsLocal == false || values.isUbiquitousItem == true
    }

    /// Items whose loss or rename would break the account or the system: volume roots, top-level
    /// system folders, the home folder and its standard folders.
    static func isProtected(_ url: URL) -> Bool {
        let path = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
        let components = path.split(separator: "/")
        if components.count <= 1 { return true }
        if components.count == 2 && (components[0] == "Users" || components[0] == "Volumes") { return true }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        if path == home { return true }
        let standard = ["Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public"]
        return standard.contains { path == home + "/" + $0 }
    }
}
