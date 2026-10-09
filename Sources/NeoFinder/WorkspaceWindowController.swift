import AppKit
import QuickLookUI
import Darwin
@preconcurrency import NeoFinderCore

private final class TopAlignedStack: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let store: SessionStore
    private let access: AccessManager
    private let engine: FileOperationEngine
    private let operationQueue = DispatchQueue(label: "local.neofinder.operations", qos: .userInitiated)
    private var session: SavedSession
    private var panes: [BrowserPaneController] = []
    private let split = NSSplitView()
    private let favoritesStack = TopAlignedStack()
    private let workspacePopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "フォルダを登録して、左右で整理を始めましょう。")
    private let progress = NSProgressIndicator()
    private let undoButton = NSButton(title: "取り消す", target: nil, action: nil)
    private let cancelButton = NSButton(title: "中止", target: nil, action: nil)
    private let copyButton = NSButton(title: "右へコピー", target: nil, action: nil)
    private var saveWork: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var previewURLs: [URL] = []
    private var activity: NSObjectProtocol?
    private var restoring = true
    private var undoAvailable = false
    private var historyEntries: [String] = []
    private(set) var operationRunning = false

    var activePane: BrowserPaneController { panes[session.current.activeSide == 1 ? 1 : 0] }
    private var otherPane: BrowserPaneController { panes[session.current.activeSide == 1 ? 0 : 1] }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Neo-Finder", isDirectory: true)
        store = SessionStore(directory: support)
        access = AccessManager(store: store)
        engine = FileOperationEngine(journalURL: support.appendingPathComponent("operations.json"))
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? FileManager.default.homeDirectoryForCurrentUser.path
        session = store.load() ?? SavedSession(current: WorkspaceState(name: "前回の作業", leftPath: home, rightPath: home))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Neo-Finder"
        window.minSize = NSSize(width: 880, height: 560)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.nextResponder = self
        window.setFrameAutosaveName("NeoFinderMainWindow")
        if !window.setFrameUsingName("NeoFinderMainWindow") { window.center() }
        createContent()
        if !access.writeRoots.isEmpty { statusLabel.stringValue = "左右の作業場所を復元しました。" }
        historyEntries = engine.historyLines()
        if let notice = engine.recoveryNotice { statusLabel.stringValue = notice; statusLabel.toolTip = notice }
        refreshWorkspaces()
        refreshFavorites()
        setActive(session.current.activeSide)
        restoring = false
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSApp.isActive, self.window?.isVisible == true, !self.operationRunning else { return }
                self.panes.forEach { $0.reload() }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(previewResigned(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.split.setPosition(self.splitDimension * self.session.current.dividerRatio, ofDividerAt: 0)
            self.activePane.focusFiles()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var splitDimension: CGFloat { split.isVertical ? split.bounds.width : split.bounds.height }

    private func createContent() {
        guard let window else { return }
        let root = NSView()
        window.contentView = root
        let top = NSStackView()
        top.orientation = .horizontal
        top.spacing = 8
        top.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let register = button("フォルダを登録…", #selector(registerFolder))
        workspacePopup.target = self
        workspacePopup.action = #selector(loadWorkspace)
        workspacePopup.setAccessibilityLabel("作業セット")
        workspacePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true
        let label = NSTextField(labelWithString: "作業セット")
        label.textColor = .secondaryLabelColor
        top.addArrangedSubview(label)
        top.addArrangedSubview(workspacePopup)
        top.addArrangedSubview(button("保存…", #selector(saveWorkspace)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        top.addArrangedSubview(spacer)
        top.addArrangedSubview(button("お気に入り＋", #selector(addFavorite)))
        top.addArrangedSubview(register)

        panes = [BrowserPaneController(side: 0, state: session.current.left), BrowserPaneController(side: 1, state: session.current.right)]
        split.isVertical = session.current.verticalSplit
        split.dividerStyle = .thin
        split.delegate = self
        for pane in panes {
            pane.showHidden = session.showHidden
            pane.relativeDates = session.relativeDates
            pane.onActivate = { [weak self] side in self?.setActive(side) }
            pane.onStateChange = { [weak self] in self?.scheduleSave() }
            pane.onOpen = { [weak self] urls in self?.openURLs(urls) }
            pane.onPreview = { [weak self] urls in self?.showPreview(urls) }
            pane.onRename = { [weak self] url in self?.renameURL(url) }
            pane.onDelete = { [weak self] urls in self?.trashURLs(urls) }
            pane.onRequestAccess = { [weak self] url in self?.chooseFolder(suggested: url) }
            pane.onDrop = { [weak self] urls, destination, move in self?.transfer(urls, to: destination, move: move) }
            split.addArrangedSubview(pane.view)
        }

        favoritesStack.orientation = .vertical
        favoritesStack.alignment = .leading
        favoritesStack.spacing = 5
        favoritesStack.edgeInsets = NSEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        let sidebarScroll = NSScrollView()
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.documentView = favoritesStack
        favoritesStack.translatesAutoresizingMaskIntoConstraints = false
        favoritesStack.widthAnchor.constraint(equalTo: sidebarScroll.contentView.widthAnchor).isActive = true
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .followsWindowActiveState
        sidebar.addSubview(sidebarScroll)
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebarScroll.topAnchor.constraint(equalTo: sidebar.topAnchor), sidebarScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor), sidebarScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor)
        ])

        let bottom = NSStackView()
        bottom.orientation = .horizontal
        bottom.spacing = 10
        bottom.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        undoButton.target = self; undoButton.action = #selector(undo(_:)); undoButton.isEnabled = false
        cancelButton.target = self; cancelButton.action = #selector(cancelFileOperation); cancelButton.isHidden = true
        copyButton.target = self; copyButton.action = #selector(copyToOther)
        for view in [progress, statusLabel, button("履歴", #selector(showHistory)), cancelButton, undoButton, copyButton] as [NSView] { bottom.addArrangedSubview(view) }
        for view in [top, sidebar, split, bottom] as [NSView] { root.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor), top.trailingAnchor.constraint(equalTo: root.trailingAnchor), top.topAnchor.constraint(equalTo: root.topAnchor), top.heightAnchor.constraint(equalToConstant: 52),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor), bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor), bottom.heightAnchor.constraint(equalToConstant: 48),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: top.bottomAnchor), sidebar.bottomAnchor.constraint(equalTo: bottom.topAnchor), sidebar.widthAnchor.constraint(equalToConstant: 172),
            split.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), split.trailingAnchor.constraint(equalTo: root.trailingAnchor), split.topAnchor.constraint(equalTo: top.bottomAnchor), split.bottomAnchor.constraint(equalTo: bottom.topAnchor)
        ])
    }

    private func button(_ title: String, _ selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded
        return button
    }

    private func setActive(_ side: Int) {
        session.current.activeSide = side == 1 ? 1 : 0
        for (index, pane) in panes.enumerated() { pane.isActive = index == session.current.activeSide }
        copyButton.title = session.current.activeSide == 0 ? "右へコピー" : "左へコピー"
        scheduleSave()
    }

    private func snapshot() -> WorkspaceState {
        var current = session.current
        current.left = panes[0].state
        current.right = panes[1].state
        current.verticalSplit = split.isVertical
        if splitDimension > 0, let first = split.arrangedSubviews.first {
            current.dividerRatio = (split.isVertical ? first.frame.width : first.frame.height) / splitDimension
        }
        return current
    }

    private func scheduleSave() {
        guard !restoring, panes.count == 2 else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        guard panes.count == 2 else { return }
        session.current = snapshot()
        do { try store.save(session) }
        catch { statusLabel.stringValue = "作業状態を保存できません：\(error.localizedDescription)" }
    }

    func prepareForTermination() { saveNow(); access.endAccess() }

    private func refreshWorkspaces() {
        workspacePopup.removeAllItems()
        workspacePopup.addItem(withTitle: "現在：" + session.current.name)
        workspacePopup.item(at: 0)?.representedObject = "current"
        for workspace in session.workspaces {
            workspacePopup.addItem(withTitle: workspace.name)
            workspacePopup.lastItem?.representedObject = workspace.id.uuidString
        }
    }

    @objc private func saveWorkspace() {
        guard let name = askText(title: "作業セットを保存", prompt: "左右の場所、タブ、表示方法と分割比率を保存します。", initial: session.current.name == "前回の作業" ? "資料整理" : session.current.name) else { return }
        var value = snapshot()
        value.name = name
        if let index = session.workspaces.firstIndex(where: { $0.name == name }) {
            guard confirm(title: "「\(name)」を更新しますか？", detail: "保存済みの作業セットを現在の配置に更新します。", action: "更新") else { return }
            value.id = session.workspaces[index].id
            session.workspaces[index] = value
        } else { value.id = UUID(); session.workspaces.append(value) }
        session.current = value
        refreshWorkspaces(); saveNow()
    }

    @objc private func loadWorkspace() {
        guard let id = workspacePopup.selectedItem?.representedObject as? String,
              let value = session.workspaces.first(where: { $0.id.uuidString == id }) else { return }
        restoring = true
        session.current = value
        panes[0].state = value.left; panes[1].state = value.right
        split.isVertical = value.verticalSplit
        split.adjustSubviews()
        split.setPosition(splitDimension * value.dividerRatio, ofDividerAt: 0)
        setActive(value.activeSide)
        restoring = false
        refreshWorkspaces(); saveNow(); activePane.focusFiles()
    }

    @objc private func deleteWorkspace() {
        guard !session.workspaces.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "保存済みの作業セットを削除"
        alert.informativeText = "ファイルやフォルダは削除されません。"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        popup.addItems(withTitles: session.workspaces.map(\.name))
        alert.accessoryView = popup
        alert.addButton(withTitle: "削除"); alert.addButton(withTitle: "キャンセル")
        if alert.runModal() == .alertFirstButtonReturn {
            session.workspaces.remove(at: popup.indexOfSelectedItem)
            refreshWorkspaces(); saveNow()
        }
    }

    private func refreshFavorites() {
        for view in favoritesStack.arrangedSubviews { favoritesStack.removeArrangedSubview(view); view.removeFromSuperview() }
        let title = NSTextField(labelWithString: "よく使う場所")
        title.font = .systemFont(ofSize: 11, weight: .semibold); title.textColor = .secondaryLabelColor
        favoritesStack.addArrangedSubview(title)
        favoritesStack.addArrangedSubview(button("フォルダを開く…", #selector(registerFolder)))
        for group in session.favoriteGroups {
            let label = NSTextField(labelWithString: group.name)
            label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = .secondaryLabelColor
            favoritesStack.setCustomSpacing(14, after: favoritesStack.arrangedSubviews.last!)
            favoritesStack.addArrangedSubview(label)
            for favorite in group.items {
                let button = NSButton(title: favorite.name, target: self, action: #selector(openFavorite(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(favorite.id.uuidString)
                button.isBordered = false
                button.alignment = .left
                button.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                button.imagePosition = .imageLeft
                button.contentTintColor = .controlAccentColor
                button.lineBreakMode = .byTruncatingMiddle
                button.toolTip = favorite.path
                button.widthAnchor.constraint(equalToConstant: 149).isActive = true
                let menu = NSMenu()
                let rename = NSMenuItem(title: "表示名を変更…", action: #selector(renameFavorite(_:)), keyEquivalent: "")
                rename.target = self; rename.representedObject = favorite.id.uuidString
                menu.addItem(rename)
                let remove = NSMenuItem(title: "お気に入りから外す", action: #selector(removeFavorite(_:)), keyEquivalent: "")
                remove.target = self; remove.representedObject = favorite.id.uuidString
                menu.addItem(remove); button.menu = menu
                favoritesStack.addArrangedSubview(button)
            }
        }
    }

    @objc private func addFavorite() {
        guard let name = askText(title: "お気に入りに追加", prompt: "表示名（元のフォルダ名は変更しません）", initial: activePane.currentURL.lastPathComponent) else { return }
        guard let group = askText(title: "グループ", prompt: "既存のグループ名、または新しい名前を入力してください。", initial: session.favoriteGroups.first?.name ?? "仕事") else { return }
        let item = Favorite(name: name, path: activePane.currentURL.path)
        if let index = session.favoriteGroups.firstIndex(where: { $0.name == group }) { session.favoriteGroups[index].items.append(item) }
        else { session.favoriteGroups.append(FavoriteGroup(name: group, items: [item])) }
        refreshFavorites(); saveNow()
    }

    @objc private func openFavorite(_ sender: NSButton) {
        guard let favorite = session.favoriteGroups.flatMap(\.items).first(where: { $0.id.uuidString == sender.identifier?.rawValue }) else { return }
        activePane.navigate(to: URL(fileURLWithPath: favorite.path))
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        for index in session.favoriteGroups.indices {
            session.favoriteGroups[index].items.removeAll { $0.id.uuidString == sender.representedObject as? String }
        }
        refreshFavorites(); saveNow()
    }

    @objc private func renameFavorite(_ sender: NSMenuItem) {
        for group in session.favoriteGroups.indices {
            guard let index = session.favoriteGroups[group].items.firstIndex(where: { $0.id.uuidString == sender.representedObject as? String }) else { continue }
            if let name = askText(title: "表示名を変更", prompt: "実際のフォルダ名は変わりません。", initial: session.favoriteGroups[group].items[index].name) {
                session.favoriteGroups[group].items[index].name = name
                refreshFavorites(); saveNow()
            }
        }
    }

    @objc private func registerFolder() { chooseFolder(suggested: activePane.currentURL) }

    private func chooseFolder(suggested: URL?) {
        let panel = NSOpenPanel()
        panel.title = "作業フォルダを登録"
        panel.message = "このフォルダと配下を開けるようにします。左右のどちらからでも使えます。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.directoryURL = suggested
        panel.prompt = "登録して開く"
        let checkbox = NSButton(checkboxWithTitle: "クラウド同期されていないローカルフォルダとして編集を有効にする", target: nil, action: nil)
        checkbox.frame = NSRect(x: 0, y: 0, width: 490, height: 30)
        panel.accessoryView = checkbox
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try access.register(url, localWrite: checkbox.state == .on)
            activePane.navigate(to: url)
            statusLabel.stringValue = access.isWriteEnabled(url) ? "「\(url.lastPathComponent)」を開きました（編集可能）。" : "「\(url.lastPathComponent)」を開きました（閲覧用）。"
            saveNow()
        } catch { showError(error); activePane.navigate(to: url) }
    }

    func openExternal(_ url: URL) {
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let folder = values?.isDirectory == true && values?.isPackage != true ? url : url.deletingLastPathComponent()
        try? access.register(folder, localWrite: false)
        activePane.addTab(url: folder)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openURLs(_ urls: [URL]) {
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true && values?.isPackage != true { activePane.navigate(to: url) }
            else { NSWorkspace.shared.open(url) }
        }
    }

    @objc func openSelected(_ sender: Any?) { openURLs(activePane.selectedURLs) }
    @objc func preview(_ sender: Any?) { showPreview(activePane.selectedURLs) }
    private func showPreview(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        previewURLs = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil); return }
        panel.dataSource = self; panel.delegate = self
        panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
    @objc private func previewResigned(_ notification: Notification) {
        guard let panel = notification.object as? QLPreviewPanel else { return }
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, panel?.isVisible != true, NSApp.isActive, self.window?.isVisible == true else { return }
            self.activePane.focusFiles()
        }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewURLs[index] as NSURL }

    @objc func copy(_ sender: Any?) {
        let urls = activePane.selectedURLs
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        statusLabel.stringValue = "\(urls.count)項目をコピーしました。⌘Vで複製、⌥⌘Vで移動します。"
    }
    @objc func paste(_ sender: Any?) { pasteFiles(move: false) }
    @objc private func moveHere() { pasteFiles(move: true) }
    private func pasteFiles(move: Bool) {
        guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return }
        transfer(urls, to: activePane.currentURL, move: move)
    }
    @objc private func copyToOther() { transfer(activePane.selectedURLs, to: otherPane.currentURL, move: false) }
    @objc private func moveToOther() { transfer(activePane.selectedURLs, to: otherPane.currentURL, move: true) }

    private func transfer(_ urls: [URL], to destination: URL, move: Bool) {
        guard !urls.isEmpty, !operationRunning else { return }
        do {
            try access.requireWrite([destination], directory: true)
            if move { try access.requireWrite(urls) }
            var conflict = ConflictPolicy.keepBoth
            let existing = urls.filter { FileManager.default.fileExists(atPath: destination.appendingPathComponent($0.lastPathComponent).path) }
            if !existing.isEmpty {
                let alert = NSAlert()
                alert.messageText = "同じ名前の項目があります"
                alert.informativeText = "転送先：\(destination.path)\n\(existing.count)項目が重複します。上書きは行いません。"
                alert.addButton(withTitle: "両方残す"); alert.addButton(withTitle: "スキップ"); alert.addButton(withTitle: "中止")
                switch alert.runModal() {
                case .alertFirstButtonReturn: conflict = .keepBoth
                case .alertSecondButtonReturn: conflict = .skip
                default: return
                }
            }
            let policy = conflict
            performOperation("\(urls.count)項目を「\(destination.lastPathComponent)」へ\(move ? "移動" : "コピー")中…") { engine in
                if move { return try engine.move(urls, to: destination, conflict: policy) }
                return try engine.copy(urls, to: destination, conflict: policy)
            }
        } catch { showError(error) }
    }

    @objc private func renameSelected() { if let url = activePane.selectedURLs.first, activePane.selectedURLs.count == 1 { renameURL(url) } }
    private func renameURL(_ url: URL) {
        guard !operationRunning else { return }
        do {
            try access.requireWrite([url])
            guard let name = askText(title: "名前を変更", prompt: url.lastPathComponent, initial: url.lastPathComponent), name != url.lastPathComponent else { return }
            performOperation("名前を変更中…") { try $0.rename(url, to: name) }
        } catch { showError(error) }
    }

    @objc private func newFolder() {
        let directory = activePane.currentURL
        do {
            try access.requireWrite([directory], directory: true)
            guard let name = askText(title: "新規フォルダ", prompt: directory.path, initial: "名称未設定フォルダ") else { return }
            performOperation("フォルダを作成中…") { try $0.createFolder(in: directory, name: name) }
        } catch { showError(error) }
    }

    @objc private func deleteSelected() { trashURLs(activePane.selectedURLs) }
    private func trashURLs(_ urls: [URL]) {
        guard !urls.isEmpty, !operationRunning else { return }
        do {
            try access.requireWrite(urls)
            performOperation("\(urls.count)項目をゴミ箱に移動中…") { try $0.trash(urls) }
        } catch { showError(error) }
    }

    private func performOperation(_ title: String, work: @escaping (FileOperationEngine) throws -> OperationReport) {
        guard !operationRunning else { return }
        operationRunning = true
        statusLabel.stringValue = title
        progress.startAnimation(nil)
        cancelButton.isHidden = false
        undoButton.isEnabled = false
        copyButton.isEnabled = false
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "ファイル操作を完了するため")
        operationQueue.async { [weak self, engine] in
            let result = Result { try work(engine) }
            let canUndo = engine.canUndo
            let history = engine.historyLines()
            DispatchQueue.main.async {
                guard let self else { return }
                self.operationRunning = false
                self.undoAvailable = canUndo
                self.historyEntries = history
                self.progress.stopAnimation(nil)
                self.cancelButton.isHidden = true
                self.undoButton.isEnabled = canUndo
                self.copyButton.isEnabled = true
                if let activity = self.activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
                switch result {
                case .success(let report):
                    self.statusLabel.stringValue = report.summary
                    self.statusLabel.toolTip = ([report.summary] + report.failures).joined(separator: "\n")
                    if !report.failures.isEmpty { self.showMessage("一部の操作を完了できませんでした", ([report.summary] + report.failures).joined(separator: "\n")) }
                case .failure(let error): self.statusLabel.stringValue = error.localizedDescription; self.showError(error)
                }
                self.panes.forEach { $0.reload() }
            }
        }
    }

    @objc func undo(_ sender: Any?) {
        guard undoAvailable, !operationRunning else { return }
        performOperation("直前の操作を取り消しています…") { try $0.undoLast() }
    }
    @objc private func dispatchUndo(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.undoManager?.undo()
        } else { undo(sender) }
    }
    @objc private func dispatchRedo(_ sender: Any?) {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.redo()
    }
    @objc private func cancelFileOperation() { engine.cancel(); statusLabel.stringValue = "中止を要求しました。処理中の項目が安全に終わるまで待っています…" }

    func explainRunningOperation() { showMessage("ファイル操作が進行中です", "完了を待つか、下部の「中止」を押してください。中止前に完了した項目は残ります。") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if operationRunning { explainRunningOperation(); return false }
        saveNow(); return true
    }
    @objc private func didBecomeActive() { if !operationRunning { panes.forEach { $0.reload() } } }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitView.isVertical ? 300 : 210 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitDimension - (splitView.isVertical ? 300 : 210) }
    func splitViewDidResizeSubviews(_ notification: Notification) { scheduleSave() }

    private func askText(title: String, prompt: String, initial: String) -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = prompt
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "キャンセル")
        let input = NSTextField(string: initial); input.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        alert.accessoryView = input; alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func confirm(title: String, detail: String, action: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: action); alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func showError(_ error: Error) { showMessage("操作を完了できませんでした", error.localizedDescription) }
    private func showMessage(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func addTab() { activePane.addTab() }
    @objc private func closeTab() { if !activePane.closeTab() { window?.performClose(nil) } }
    @objc private func goBack() { activePane.goBack() }
    @objc private func goForward() { activePane.goForward() }
    @objc private func goUp() { activePane.goUp() }
    @objc private func goToFolder() {
        guard let path = askText(title: "フォルダへ移動", prompt: "パスを入力してください。未許可の場所は登録が必要です。", initial: activePane.currentURL.path) else { return }
        activePane.navigate(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }
    @objc private func toggleHidden() { session.showHidden.toggle(); panes.forEach { $0.showHidden = session.showHidden; $0.reload() }; saveNow() }
    @objc private func toggleRelative() { session.relativeDates.toggle(); panes.forEach { $0.relativeDates = session.relativeDates; $0.reload() }; saveNow() }
    @objc private func listView() { activePane.setViewMode(.list) }
    @objc private func columnsView() { activePane.setViewMode(.columns) }
    @objc private func sortName() { activePane.setSort(.name) }
    @objc private func sortDate() { activePane.setSort(.date) }
    @objc private func sortSize() { activePane.setSort(.size) }
    @objc private func toggleSplit() { split.isVertical.toggle(); split.adjustSubviews(); split.setPosition(splitDimension / 2, ofDividerAt: 0); saveNow() }
    @objc private func focusOther() { setActive(session.current.activeSide == 0 ? 1 : 0); activePane.focusFiles() }
    @objc private func focusFilter() { activePane.focusFilter() }
    @objc private func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting(activePane.selectedURLs.isEmpty ? [activePane.currentURL] : activePane.selectedURLs) }
    @objc private func showInfo() {
        let urls = activePane.selectedURLs.isEmpty ? [activePane.currentURL] : activePane.selectedURLs
        let lines = urls.prefix(20).map { url -> String in
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .typeIdentifierKey, .tagNamesKey])
            return "\(url.path)\n種類：\(v?.typeIdentifier ?? "不明")\nサイズ：\(v?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")\n変更日：\(v?.contentModificationDate?.formatted() ?? "—")\nタグ：\((v?.tagNames ?? []).joined(separator: "、"))"
        }
        showMessage("情報（\(urls.count)項目）", lines.joined(separator: "\n\n"))
    }
    @objc private func shareSelected() {
        let urls = activePane.selectedURLs
        guard !urls.isEmpty else { return }
        NSSharingServicePicker(items: urls).show(relativeTo: copyButton.bounds, of: copyButton, preferredEdge: .minY)
    }
    @objc private func help() {
        showMessage("Neo-Finder 0.1", "左右のペインで独立したタブと履歴を使えます。\n\n最初に「フォルダを登録」で作業場所を選択します。ローカルフォルダの編集を有効にすると、コピー・同一ボリューム移動・名前変更・新規フォルダ・ゴミ箱が使えます。\n\nReturn：名前変更　Space：Quick Look\n⌘C → ⌘V：コピー　⌘C → ⌥⌘V：移動\n⌘Z：直前の取消可能な操作を戻す\n\n上書き・別ボリューム移動・クラウドへの書込みは初期版の対象外です。取消はこの起動中のみで、外部変更がある項目には実行しません。")
    }

    @objc private func showHistory() {
        let alert = NSAlert()
        alert.messageText = "操作履歴"
        alert.informativeText = "中断した操作は自動で再開しません。取り消しは今回の起動中のみです。"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 320))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = .systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.string = historyEntries.isEmpty ? "まだ操作はありません。" : historyEntries.joined(separator: "\n\n")
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "閉じる")
        alert.runModal()
    }

    func installMenus() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu { let item = NSMenuItem(); item.title = title; let child = NSMenu(title: title); item.submenu = child; menu.addItem(item); return child }
        func item(_ parent: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers; entry.target = target; parent.addItem(entry)
        }
        let app = submenu("Neo-Finder")
        item(app, "Neo-Finderについて", #selector(help), target: self)
        let services = NSMenuItem(title: "サービス", action: nil, keyEquivalent: ""); services.submenu = NSMenu(title: "サービス"); app.addItem(services); NSApp.servicesMenu = services.submenu
        app.addItem(.separator()); item(app, "Neo-Finderを隠す", #selector(NSApplication.hide(_:)), "h")
        item(app, "Neo-Finderを終了", #selector(NSApplication.terminate(_:)), "q")
        let file = submenu("ファイル")
        item(file, "フォルダを登録…", #selector(registerFolder), target: self)
        item(file, "開く", #selector(openSelected(_:)), "o", target: self)
        item(file, "新規タブ", #selector(addTab), "t", target: self)
        item(file, "タブ／ウインドウを閉じる", #selector(closeTab), "w", target: self)
        item(file, "新規フォルダ…", #selector(newFolder), "n", [.command, .shift], target: self)
        file.addItem(.separator())
        item(file, "名前を変更…", #selector(renameSelected), target: self)
        item(file, "ゴミ箱に入れる", #selector(deleteSelected), "\u{8}", target: self)
        item(file, "情報を見る", #selector(showInfo), "i", target: self)
        item(file, "Quick Look", #selector(preview(_:)), "y", target: self)
        item(file, "共有…", #selector(shareSelected), target: self)
        item(file, "Finderで表示", #selector(revealInFinder), target: self)
        let edit = submenu("編集")
        item(edit, "取り消す", #selector(dispatchUndo(_:)), "z", target: self)
        item(edit, "やり直す", #selector(dispatchRedo(_:)), "z", [.command, .shift], target: self)
        edit.addItem(.separator())
        item(edit, "カット（テキスト）", #selector(NSText.cut(_:)), "x")
        item(edit, "コピー", #selector(copy(_:)), "c")
        item(edit, "ペースト", #selector(paste(_:)), "v")
        item(edit, "項目をここに移動", #selector(moveHere), "v", [.command, .option], target: self)
        item(edit, "すべてを選択", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        item(edit, "反対側へコピー", #selector(copyToOther), target: self)
        item(edit, "反対側へ移動", #selector(moveToOther), target: self)
        let view = submenu("表示")
        item(view, "リスト", #selector(listView), "2", target: self)
        item(view, "カラム", #selector(columnsView), "3", target: self)
        view.addItem(.separator())
        item(view, "名前で並べ替え", #selector(sortName), target: self)
        item(view, "変更日で並べ替え", #selector(sortDate), target: self)
        item(view, "サイズで並べ替え", #selector(sortSize), target: self)
        view.addItem(.separator())
        item(view, "隠し項目を表示", #selector(toggleHidden), ".", [.command, .shift], target: self)
        item(view, "相対日付を表示", #selector(toggleRelative), target: self)
        item(view, "左右／上下を切り替え", #selector(toggleSplit), target: self)
        item(view, "このフォルダ内を絞り込む", #selector(focusFilter), target: self)
        let go = submenu("移動")
        item(go, "戻る", #selector(goBack), "[", target: self)
        item(go, "進む", #selector(goForward), "]", target: self)
        item(go, "親フォルダ", #selector(goUp), target: self)
        item(go, "フォルダへ移動…", #selector(goToFolder), "g", [.command, .shift], target: self)
        item(go, "反対側のペインへ", #selector(focusOther), target: self)
        let workspace = submenu("作業セット")
        item(workspace, "現在の作業セットを保存…", #selector(saveWorkspace), target: self)
        item(workspace, "保存済みセットを削除…", #selector(deleteWorkspace), target: self)
        item(workspace, "現在の場所をお気に入りへ…", #selector(addFavorite), target: self)
        let window = submenu("ウインドウ")
        item(window, "しまう", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "拡大／縮小", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = window
        let help = submenu("ヘルプ"); item(help, "Neo-Finderの使い方", #selector(self.help), target: self)
        NSApp.mainMenu = menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action
        if action == #selector(dispatchUndo(_:)) {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { return editor.undoManager?.canUndo ?? false }
            return window?.isVisible == true && NSApp.keyWindow === window && undoAvailable && !operationRunning
        }
        if action == #selector(dispatchRedo(_:)) { return (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canRedo ?? false }
        let fileActions: [Selector] = [#selector(copyToOther), #selector(moveToOther), #selector(deleteSelected), #selector(renameSelected), #selector(newFolder), #selector(moveHere), #selector(paste(_:)), #selector(undo(_:))]
        if fileActions.contains(where: { $0 == action }) {
            guard window?.isVisible == true, NSApp.keyWindow === window else { return false }
            if NSApp.keyWindow?.firstResponder is NSTextView { return false }
        }
        if action == #selector(toggleHidden) { menuItem.state = session.showHidden ? .on : .off }
        if action == #selector(toggleRelative) { menuItem.state = session.relativeDates ? .on : .off }
        if action == #selector(undo(_:)) { return undoAvailable && !operationRunning }
        if [#selector(copyToOther), #selector(moveToOther), #selector(deleteSelected), #selector(renameSelected)].contains(action) {
            return !operationRunning && !activePane.selectedURLs.isEmpty && (action != #selector(renameSelected) || activePane.selectedURLs.count == 1)
        }
        if [#selector(newFolder), #selector(moveHere), #selector(paste(_:))].contains(action) { return !operationRunning }
        return true
    }
}
