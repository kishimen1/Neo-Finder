import AppKit
import NeoFinderCore

/// What the palette is being asked for.
enum PaletteMode {
    /// Folders to go to, commands and workspaces.
    case everything
    /// A folder that receives the given items.
    case destination(items: [URL], move: Bool)
    /// A folder handed back to the caller.
    case pick(prompt: String, handler: (URL) -> Void)
}

private struct FolderCandidate {
    var path: String
    var label: String
    var source: String
    var boost: Double
}

extension WorkspaceWindowController {
    @objc func showPalette() { presentPalette(.everything) }

    /// ⇧⌘G: start from the current folder's path and keep typing or press Tab to descend.
    @objc func goToFolder() {
        let path = activePane.currentURL.path
        presentPalette(.everything, initial: abbreviated(path) + (path == "/" ? "" : "/"))
    }

    @objc func moveToChosen() { chooseDestination(move: true) }
    @objc func copyToChosen() { chooseDestination(move: false) }

    private func chooseDestination(move: Bool) {
        let items = activePane.selectedURLs
        guard !items.isEmpty else { return }
        presentPalette(.destination(items: items, move: move))
    }

    func presentPalette(_ mode: PaletteMode, initial: String = "") {
        guard let window else { return }
        let prompt: String
        let placeholder: String
        switch mode {
        case .everything:
            prompt = "場所へ移動・コマンドを実行"
            placeholder = "フォルダ名、コマンド名、または / や ~ から始まるパス"
        case .destination(let items, let move):
            prompt = "\(items.count)項目の\(move ? "移動" : "コピー")先"
            placeholder = "行き先のフォルダ名、または / や ~ から始まるパス"
        case .pick(let text, _):
            prompt = text
            placeholder = "フォルダ名、または / や ~ から始まるパス"
        }
        palette.show(over: window, prompt: prompt, placeholder: placeholder, initial: initial) { [weak self] query in
            self?.paletteItems(mode, query: query) ?? []
        }
    }

    private func paletteItems(_ mode: PaletteMode, query rawQuery: String) -> [PaletteItem] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        let choose: (URL) -> Void
        let verb: String
        var excluded: Set<String> = []
        switch mode {
        case .everything:
            verb = "開く"
            choose = { [weak self] url in self?.activePane.navigate(to: url) }
        case .destination(let items, let move):
            verb = move ? "ここへ移動" : "ここへコピー"
            choose = { [weak self] url in self?.transfer(items, to: url, move: move) }
            excluded = Set(items.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        case .pick(_, let handler):
            verb = "選ぶ"
            choose = handler
        }
        if query.hasPrefix("/") || query.hasPrefix("~") { return pathItems(query, verb: verb, choose: choose) }

        var ranked: [(item: PaletteItem, score: Double)] = []
        for candidate in folderCandidates(preferOtherPane: !isEverything(mode)) where !excluded.contains(candidate.path) {
            var score = candidate.boost
            if !query.isEmpty {
                let byName = FuzzyMatcher.score(candidate.label, query: query).map { Double($0) + 300 }
                let byPath = FuzzyMatcher.score(candidate.path, query: query).map { Double($0) }
                guard let best = [byName, byPath].compactMap({ $0 }).max() else { continue }
                score = best + candidate.boost * 10
            }
            let url = URL(fileURLWithPath: candidate.path, isDirectory: true)
            let item = PaletteItem(title: candidate.label, subtitle: candidate.source + "　" + abbreviated(candidate.path),
                                   symbol: "folder", completion: abbreviated(candidate.path) + "/") { choose(url) }
            ranked.append((item, score))
        }
        ranked.sort { $0.score > $1.score }
        var result = Array(ranked.prefix(query.isEmpty ? 14 : 40))

        if isEverything(mode) {
            var extras: [(item: PaletteItem, score: Double)] = []
            for workspace in session.workspaces {
                let title = "作業セット：" + workspace.name
                guard let score = FuzzyMatcher.score(title, query: query) else { continue }
                let item = PaletteItem(title: title, subtitle: "保存した左右の配置を開く", symbol: "rectangle.split.2x1") { [weak self] in
                    self?.applyWorkspace(workspace)
                }
                extras.append((item, Double(score) + 150))
            }
            for command in paletteCommands() {
                guard let score = FuzzyMatcher.score(command.title + " " + command.keywords, query: query) else { continue }
                let item = PaletteItem(title: command.title, subtitle: "コマンド" + (command.shortcut.isEmpty ? "" : "　" + command.shortcut),
                                       symbol: "command", run: command.run)
                extras.append((item, Double(score) + 100))
            }
            if query.isEmpty { result += extras }
            else {
                result += extras
                result.sort { $0.score > $1.score }
            }
        }
        return result.map { $0.item }
    }

    private func isEverything(_ mode: PaletteMode) -> Bool {
        if case .everything = mode { return true }
        return false
    }

    /// Typed paths list the folders inside the directory being typed, so Tab can walk down the tree.
    private func pathItems(_ query: String, verb: String, choose: @escaping (URL) -> Void) -> [PaletteItem] {
        let expanded = (query as NSString).expandingTildeInPath
        let complete = query.hasSuffix("/") || query == "~"
        let directory = complete ? expanded : (expanded as NSString).deletingLastPathComponent
        let partial = complete ? "" : (expanded as NSString).lastPathComponent
        var items: [PaletteItem] = []
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            items.append(PaletteItem(title: verb + "：" + (url.path == "/" ? "Macintosh HD" : url.lastPathComponent),
                                     subtitle: url.path, symbol: "arrow.right.circle") { choose(url) })
        }
        let parent = URL(fileURLWithPath: directory, isDirectory: true)
        let children = (try? FolderReader.contents(of: parent, showHidden: session.showHidden || partial.hasPrefix("."))) ?? []
        var matches: [(entry: FileEntry, score: Int)] = []
        for entry in children where entry.isDirectory && !entry.isPackage {
            if let score = FuzzyMatcher.score(entry.name, query: partial) { matches.append((entry, score)) }
        }
        matches.sort { first, second in
            if first.score != second.score { return first.score > second.score }
            return first.entry.name.localizedStandardCompare(second.entry.name) == .orderedAscending
        }
        for match in matches.prefix(60) {
            let url = match.entry.url
            items.append(PaletteItem(title: match.entry.name, subtitle: abbreviated(url.path), symbol: "folder",
                                     completion: abbreviated(url.path) + "/") { choose(url) })
        }
        return items
    }

    /// Folders worth offering before anything is typed: favorites, recent places, open tabs and neighbours.
    private func folderCandidates(preferOtherPane: Bool) -> [FolderCandidate] {
        var byPath: [String: FolderCandidate] = [:]
        func add(_ path: String, label: String? = nil, source: String, boost: Double) {
            guard !path.isEmpty else { return }
            let clean = URL(fileURLWithPath: path).standardizedFileURL.path
            if let existing = byPath[clean], existing.boost >= boost { return }
            let name = clean == "/" ? "Macintosh HD" : (clean as NSString).lastPathComponent
            byPath[clean] = FolderCandidate(path: clean, label: label ?? name, source: source, boost: boost)
        }
        if preferOtherPane { add(otherPane.currentURL.path, source: "反対側のペイン", boost: 60) }
        for group in session.favoriteGroups {
            for favorite in group.items { add(favorite.path, label: favorite.name, source: "お気に入り・" + group.name, boost: 40) }
        }
        for (index, path) in session.triageSlots.enumerated() { add(path, source: "仕分け先\(index + 1)", boost: 30) }
        for (side, pane) in panes.enumerated() {
            let name = side == 0 ? "左" : "右"
            for tab in pane.state.tabs { add(tab.path, source: name + "のタブ", boost: 25) }
            add(pane.currentURL.deletingLastPathComponent().path, source: name + "の親フォルダ", boost: 8)
            if !pane.isFlat {
                for entry in pane.entries where entry.isDirectory && !entry.isPackage {
                    add(entry.url.path, source: name + "のサブフォルダ", boost: 10)
                }
            }
        }
        let now = Date()
        for recent in session.recents {
            add(recent.path, source: "最近使った場所", boost: min(38, 12 + RecentLocations.frecency(recent, now: now)))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in ["Desktop", "Documents", "Downloads"] { add(home.appendingPathComponent(name).path, source: "ホーム", boost: 5) }
        add(home.path, source: "ホーム", boost: 4)
        return Array(byPath.values)
    }

    private func paletteCommands() -> [(title: String, keywords: String, shortcut: String, run: () -> Void)] {
        var commands: [(title: String, keywords: String, shortcut: String, run: () -> Void)] = []
        func add(_ title: String, _ keywords: String, _ shortcut: String, _ run: @escaping () -> Void) {
            commands.append((title, keywords, shortcut, run))
        }
        add("新規フォルダ", "new folder mkdir 作成", "⇧⌘N") { [weak self] in self?.newFolder() }
        add("新規タブ", "new tab", "⌘T") { [weak self] in self?.addTab() }
        add("反対側へコピー", "copy other", "F5") { [weak self] in self?.copyToOther() }
        add("反対側へ移動", "move other", "F6") { [weak self] in self?.moveToOther() }
        add("行き先を指定して移動…", "move to 送る", "⇧⌘M") { [weak self] in self?.moveToChosen() }
        add("行き先を指定してコピー…", "copy to 送る", "⇧⌘K") { [weak self] in self?.copyToChosen() }
        add("収集棚に追加", "shelf 棚 集める", "⌘B") { [weak self] in self?.addToShelf() }
        add("棚の項目をここへ移動", "shelf 棚", "⌥⌘B") { [weak self] in self?.shelfMoveHere() }
        add("棚の項目をここへコピー", "shelf 棚", "⇧⌘B") { [weak self] in self?.shelfCopyHere() }
        add("棚を空にする", "shelf 棚 clear", "") { [weak self] in self?.clearShelf() }
        add("仕分けモード", "triage 振り分け 整理", "⇧⌘T") { [weak self] in self?.toggleTriage() }
        add("左右を比較", "compare diff 差分", "⇧⌘D") { [weak self] in self?.toggleCompare() }
        add("差分を選択", "compare diff select", "") { [weak self] in self?.selectDifferences() }
        add("階層を展開して表示", "flat recursive サブフォルダ 再帰", "⇧⌘F") { [weak self] in self?.toggleFlat() }
        add("このフォルダ内を絞り込む", "filter search 検索", "⌘F") { [weak self] in self?.focusFilter() }
        add("隠し項目を表示／隠す", "hidden dot", "⇧⌘.") { [weak self] in self?.toggleHidden() }
        add("リスト表示", "list view", "⌘2") { [weak self] in self?.listView() }
        add("カラム表示", "column view", "⌘3") { [weak self] in self?.columnsView() }
        add("左右／上下を切り替え", "split layout", "") { [weak self] in self?.toggleSplit() }
        add("Finderの最前面ウインドウを開く", "finder import 取り込む", "⇧⌘O") { [weak self] in self?.openFinderWindow() }
        add("Finderで表示", "reveal finder", "") { [weak self] in self?.revealInFinder() }
        add("ターミナルで開く", "terminal shell", "") { [weak self] in self?.openTerminal() }
        add("パスをコピー", "copy path", "⌥⌘C") { [weak self] in self?.copyPath() }
        add("現在の作業セットを保存…", "workspace save", "") { [weak self] in self?.saveWorkspace() }
        add("現在の場所をお気に入りへ…", "favorite bookmark", "") { [weak self] in self?.addFavorite() }
        add("このタブを日付連動にする…", "template 年度 月次 date", "") { [weak self] in self?.setTabTemplate() }
        add("日付連動を解除", "template", "") { [weak self] in self?.clearTabTemplate() }
        add("直前の操作を取り消す", "undo", "⌘Z") { [weak self] in self?.undo(nil) }
        add("操作履歴", "history log", "") { [weak self] in self?.showHistory() }
        add("ゴミ箱に入れる", "trash delete 削除", "⌘Delete") { [weak self] in self?.deleteSelected() }
        return commands
    }

    func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
