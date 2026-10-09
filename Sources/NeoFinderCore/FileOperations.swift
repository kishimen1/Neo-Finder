import Foundation
import CryptoKit
import Darwin

public enum ConflictPolicy: String, Codable, CaseIterable, Sendable {
    case keepBoth, skip, cancel
}

public struct OperationReport: Codable, Sendable {
    public let summary: String
    public let completed: Int
    public let failures: [String]
    public let cancelled: Bool

    public init(summary: String, completed: Int, failures: [String], cancelled: Bool = false) {
        self.summary = summary
        self.completed = completed
        self.failures = failures
        self.cancelled = cancelled
    }
}

/// A synchronous engine. Call it on a background serial queue; cancellation is thread-safe.
/// No operation replaces an existing item. Undo is restricted to this engine's lifetime.
public final class FileOperationEngine {
    public typealias TrashHandler = (URL) throws -> URL

    private let manager = FileManager.default
    private let operationLock = NSRecursiveLock()
    private let cancellationLock = NSLock()
    private var cancellationRequested = false
    private let journalURL: URL?
    private let trashHandler: TrashHandler?
    private var journal: [JournalEntry] = []
    private var journalReadError: String?
    private var undoStack: [[UndoAction]] = []
    private var coordinationStack: [NSFileCoordinator] = []
    /// Set only from the journal present at initialization; no previous work is resumed automatically.
    public private(set) var recoveryNotice: String?

    /// `trashHandler` is a test seam; production uses FileManager.trashItem and its returned URL.
    public init(journalURL: URL? = nil, trashHandler: TrashHandler? = nil) {
        self.journalURL = journalURL
        self.trashHandler = trashHandler
        if let url = journalURL, manager.fileExists(atPath: url.path) {
            do {
                journal = try JSONDecoder().decode([JournalEntry].self, from: Data(contentsOf: url))
                let unfinished = journal.filter { $0.state == "実行中" }
                if !unfinished.isEmpty {
                    let paths = unfinished.compactMap(\.activeItem).joined(separator: "\n")
                    recoveryNotice = "前回の未完了の操作が\(unfinished.count)件あります。自動再開や取り消しは行っていません。操作履歴と元・先の場所をFinderで確認してください。" + (paths.isEmpty ? "" : "\n確認対象:\n" + paths)
                }
            } catch {
                journalReadError = "操作履歴を読み込めません。履歴を確認してください: \(error.localizedDescription)"
                recoveryNotice = journalReadError
            }
        }
    }

    public var canUndo: Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return !undoStack.isEmpty
    }

    public func historyLines() -> [String] {
        operationLock.lock()
        defer { operationLock.unlock() }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return journal.reversed().map { entry in
            var lines = ["\(formatter.string(from: entry.date))  \(entry.kind) — \(entry.state) / \(entry.completed)項目完了"]
            if !entry.sources.isEmpty { lines.append("対象: " + entry.sources.joined(separator: ", ")) }
            if let destination = entry.destination { lines.append("先: " + destination) }
            if let activeItem = entry.activeItem { lines.append("処理中だった項目: " + activeItem) }
            lines.append(contentsOf: entry.failures)
            return lines.joined(separator: "\n")
        }
    }

    public func cancel() {
        cancellationLock.lock()
        cancellationRequested = true
        cancellationLock.unlock()
    }

    public func copy(_ sources: [URL], to directory: URL, conflict: ConflictPolicy = .keepBoth) throws -> OperationReport {
        try transfer(sources, to: directory, conflict: conflict, moving: false)
    }

    public func move(_ sources: [URL], to directory: URL, conflict: ConflictPolicy = .keepBoth) throws -> OperationReport {
        try transfer(sources, to: directory, conflict: conflict, moving: true)
    }

    public func rename(_ source: URL, to name: String) throws -> OperationReport {
        try validateName(name)
        return try perform(kind: "名称変更", sources: [source], destination: source.deletingLastPathComponent()) { source in
            try self.coordinated(source, directory: source.deletingLastPathComponent(), moving: true) { coordinatedSource, directory in
                try self.validateSource(coordinatedSource)
                let destination = directory.appendingPathComponent(name)
                guard coordinatedSource.standardizedFileURL.path != destination.standardizedFileURL.path else {
                    throw EngineError.message("元の名前と同じです。")
                }
                // Case-only renames need a separately journaled two-step operation; reject safely for now.
                if let targetStat = try self.optionalStat(destination), targetStat.st_ino == (try self.stat(coordinatedSource)).st_ino {
                    throw EngineError.message("同じ項目への名称変更です。大小文字のみの変更はFinderで行ってください。")
                }
                try self.exclusiveMove(coordinatedSource, to: destination)
                return self.mutationResult(url: destination, undoKind: .relocate(original: coordinatedSource))
            }
        }
    }

    public func createFolder(in directory: URL, name: String) throws -> OperationReport {
        try validateName(name)
        return try perform(kind: "フォルダ作成", sources: [directory], destination: directory) { directory in
            try self.coordinatedDirectory(directory) { coordinatedDirectory in
                try self.validateDirectory(coordinatedDirectory)
                let destination = coordinatedDirectory.appendingPathComponent(name, isDirectory: true)
                // POSIX mkdir is exclusive, unlike createDirectory's existing-directory success semantics.
                guard destination.withUnsafeFileSystemRepresentation({ mkdir($0!, mode_t(0o755)) }) == 0 else {
                    throw self.posixError(destination)
                }
                return self.mutationResult(url: destination, undoKind: .emptyFolder)
            }
        }
    }

    public func trash(_ sources: [URL]) throws -> OperationReport {
        try perform(kind: "ゴミ箱へ移動", sources: sources, destination: nil) { source in
            try self.coordinatedItem(source) { source in
                try self.validateSource(source)
                let before = try self.fingerprint(source)
                if let result = try self.sendToTrash(source) {
                    return self.trashMutationResult(url: result, original: source, before: before)
                }
                return MutationResult(url: source, undoKind: .relocate(original: source), fingerprint: nil,
                                      warning: "ゴミ箱内のURLを取得できません。Finderで確認してください。")
            }
        }
    }

    public func undoLast() throws -> OperationReport {
        operationLock.lock()
        defer { operationLock.unlock() }
        resetCancellation()
        guard let actions = undoStack.last else {
            return OperationReport(summary: "取り消せる操作はありません。", completed: 0, failures: [])
        }
        let entryID = try beginJournal(kind: "取り消し", sources: actions.map(\.url), destination: nil)
        undoStack.removeLast()
        var remaining: [UndoAction] = []
        var failures: [String] = []
        var completed = 0
        for action in actions.reversed() {
            if isCancelled {
                remaining.insert(action, at: 0)
                continue
            }
            do {
                try markActive(entryID, url: action.url)
                try coordinatedItem(action.url) { url in
                    guard try self.fingerprint(url) == action.fingerprint else {
                        throw EngineError.message("操作後に内容または属性が変わったため、取り消しを保留しました。")
                    }
                    switch action.kind {
                    case .removeCopy:
                        _ = try self.sendToTrash(url)
                    case .emptyFolder:
                        guard try self.manager.contentsOfDirectory(atPath: url.path).isEmpty else {
                            throw EngineError.message("フォルダに項目が追加されているため取り消せません。")
                        }
                        _ = try self.sendToTrash(url)
                    case .relocate(let original):
                        try self.coordinatedDirectory(original.deletingLastPathComponent()) { _ in
                            try self.validateDirectory(original.deletingLastPathComponent())
                            try self.exclusiveMove(url, to: original)
                        }
                    }
                }
                completed += 1
            } catch {
                remaining.insert(action, at: 0)
                failures.append("\(action.url.lastPathComponent): \(error.localizedDescription)")
            }
            updateJournal(entryID, completed: completed, failures: failures, finished: false)
        }
        if !remaining.isEmpty { undoStack.append(remaining) }
        return finish(entryID, kind: "取り消し", completed: completed, failures: failures)
    }

    private func transfer(_ sources: [URL], to directory: URL, conflict: ConflictPolicy, moving: Bool) throws -> OperationReport {
        try validateDirectory(directory)
        return try perform(kind: moving ? "移動" : "コピー", sources: sources, destination: directory) { source in
            try self.coordinated(source, directory: directory, moving: moving) { source, directory in
                try self.validateTransfer(source, to: directory, moving: moving)
                let proposed = directory.appendingPathComponent(source.lastPathComponent)
                let target = try self.availableDestination(proposed, conflict: conflict)
                guard let target else { return nil }
                if moving {
                    try self.exclusiveMove(source, to: target)
                    return self.mutationResult(url: target, undoKind: .relocate(original: source))
                }
                let before = try self.fingerprint(source)
                let staging = directory.appendingPathComponent(".NeoFinder-transfer-\(UUID().uuidString)", isDirectory: true)
                guard staging.withUnsafeFileSystemRepresentation({ mkdir($0!, mode_t(0o700)) }) == 0 else {
                    throw self.posixError(staging)
                }
                let payload = staging.appendingPathComponent(source.lastPathComponent)
                defer { try? self.manager.removeItem(at: staging) }
                try self.manager.copyItem(at: source, to: payload)
                guard try self.fingerprint(source) == before else {
                    throw EngineError.message("コピー中に元の項目が変わりました。コピー先は確定していません。")
                }
                let copied = try self.fingerprint(payload)
                guard before.contentSignature == copied.contentSignature else {
                    throw EngineError.message("コピー内容を検証できません。コピー先は確定していません。")
                }
                // A conflict appearing after preflight is an error, never an overwrite.
                try self.exclusiveMove(payload, to: target)
                return self.mutationResult(url: target, undoKind: .removeCopy)
            }
        }
    }

    private func perform(kind: String, sources: [URL], destination: URL?, body: (URL) throws -> MutationResult?) throws -> OperationReport {
        operationLock.lock()
        defer { operationLock.unlock() }
        resetCancellation()
        let entryID = try beginJournal(kind: kind, sources: sources, destination: destination)
        var actions: [UndoAction] = []
        var completed = 0
        var failures: [String] = []
        for source in sources {
            if isCancelled { break }
            do {
                try markActive(entryID, url: source)
                if let result = try body(source) {
                    completed += 1
                    if let fingerprint = result.fingerprint {
                        actions.append(UndoAction(url: result.url, kind: result.undoKind, fingerprint: fingerprint))
                    } else {
                        failures.append("\(source.lastPathComponent): 操作は完了しましたが取消用の確認ができません: \(result.warning ?? "不明なエラー")")
                    }
                }
            } catch EngineError.conflictCancelled {
                cancel()
                break
            } catch {
                failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
            updateJournal(entryID, completed: completed, failures: failures, finished: false)
        }
        if !actions.isEmpty { undoStack.append(actions) }
        return finish(entryID, kind: kind, completed: completed, failures: failures)
    }

    private func availableDestination(_ proposed: URL, conflict: ConflictPolicy) throws -> URL? {
        guard try optionalStat(proposed) != nil else { return proposed }
        switch conflict {
        case .skip: return nil
        case .cancel: throw EngineError.conflictCancelled
        case .keepBoth:
            let info = try stat(proposed)
            let isDirectory = info.st_mode & S_IFMT == S_IFDIR
            let ext = isDirectory ? "" : proposed.pathExtension
            let stem = ext.isEmpty ? proposed.lastPathComponent : proposed.deletingPathExtension().lastPathComponent
            for number in 2...10_000 {
                let name = "\(stem) (\(number))" + (ext.isEmpty ? "" : ".\(ext)")
                let candidate = proposed.deletingLastPathComponent().appendingPathComponent(name)
                if try optionalStat(candidate) == nil { return candidate }
            }
            throw EngineError.message("同名の項目が多すぎるため、保存先を決められません。")
        }
    }

    // Capture before releasing coordination, so another cooperating editor cannot be mistaken
    // for part of our own mutation. A snapshot failure never misreports a completed mutation.
    private func mutationResult(url: URL, undoKind: UndoKind) -> MutationResult {
        do {
            return MutationResult(url: url, undoKind: undoKind, fingerprint: try fingerprint(url), warning: nil)
        } catch {
            return MutationResult(url: url, undoKind: undoKind, fingerprint: nil, warning: error.localizedDescription)
        }
    }

    /// Finder can attach trash metadata just after trashItem returns. Wait for two identical
    /// snapshots, but accept only the same inode tree and bytes recorded before the move.
    /// This does not relax the later Undo comparison, which still includes all metadata.
    private func trashMutationResult(url: URL, original: URL, before: Fingerprint) -> MutationResult {
        let kind = UndoKind.relocate(original: original)
        var previous: Fingerprint?
        var warning = "ゴミ箱内の属性が更新中のため、取り消しを登録できませんでした。"
        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.05) }
            do {
                let snapshot = try fingerprint(url)
                guard before.contentSignature == snapshot.contentSignature,
                      before.identitySignature == snapshot.identitySignature else {
                    return MutationResult(url: url, undoKind: kind, fingerprint: nil,
                                          warning: "ゴミ箱への移動中に内容または実体が変わったため、取り消しを登録しませんでした。")
                }
                if previous == snapshot {
                    return MutationResult(url: url, undoKind: kind, fingerprint: snapshot, warning: nil)
                }
                previous = snapshot
            } catch EngineError.unstableSnapshot {
                previous = nil
            } catch {
                // Never retry permission errors or adopt an uninspectable item.
                warning = error.localizedDescription
                break
            }
        }
        return MutationResult(url: url, undoKind: kind, fingerprint: nil, warning: warning)
    }

    private func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw EngineError.message("名前に空文字、区切り文字、または . / .. は使用できません。")
        }
    }

    private func validateSource(_ url: URL) throws {
        guard url.isFileURL, url.standardizedFileURL.path != "/" else {
            throw EngineError.message("この場所は操作できません。")
        }
        _ = try stat(url)
    }

    private func validateDirectory(_ url: URL) throws {
        guard url.isFileURL, try stat(url.resolvingSymlinksInPath()).st_mode & S_IFMT == S_IFDIR else {
            throw EngineError.message("転送先のフォルダが見つかりません。")
        }
    }

    private func validateTransfer(_ source: URL, to directory: URL, moving: Bool) throws {
        try validateSource(source)
        try validateDirectory(directory)
        let sourceStat = try stat(source)
        let sourcePath = source.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(source.lastPathComponent).standardizedFileURL.path
        let destinationDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let target = destinationDirectory.appendingPathComponent(source.lastPathComponent)
        if target.path == sourcePath {
            throw EngineError.message("元の項目と転送先が同じ場所です。別のフォルダを選んでください。")
        }
        if let targetStat = try optionalStat(target), targetStat.st_dev == sourceStat.st_dev, targetStat.st_ino == sourceStat.st_ino {
            throw EngineError.message("元の項目と転送先が同じ実体です。")
        }
        if sourceStat.st_mode & S_IFMT == S_IFDIR,
           destinationDirectory.path == sourcePath || destinationDirectory.path.hasPrefix(sourcePath + "/") {
            throw EngineError.message("フォルダを自分自身またはその中へ転送できません。")
        }
        if moving, try stat(destinationDirectory).st_dev != sourceStat.st_dev {
            throw EngineError.message("別ボリュームへの移動には未対応です。コピーを使用してください。")
        }
    }

    private func exclusiveMove(_ source: URL, to destination: URL) throws {
        guard let notifier = coordinationStack.last else {
            throw EngineError.message("移動のアクセス調整がありません。")
        }
        notifier.item(at: source, willMoveTo: destination)
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                renamex_np(sourcePath!, destinationPath!, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw posixError(destination) }
        notifier.item(at: source, didMoveTo: destination)
    }

    private func sendToTrash(_ url: URL) throws -> URL? {
        if let trashHandler { return try trashHandler(url) }
        var result: NSURL?
        try manager.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    private func coordinated<T>(_ source: URL, directory: URL, moving: Bool, body: (URL, URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        if moving {
            coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: directory, options: [], error: &coordinationError) { source, destination in
                result = Result { try self.withCoordinator(coordinator) { try body(source, destination) } }
            }
        } else {
            coordinator.coordinate(readingItemAt: source, options: .withoutChanges, writingItemAt: directory, options: [], error: &coordinationError) { source, destination in
                result = Result { try self.withCoordinator(coordinator) { try body(source, destination) } }
            }
        }
        if let result { return try result.get() }
        throw coordinationError ?? EngineError.message("ファイルアクセスを調整できません。") as NSError
    }

    private func coordinatedItem<T>(_ url: URL, body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forMoving, error: &coordinationError) { coordinatedURL in
            result = Result { try self.withCoordinator(coordinator) { try body(coordinatedURL) } }
        }
        if let result { return try result.get() }
        throw coordinationError ?? EngineError.message("ファイルアクセスを調整できません。") as NSError
    }

    private func coordinatedDirectory<T>(_ url: URL, body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try self.withCoordinator(coordinator) { try body(coordinatedURL) } }
        }
        if let result { return try result.get() }
        throw coordinationError ?? EngineError.message("フォルダアクセスを調整できません。") as NSError
    }

    private func withCoordinator<T>(_ coordinator: NSFileCoordinator, body: () throws -> T) rethrows -> T {
        coordinationStack.append(coordinator)
        defer { coordinationStack.removeLast() }
        return try body()
    }

    private var isCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancellationRequested
    }

    private func resetCancellation() {
        cancellationLock.lock()
        cancellationRequested = false
        cancellationLock.unlock()
    }

    private func optionalStat(_ url: URL) throws -> Darwin.stat? {
        var value = Darwin.stat()
        if url.withUnsafeFileSystemRepresentation({ lstat($0!, &value) }) == 0 { return value }
        if errno == ENOENT || errno == ENOTDIR { return nil }
        throw posixError(url)
    }

    private func stat(_ url: URL) throws -> Darwin.stat {
        guard let value = try optionalStat(url) else {
            throw EngineError.message("項目が見つかりません: \(url.path)")
        }
        return value
    }

    private func posixError(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }

    // Full descendant content and metadata are compared. Symbolic links are hashed as links,
    // never followed. Hashing is deliberate work only during a write/undo, never directory browsing.
    private func fingerprint(_ root: URL) throws -> Fingerprint {
        var nodes: [NodeFingerprint] = []
        func walk(_ url: URL, relative: String) throws {
            let before = try stat(url)
            let type = before.st_mode & S_IFMT
            let digest: String
            if type == S_IFREG {
                let descriptor = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
                guard descriptor >= 0 else { throw posixError(url) }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var hasher = SHA256()
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
                digest = hasher.finalize().description
            } else if type == S_IFLNK {
                digest = try manager.destinationOfSymbolicLink(atPath: url.path)
            } else if type == S_IFDIR {
                digest = "directory"
            } else {
                throw EngineError.message("特殊ファイルの内容を安全に確認できません。")
            }
            let xattrs = try extendedAttributeDigest(url)
            let acl = try accessControlDigest(url)
            if type == S_IFDIR {
                let children = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children { try walk(child, relative: relative + "/" + child.lastPathComponent) }
            }
            let after = try stat(url)
            guard before.st_ino == after.st_ino, before.st_dev == after.st_dev,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw EngineError.unstableSnapshot
            }
            nodes.append(NodeFingerprint(relative: relative, device: Int64(after.st_dev), inode: UInt64(after.st_ino),
                                         mode: UInt32(after.st_mode), uid: after.st_uid, gid: after.st_gid,
                                         flags: after.st_flags, size: type == S_IFDIR ? 0 : Int64(after.st_size),
                                         modifiedSeconds: Int64(after.st_mtimespec.tv_sec), modifiedNanos: Int64(after.st_mtimespec.tv_nsec),
                                         createdSeconds: Int64(after.st_birthtimespec.tv_sec), createdNanos: Int64(after.st_birthtimespec.tv_nsec),
                                         digest: digest, xattrs: xattrs, acl: acl))
        }
        try walk(root, relative: "")
        return Fingerprint(nodes: nodes)
    }

    private func extendedAttributeDigest(_ url: URL) throws -> String {
        let size = url.withUnsafeFileSystemRepresentation { listxattr($0!, nil, 0, XATTR_NOFOLLOW) }
        guard size >= 0 else { throw posixError(url) }
        if size == 0 { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        let actual = url.withUnsafeFileSystemRepresentation { listxattr($0!, &buffer, size, XATTR_NOFOLLOW) }
        guard actual >= 0 else {
            if errno == ERANGE { throw EngineError.unstableSnapshot }
            throw posixError(url)
        }
        let names = buffer.prefix(actual).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.sorted()
        var hasher = SHA256()
        for name in names {
            let length = url.withUnsafeFileSystemRepresentation { getxattr($0!, name, nil, 0, 0, XATTR_NOFOLLOW) }
            guard length >= 0 else {
                if errno == ENOATTR { throw EngineError.unstableSnapshot }
                throw posixError(url)
            }
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { bytes in
                url.withUnsafeFileSystemRepresentation { getxattr($0!, name, bytes.baseAddress, length, 0, XATTR_NOFOLLOW) }
            }
            guard read == length else {
                if read >= 0 || errno == ERANGE || errno == ENOATTR { throw EngineError.unstableSnapshot }
                throw posixError(url)
            }
            hasher.update(data: Data(name.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: data)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().description
    }

    private func accessControlDigest(_ url: URL) throws -> String {
        errno = 0
        guard let acl = url.withUnsafeFileSystemRepresentation({ acl_get_link_np($0!, ACL_TYPE_EXTENDED) }) else {
            if errno == ENOENT || errno == ENOTSUP { return "" }
            throw posixError(url)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length = 0
        guard let text = acl_to_text(acl, &length) else { throw posixError(url) }
        defer { acl_free(text) }
        return SHA256.hash(data: Data(bytes: text, count: length)).description
    }

    private func beginJournal(kind: String, sources: [URL], destination: URL?) throws -> UUID {
        if let journalReadError { throw EngineError.message(journalReadError) }
        let entry = JournalEntry(id: UUID(), date: Date(), kind: kind, sources: sources.map(\.path), destination: destination?.path,
                                 activeItem: nil, completed: 0, failures: [], state: "実行中")
        journal.append(entry)
        if journal.count > 300 { journal.removeFirst(journal.count - 300) }
        try saveJournal()
        return entry.id
    }

    private func markActive(_ id: UUID, url: URL) throws {
        if let index = journal.firstIndex(where: { $0.id == id }) {
            journal[index].activeItem = url.path
            try saveJournal()
        }
    }

    private func updateJournal(_ id: UUID, completed: Int, failures: [String], finished: Bool) {
        if let index = journal.firstIndex(where: { $0.id == id }) {
            journal[index].completed = completed
            journal[index].failures = failures
            if finished {
                journal[index].activeItem = nil
                journal[index].state = isCancelled ? "中止" : failures.isEmpty ? "完了" : completed == 0 ? "失敗" : "部分成功"
            }
        }
    }

    private func finish(_ id: UUID, kind: String, completed: Int, failures: [String]) -> OperationReport {
        var failures = failures
        updateJournal(id, completed: completed, failures: failures, finished: true)
        do { try saveJournal() } catch { failures.append("操作履歴の保存に失敗しました: \(error.localizedDescription)") }
        let suffix = isCancelled ? "（中止）" : failures.isEmpty ? "" : "・\(failures.count)件の確認事項"
        return OperationReport(summary: "\(kind)：\(completed)項目完了\(suffix)", completed: completed, failures: failures, cancelled: isCancelled)
    }

    private func saveJournal() throws {
        guard let journalURL else { return }
        try manager.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: journalURL, options: .atomic)
    }

    private enum EngineError: LocalizedError {
        case message(String), conflictCancelled, unstableSnapshot
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            case .conflictCancelled: return "同名の項目があるため中止しました。"
            case .unstableSnapshot: return "確認中に項目が変更されました。"
            }
        }
    }
    private enum UndoKind { case removeCopy, emptyFolder, relocate(original: URL) }
    private struct MutationResult { let url: URL; let undoKind: UndoKind; let fingerprint: Fingerprint?; let warning: String? }
    private struct UndoAction { let url: URL; let kind: UndoKind; let fingerprint: Fingerprint }
    private struct Fingerprint: Equatable {
        let nodes: [NodeFingerprint]
        var contentSignature: [String] { nodes.map { "\($0.relative)|\($0.mode & UInt32(S_IFMT))|\($0.size)|\($0.digest)" } }
        var identitySignature: [String] { nodes.map { "\($0.relative)|\($0.device)|\($0.inode)" } }
    }
    private struct NodeFingerprint: Equatable {
        let relative: String
        let device: Int64
        let inode: UInt64
        let mode: UInt32
        let uid: UInt32
        let gid: UInt32
        let flags: UInt32
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanos: Int64
        let createdSeconds: Int64
        let createdNanos: Int64
        let digest: String
        let xattrs: String
        let acl: String
    }
    private struct JournalEntry: Codable {
        let id: UUID
        let date: Date
        let kind: String
        let sources: [String]
        let destination: String?
        var activeItem: String?
        var completed: Int
        var failures: [String]
        var state: String
    }
}
