import AppKit
import NeoFinderCore

/// One independent Finder-style browser. File mutations are delegated to the window's operation service.
@MainActor
final class BrowserPaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    let side: Int
    private var paneState: PaneState
    var state: PaneState {
        get { paneState }
        set {
            paneState = newValue
            normalizeState()
            if isViewLoaded {
                filterField.stringValue = ""
                updateNavigation()
                reload()
            }
        }
    }
    var currentURL: URL { URL(fileURLWithPath: currentTab.path, isDirectory: true) }
    var selectedURLs: [URL] {
        guard let table = selectionTable ?? visibleCurrentTable,
              let model = tableModels[ObjectIdentifier(table)] else { return [] }
        return table.selectedRowIndexes.compactMap { model.entries.indices.contains($0) ? model.entries[$0].url : nil }
    }
    var isActive = false {
        didSet {
            if isViewLoaded { updateActiveAppearance() }
        }
    }
    var showHidden = false { didSet { if showHidden != oldValue, isViewLoaded { reload() } } }
    var relativeDates = true { didSet { if isViewLoaded { refreshCellDisplays() } } }
    var onActivate: ((Int) -> Void)?
    var onStateChange: (() -> Void)?
    var onOpen: (([URL]) -> Void)?
    var onPreview: (([URL]) -> Void)?
    var onRename: ((URL) -> Void)?
    var onDelete: (([URL]) -> Void)?
    var onDrop: (([URL], URL, Bool) -> Void)?
    var onRequestAccess: ((URL) -> Void)?

    private var currentTabIndex: Int { paneState.tabs.firstIndex { $0.id == paneState.selectedTabID } ?? 0 }
    private var currentTab: BrowserTab { paneState.tabs[currentTabIndex] }
    private let paneLabel = NSTextField(labelWithString: "")
    private let tabStack = NSStackView()
    private let tabScroll = NSScrollView()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let pathControl = NSPathControl()
    private let filterField = NSSearchField()
    private let viewSelector = NSSegmentedControl(labels: ["リスト", "カラム"], trackingMode: .selectOne, target: nil, action: nil)
    private let fileArea = NSView()
    private let listScroll = NSScrollView()
    private let listTable = BrowserFileTable()
    private let columnsScroll = NSScrollView()
    private let columnStack = NSStackView()
    private let messageStack = NSStackView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let accessButton = NSButton(title: "フォルダを選択してアクセスを許可…", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let filterBadge = NSTextField(labelWithString: "")
    private var allEntries: [FileEntry] = []
    private var ancestorEntries: [(URL, [FileEntry])] = []
    private var ancestorLoadErrors: [String: String] = [:]
    private var tableModels: [ObjectIdentifier: TableModel] = [:]
    private var columnTables: [BrowserFileTable] = []
    private weak var selectionTable: BrowserFileTable?
    private var generation = 0
    private var loadedPath: String?
    private var loadedTabID: UUID?
    private var loadError: Error?
    private var loading = false
    private var initialRead = false
    private var pendingRead: (path: String, tab: UUID, mode: BrowserViewMode, hidden: Bool)?
    private var renderedConfiguration: RenderConfiguration?
    private var lastDateRefresh = Date.distantPast
    private var changingSelection = false
    private var filterWork: DispatchWorkItem?
    private var rememberedSelections: [UUID: [URL]] = [:]

    private final class TableModel {
        let url: URL
        let current: Bool
        var entries: [FileEntry]
        init(url: URL, current: Bool, entries: [FileEntry]) {
            self.url = url; self.current = current; self.entries = entries
        }
    }

    private struct TableSnapshot {
        var selected: Set<String>
        var origin: NSPoint
        var focused: Bool
    }

    private struct RenderConfiguration: Equatable {
        let tab: UUID
        let path: String
        let mode: BrowserViewMode
        let sort: FileSort
        let ascending: Bool
        let query: String
    }

    private var renderConfiguration: RenderConfiguration {
        RenderConfiguration(tab: currentTab.id, path: currentURL.path, mode: currentTab.viewMode,
                            sort: currentTab.sort, ascending: currentTab.ascending, query: filterField.stringValue)
    }

    init(side: Int, state: PaneState) {
        self.side = side
        self.paneState = state
        super.init(nibName: nil, bundle: nil)
        normalizeState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.setAccessibilityLabel(side == 0 ? "左のファイルペイン" : "右のファイルペイン")
        buildInterface()
        updateNavigation()
        updateActiveAppearance()
        reload()
    }

    private func normalizeState() {
        if paneState.tabs.isEmpty { paneState = PaneState(path: FileManager.default.homeDirectoryForCurrentUser.path) }
        if !paneState.tabs.contains(where: { $0.id == paneState.selectedTabID }) { paneState.selectedTabID = paneState.tabs[0].id }
    }

    private func buildInterface() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 1),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -1),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -1)
        ])

        let tabRow = NSStackView()
        tabRow.orientation = .horizontal
        tabRow.spacing = 5
        tabRow.edgeInsets = NSEdgeInsets(top: 6, left: 9, bottom: 5, right: 7)
        paneLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        paneLabel.setContentHuggingPriority(.required, for: .horizontal)
        paneLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        tabRow.addArrangedSubview(paneLabel)
        tabStack.orientation = .horizontal
        tabStack.spacing = 4
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = true
        tabScroll.autohidesScrollers = true
        tabScroll.horizontalScrollElasticity = .allowed
        tabScroll.verticalScrollElasticity = .none
        tabScroll.documentView = tabStack
        tabScroll.heightAnchor.constraint(equalToConstant: 30).isActive = true
        tabStack.heightAnchor.constraint(equalTo: tabScroll.contentView.heightAnchor).isActive = true
        tabRow.addArrangedSubview(tabScroll)
        let add = symbolButton("plus", label: "新しいタブ", action: #selector(addTabClicked))
        tabRow.addArrangedSubview(add)
        add.widthAnchor.constraint(equalToConstant: 25).isActive = true
        append(tabRow, to: stack)

        let locationRow = NSStackView()
        locationRow.orientation = .horizontal
        locationRow.spacing = 3
        locationRow.edgeInsets = NSEdgeInsets(top: 3, left: 7, bottom: 5, right: 7)
        configureSymbol(backButton, symbol: "chevron.left", label: "戻る（⌘[）", action: #selector(backClicked))
        configureSymbol(forwardButton, symbol: "chevron.right", label: "進む（⌘]）", action: #selector(forwardClicked))
        configureSymbol(upButton, symbol: "arrow.up", label: "親フォルダ（⌘↑）", action: #selector(upClicked))
        for button in [backButton, forwardButton, upButton] {
            button.widthAnchor.constraint(equalToConstant: 25).isActive = true
            locationRow.addArrangedSubview(button)
        }
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.target = self
        pathControl.doubleAction = #selector(pathClicked)
        pathControl.setAccessibilityLabel("現在の場所。親の項目をダブルクリックして移動")
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationRow.addArrangedSubview(pathControl)
        append(locationRow, to: stack)

        let filterRow = NSStackView()
        filterRow.orientation = .horizontal
        filterRow.spacing = 7
        filterRow.edgeInsets = NSEdgeInsets(top: 2, left: 9, bottom: 8, right: 9)
        filterField.placeholderString = "このフォルダを絞り込む"
        filterField.setAccessibilityLabel(side == 0 ? "左のフォルダ内を絞り込む" : "右のフォルダ内を絞り込む")
        filterField.delegate = self
        filterField.sendsSearchStringImmediately = true
        filterField.sendsWholeSearchString = false
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filterRow.addArrangedSubview(filterField)
        viewSelector.segmentStyle = .rounded
        viewSelector.controlSize = .small
        viewSelector.target = self
        viewSelector.action = #selector(viewModeChanged)
        viewSelector.setWidth(66, forSegment: 0)
        viewSelector.setWidth(66, forSegment: 1)
        viewSelector.setContentCompressionResistancePriority(.required, for: .horizontal)
        viewSelector.setToolTip("リスト表示（⌘2）", forSegment: 0)
        viewSelector.setToolTip("カラム表示（⌘3）", forSegment: 1)
        viewSelector.setAccessibilityLabel("表示方式")
        filterRow.addArrangedSubview(viewSelector)
        append(filterRow, to: stack)

        let separator = NSBox()
        separator.boxType = .separator
        append(separator, to: stack)
        fileArea.translatesAutoresizingMaskIntoConstraints = false
        append(fileArea, to: stack)
        fileArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        configureTable(listTable, details: true, title: "名前")
        configureScroll(listScroll, table: listTable)
        pin(listScroll, in: fileArea)
        columnsScroll.hasHorizontalScroller = true
        columnsScroll.hasVerticalScroller = false
        columnsScroll.autohidesScrollers = true
        columnsScroll.drawsBackground = true
        columnsScroll.backgroundColor = .controlBackgroundColor
        columnStack.orientation = .horizontal
        columnStack.spacing = 1
        columnStack.alignment = .top
        columnStack.translatesAutoresizingMaskIntoConstraints = false
        columnsScroll.documentView = columnStack
        columnStack.heightAnchor.constraint(equalTo: columnsScroll.contentView.heightAnchor).isActive = true
        pin(columnsScroll, in: fileArea)

        messageStack.orientation = .vertical
        messageStack.alignment = .centerX
        messageStack.spacing = 9
        messageStack.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.maximumNumberOfLines = 5
        messageStack.addArrangedSubview(messageLabel)
        accessButton.bezelStyle = .rounded
        accessButton.controlSize = .small
        accessButton.target = self
        accessButton.action = #selector(requestAccessClicked)
        messageStack.addArrangedSubview(accessButton)
        fileArea.addSubview(messageStack)
        NSLayoutConstraint.activate([
            messageStack.centerXAnchor.constraint(equalTo: fileArea.centerXAnchor),
            messageStack.centerYAnchor.constraint(equalTo: fileArea.centerYAnchor),
            messageStack.widthAnchor.constraint(lessThanOrEqualTo: fileArea.widthAnchor, constant: -30)
        ])

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        footer.addArrangedSubview(statusLabel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)
        filterBadge.font = .systemFont(ofSize: 10, weight: .medium)
        filterBadge.textColor = .controlAccentColor
        filterBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        footer.addArrangedSubview(filterBadge)
        append(footer, to: stack)
    }

    private func append(_ child: NSView, to stack: NSStackView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func pin(_ child: NSView, in parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    private func symbolButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton()
        configureSymbol(button, symbol: symbol, label: label, action: action)
        return button
    }

    private func configureSymbol(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
    }

    private func configureScroll(_ scroll: NSScrollView, table: BrowserFileTable) {
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
    }

    private func configureTable(_ table: BrowserFileTable, details: Bool, title: String) {
        table.delegate = self
        table.dataSource = self
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = true
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 10, height: 2)
        table.usesAlternatingRowBackgroundColors = details
        table.style = .plain
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked(_:))
        table.setAccessibilityLabel(side == 0 ? "左のファイル一覧" : "右のファイル一覧")
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = title
        name.width = details ? 230 : 225
        name.minWidth = 100
        name.resizingMask = .autoresizingMask
        if details { name.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true) }
        table.addTableColumn(name)
        if details {
            let date = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
            date.title = "更新日"
            date.width = 104
            date.minWidth = 78
            date.maxWidth = 175
            date.resizingMask = .userResizingMask
            date.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: false)
            table.addTableColumn(date)
            let size = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
            size.title = "サイズ"
            size.width = 76
            size.minWidth = 58
            size.maxWidth = 120
            size.resizingMask = .userResizingMask
            size.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: false)
            table.addTableColumn(size)
            table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        }
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        table.onActivate = { [weak self, weak table] in
            guard let self, let table else { return }
            self.selectionTable = table
            self.activate()
            self.updateStatus()
        }
        table.handleKey = { [weak self] event in self?.handleTableKey(event) ?? false }
        table.onCommitSelection = { [weak self, weak table] in
            guard let table else { return }
            self?.openSelectedColumnFolder(in: table)
        }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
    }

    private func activate() { onActivate?(side) }

    private func updateActiveAppearance() {
        paneLabel.stringValue = side == 0 ? (isActive ? "左 • 操作中" : "左") : (isActive ? "右 • 操作中" : "右")
        paneLabel.textColor = isActive ? .controlAccentColor : .secondaryLabelColor
        view.layer?.borderWidth = isActive ? 1.5 : 0.5
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.borderColor = (isActive ? NSColor.controlAccentColor.withAlphaComponent(0.65) : .separatorColor).cgColor
        }
    }

    private func updateNavigation() {
        pathControl.url = currentURL
        pathControl.toolTip = currentURL.path
        backButton.isEnabled = currentTab.historyIndex > 0
        forwardButton.isEnabled = currentTab.historyIndex + 1 < currentTab.history.count
        upButton.isEnabled = currentURL.path != "/"
        viewSelector.selectedSegment = currentTab.viewMode == .list ? 0 : 1
        for child in tabStack.arrangedSubviews { tabStack.removeArrangedSubview(child); child.removeFromSuperview() }
        for (index, tab) in paneState.tabs.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 0
            let url = URL(fileURLWithPath: tab.path)
            let button = NSButton(title: url.path == "/" ? "Macintosh HD" : url.lastPathComponent, target: self, action: #selector(tabClicked(_:)))
            button.tag = index
            button.bezelStyle = .roundRect
            button.setButtonType(.pushOnPushOff)
            button.state = tab.id == paneState.selectedTabID ? .on : .off
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: tab.id == paneState.selectedTabID ? .semibold : .regular)
            button.toolTip = tab.path
            button.setAccessibilityLabel("タブ: \(tab.path)")
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
            button.lineBreakMode = .byTruncatingMiddle
            row.addArrangedSubview(button)
            let close = symbolButton("xmark", label: "\(button.title)タブを閉じる", action: #selector(closeTabClicked(_:)))
            close.tag = index
            close.controlSize = .mini
            close.widthAnchor.constraint(equalToConstant: 19).isActive = true
            row.addArrangedSubview(close)
            tabStack.addArrangedSubview(row)
        }
        listScroll.isHidden = currentTab.viewMode != .list
        columnsScroll.isHidden = currentTab.viewMode != .columns
    }

    func navigate(to url: URL) {
        let destination = url.standardizedFileURL
        guard destination.path != currentURL.path else { reload(); return }
        rememberSelection()
        var tab = currentTab
        tab.navigate(to: destination.path)
        paneState.tabs[currentTabIndex] = tab
        filterField.stringValue = ""
        activate()
        updateNavigation()
        onStateChange?()
        reload()
    }

    func addTab(url: URL? = nil) {
        rememberSelection()
        var tab = BrowserTab(path: (url ?? currentURL).path)
        tab.viewMode = currentTab.viewMode
        tab.sort = currentTab.sort
        tab.ascending = currentTab.ascending
        paneState.tabs.append(tab)
        paneState.selectedTabID = tab.id
        filterField.stringValue = ""
        activate()
        updateNavigation()
        onStateChange?()
        reload()
    }

    @discardableResult
    func closeTab() -> Bool {
        guard paneState.tabs.count > 1 else { return false }
        let index = currentTabIndex
        rememberedSelections.removeValue(forKey: currentTab.id)
        paneState.tabs.remove(at: index)
        paneState.selectedTabID = paneState.tabs[min(index, paneState.tabs.count - 1)].id
        filterField.stringValue = ""
        updateNavigation()
        onStateChange?()
        reload()
        return true
    }

    func goBack() {
        var tab = currentTab
        guard let path = tab.goBack() else { return }
        rememberSelection()
        tab.path = path
        paneState.tabs[currentTabIndex] = tab
        filterField.stringValue = ""
        updateNavigation()
        onStateChange?()
        reload()
    }

    func goForward() {
        var tab = currentTab
        guard let path = tab.goForward() else { return }
        rememberSelection()
        tab.path = path
        paneState.tabs[currentTabIndex] = tab
        filterField.stringValue = ""
        updateNavigation()
        onStateChange?()
        reload()
    }

    func goUp() { navigate(to: currentURL.deletingLastPathComponent()) }

    func setViewMode(_ mode: BrowserViewMode) {
        guard currentTab.viewMode != mode else { return }
        let selectedPaths = Set(selectedURLs.map(\.path))
        rememberSelection()
        paneState.tabs[currentTabIndex].viewMode = mode
        updateNavigation()
        // Make the new view usable during the initiating event, using metadata already in memory.
        // The later read preserves focus only if this table is still the actual first responder.
        applyFilter()
        if let table = visibleCurrentTable, let model = tableModels[ObjectIdentifier(table)] {
            changingSelection = true
            table.selectRowIndexes(IndexSet(model.entries.indices.filter { selectedPaths.contains(model.entries[$0].url.path) }), byExtendingSelection: false)
            changingSelection = false
        }
        focusFiles()
        updateStatus()
        onStateChange?()
        reload()
    }

    func setSort(_ sort: FileSort) {
        if currentTab.sort == sort { paneState.tabs[currentTabIndex].ascending.toggle() }
        else {
            paneState.tabs[currentTabIndex].sort = sort
            paneState.tabs[currentTabIndex].ascending = sort == .name
        }
        applyFilter()
        onStateChange?()
    }

    func focusFiles() {
        activate()
        if let table = visibleCurrentTable { selectionTable = table; view.window?.makeFirstResponder(table) }
    }

    func focusFilter() {
        activate()
        view.window?.makeFirstResponder(filterField)
        filterField.selectText(nil)
    }

    private var visibleCurrentTable: BrowserFileTable? { currentTab.viewMode == .list ? listTable : columnTables.last }

    private func rememberSelection() { rememberedSelections[currentTab.id] = selectedURLs }

    /// Read metadata away from the UI thread. A generation guard rejects results for a tab that was left meanwhile.
    func reload() {
        guard isViewLoaded else { return }
        let url = currentURL
        let hidden = showHidden
        let mode = currentTab.viewMode
        let tabID = currentTab.id
        if loading, let pendingRead,
           pendingRead.path == url.path, pendingRead.tab == tabID,
           pendingRead.mode == mode, pendingRead.hidden == hidden { return }
        generation += 1
        let request = generation
        pendingRead = (url.path, tabID, mode, hidden)
        let ancestors = mode == .columns ? ancestorURLs(for: url) : []
        let samePath = loadedPath == url.path && loadedTabID == tabID
        initialRead = !samePath || renderedConfiguration == nil
        if !samePath {
            changingSelection = true
            allEntries = []
            ancestorEntries = []
            ancestorLoadErrors = [:]
            tableModels.removeAll()
            selectionTable = nil
            listTable.reloadData()
            for child in columnStack.arrangedSubviews { columnStack.removeArrangedSubview(child); child.removeFromSuperview() }
            columnTables.removeAll()
            changingSelection = false
            loadError = nil
        }
        loading = true
        updateStatus()
        updateMessage()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try FolderReader.contents(of: url, showHidden: hidden) }
            let parentResults: [(URL, [FileEntry], String?)] = ancestors.map { parent in
                do { return (parent, try FolderReader.contents(of: parent, showHidden: hidden), nil) }
                catch { return (parent, [], error.localizedDescription) }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == request else { return }
                self.loading = false
                self.pendingRead = nil
                self.loadedPath = url.path
                self.loadedTabID = tabID
                let parentErrors = Dictionary(uniqueKeysWithValues: parentResults.compactMap { parent in
                    parent.2.map { (parent.0.path, $0) }
                })
                switch result {
                case .success(let entries):
                    let unchanged = self.renderedConfiguration == self.renderConfiguration
                        && Self.sameEntries(self.allEntries, entries)
                        && self.ancestorLoadErrors == parentErrors
                        && self.ancestorEntries.count == parentResults.count
                        && zip(self.ancestorEntries, parentResults).allSatisfy { old, new in
                            old.0 == new.0 && Self.sameEntries(old.1, new.1)
                        }
                    self.loadError = nil
                    if unchanged {
                        if self.relativeDates && Date().timeIntervalSince(self.lastDateRefresh) >= 60 { self.refreshCellDisplays() }
                        self.updateStatus()
                        self.updateMessage()
                        return
                    }
                    self.allEntries = entries
                case .failure(let error):
                    self.allEntries = []
                    self.loadError = error
                }
                self.ancestorEntries = parentResults.map { ($0.0, $0.1) }
                self.ancestorLoadErrors = parentErrors
                self.applyFilter()
                self.updateMessage()
            }
        }
    }

    /// Polling never rebuilds unchanged rows: selection, an in-progress drag, and accessibility elements stay stable.
    private static func sameEntries(_ first: [FileEntry], _ second: [FileEntry]) -> Bool {
        guard first.count == second.count else { return false }
        func same(_ a: FileEntry, _ b: FileEntry) -> Bool {
            a.url == b.url && a.name == b.name && a.isDirectory == b.isDirectory
                && a.isPackage == b.isPackage && a.isSymbolicLink == b.isSymbolicLink
                && a.size == b.size && a.modifiedAt == b.modifiedAt && a.tags == b.tags
        }
        if zip(first, second).allSatisfy({ same($0.0, $0.1) }) { return true }
        let indexed = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0) })
        return second.allSatisfy { item in indexed[item.id].map { same($0, item) } ?? false }
    }

    private func ancestorURLs(for url: URL) -> [URL] {
        var paths: [URL] = []
        var cursor = url
        for _ in 0..<2 {
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { break }
            paths.insert(parent, at: 0)
            cursor = parent
        }
        return paths
    }

    private func tableSnapshots() -> [String: TableSnapshot] {
        var result: [String: TableSnapshot] = [:]
        let visibleTables = currentTab.viewMode == .list ? [listTable] : columnTables
        for table in visibleTables {
            guard let model = tableModels[ObjectIdentifier(table)] else { continue }
            let selected = Set(table.selectedRowIndexes.compactMap { model.entries.indices.contains($0) ? model.entries[$0].url.path : nil })
            result[model.url.path] = TableSnapshot(selected: selected, origin: table.enclosingScrollView?.contentView.bounds.origin ?? .zero, focused: view.window?.firstResponder === table)
        }
        return result
    }

    private func applyFilter() {
        let snapshots = tableSnapshots()
        let oldSelectionPath = selectionTable.flatMap { tableModels[ObjectIdentifier($0)]?.url.path }
        let filtered = FileEntry.filtered(allEntries, query: filterField.stringValue, sort: currentTab.sort, ascending: currentTab.ascending)
        changingSelection = true
        defer {
            changingSelection = false
            renderedConfiguration = renderConfiguration
            lastDateRefresh = Date()
            updateStatus()
            updateMessage()
        }
        tableModels[ObjectIdentifier(listTable)] = TableModel(url: currentURL, current: true, entries: filtered)
        listTable.sortDescriptors = [NSSortDescriptor(key: sortKey(currentTab.sort), ascending: currentTab.ascending)]
        listTable.reloadData()
        if currentTab.viewMode == .columns {
            let desired = ancestorEntries.map { $0.0.path } + [currentURL.path]
            let existing = columnTables.compactMap { tableModels[ObjectIdentifier($0)]?.url.path }
            if desired != existing {
                for table in columnTables { tableModels.removeValue(forKey: ObjectIdentifier(table)) }
                for child in columnStack.arrangedSubviews { columnStack.removeArrangedSubview(child); child.removeFromSuperview() }
                columnTables.removeAll()
                for (index, path) in desired.enumerated() {
                    let url = URL(fileURLWithPath: path)
                    let table = BrowserFileTable()
                    configureTable(table, details: false, title: url.path == "/" ? "Macintosh HD" : url.lastPathComponent)
                    let scroll = NSScrollView()
                    configureScroll(scroll, table: table)
                    scroll.translatesAutoresizingMaskIntoConstraints = false
                    columnStack.addArrangedSubview(scroll)
                    // Constraints between two views require their common ancestor to exist first.
                    NSLayoutConstraint.activate([
                        scroll.widthAnchor.constraint(equalToConstant: 245),
                        scroll.heightAnchor.constraint(equalTo: columnStack.heightAnchor)
                    ])
                    columnTables.append(table)
                    tableModels[ObjectIdentifier(table)] = TableModel(url: url, current: index == desired.count - 1, entries: [])
                }
                view.layoutSubtreeIfNeeded()
                let maxX = max(0, columnStack.frame.width - columnsScroll.contentView.bounds.width)
                columnsScroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
                columnsScroll.reflectScrolledClipView(columnsScroll.contentView)
            }
            for (index, table) in columnTables.enumerated() {
                guard let model = tableModels[ObjectIdentifier(table)] else { continue }
                let name = model.url.path == "/" ? "Macintosh HD" : model.url.lastPathComponent
                if let reason = ancestorLoadErrors[model.url.path], !model.current {
                    table.tableColumns.first?.title = name + "（読込不可）"
                    table.toolTip = "この階層は読み込めません。必要なら親フォルダへ移動してアクセスを許可してください。\n" + reason
                    table.setAccessibilityLabel("\(name)、読込不可。\(reason)")
                } else {
                    table.tableColumns.first?.title = name
                    table.toolTip = model.url.path
                    table.setAccessibilityLabel((side == 0 ? "左" : "右") + "のファイル一覧: " + model.url.path)
                }
                model.entries = model.current ? filtered : FileEntry.filtered(ancestorEntries[index].1, query: "", sort: .name, ascending: true)
                table.reloadData()
                if !model.current, snapshots[model.url.path] == nil {
                    let next = index + 1 < columnTables.count ? tableModels[ObjectIdentifier(columnTables[index + 1])]?.url : currentURL
                    if let row = model.entries.firstIndex(where: { $0.url.path == next?.path }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                }
            }
        }
        for table in [listTable] + columnTables {
            guard let model = tableModels[ObjectIdentifier(table)] else { continue }
            if let snapshot = snapshots[model.url.path] {
                let indexes = IndexSet(model.entries.indices.filter { snapshot.selected.contains(model.entries[$0].url.path) })
                table.selectRowIndexes(indexes, byExtendingSelection: false)
                if let scroll = table.enclosingScrollView {
                    let maxY = max(0, table.bounds.height - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxY, snapshot.origin.y)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                if snapshot.focused, !table.isHiddenOrHasHiddenAncestor { view.window?.makeFirstResponder(table) }
            } else if model.current, let previous = rememberedSelections[currentTab.id] {
                let paths = Set(previous.map(\.path))
                table.selectRowIndexes(IndexSet(model.entries.indices.filter { paths.contains(model.entries[$0].url.path) }), byExtendingSelection: false)
            }
        }
        if let oldSelectionPath {
            let eligibleTables = currentTab.viewMode == .list ? [listTable] : columnTables
            selectionTable = eligibleTables.last { tableModels[ObjectIdentifier($0)]?.url.path == oldSelectionPath }
        }
        if selectionTable == nil {
            if currentTab.viewMode == .columns, let parent = columnTables.dropLast().last, parent.selectedRow >= 0 {
                selectionTable = parent
            } else { selectionTable = visibleCurrentTable }
        }
    }

    private func sortKey(_ sort: FileSort) -> String {
        switch sort { case .name: return "name"; case .date: return "date"; case .size: return "size" }
    }

    private func updateStatus() {
        let visible = visibleCurrentTable.flatMap { tableModels[ObjectIdentifier($0)]?.entries.count } ?? 0
        let selected = selectedURLs.count
        if loading && initialRead { statusLabel.stringValue = "読み込み中…" }
        else if loadError != nil { statusLabel.stringValue = "この場所を読み込めません" }
        else if !filterField.stringValue.isEmpty { statusLabel.stringValue = "\(allEntries.count)項目中 \(visible)項目" + (selected > 0 ? " ・ \(selected)項目を選択" : "") }
        else { statusLabel.stringValue = "\(allEntries.count)項目" + (selected > 0 ? " ・ \(selected)項目を選択" : "") }
        filterBadge.stringValue = filterField.stringValue.isEmpty ? "" : "絞り込み中"
    }

    private func updateMessage() {
        let visible = visibleCurrentTable.flatMap { tableModels[ObjectIdentifier($0)]?.entries.count } ?? 0
        accessButton.isHidden = true
        if let error = loadError {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                messageLabel.stringValue = "フォルダが見つかりません。\n場所が移動されたか、ディスクが未接続の可能性があります。"
            } else {
                messageLabel.stringValue = "このフォルダを読み込めません。\nアクセスを許可するか、別の場所を開いてください。\n\(error.localizedDescription)"
            }
            messageLabel.toolTip = currentURL.path + "\n" + error.localizedDescription
            accessButton.isHidden = false
            messageStack.isHidden = false
        } else if loading && initialRead && allEntries.isEmpty {
            messageLabel.stringValue = "読み込み中…"
            messageStack.isHidden = false
        } else if currentTab.viewMode == .list && visible == 0 {
            messageLabel.stringValue = allEntries.isEmpty ? "このフォルダには表示する項目がありません" : "絞り込みに一致する項目はありません\n検索欄の×で解除できます"
            messageStack.isHidden = false
        } else { messageStack.isHidden = true }
    }

    private func refreshCellDisplays() {
        for table in [listTable] + columnTables {
            if table.numberOfRows > 0, let dateColumn = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "date" }) {
                table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows), columnIndexes: IndexSet(integer: dateColumn))
            }
        }
        lastDateRefresh = Date()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableModels[ObjectIdentifier(tableView)]?.entries.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let model = tableModels[ObjectIdentifier(tableView)], model.entries.indices.contains(row), let tableColumn else { return nil }
        let item = model.entries[row]
        let key = tableColumn.identifier.rawValue
        if key == "name" {
            let identifier = NSUserInterfaceItemIdentifier("fileName")
            let cell: BrowserNameCell
            if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? BrowserNameCell { cell = existing }
            else { cell = BrowserNameCell(); cell.identifier = identifier }
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.textField?.stringValue = item.name
            cell.arrow.isHidden = !(currentTab.viewMode == .columns && item.isDirectory && !item.isPackage)
            cell.tagMark.isHidden = item.tags.isEmpty
            cell.toolTip = item.name + (item.tags.isEmpty ? "" : "\nタグ: " + item.tags.joined(separator: "、"))
            cell.setAccessibilityLabel(item.name + (item.isDirectory ? "、フォルダ" : "") + (item.isSymbolicLink ? "、シンボリックリンク" : ""))
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier(key + "Cell")
        let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        if key == "date" {
            field.stringValue = dateText(item.modifiedAt)
            field.toolTip = item.modifiedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .full, timeStyle: .medium) }
            field.alignment = .left
        } else {
            field.stringValue = item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
            field.toolTip = item.isDirectory ? "フォルダ容量は自動集計しません" : "\(item.size)バイト"
            field.alignment = .right
        }
        return field
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard let entries = tableModels[ObjectIdentifier(tableView)]?.entries, entries.indices.contains(row) else { return nil }
        return entries[row].name
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !changingSelection, let table = notification.object as? BrowserFileTable else { return }
        selectionTable = table
        activate()
        updateStatus()
        if !table.isHandlingMouseDown && !table.isContextSelection { openSelectedColumnFolder(in: table) }
    }

    private func openSelectedColumnFolder(in table: BrowserFileTable) {
        guard !changingSelection else { return }
        guard currentTab.viewMode == .columns, table.selectedRowIndexes.count == 1,
              let model = tableModels[ObjectIdentifier(table)], model.entries.indices.contains(table.selectedRow) else { return }
        let entry = model.entries[table.selectedRow]
        if entry.isDirectory && !entry.isPackage && entry.url.path != currentURL.path { navigate(to: entry.url) }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !changingSelection, let descriptor = tableView.sortDescriptors.first else { return }
        let sort: FileSort = descriptor.key == "date" ? .date : descriptor.key == "size" ? .size : .name
        paneState.tabs[currentTabIndex].sort = sort
        paneState.tabs[currentTabIndex].ascending = descriptor.ascending
        applyFilter()
        onStateChange?()
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        if relativeDates {
            let calendar = Calendar.current
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
            switch days {
            case 0: return "今日 " + DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            case 1: return "昨日"
            case 2...30: return "\(days)日前"
            case -1: return "明日"
            case -30 ... -2: return "\(-days)日後"
            default: break
            }
        }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .none)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === filterField else { return }
        scheduleFilter()
    }

    func controlTextDidBeginEditing(_ notification: Notification) { activate() }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSSearchField === filterField else { return }
        scheduleFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === filterField && commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            guard !textView.hasMarkedText() else { return false }
            filterField.stringValue = ""
            applyFilter()
            focusFiles()
            return true
        }
        return false
    }

    private func scheduleFilter() {
        filterWork?.cancel()
        // During Japanese IME composition, keep the current result set until text is committed.
        if let editor = filterField.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let editor = self.filterField.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            self.applyFilter()
        }
        filterWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    private func handleTableKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty {
            if event.keyCode == 36 || event.keyCode == 76 { renameSelection(); return true }
            if event.keyCode == 49 { previewSelection(); return true }
            if currentTab.viewMode == .columns && event.keyCode == 123 { goUp(); return true }
            if currentTab.viewMode == .columns && event.keyCode == 124 { openSelection(); focusFiles(); return true }
        }
        if modifiers == .command {
            if event.keyCode == 125 { openSelection(); return true }
            if event.keyCode == 126 { goUp(); return true }
            if event.keyCode == 51 { deleteSelection(); return true }
        }
        return false
    }

    private func openSelection() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        if urls.count == 1,
           let table = selectionTable, let model = tableModels[ObjectIdentifier(table)],
           let entry = model.entries.first(where: { $0.url == urls[0] }), entry.isDirectory && !entry.isPackage {
            navigate(to: urls[0])
        } else { onOpen?(urls) }
    }

    private func previewSelection() { let urls = selectedURLs; if !urls.isEmpty { onPreview?(urls) } }
    private func renameSelection() { if selectedURLs.count == 1, let url = selectedURLs.first { onRename?(url) } }
    private func deleteSelection() { let urls = selectedURLs; if !urls.isEmpty { onDelete?(urls) } }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (title, selector) in [("開く", #selector(openClicked)), ("クイックルック", #selector(previewClicked)), ("名前を変更…", #selector(renameClicked)), ("Finderで表示", #selector(revealClicked))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.isEnabled = !selectedURLs.isEmpty && (selector != #selector(renameClicked) || selectedURLs.count == 1)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let trash = NSMenuItem(title: "ゴミ箱に入れる", action: #selector(deleteClicked), keyEquivalent: "")
        trash.target = self
        trash.isEnabled = !selectedURLs.isEmpty
        menu.addItem(trash)
        menu.autoenablesItems = false
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let entries = tableModels[ObjectIdentifier(tableView)]?.entries, entries.indices.contains(row) else { return nil }
        return entries[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        (tableView as? BrowserFileTable)?.didBeginDragging = true
    }

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
    }

    private func dropDestination(_ table: NSTableView, row: Int, operation: NSTableView.DropOperation) -> URL? {
        guard let model = tableModels[ObjectIdentifier(table)] else { return nil }
        if operation == .on, model.entries.indices.contains(row) {
            let entry = model.entries[row]
            if entry.isDirectory && !entry.isPackage { return entry.url }
        }
        return model.url
    }

    private func shouldMove(_ urls: [URL], to destination: URL) -> Bool {
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) { return false }
        if flags.contains(.command) { return true }
        guard let targetVolume = try? destination.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject else { return false }
        return urls.allSatisfy { url in
            guard let sourceVolume = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject else { return false }
            return sourceVolume.isEqual(targetVolume)
        }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        let urls = droppedURLs(info)
        guard !urls.isEmpty, let destination = dropDestination(tableView, row: row, operation: operation) else { return [] }
        if urls.contains(where: { $0.standardizedFileURL == destination.standardizedFileURL }) { return [] }
        if let model = tableModels[ObjectIdentifier(tableView)], !(operation == .on && model.entries.indices.contains(row) && model.entries[row].isDirectory && !model.entries[row].isPackage) {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return shouldMove(urls, to: destination) ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        let urls = droppedURLs(info)
        guard !urls.isEmpty, let destination = dropDestination(tableView, row: row, operation: operation), let onDrop else { return false }
        activate()
        onDrop(urls, destination, shouldMove(urls, to: destination))
        return true
    }

    @objc private func addTabClicked() { addTab() }
    @objc private func backClicked() { activate(); goBack() }
    @objc private func forwardClicked() { activate(); goForward() }
    @objc private func upClicked() { activate(); goUp() }
    @objc private func pathClicked() { if let url = pathControl.clickedPathComponentCell()?.url { navigate(to: url) } }
    @objc private func filterChanged() { scheduleFilter() }
    @objc private func viewModeChanged() { activate(); setViewMode(viewSelector.selectedSegment == 0 ? .list : .columns) }
    @objc private func requestAccessClicked() { onRequestAccess?(currentURL) }
    @objc private func openClicked() { openSelection() }
    @objc private func previewClicked() { previewSelection() }
    @objc private func renameClicked() { renameSelection() }
    @objc private func deleteClicked() { deleteSelection() }
    @objc private func revealClicked() { NSWorkspace.shared.activateFileViewerSelecting(selectedURLs) }
    @objc private func tableDoubleClicked(_ sender: NSTableView) {
        guard sender.clickedRow >= 0 else { return }
        selectionTable = sender as? BrowserFileTable
        activate()
        openSelection()
    }
    @objc private func tabClicked(_ sender: NSButton) {
        guard paneState.tabs.indices.contains(sender.tag) else { return }
        rememberSelection()
        paneState.selectedTabID = paneState.tabs[sender.tag].id
        filterField.stringValue = ""
        activate()
        updateNavigation()
        onStateChange?()
        reload()
    }
    @objc private func closeTabClicked(_ sender: NSButton) {
        guard paneState.tabs.indices.contains(sender.tag) else { return }
        activate()
        if paneState.tabs[sender.tag].id == paneState.selectedTabID {
            if !closeTab() { view.window?.performClose(nil) }
        } else {
            let removed = paneState.tabs.remove(at: sender.tag)
            rememberedSelections.removeValue(forKey: removed.id)
            updateNavigation()
            onStateChange?()
        }
    }
}

@MainActor
private final class BrowserFileTable: NSTableView {
    var onActivate: (() -> Void)?
    var handleKey: ((NSEvent) -> Bool)?
    var onCommitSelection: (() -> Void)?
    var isHandlingMouseDown = false
    var isContextSelection = false
    var didBeginDragging = false
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onActivate?() }
        return result
    }
    override func mouseDown(with event: NSEvent) {
        onActivate?()
        isHandlingMouseDown = true
        didBeginDragging = false
        super.mouseDown(with: event)
        isHandlingMouseDown = false
        // Keep the source table alive throughout AppKit's drag tracking.
        if !didBeginDragging && event.modifierFlags.intersection([.command, .shift, .control]).isEmpty { onCommitSelection?() }
    }
    override func keyDown(with event: NSEvent) {
        if handleKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        onActivate?()
        isContextSelection = true
        defer { isContextSelection = false }
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return super.menu(for: event)
    }
}

@MainActor
private final class BrowserNameCell: NSTableCellView {
    let arrow = NSImageView()
    let tagMark = NSImageView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        arrow.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "フォルダ")
        arrow.contentTintColor = .tertiaryLabelColor
        tagMark.image = NSImage(systemSymbolName: "tag", accessibilityDescription: "Finderタグあり")
        tagMark.contentTintColor = .secondaryLabelColor
        for child in [icon, label, tagMark, arrow] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: tagMark.leadingAnchor, constant: -3),
            tagMark.centerYAnchor.constraint(equalTo: centerYAnchor),
            tagMark.widthAnchor.constraint(equalToConstant: 11), tagMark.heightAnchor.constraint(equalToConstant: 11),
            tagMark.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -3),
            arrow.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 8), arrow.heightAnchor.constraint(equalToConstant: 11),
            arrow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
