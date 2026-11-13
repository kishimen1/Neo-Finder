import AppKit
import QuickLookUI

/// Covers the inactive pane during triage: a large preview of the selected item and the
/// nine destinations the number keys send it to.
@MainActor
final class TriageView: NSView {
    /// Slot index 0–8; the flag is true when the destination should be (re)assigned instead of used.
    var onSlot: ((Int, Bool) -> Void)?
    var onExit: (() -> Void)?
    private let preview: QLPreviewView?
    private let nameLabel = NSTextField(labelWithString: "")
    private var slotButtons: [NSButton] = []
    private var shownPath: String?

    init() {
        preview = QLPreviewView(frame: .zero, style: .normal)
        super.init(frame: .zero)
        setAccessibilityLabel("仕分けモード")

        let title = NSTextField(labelWithString: "仕分けモード")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let exit = NSButton(title: "終了（Esc）", target: self, action: #selector(exitClicked))
        exit.bezelStyle = .rounded
        exit.controlSize = .small
        exit.refusesFirstResponder = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, spacer, exit])
        header.orientation = .horizontal

        let help = NSTextField(wrappingLabelWithString: "1〜9：その行き先へ移動して次へ　Space：次へ　Return：名前を変更　⌘Z：取り消す　⌥1〜9：行き先を設定")
        help.font = .systemFont(ofSize: 10)
        help.textColor = .secondaryLabelColor

        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let previewHost: NSView = (preview as NSView?) ?? NSView()
        previewHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        previewHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        var rows: [[NSView]] = []
        for row in 0..<3 {
            var line: [NSView] = []
            for column in 0..<3 {
                let button = NSButton(title: "", target: self, action: #selector(slotClicked(_:)))
                button.tag = row * 3 + column
                button.bezelStyle = .rounded
                button.lineBreakMode = .byTruncatingMiddle
                button.refusesFirstResponder = true
                button.setContentHuggingPriority(.defaultLow, for: .horizontal)
                button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                slotButtons.append(button)
                line.append(button)
            }
            rows.append(line)
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 5
        grid.columnSpacing = 6
        for index in 0..<3 { grid.column(at: index).xPlacement = .fill }

        let stack = NSStackView(views: [header, help, nameLabel, previewHost, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            previewHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ]
        for child in [header, help, nameLabel, previewHost, grid] as [NSView] {
            constraints.append(child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24))
        }
        for button in slotButtons.dropFirst() {
            constraints.append(button.widthAnchor.constraint(equalTo: slotButtons[0].widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        setSlots([])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    // Clicks on the empty area must not reach the pane underneath.
    override func mouseDown(with event: NSEvent) {}

    func show(_ url: URL?) {
        guard shownPath != url?.path else { return }
        shownPath = url?.path
        nameLabel.stringValue = url?.lastPathComponent ?? "項目を選択してください"
        nameLabel.toolTip = url?.path
        if let url { preview?.previewItem = url as NSURL }
        else { preview?.previewItem = nil }
    }

    func setSlots(_ paths: [String]) {
        for (index, button) in slotButtons.enumerated() {
            let path = index < paths.count ? paths[index] : ""
            if path.isEmpty {
                button.title = "\(index + 1)　未設定"
                button.toolTip = "クリックまたは ⌥\(index + 1) で行き先を設定"
            } else {
                button.title = "\(index + 1)　" + URL(fileURLWithPath: path).lastPathComponent
                button.toolTip = path + "\n⌥クリックまたは ⌥\(index + 1) で変更"
            }
            button.setAccessibilityLabel(path.isEmpty ? "仕分け先\(index + 1)、未設定" : "仕分け先\(index + 1)、\(path)")
        }
    }

    @objc private func slotClicked(_ sender: NSButton) {
        onSlot?(sender.tag, NSEvent.modifierFlags.contains(.option))
    }

    @objc private func exitClicked() { onExit?() }
}
