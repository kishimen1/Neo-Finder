import AppKit

/// One row of the palette: a folder to go to, a destination, or a command.
struct PaletteItem {
    let title: String
    let subtitle: String
    let symbol: String
    /// Text placed in the input when Tab is pressed on this row, used to descend into a folder.
    var completion: String? = nil
    let run: () -> Void
}

/// A keyboard-first chooser shown over the main window. The caller supplies ranked rows for
/// whatever has been typed; this class only owns the input, the list and the key handling.
@MainActor
final class PaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let panel: NSPanel
    private let promptLabel = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let table = NSTableView()
    private let hintLabel = NSTextField(labelWithString: "↑↓ 選択　Return 実行　Tab フォルダの中へ　Esc 閉じる")
    private var items: [PaletteItem] = []
    private var provider: (String) -> [PaletteItem] = { _ in [] }
    private weak var parent: NSWindow?
    private var closing = false
    /// Called after the palette closes, before a chosen row runs.
    var onClose: (() -> Void)?
    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 430),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.delegate = self
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }

        promptLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        promptLabel.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 18)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel("パレットの入力")
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.style = .plain
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setAccessibilityLabel("候補")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [promptLabel, field, separator, scroll, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 10, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        panel.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32)
        ])
    }

    /// `provider` returns the rows for the current input, best first.
    func show(over window: NSWindow, prompt: String, placeholder: String, initial: String = "",
              provider: @escaping (String) -> [PaletteItem]) {
        if panel.isVisible { close() }
        self.provider = provider
        parent = window
        promptLabel.stringValue = prompt
        field.placeholderString = placeholder
        field.stringValue = initial
        let frame = window.frame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.maxY - size.height - max(60, frame.height * 0.14)))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (initial as NSString).length, length: 0)
        refresh()
    }

    func close() {
        guard !closing, panel.isVisible else { return }
        closing = true
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
        closing = false
        onClose?()
    }

    private func refresh() {
        items = provider(field.stringValue)
        table.reloadData()
        if !items.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = min(max(0, table.selectedRow + delta), items.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func runSelected() {
        guard items.indices.contains(table.selectedRow) else { return }
        let item = items[table.selectedRow]
        close()
        item.run()
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        runSelected()
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Leave every key to the input method while a Japanese conversion is in progress.
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.moveDown(_:)) { moveSelection(1); return true }
        if commandSelector == #selector(NSResponder.moveUp(_:)) { moveSelection(-1); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { runSelected(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            if items.indices.contains(table.selectedRow), let completion = items[table.selectedRow].completion {
                field.stringValue = completion
                field.currentEditor()?.selectedRange = NSRange(location: (completion as NSString).length, length: 0)
                refresh()
            }
            return true
        }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("paletteCell")
        let cell: PaletteCell
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? PaletteCell { cell = existing }
        else { cell = PaletteCell(); cell.identifier = identifier }
        let item = items[row]
        cell.imageView?.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        cell.textField?.stringValue = item.title
        cell.detail.stringValue = item.subtitle
        cell.setAccessibilityLabel(item.title + "、" + item.subtitle)
        return cell
    }
}

@MainActor
private final class PaletteCell: NSTableCellView {
    let detail = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        for child in [icon, title, detail] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
