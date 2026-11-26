import AppKit

/// Small borderless list shown under the caret with SQL suggestions. It never
/// becomes the key window, so typing continues in the editor while the list is
/// visible; the editor forwards Up/Down/Enter/Tab/Escape to it.
final class SQLCompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private var items: [String] = []
    private var selected = 0
    var onCommit: ((String) -> Void)?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]

        tableView.headerView = nil
        tableView.rowHeight = 18
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.style = .plain
        tableView.backgroundColor = .windowBackgroundColor
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.target = self
        tableView.action = #selector(clickRow(_:))

        scroll.documentView = tableView
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.borderType = .lineBorder
        panel.contentView = scroll
    }

    var isVisible: Bool { panel.isVisible }

    var selectedItem: String? {
        guard selected >= 0, selected < items.count else { return nil }
        return items[selected]
    }

    /// `point` is the caret's bottom-left corner in screen coordinates.
    func show(items: [String], at point: NSPoint) {
        guard !items.isEmpty else {
            hide()
            return
        }
        self.items = items
        selected = 0
        tableView.reloadData()

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let widest = items.reduce(CGFloat(0)) { width, item in
            max(width, (item as NSString).size(withAttributes: [.font: font]).width)
        }
        let width = min(380, max(150, widest + 24))
        let rows = min(items.count, 9)
        let height = CGFloat(rows) * tableView.rowHeight + 2
        tableView.tableColumns.first?.width = width - 4
        panel.setContentSize(NSSize(width: width, height: height))

        var origin = point
        let screen = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        if let screen {
            origin.x = min(max(origin.x, screen.minX + 2), screen.maxX - width - 2)
            // If there is no room below the caret, flip the list above it.
            if origin.y - height < screen.minY {
                origin.y = origin.y + height + 16
            }
        }
        panel.setFrameTopLeftPoint(origin)
        panel.orderFront(nil)
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selected = min(max(selected + delta, 0), items.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        tableView.scrollRowToVisible(selected)
    }

    func commitSelected() {
        guard let item = selectedItem else { return }
        onCommit?(item)
    }

    @objc private func clickRow(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        selected = row
        commitSelected()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("CompletionCell")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            field.lineBreakMode = .byTruncatingTail
        }
        field.stringValue = row < items.count ? items[row] : ""
        return field
    }
}
