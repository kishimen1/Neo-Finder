import AppKit
import QuickLookUI
import Darwin
@preconcurrency import NeoFinderCore

private final class TopAlignedStack: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let store: SessionStore
    let access: AccessManager
    let engine: FileOperationEngine
    let operationQueue = DispatchQueue(label: "local.neofinder.operations", qos: .userInitiated)
    var session: SavedSession
    var panes: [BrowserPaneController] = []
    let split = NSSplitView()
    let favoritesStack = TopAlignedStack()
    let workspacePopup = NSPopUpButton()
    let statusLabel = NSTextField(labelWithString: "フォルダを登録して、左右で整理を始めましょう。")
    let progress = NSProgressIndicator()
    let undoButton = NSButton(title: "取り消す", target: nil, action: nil)
    let cancelButton = NSButton(title: "中止", target: nil, action: nil)
    let copyButton = NSButton(title: "右へコピー", target: nil, action: nil)
    var saveWork: DispatchWorkItem?
    var refreshTimer: Timer?
    var previewURLs: [URL] = []
    var activity: NSObjectProtocol?
    var restoring = true
    var undoAvailable = false
    var historyEntries: [String] = []
    typealias OperationWork = (FileOperationEngine) throws -> OperationReport
    /// Operations requested while another one runs. They start in order, one at a time.
    var pendingOperations: [(title: String, work: OperationWork, completion: ((OperationReport?) -> Void)?)] = []
    let palette = PaletteController()
    let triageView = TriageView()
    var triageActive = false
    var triagePreviewWork: DispatchWorkItem?
    var compareActive = false
    private(set) var operationRunning = false

    var activePane: BrowserPaneController { panes[session.current.activeSide == 1 ? 1 : 0] }
    var otherPane: BrowserPaneController { panes[session.current.activeSide == 1 ? 0 : 1] }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Neo-Finder", isDirectory: true)
        WorkspaceWindowController.adoptSandboxedData(into: support)
        store = SessionStore(directory: support)
        access = AccessManager()
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
        statusLabel.stringValue = "⌘K：パレット　Tab：反対側へ　F5／F6：反対側へコピー／移動　⇧⌘M：行き先を指定して移動"
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
            self.applyTemplates()
        }
    }

    /// Version 0.1 was sandboxed and kept its state inside the app container. Copy it once so
    /// workspaces and favorites survive the move; the old files are left untouched.
    static func adoptSandboxedData(into support: URL) {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: support.appendingPathComponent("session.json").path) else { return }
        let old = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/local.neofinder.app/Data/Library/Application Support/Neo-Finder", isDirectory: true)
        guard manager.fileExists(atPath: old.appendingPathComponent("session.json").path) else { return }
        try? manager.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["session.json", "operations.json"] {
            try? manager.copyItem(at: old.appendingPathComponent(name), to: support.appendingPathComponent(name))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var splitDimension: CGFloat { split.isVertical ? split.bounds.width : split.bounds.height }

    func createContent() {
        guard let window else { return }
        let root = NSView()
        window.contentView = root
        let top = NSStackView()
        top.orientation = .horizontal
        top.spacing = 8
        top.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let register = button("フォルダを開く…", #selector(registerFolder))
        let paletteButton = button("パレット ⌘K", #selector(showPalette))
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
        top.addArrangedSubview(paletteButton)
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
            pane.onRename = { [weak self] url, name in self?.renameURL(url, to: name) }
            pane.onDelete = { [weak self] urls in self?.trashURLs(urls) }
            pane.onRequestAccess = { [weak self] _ in self?.openPrivacySettings() }
            pane.onSelectionChange = { [weak self] in self?.selectionChanged() }
            pane.onEntriesChange = { [weak self] in self?.entriesChanged() }
            pane.onNavigate = { [weak self] url in self?.recordRecent(url, weight: 1) }
            pane.onFocusOther = { [weak self] in self?.focusOther() }
            pane.onTransferToOther = { [weak self] move in
                guard let self else { return }
                self.transfer(self.activePane.selectedURLs, to: self.otherPane.currentURL, move: move)
            }
            pane.keyInterceptor = { [weak self] event in self?.handleTriageKey(event) ?? false }
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
        triageView.onSlot = { [weak self] index, assign in self?.triageSlot(index, assign: assign) }
        triageView.onExit = { [weak self] in self?.endTriage() }
        palette.onClose = { [weak self] in self?.activePane.focusFiles() }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor), top.trailingAnchor.constraint(equalTo: root.trailingAnchor), top.topAnchor.constraint(equalTo: root.topAnchor), top.heightAnchor.constraint(equalToConstant: 52),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor), bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor), bottom.heightAnchor.constraint(equalToConstant: 48),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: top.bottomAnchor), sidebar.bottomAnchor.constraint(equalTo: bottom.topAnchor), sidebar.widthAnchor.constraint(equalToConstant: 172),
            split.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), split.trailingAnchor.constraint(equalTo: root.trailingAnchor), split.topAnchor.constraint(equalTo: top.bottomAnchor), split.bottomAnchor.constraint(equalTo: bottom.topAnchor)
        ])
    }

    func button(_ title: String, _ selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded
        return button
    }

    func setActive(_ side: Int) {
        session.current.activeSide = side == 1 ? 1 : 0
        for (index, pane) in panes.enumerated() { pane.isActive = index == session.current.activeSide }
        copyButton.title = session.current.activeSide == 0 ? "右へコピー" : "左へコピー"
        scheduleSave()
    }

    func snapshot() -> WorkspaceState {
        var current = session.current
        current.left = panes[0].state
        current.right = panes[1].state
        current.verticalSplit = split.isVertical
        if splitDimension > 0, let first = split.arrangedSubviews.first {
            current.dividerRatio = (split.isVertical ? first.frame.width : first.frame.height) / splitDimension
        }
        return current
    }

    func scheduleSave() {
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

    func prepareForTermination() { saveNow() }

    func refreshWorkspaces() {
        workspacePopup.removeAllItems()
        workspacePopup.addItem(withTitle: "現在：" + session.current.name)
        workspacePopup.item(at: 0)?.representedObject = "current"
        for workspace in session.workspaces {
            workspacePopup.addItem(withTitle: workspace.name)
            workspacePopup.lastItem?.representedObject = workspace.id.uuidString
        }
    }

    @objc func saveWorkspace() {
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

    @objc func loadWorkspace() {
        guard let id = workspacePopup.selectedItem?.representedObject as? String,
              let value = session.workspaces.first(where: { $0.id.uuidString == id }) else { return }
        applyWorkspace(value)
    }

    func applyWorkspace(_ value: WorkspaceState) {
        if triageActive { endTriage() }
        restoring = true
        session.current = value
        panes[0].state = value.left; panes[1].state = value.right
        split.isVertical = value.verticalSplit
        split.adjustSubviews()
        split.setPosition(splitDimension * value.dividerRatio, ofDividerAt: 0)
        setActive(value.activeSide)
        restoring = false
        refreshWorkspaces(); saveNow(); activePane.focusFiles()
        applyTemplates()
    }

    @objc func deleteWorkspace() {
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

    func refreshFavorites() {
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
        appendShelf()
    }

    @objc func addFavorite() {
        guard let name = askText(title: "お気に入りに追加", prompt: "表示名（元のフォルダ名は変更しません）", initial: activePane.currentURL.lastPathComponent) else { return }
        guard let group = askText(title: "グループ", prompt: "既存のグループ名、または新しい名前を入力してください。", initial: session.favoriteGroups.first?.name ?? "仕事") else { return }
        let item = Favorite(name: name, path: activePane.currentURL.path)
        if let index = session.favoriteGroups.firstIndex(where: { $0.name == group }) { session.favoriteGroups[index].items.append(item) }
        else { session.favoriteGroups.append(FavoriteGroup(name: group, items: [item])) }
        refreshFavorites(); saveNow()
    }

    @objc func openFavorite(_ sender: NSButton) {
        guard let favorite = session.favoriteGroups.flatMap(\.items).first(where: { $0.id.uuidString == sender.identifier?.rawValue }) else { return }
        activePane.navigate(to: URL(fileURLWithPath: favorite.path))
    }

    @objc func removeFavorite(_ sender: NSMenuItem) {
        for index in session.favoriteGroups.indices {
            session.favoriteGroups[index].items.removeAll { $0.id.uuidString == sender.representedObject as? String }
        }
        refreshFavorites(); saveNow()
    }

    @objc func renameFavorite(_ sender: NSMenuItem) {
        for group in session.favoriteGroups.indices {
            guard let index = session.favoriteGroups[group].items.firstIndex(where: { $0.id.uuidString == sender.representedObject as? String }) else { continue }
            if let name = askText(title: "表示名を変更", prompt: "実際のフォルダ名は変わりません。", initial: session.favoriteGroups[group].items[index].name) {
                session.favoriteGroups[group].items[index].name = name
                refreshFavorites(); saveNow()
            }
        }
    }

    @objc func registerFolder() { chooseFolder(suggested: activePane.currentURL) }

    func chooseFolder(suggested: URL?) {
        let panel = NSOpenPanel()
        panel.title = "フォルダを開く"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.directoryURL = suggested
        panel.prompt = "開く"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        activePane.navigate(to: url)
        statusLabel.stringValue = access.isWriteEnabled(url) ? "「\(url.lastPathComponent)」を開きました。" : "「\(url.lastPathComponent)」を開きました（クラウド・ネットワーク上のため閲覧のみ）。"
    }

    /// Reading a folder failed, most often because macOS privacy protection denied it.
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        statusLabel.stringValue = "「フルディスクアクセス」でNeo-Finderを許可し、アプリを再起動してください。"
    }

    func openExternal(_ url: URL) {
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let folder = values?.isDirectory == true && values?.isPackage != true ? url : url.deletingLastPathComponent()
        activePane.addTab(url: folder)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openURLs(_ urls: [URL]) {
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true && values?.isPackage != true { activePane.navigate(to: url) }
            else { NSWorkspace.shared.open(url) }
        }
    }

    @objc func openSelected(_ sender: Any?) { openURLs(activePane.selectedURLs) }
    @objc func preview(_ sender: Any?) { showPreview(activePane.selectedURLs) }
    func showPreview(_ urls: [URL]) {
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
    @objc func previewResigned(_ notification: Notification) {
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
    @objc func moveHere() { pasteFiles(move: true) }
    func pasteFiles(move: Bool) {
        guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return }
        transfer(urls, to: activePane.currentURL, move: move)
    }
    @objc func copyToOther() { transfer(activePane.selectedURLs, to: otherPane.currentURL, move: false) }
    @objc func moveToOther() { transfer(activePane.selectedURLs, to: otherPane.currentURL, move: true) }

    /// Returns true when the transfer was started or queued.
    @discardableResult
    func transfer(_ urls: [URL], to destination: URL, move: Bool) -> Bool {
        guard !urls.isEmpty else { return false }
        let target = destination.standardizedFileURL.path
        if urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == target }) {
            statusLabel.stringValue = "選択した項目は、すでに「\(destination.lastPathComponent)」にあります。"
            return false
        }
        do {
            try access.requireWrite([destination], directory: true)
            if move { try access.requireWrite(urls) }
            var conflict = ConflictPolicy.keepBoth
            let existing = urls.filter { FileManager.default.fileExists(atPath: destination.appendingPathComponent($0.lastPathComponent).path) }
            if !existing.isEmpty {
                let alert = NSAlert()
                alert.messageText = "同じ名前の項目があります"
                alert.informativeText = "転送先：\(destination.path)\n\(existing.count)項目が重複します。\n「置き換える」は転送先の旧項目をゴミ箱へ移してから入れ替えます（フォルダは結合せず丸ごと入れ替え）。⌘Zで元に戻せます。"
                alert.addButton(withTitle: "両方残す"); alert.addButton(withTitle: "置き換える")
                alert.addButton(withTitle: "スキップ"); alert.addButton(withTitle: "中止")
                switch alert.runModal() {
                case .alertFirstButtonReturn: conflict = .keepBoth
                case .alertSecondButtonReturn: conflict = .replace
                case .alertThirdButtonReturn: conflict = .skip
                default: return false
                }
            }
            let policy = conflict
            recordRecent(destination, weight: 3)
            if move {
                // After the items leave, select the next one so the keyboard flow continues.
                for pane in panes where !Set(pane.selectedURLs).isDisjoint(with: urls) { pane.prepareAdvance() }
            }
            performOperation("\(urls.count)項目を「\(destination.lastPathComponent)」へ\(move ? "移動" : "コピー")中…") { engine in
                if move { return try engine.move(urls, to: destination, conflict: policy) }
                return try engine.copy(urls, to: destination, conflict: policy)
            }
            return true
        } catch { showError(error); return false }
    }

    @objc func renameSelected() { activePane.beginRename() }
    /// The name was already typed in place in the list.
    func renameURL(_ url: URL, to name: String) {
        do {
            try access.requireWrite([url])
            performOperation("名前を変更中…") { try $0.rename(url, to: name) }
        } catch { showError(error) }
    }

    /// Like Finder: create the folder at once, then let its name be typed in place.
    @objc func newFolder() {
        let directory = activePane.currentURL
        let pane = activePane
        do {
            try access.requireWrite([directory], directory: true)
            var candidate = "名称未設定フォルダ"
            var number = 2
            while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                candidate = "名称未設定フォルダ \(number)"
                number += 1
            }
            let name = candidate
            let created = directory.appendingPathComponent(name, isDirectory: true)
            performOperation("フォルダを作成中…", completion: { report in
                if let report, report.completed == 1 { pane.reveal([created], rename: true) }
            }) { try $0.createFolder(in: directory, name: name) }
        } catch { showError(error) }
    }

    @objc func deleteSelected() { trashURLs(activePane.selectedURLs) }
    func trashURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        do {
            try access.requireWrite(urls)
            for pane in panes where !Set(pane.selectedURLs).isDisjoint(with: urls) { pane.prepareAdvance() }
            performOperation("\(urls.count)項目をゴミ箱に移動中…") { try $0.trash(urls) }
        } catch { showError(error) }
    }

    /// Runs a file operation in the background. While one is running, later requests wait in order.
    func performOperation(_ title: String, completion: ((OperationReport?) -> Void)? = nil, work: @escaping OperationWork) {
        if operationRunning {
            pendingOperations.append((title, work, completion))
            statusLabel.stringValue = "実行中の操作の後に \(pendingOperations.count)件が待機しています。"
            return
        }
        operationRunning = true
        progress.startAnimation(nil)
        cancelButton.isHidden = false
        undoButton.isEnabled = false
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "ファイル操作を完了するため")
        runOperation(title, completion: completion, work: work)
    }

    func runOperation(_ title: String, completion: ((OperationReport?) -> Void)?, work: @escaping OperationWork) {
        statusLabel.stringValue = pendingOperations.isEmpty ? title : title + "（待機 \(pendingOperations.count)件）"
        operationQueue.async { [weak self, engine] in
            let result = Result { try work(engine) }
            let canUndo = engine.canUndo
            let history = engine.historyLines()
            DispatchQueue.main.async {
                guard let self else { return }
                self.undoAvailable = canUndo
                self.historyEntries = history
                var finished: OperationReport?
                switch result {
                case .success(let report):
                    finished = report
                    self.statusLabel.stringValue = report.summary
                    self.statusLabel.toolTip = ([report.summary] + report.failures).joined(separator: "\n")
                    if !report.failures.isEmpty { self.showMessage("一部の操作を完了できませんでした", ([report.summary] + report.failures).joined(separator: "\n")) }
                case .failure(let error): self.statusLabel.stringValue = error.localizedDescription; self.showError(error)
                }
                self.panes.forEach { $0.reload() }
                completion?(finished)
                if self.pendingOperations.isEmpty {
                    self.operationRunning = false
                    self.progress.stopAnimation(nil)
                    self.cancelButton.isHidden = true
                    self.undoButton.isEnabled = canUndo
                    if let activity = self.activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
                } else {
                    let next = self.pendingOperations.removeFirst()
                    self.runOperation(next.title, completion: next.completion, work: next.work)
                }
            }
        }
    }

    @objc func undo(_ sender: Any?) {
        guard undoAvailable, !operationRunning else { return }
        performOperation("直前の操作を取り消しています…") { try $0.undoLast() }
    }
    @objc func dispatchUndo(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.undoManager?.undo()
        } else { undo(sender) }
    }
    @objc func dispatchRedo(_ sender: Any?) {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.redo()
    }
    @objc func cancelFileOperation() {
        pendingOperations.removeAll()
        engine.cancel()
        statusLabel.stringValue = "中止を要求しました。待機中の操作は取り消し、処理中の項目が安全に終わるまで待っています…"
    }

    func explainRunningOperation() { showMessage("ファイル操作が進行中です", "完了を待つか、下部の「中止」を押してください。中止前に完了した項目は残り、待機中の操作は実行しません。") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if operationRunning { explainRunningOperation(); return false }
        saveNow(); return true
    }
    @objc func didBecomeActive() { if !operationRunning { panes.forEach { $0.reload() } } }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitView.isVertical ? 300 : 210 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitDimension - (splitView.isVertical ? 300 : 210) }
    func splitViewDidResizeSubviews(_ notification: Notification) { scheduleSave() }

    func askText(title: String, prompt: String, initial: String) -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = prompt
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "キャンセル")
        let input = NSTextField(string: initial); input.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        alert.accessoryView = input; alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func confirm(title: String, detail: String, action: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: action); alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func showError(_ error: Error) { showMessage("操作を完了できませんでした", error.localizedDescription) }
    func showMessage(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func addTab() { activePane.addTab() }
    @objc func closeTab() { if !activePane.closeTab() { window?.performClose(nil) } }
    @objc func goBack() { activePane.goBack() }
    @objc func goForward() { activePane.goForward() }
    @objc func goUp() { activePane.goUp() }
    @objc func toggleHidden() { session.showHidden.toggle(); panes.forEach { $0.showHidden = session.showHidden; $0.reload() }; saveNow() }
    @objc func toggleRelative() { session.relativeDates.toggle(); panes.forEach { $0.relativeDates = session.relativeDates; $0.reload() }; saveNow() }
    @objc func listView() { activePane.setViewMode(.list) }
    @objc func columnsView() { activePane.setViewMode(.columns) }
    @objc func sortName() { activePane.setSort(.name) }
    @objc func sortDate() { activePane.setSort(.date) }
    @objc func sortSize() { activePane.setSort(.size) }
    @objc func nextTab() { activePane.selectAdjacentTab(1) }
    @objc func previousTab() { activePane.selectAdjacentTab(-1) }
    @objc func toggleFlat() { activePane.toggleFlat() }
    @objc func toggleSplit() { split.isVertical.toggle(); split.adjustSubviews(); split.setPosition(splitDimension / 2, ofDividerAt: 0); saveNow() }
    @objc func focusOther() {
        // The other pane is covered by the preview during triage.
        guard !triageActive else { return }
        setActive(session.current.activeSide == 0 ? 1 : 0); activePane.focusFiles()
    }
    @objc func focusFilter() { activePane.focusFilter() }
    @objc func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting(activePane.selectedURLs.isEmpty ? [activePane.currentURL] : activePane.selectedURLs) }
    @objc func showInfo() {
        let urls = activePane.selectedURLs.isEmpty ? [activePane.currentURL] : activePane.selectedURLs
        let lines = urls.prefix(20).map { url -> String in
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .typeIdentifierKey, .tagNamesKey])
            return "\(url.path)\n種類：\(v?.typeIdentifier ?? "不明")\nサイズ：\(v?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")\n変更日：\(v?.contentModificationDate?.formatted() ?? "—")\nタグ：\((v?.tagNames ?? []).joined(separator: "、"))"
        }
        showMessage("情報（\(urls.count)項目）", lines.joined(separator: "\n\n"))
    }
    @objc func shareSelected() {
        let urls = activePane.selectedURLs
        guard !urls.isEmpty else { return }
        NSSharingServicePicker(items: urls).show(relativeTo: copyButton.bounds, of: copyButton, preferredEdge: .minY)
    }
    @objc func help() {
        showMessage("Neo-Finder 0.2", "左右のペインで独立したタブと履歴を使えます。フォルダの登録は不要です。\n\n⌘K：パレット（場所・コマンド・作業セット）　⇧⌘G：パスを入力\nTab：反対側のペインへ　F5／F6（⌘Return／⇧⌘Return）：反対側へコピー／移動\n⇧⌘M／⇧⌘K：行き先を入力して移動／コピー\nReturn：その場で名前変更（Tabで次の項目へ）　Space：Quick Look\n⇧⌘T：仕分けモード（1〜9で行き先へ送る）\n⇧⌘D：左右を比較　⇧⌘F：階層を展開して表示　⌘F：絞り込み\n⌘B：収集棚に追加　⌥⌘B／⇧⌘B：棚の項目をここへ移動／コピー\n⌘Z：直前の操作を戻す\n\n同名の項目は「置き換える」を選ぶと旧項目をゴミ箱へ移してから入れ替えます。クラウド同期・ネットワーク上の場所の編集は、Neo-Finderメニューで許可した場合のみ行います。取消はこの起動中のみで、外部変更がある項目には実行しません。")
    }

    @objc func showHistory() {
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
        item(app, "クラウド・ネットワーク上の編集を許可（実験的）", #selector(toggleRemoteWrites), target: self)
        let services = NSMenuItem(title: "サービス", action: nil, keyEquivalent: ""); services.submenu = NSMenu(title: "サービス"); app.addItem(services); NSApp.servicesMenu = services.submenu
        app.addItem(.separator()); item(app, "Neo-Finderを隠す", #selector(NSApplication.hide(_:)), "h")
        item(app, "Neo-Finderを終了", #selector(NSApplication.terminate(_:)), "q")
        let file = submenu("ファイル")
        item(file, "フォルダを開く…", #selector(registerFolder), target: self)
        item(file, "Finderの最前面ウインドウを開く", #selector(openFinderWindow), "o", [.command, .shift], target: self)
        item(file, "開く", #selector(openSelected(_:)), "o", target: self)
        item(file, "新規タブ", #selector(addTab), "t", target: self)
        item(file, "タブ／ウインドウを閉じる", #selector(closeTab), "w", target: self)
        item(file, "新規フォルダ", #selector(newFolder), "n", [.command, .shift], target: self)
        file.addItem(.separator())
        item(file, "名前を変更（Return）", #selector(renameSelected), target: self)
        item(file, "ゴミ箱に入れる", #selector(deleteSelected), "\u{8}", target: self)
        item(file, "情報を見る", #selector(showInfo), "i", target: self)
        item(file, "Quick Look", #selector(preview(_:)), "y", target: self)
        item(file, "共有…", #selector(shareSelected), target: self)
        item(file, "Finderで表示", #selector(revealInFinder), target: self)
        item(file, "ターミナルで開く", #selector(openTerminal), target: self)
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
        item(edit, "パスをコピー", #selector(copyPath), "c", [.command, .option], target: self)
        edit.addItem(.separator())
        item(edit, "反対側へコピー", #selector(copyToOther), "\u{F708}", [], target: self)
        item(edit, "反対側へ移動", #selector(moveToOther), "\u{F709}", [], target: self)
        item(edit, "行き先を指定して移動…", #selector(moveToChosen), "m", [.command, .shift], target: self)
        item(edit, "行き先を指定してコピー…", #selector(copyToChosen), "k", [.command, .shift], target: self)
        edit.addItem(.separator())
        item(edit, "収集棚に追加", #selector(addToShelf), "b", target: self)
        item(edit, "棚の項目をここへ移動", #selector(shelfMoveHere), "b", [.command, .option], target: self)
        item(edit, "棚の項目をここへコピー", #selector(shelfCopyHere), "b", [.command, .shift], target: self)
        item(edit, "棚を空にする", #selector(clearShelf), target: self)
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
        item(view, "このフォルダ内を絞り込む", #selector(focusFilter), "f", target: self)
        item(view, "階層を展開して表示", #selector(toggleFlat), "f", [.command, .shift], target: self)
        view.addItem(.separator())
        item(view, "仕分けモード", #selector(toggleTriage), "t", [.command, .shift], target: self)
        item(view, "左右を比較", #selector(toggleCompare), "d", [.command, .shift], target: self)
        item(view, "差分を選択", #selector(selectDifferences), target: self)
        let go = submenu("移動")
        item(go, "戻る", #selector(goBack), "[", target: self)
        item(go, "進む", #selector(goForward), "]", target: self)
        item(go, "親フォルダ", #selector(goUp), target: self)
        item(go, "パレット…", #selector(showPalette), "k", target: self)
        item(go, "フォルダへ移動…", #selector(goToFolder), "g", [.command, .shift], target: self)
        item(go, "反対側のペインへ（Tab）", #selector(focusOther), target: self)
        item(go, "次のタブ", #selector(nextTab), "}", target: self)
        item(go, "前のタブ", #selector(previousTab), "{", target: self)
        let workspace = submenu("作業セット")
        item(workspace, "現在の作業セットを保存…", #selector(saveWorkspace), target: self)
        item(workspace, "保存済みセットを削除…", #selector(deleteWorkspace), target: self)
        item(workspace, "現在の場所をお気に入りへ…", #selector(addFavorite), target: self)
        workspace.addItem(.separator())
        item(workspace, "このタブを日付連動にする…", #selector(setTabTemplate), target: self)
        item(workspace, "日付連動を解除", #selector(clearTabTemplate), target: self)
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
        let fileActions: [Selector] = [#selector(copyToOther), #selector(moveToOther), #selector(deleteSelected), #selector(renameSelected), #selector(newFolder), #selector(moveHere), #selector(paste(_:)), #selector(undo(_:)),
                                       #selector(moveToChosen), #selector(copyToChosen), #selector(addToShelf), #selector(shelfMoveHere), #selector(shelfCopyHere),
                                       #selector(toggleTriage), #selector(copyPath)]
        if fileActions.contains(where: { $0 == action }) {
            guard window?.isVisible == true, NSApp.keyWindow === window else { return false }
            if NSApp.keyWindow?.firstResponder is NSTextView { return false }
        }
        if action == #selector(toggleHidden) { menuItem.state = session.showHidden ? .on : .off }
        if action == #selector(toggleRelative) { menuItem.state = session.relativeDates ? .on : .off }
        if action == #selector(toggleRemoteWrites) { menuItem.state = access.allowRemoteWrites ? .on : .off }
        if action == #selector(toggleTriage) { menuItem.state = triageActive ? .on : .off }
        if action == #selector(toggleCompare) { menuItem.state = compareActive ? .on : .off }
        if action == #selector(toggleFlat) { menuItem.state = activePane.isFlat ? .on : .off }
        if action == #selector(clearTabTemplate) { return activePane.currentTemplate != nil }
        if action == #selector(undo(_:)) { return undoAvailable && !operationRunning }
        if [#selector(copyToOther), #selector(moveToOther), #selector(deleteSelected), #selector(renameSelected),
            #selector(moveToChosen), #selector(copyToChosen), #selector(addToShelf)].contains(action) {
            return !activePane.selectedURLs.isEmpty && (action != #selector(renameSelected) || activePane.selectedURLs.count == 1)
        }
        if [#selector(shelfMoveHere), #selector(shelfCopyHere), #selector(clearShelf)].contains(action) { return !session.shelf.isEmpty }
        return true
    }
}
