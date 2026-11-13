import AppKit
import NeoFinderCore

/// Triage mode, the shelf, left/right comparison, calendar-following tabs and Finder hand-over.
extension WorkspaceWindowController {
    // MARK: Recent places

    func recordRecent(_ url: URL, weight: Int) {
        RecentLocations.record(url.standardizedFileURL.path, in: &session.recents, weight: weight)
        scheduleSave()
    }

    func selectionChanged() {
        guard triageActive else { return }
        triagePreviewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.triageActive else { return }
            self.triageView.show(self.activePane.selectedURLs.first)
        }
        triagePreviewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func entriesChanged() {
        if compareActive { recomputeComparison() }
    }

    // MARK: Triage mode

    /// The inactive pane becomes a large preview; the number keys send the selected item to a
    /// preset destination and the selection moves on to the next item.
    @objc func toggleTriage() {
        if triageActive { endTriage(); return }
        triageActive = true
        let host = otherPane.view
        triageView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(triageView)
        NSLayoutConstraint.activate([
            triageView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            triageView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            triageView.topAnchor.constraint(equalTo: host.topAnchor),
            triageView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        triageView.setSlots(session.triageSlots)
        activePane.focusFiles()
        if activePane.selectedURLs.isEmpty { activePane.selectRelative(1) }
        triageView.show(activePane.selectedURLs.first)
        statusLabel.stringValue = "仕分けモード：1〜9で行き先へ移動、Spaceで次へ、Returnで名前変更、Escで終了。"
    }

    func endTriage() {
        guard triageActive else { return }
        triageActive = false
        triagePreviewWork?.cancel()
        triageView.show(nil)
        triageView.removeFromSuperview()
        activePane.focusFiles()
        statusLabel.stringValue = "仕分けモードを終了しました。"
    }

    /// Keys claimed from the file list while triage is active.
    func handleTriageKey(_ event: NSEvent) -> Bool {
        guard triageActive else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Number-row key codes for 1…9; these do not depend on the keyboard layout's characters.
        let digits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
        if let slot = digits[event.keyCode], modifiers.isEmpty || modifiers == .option {
            triageSlot(slot, assign: modifiers == .option)
            return true
        }
        if event.keyCode == 49 && modifiers.isEmpty { activePane.selectRelative(1); return true }
        if event.keyCode == 53 && modifiers.isEmpty { endTriage(); return true }
        return false
    }

    func triageSlot(_ index: Int, assign: Bool) {
        guard session.triageSlots.indices.contains(index) else { return }
        let path = session.triageSlots[index]
        if assign || path.isEmpty {
            presentPalette(.pick(prompt: "仕分け先 \(index + 1) にするフォルダ", handler: { [weak self] url in
                guard let self else { return }
                self.session.triageSlots[index] = url.standardizedFileURL.path
                self.triageView.setSlots(self.session.triageSlots)
                self.saveNow()
                self.statusLabel.stringValue = "仕分け先 \(index + 1)：\(url.lastPathComponent)"
            }))
            return
        }
        let items = activePane.selectedURLs
        guard !items.isEmpty else { return }
        transfer(items, to: URL(fileURLWithPath: path, isDirectory: true), move: true)
    }

    // MARK: Left/right comparison

    @objc func toggleCompare() {
        compareActive.toggle()
        recomputeComparison()
        if !compareActive { statusLabel.stringValue = "比較表示を終了しました。" }
    }

    func recomputeComparison() {
        guard compareActive else {
            panes.forEach { $0.comparison = nil }
            return
        }
        let left = panes[0].entries
        let right = panes[1].entries
        let leftMarks = FolderComparison.statuses(for: left, against: right)
        let rightMarks = FolderComparison.statuses(for: right, against: left)
        panes[0].comparison = leftMarks
        panes[1].comparison = rightMarks
        func count(_ marks: [String: CompareStatus], _ status: CompareStatus) -> Int { marks.values.filter { $0 == status }.count }
        statusLabel.stringValue = "比較：左のみ \(count(leftMarks, .onlyHere))・右のみ \(count(rightMarks, .onlyHere))・左が新しい \(count(leftMarks, .newer))・右が新しい \(count(rightMarks, .newer))・相違 \(count(leftMarks, .different))（名前・サイズ・変更日で判定）"
    }

    /// Selects what the other side lacks or has an older version of, ready for F5.
    @objc func selectDifferences() {
        if !compareActive { toggleCompare() }
        let count = activePane.selectDifferences()
        statusLabel.stringValue = count == 0 ? "反対側に無い項目・新しい項目はありません。" : "\(count)項目を選択しました。F5で反対側へコピーできます。"
    }

    // MARK: Shelf

    /// Collects the selection so items from several folders can be sent somewhere in one step.
    @objc func addToShelf() {
        let paths = activePane.selectedURLs.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        for path in paths where !session.shelf.contains(path) { session.shelf.append(path) }
        refreshFavorites()
        saveNow()
        statusLabel.stringValue = "収集棚：\(session.shelf.count)項目。⌥⌘Bでここへ移動、⇧⌘Bでここへコピーします。"
    }

    @objc func shelfMoveHere() { shelfTransfer(move: true) }
    @objc func shelfCopyHere() { shelfTransfer(move: false) }

    func shelfTransfer(move: Bool) {
        let items = session.shelf.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !items.isEmpty else {
            statusLabel.stringValue = "収集棚に移せる項目がありません。"
            if !session.shelf.isEmpty { session.shelf.removeAll(); refreshFavorites(); saveNow() }
            return
        }
        guard transfer(items, to: activePane.currentURL, move: move) else { return }
        session.shelf.removeAll()
        refreshFavorites()
        saveNow()
    }

    @objc func clearShelf() {
        session.shelf.removeAll()
        refreshFavorites()
        saveNow()
        statusLabel.stringValue = "収集棚を空にしました（ファイルは変更していません）。"
    }

    @objc func removeShelfItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        session.shelf.removeAll { $0 == path }
        refreshFavorites()
        saveNow()
    }

    @objc func revealShelfItem(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        let url = URL(fileURLWithPath: path)
        activePane.navigate(to: url.deletingLastPathComponent())
        activePane.reveal([url])
    }

    /// Adds the shelf section below the favorites in the sidebar.
    func appendShelf() {
        if let last = favoritesStack.arrangedSubviews.last { favoritesStack.setCustomSpacing(18, after: last) }
        let title = NSTextField(labelWithString: "収集棚（\(session.shelf.count)）")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        favoritesStack.addArrangedSubview(title)
        if session.shelf.isEmpty {
            let hint = NSTextField(wrappingLabelWithString: "⌘Bで選択項目を集め、行き先でまとめて移動・コピーします。")
            hint.font = .systemFont(ofSize: 10)
            hint.textColor = .tertiaryLabelColor
            hint.preferredMaxLayoutWidth = 149
            favoritesStack.addArrangedSubview(hint)
            return
        }
        for path in session.shelf.prefix(40) {
            let item = NSButton(title: (path as NSString).lastPathComponent, target: self, action: #selector(revealShelfItem(_:)))
            item.identifier = NSUserInterfaceItemIdentifier(path)
            item.isBordered = false
            item.alignment = .left
            item.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: nil)
            item.imagePosition = .imageLeft
            item.lineBreakMode = .byTruncatingMiddle
            item.toolTip = path
            item.widthAnchor.constraint(equalToConstant: 149).isActive = true
            let menu = NSMenu()
            let remove = NSMenuItem(title: "棚から外す", action: #selector(removeShelfItem(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = path
            menu.addItem(remove)
            item.menu = menu
            favoritesStack.addArrangedSubview(item)
        }
        if session.shelf.count > 40 {
            let more = NSTextField(labelWithString: "ほか\(session.shelf.count - 40)項目")
            more.font = .systemFont(ofSize: 10)
            more.textColor = .tertiaryLabelColor
            favoritesStack.addArrangedSubview(more)
        }
        for (label, selector) in [("ここへ移動", #selector(shelfMoveHere)), ("ここへコピー", #selector(shelfCopyHere)), ("空にする", #selector(clearShelf))] {
            let action = button(label, selector)
            action.controlSize = .small
            favoritesStack.addArrangedSubview(action)
        }
    }

    // MARK: Calendar-following tabs

    @objc func setTabTemplate() {
        let path = activePane.currentURL.path
        let initial = activePane.currentTemplate ?? PathTemplate.suggest(for: path) ?? path
        guard let text = askText(title: "このタブを日付連動にする",
                                 prompt: "作業セットを開いたときと起動時に、その日のフォルダを開きます。\n使える変数：{yyyy} {yy} {MM} {M} {dd} {年度} {令和年度}。年度は4月始まり。{MM-1} のように書くと前月です。",
                                 initial: initial) else { return }
        guard PathTemplate.containsVariable(text) else {
            showMessage("変数がありません", "{年度} や {MM} などの変数を、日付で変わる部分に入れてください。\n例：~/経理/{年度}年度/{MM}月")
            return
        }
        activePane.setTemplate(text)
        statusLabel.stringValue = "日付連動：今日は「\(abbreviated(PathTemplate.expand(text)))」を開きます。"
        applyTemplate(to: activePane)
        saveNow()
    }

    @objc func clearTabTemplate() {
        activePane.setTemplate(nil)
        saveNow()
        statusLabel.stringValue = "このタブの日付連動を解除しました。"
    }

    func applyTemplates() { panes.forEach { applyTemplate(to: $0) } }

    func applyTemplate(to pane: BrowserPaneController) {
        guard let destination = pane.templateDestination() else { return }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { pane.navigate(to: destination, activating: false) }
            return
        }
        guard confirm(title: "「\(destination.lastPathComponent)」はまだありません",
                      detail: "日付連動タブが今日開く場所です。\n\(destination.path)\n\nフォルダを作成しますか？", action: "作成") else { return }
        do {
            // Check the folder that will actually receive the new folders.
            var ancestor = destination.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: ancestor.path) && ancestor.path != "/" {
                ancestor = ancestor.deletingLastPathComponent()
            }
            try access.requireWrite([ancestor], directory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            pane.navigate(to: destination, activating: false)
        } catch { showError(error) }
    }

    // MARK: Finder and system hand-over

    /// Opens the folder shown in Finder's front window and selects what is selected there.
    @objc func openFinderWindow() {
        let source = """
        tell application "Finder"
            if (count of Finder windows) is 0 then return ""
            set out to POSIX path of (target of front Finder window as alias)
            repeat with anItem in (get selection)
                set out to out & linefeed & POSIX path of (anItem as alias)
            end repeat
            return out
        end tell
        """
        var failure: NSDictionary?
        let text = NSAppleScript(source: source)?.executeAndReturnError(&failure).stringValue ?? ""
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first else {
            let reason = (failure?[NSAppleScript.errorMessage] as? String) ?? "Finderのウインドウが開いていないか、フォルダではない場所（検索結果・最近の項目など）を表示しています。"
            showMessage("Finderの場所を取り込めません", reason + "\n\n初回は「システム設定 › プライバシーとセキュリティ › オートメーション」でNeo-FinderによるFinderの制御を許可してください。")
            return
        }
        activePane.navigate(to: URL(fileURLWithPath: first, isDirectory: true))
        let selected = lines.dropFirst().map { URL(fileURLWithPath: $0) }
        if !selected.isEmpty { activePane.reveal(Array(selected)) }
        activePane.focusFiles()
    }

    @objc func copyPath() {
        let urls = activePane.selectedURLs.isEmpty ? [activePane.currentURL] : activePane.selectedURLs
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        statusLabel.stringValue = urls.count == 1 ? "パスをコピーしました：\(urls[0].path)" : "\(urls.count)項目のパスをコピーしました。"
    }

    @objc func openTerminal() {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([activePane.currentURL], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func toggleRemoteWrites() {
        if access.allowRemoteWrites {
            access.allowRemoteWrites = false
            statusLabel.stringValue = "クラウド・ネットワーク上の場所は閲覧のみに戻しました。"
            return
        }
        guard confirm(title: "クラウド・ネットワーク上の編集を許可しますか？",
                      detail: "OneDrive・iCloud Drive・Dropbox等の同期フォルダと、ネットワーク上のボリュームでコピー・移動・名前変更・ゴミ箱を使えるようにします。\n\n同期中の項目やオンライン専用ファイルでは、取り消しが保留になったり、ダウンロードが発生したりすることがあります。まず重要でないファイルで試してください。",
                      action: "許可") else { return }
        access.allowRemoteWrites = true
        statusLabel.stringValue = "クラウド・ネットワーク上の場所の編集を許可しました（実験的）。"
    }
}
