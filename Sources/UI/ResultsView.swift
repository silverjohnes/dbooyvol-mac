import SwiftUI
import AppKit

/// Table cell whose text is centered vertically inside the row. The stock
/// label cell draws the string at the top of its bounds, which looks shifted up
/// in the result grid.
final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawing = super.drawingRect(forBounds: rect)
        let textHeight = min(rect.height, ceil(attributedStringValue.size().height))
        guard textHeight > 0 else { return drawing }
        drawing.origin.y = rect.origin.y + (rect.height - textHeight) / 2
        drawing.size.height = textHeight
        return drawing
    }
}

/// One reusable result cell: a vertically centered label plus an optional
/// "open link" button. Building it once and reconfiguring it keeps scrolling
/// through large results cheap — creating a view with Auto Layout constraints
/// for every visible cell was the slow part of a full-page scroll.
final class GridCellView: NSTableCellView, NSTextFieldDelegate {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("gridCell")

    let label = NSTextField(labelWithString: "")
    let linkButton = LinkButton()

    private static var symbolCache: [Int: NSImage] = [:]
    private var isSelectedCell = false
    private var isCurrentCell = false
    private var isEditingCell = false
    /// True while the inline editor is open; such a view is never pooled,
    /// because taking its editor away would abort the edit.
    var isEditing: Bool { isEditingCell }
    private var editOriginalValue: String?
    /// Called with the new value when an inline edit is confirmed with Enter.
    var onCommitEdit: ((String?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true

        label.cell = VerticallyCenteredTextFieldCell(textCell: "")
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.focusRingType = .none
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.delegate = self
        addSubview(label)

        linkButton.isHidden = true
        addSubview(linkButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Manual frames instead of Auto Layout: a result grid can have hundreds of
    /// visible cells, and solving a constraint set for each one was the main
    /// cost of rebuilding the table when a tab was switched.
    override func layout() {
        super.layout()
        layoutContent()
    }

    /// Places the label and the link icon inside the current bounds. Called
    /// from `layout()` and again whenever the cell is reconfigured, so a view
    /// taken from the pool never keeps the frame it had in its previous row.
    private func layoutContent() {
        let inset: CGFloat = 6
        let linkWidth: CGFloat = 16
        let textX = linkButton.isHidden ? inset : inset + linkWidth + 4
        label.frame = NSRect(x: textX, y: 0,
                             width: max(0, bounds.width - textX - inset),
                             height: bounds.height)
        linkButton.frame = NSRect(x: 4, y: (bounds.height - linkWidth) / 2,
                                  width: linkWidth, height: linkWidth)
    }

    private static func symbol(for font: NSFont) -> NSImage? {
        let point = Int(max(10, font.pointSize - 1).rounded())
        if let cached = symbolCache[point] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: CGFloat(point), weight: .semibold)
        let image = NSImage(
            systemSymbolName: "arrow.up.forward.square",
            accessibilityDescription: L10n.tr("Открыть ссылку")
        )?.withSymbolConfiguration(configuration)
        symbolCache[point] = image
        return image
    }

    /// Highlights (or un-highlights) the cell in place. Selection changes must
    /// not go through `reloadData`: that destroyed the cell views in the middle
    /// of a click or drag, which made selecting feel slow and jumpy.
    func setSelected(_ selected: Bool) {
        guard selected != isSelectedCell else { return }
        isSelectedCell = selected
        updateSelectionLayer()
    }

    func setCurrent(_ current: Bool) {
        guard current != isCurrentCell else { return }
        isCurrentCell = current
        updateSelectionLayer()
    }

    private func updateSelectionLayer() {
        // Layer changes without an explicit transaction get an implicit
        // animation, which made a font-size change look like a 200 ms hitch.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = isSelectedCell
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.30).cgColor
            : nil
        layer?.borderWidth = isCurrentCell ? 2 : 0
        layer?.borderColor = isCurrentCell ? NSColor.systemOrange.cgColor : nil
        CATransaction.commit()
    }

    func configure(value: String?, font: NSFont, numeric: Bool, link: URL?,
                   highlighted: NSAttributedString?, selected: Bool, current: Bool) {
        if isEditingCell {
            if selected != isSelectedCell || current != isCurrentCell {
                isSelectedCell = selected
                isCurrentCell = current
                updateSelectionLayer()
            }
            return
        }
        // Always build the whole attributed string for the cell. Mixing
        // `stringValue` with a later `attributedStringValue` (the search
        // highlight path) leaves the field carrying attributes from the row
        // this view was reused from: an old background, an old paragraph style
        // and, because the vertical centring measures the attributed string, a
        // line height that does not match the current font. That made the text
        // of a reused cell sit a point or two below its neighbours.
        let text = value ?? "NULL"
        let color: NSColor = value == nil ? .tertiaryLabelColor : .labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = numeric ? .right : .left
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        if let highlighted {
            highlighted.enumerateAttribute(.backgroundColor,
                                           in: NSRange(location: 0, length: highlighted.length)) { background, range, _ in
                guard let background else { return }
                attributed.addAttribute(.backgroundColor, value: background, range: range)
            }
        }

        let hasLink = link != nil
        // A pooled cell may still be laid out for the row height or the link
        // inset of its previous owner. Re-run `layout()` when anything it
        // depends on changed, otherwise the label keeps the old frame and the
        // text is drawn off centre.
        let staleLayout = label.font != font
            || abs(label.frame.height - bounds.height) > 0.5
            || linkButton.isHidden == hasLink
        label.font = font
        label.attributedStringValue = attributed
        if linkButton.isHidden == hasLink {
            linkButton.isHidden = !hasLink
        }
        if staleLayout { needsLayout = true }
        if let link {
            linkButton.url = link
            linkButton.appTooltipText = link.absoluteString
            linkButton.image = Self.symbol(for: font)
        }
        layoutContent()

        if selected != isSelectedCell || current != isCurrentCell {
            isSelectedCell = selected
            isCurrentCell = current
            updateSelectionLayer()
        }
    }

    /// Turns the cell into an editable field with its text selected. Enter
    /// commits, Escape restores the previous value.
    func beginEditing(value: String?) {
        guard !isEditingCell else { return }
        isEditingCell = true
        editOriginalValue = value
        label.isEditable = true
        label.isSelectable = true
        label.lineBreakMode = .byClipping
        label.stringValue = value ?? ""
        window?.makeFirstResponder(label)
        label.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard isEditingCell else { return }
        let movement = (notification.userInfo?["NSTextMovement"] as? Int) ?? 0
        let cancelled = movement == NSCancelTextMovement
        let text = label.stringValue
        isEditingCell = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        if cancelled {
            label.stringValue = editOriginalValue ?? "NULL"
            return
        }
        let value: String? = text.isEmpty ? nil : text
        label.stringValue = value ?? "NULL"
        onCommitEdit?(value)
    }
}

/// Small "open in system" icon shown in front of URL values. A plain view
/// instead of an NSButton: AppKit lays out a button cell (and measures its
/// title) for every visible cell, which made switching tabs slow.
final class LinkButton: NSView {
    var url: URL?
    var image: NSImage? { didSet { needsDisplay = true } }
    var onClick: ((URL) -> Void)?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        NSColor.controlAccentColor.setFill()
        bounds.fill()
        image.draw(in: bounds, from: .zero, operation: .destinationIn, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        guard let url else { return }
        onClick?(url)
    }
}

final class GridTableView: NSTableView {
    var onCellMouse: ((NSEvent) -> Void)?
    var copyHandler: (() -> Void)?
    var pasteHandler: (() -> Void)?
    /// Builds the result context menu; the click location is already selected
    /// by `onContextClick` when this is called.
    var menuProvider: (() -> NSMenu?)?
    var onContextClick: ((NSEvent) -> Void)?
    /// Called with a number of font-size steps when Ctrl + wheel or pinch is used.
    var onZoom: ((CGFloat) -> Void)?
    /// Called when the grid becomes the first responder.
    var onFocus: (() -> Void)?
    /// Tab switches between the grid and the vertical single-row view.
    var onToggleSingleRow: (() -> Void)?
    /// ⌘A selects every cell, like the corner above the row numbers.
    var selectAllHandler: (() -> Void)?
    private var zoomAccumulator: CGFloat = 0
    private var magnifyAccumulator: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, flags.isEmpty, let onToggleSingleRow {
            onToggleSingleRow()
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onCellMouse?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        onCellMouse?(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.control), let onZoom else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        if event.hasPreciseScrollingDeltas {
            zoomAccumulator += delta
            let steps = Int(zoomAccumulator / 12)
            if steps != 0 {
                zoomAccumulator -= CGFloat(steps) * 12
                onZoom(CGFloat(steps))
            }
        } else {
            onZoom(delta > 0 ? 1 : -1)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let onZoom else {
            super.magnify(with: event)
            return
        }
        magnifyAccumulator += event.magnification
        let steps = Int(magnifyAccumulator / 0.05)
        if steps != 0 {
            magnifyAccumulator -= CGFloat(steps) * 0.05
            onZoom(CGFloat(steps))
        }
    }

    @objc func copy(_ sender: Any?) {
        copyHandler?()
    }

    override func selectAll(_ sender: Any?) {
        selectAllHandler?()
    }

    @objc func paste(_ sender: Any?) {
        pasteHandler?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextClick?(event)
        return menuProvider?() ?? super.menu(for: event)
    }
}

/// Header view with per-column sort arrows and a type tooltip.
/// Clicking the title selects the whole column; clicking the arrow on the
/// right sorts it (first click descending, then ascending, and so on).
final class GridHeaderView: NSTableHeaderView {
    weak var model: AppModel?
    private let arrowHitWidth: CGFloat = 22

    func refreshToolTips() {
        guard let model else { return }
        if model.showTypeOnHeaderHover {
            appTooltipProvider = { [weak self] point in
                self?.tooltip(at: point)
            }
        } else {
            appTooltipProvider = nil
        }
    }

    override func layout() {
        super.layout()
        refreshToolTips()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let tableView else { return }
        for i in 0..<tableView.tableColumns.count {
            addCursorRect(arrowRect(forColumn: i), cursor: .pointingHand)
        }
    }

    /// On macOS Control-click arrives as a right click. Keep it working as
    /// the "add/remove column" modifier, while a real right click is ignored.
    override func rightMouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else {
            super.rightMouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let col = column(at: point)
        guard col >= 0 else { return }
        window?.makeFirstResponder(tableView)
        model?.selectResultColumn(col,
                                  extend: event.modifierFlags.contains(.shift),
                                  toggle: true)
    }

    private var dragStart: NSPoint?
    private var dragDataColumns: [Int] = []
    private var isDraggingColumns = false
    private var dragGhost: DragGhost?

    /// True when the point is within the grab zone of a column divider. The
    /// zone matches the system resize cursor, which appears a few points on
    /// both sides of the boundary.
    private func isOnColumnDivider(_ point: NSPoint) -> Bool {
        guard let table = tableView else { return false }
        let tolerance: CGFloat = 4
        for position in 0..<table.tableColumns.count {
            let rect = headerRect(ofColumn: position)
            guard rect.width > 0 else { continue }
            if abs(point.x - rect.maxX) <= tolerance { return true }
        }
        return false
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A press on the divider between headers belongs to NSTableHeaderView:
        // it resizes the column. Handling it here swallowed the resize and
        // started a column reorder instead, so the width could not be changed.
        if isOnColumnDivider(point) {
            dragStart = nil
            isDraggingColumns = false
            endColumnDragGhost()
            super.mouseDown(with: event)
            return
        }
        let col = column(at: point)
        guard col >= 0, let data = dataIndex(forPosition: col) else {
            super.mouseDown(with: event)
            return
        }
        endColumnDragGhost()
        window?.makeFirstResponder(tableView)
        if arrowRect(forColumn: col).contains(point) {
            model?.toggleResultSort(column: data)
            needsDisplay = true
            return
        }
        // Keep the standard double-click on the header (automatic width).
        if event.clickCount >= 2 {
            super.mouseDown(with: event)
            return
        }

        let flags = event.modifierFlags
        let toggle = flags.contains(.command) || flags.contains(.control)
        let selection = model?.gridSelection
        let alreadySelected = selection?.kind == .columns && selection?.cols.contains(data) == true
        // Pressing an already selected column without a modifier keeps the
        // whole block, so several selected columns can be dragged together.
        if !(alreadySelected && !toggle && !flags.contains(.shift)) {
            model?.selectResultColumn(data,
                                      extend: flags.contains(.shift),
                                      toggle: toggle)
        }

        // Drag every selected column when the pressed one belongs to the
        // selection; otherwise only the pressed column.
        var dragging: [Int]
        if let selection = model?.gridSelection, selection.kind == .columns,
           selection.cols.contains(data), selection.cols.count > 1 {
            dragging = selection.cols.sorted()
        } else {
            dragging = [data]
        }
        dragging.sort { visualPosition(of: $0) < visualPosition(of: $1) }
        dragDataColumns = dragging
        dragStart = point
        isDraggingColumns = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let table = tableView else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if !isDraggingColumns {
            guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
            isDraggingColumns = true
            beginColumnDragGhost()
            NSCursor.closedHand.push()
        }
        moveColumnDragGhost(to: point)

        let current = table.tableColumns.compactMap { dataIndex(forColumn: $0) }
        let dragged = Set(dragDataColumns)
        let base = current.filter { !dragged.contains($0) }
        // Insert before the first base column whose midpoint is right of the
        // pointer; the dragged block itself does not take part.
        var insertAt = 0
        for data in base {
            guard let position = current.firstIndex(of: data) else { continue }
            if point.x > headerRect(ofColumn: position).midX { insertAt += 1 }
        }
        let block = dragDataColumns.filter { dragged.contains($0) }
        let newOrder = Array(base[0..<insertAt]) + block + Array(base[insertAt...])
        applyVisualOrder(newOrder)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingColumns, let table = tableView {
            let order = table.tableColumns.compactMap { dataIndex(forColumn: $0) }
            model?.setResultColumnOrder(order)
            NSCursor.pop()
        }
        endColumnDragGhost()
        dragStart = nil
        dragDataColumns = []
        isDraggingColumns = false
        super.mouseUp(with: event)
    }

    /// Snapshot of the dragged header cells, shown semi-transparent while the
    /// block is moved. Multi-column selections keep their gaps.
    private func beginColumnDragGhost() {
        endColumnDragGhost()
        let rects = dragDataColumns.compactMap { data -> NSRect? in
            let position = visualPosition(of: data)
            guard position >= 0 else { return nil }
            return headerRect(ofColumn: position)
        }
        guard let first = rects.first else { return }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        let image = DragGhost.snapshot(of: self, rects: rects)
        let grab = DragGhost.grabOffset(imageRect: union,
                                        grabPoint: dragStart ?? NSPoint(x: union.midX, y: union.midY),
                                        in: self)
        dragGhost = DragGhost(image: image, grab: grab)
        if let start = dragStart, let point = DragGhost.screenPoint(start, in: self) {
            dragGhost?.show(at: point)
        }
    }

    private func moveColumnDragGhost(to point: NSPoint) {
        guard let screen = DragGhost.screenPoint(point, in: self) else { return }
        dragGhost?.move(toScreen: screen)
    }

    private func endColumnDragGhost() {
        dragGhost?.close()
        dragGhost = nil
    }

    private func dataIndex(forColumn column: NSTableColumn) -> Int? {
        let raw = column.identifier.rawValue
        guard raw.first == "c" else { return nil }
        return Int(raw.dropFirst())
    }

    private func visualPosition(of data: Int) -> Int {
        tableView?.tableColumns.firstIndex { dataIndex(forColumn: $0) == data } ?? data
    }

    /// Moves the table columns into the requested visual order in place, so
    /// the grid keeps its scroll position and widths during a drag.
    private func applyVisualOrder(_ order: [Int]) {
        guard let table = tableView else { return }
        for (target, data) in order.enumerated() {
            guard let current = table.tableColumns.firstIndex(where: {
                dataIndex(forColumn: $0) == data
            }) else { continue }
            if current != target {
                table.moveColumn(current, toColumn: target)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let tableView else { return }
        for i in 0..<tableView.tableColumns.count {
            let rect = headerRect(ofColumn: i)
            guard rect.width > 0, rect.intersects(dirtyRect) else { continue }
            let data = dataIndex(forPosition: i) ?? i
            let active = model?.resultSort?.column == data
            let ascending = active ? model?.resultSort?.ascending : nil
            drawSortArrow(in: arrowRect(forColumn: i), ascending: ascending)
            if let selection = model?.gridSelection, selection.cols.contains(data) {
                NSColor.controlAccentColor.withAlphaComponent(0.7).setFill()
                let y = isFlipped ? rect.maxY - 2 : rect.minY
                NSRect(x: rect.minX, y: y, width: rect.width, height: 2).fill()
            }
        }
    }

    /// Columns can be dragged into another visual order; the identifier keeps
    /// the position of the column in the result data.
    private func dataIndex(forPosition position: Int) -> Int? {
        guard let tableView, position >= 0, position < tableView.tableColumns.count else { return nil }
        let raw = tableView.tableColumns[position].identifier.rawValue
        guard raw.first == "c" else { return nil }
        return Int(raw.dropFirst())
    }

    private func arrowRect(forColumn column: Int) -> NSRect {
        let rect = headerRect(ofColumn: column)
        return NSRect(x: rect.maxX - arrowHitWidth, y: rect.minY,
                      width: arrowHitWidth, height: rect.height)
    }

    private func drawSortArrow(in rect: NSRect, ascending: Bool?) {
        let active = ascending != nil
        let color = active
            ? NSColor.controlAccentColor
            : NSColor.secondaryLabelColor.withAlphaComponent(0.45)
        color.setFill()

        let cx = rect.midX
        let cy = rect.midY
        // Positive delta points visually down regardless of the view's flip state.
        let down: CGFloat = isFlipped ? 1 : -1

        func triangle(baseY: CGFloat, tipY: CGFloat, halfWidth: CGFloat) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: cx - halfWidth, y: baseY))
            path.line(to: NSPoint(x: cx + halfWidth, y: baseY))
            path.line(to: NSPoint(x: cx, y: tipY))
            path.close()
            path.fill()
        }

        if let ascending {
            if ascending {
                triangle(baseY: cy + 2 * down, tipY: cy - 3 * down, halfWidth: 4)
            } else {
                triangle(baseY: cy - 2 * down, tipY: cy + 3 * down, halfWidth: 4)
            }
        } else {
            triangle(baseY: cy + 1 * down, tipY: cy + 4 * down, halfWidth: 3)
            triangle(baseY: cy - 1 * down, tipY: cy - 4 * down, halfWidth: 3)
        }
    }

    func tooltip(at point: NSPoint) -> String {
        guard let model, model.showTypeOnHeaderHover else { return "" }
        let col = column(at: point)
        guard col >= 0, let index = dataIndex(forPosition: col),
              let result = model.result, index < result.columns.count else { return "" }
        let column = result.columns[index]
        let meta = model.tableMeta(for: column, profileID: result.profileID)
        var lines: [String] = []
        if let info = meta?.column(column.name) {
            var first = L10n.fmt("Столбец: %@ %@", column.name, info.displayType)
            if !info.nullable { first += " NOT NULL" }
            lines.append(first)
        } else {
            lines.append(L10n.fmt("Столбец: %@ %@", column.name, column.type))
        }
        if let meta, !meta.primaryKey.isEmpty {
            lines.append(L10n.fmt("Уникальный ключ: %@(%@)", column.table,
                                  meta.primaryKey.joined(separator: ", ")))
            if meta.primaryKey.contains(where: { $0.caseInsensitiveCompare(column.name) == .orderedSame }) {
                lines.append(L10n.fmt("Часть ключа: %@", column.name))
            } else {
                lines.append(L10n.tr("Часть ключа:"))
            }
            if let pk = meta.primaryKeyName {
                let qualified = [column.catalog, column.schema, column.table, pk]
                    .filter { !$0.isEmpty }.joined(separator: ".")
                lines.append(qualified)
            }
        } else if !column.table.isEmpty {
            let qualified = [column.catalog, column.schema, column.table]
                .filter { !$0.isEmpty }.joined(separator: ".")
            lines.append(L10n.fmt("Таблица: %@", qualified))
        }
        return lines.joined(separator: "\n")
    }
}

final class GridScrollView: NSScrollView {
    /// Called whenever the visible part of the grid moves, including scrollbar
    /// drags and trackpad scrolling.
    var onScroll: (() -> Void)?

    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        onScroll?()
    }
}

/// Frozen row-number gutter drawn next to the grid. It is a sibling of the
/// scroll view, so horizontal scrolling never moves it.
final class RowNumberView: NSView {
    weak var table: NSTableView?
    weak var model: AppModel?

    private static let keyImage: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.secondaryLabelColor]))
        return NSImage(systemSymbolName: "key.fill",
                       accessibilityDescription: L10n.tr("Уникальный ключ"))?
            .withSymbolConfiguration(configuration)
    }()

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func row(at point: NSPoint) -> Int {
        guard let table else { return -1 }
        return table.row(at: NSPoint(x: 0, y: point.y + table.visibleRect.minY))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let table, let model else { return }
        window?.makeFirstResponder(table)
        let p = convert(event.locationInWindow, from: nil)
        // The corner above the numbers selects the whole grid.
        if p.y < headerHeight {
            model.selectEntireResult()
            return
        }
        let row = row(at: p)
        guard row >= 0 else { return }
        let flags = event.modifierFlags
        let toggle = flags.contains(.command) || flags.contains(.control)
        model.selectResultRow(row, extend: flags.contains(.shift), toggle: toggle)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control), let table, let model else {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(table)
        let p = convert(event.locationInWindow, from: nil)
        if p.y < headerHeight {
            model.selectEntireResult()
            return
        }
        let row = row(at: p)
        guard row >= 0 else { return }
        model.selectResultRow(row,
                              extend: event.modifierFlags.contains(.shift),
                              toggle: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard p.y >= headerHeight else { return }
        let row = row(at: p)
        guard row >= 0 else { return }
        model.selectResultRow(row, extend: true)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        refreshToolTips()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshToolTips()
    }

    func refreshToolTips() {
        appTooltipProvider = { [weak self] point in
            self?.tooltip(at: point)
        }
    }

    func tooltip(at point: NSPoint) -> String {
        if point.y < headerHeight {
            return uniqueKeyTooltip()
        }
        return L10n.tr("Нажмите, чтобы выделить строку; ⌘ — добавить, ⇧ — диапазон")
    }

    /// The key icon replaces the old "№" label. Its tooltip names the unique
    /// key of the source table(s), when the driver reports one.
    private func uniqueKeyTooltip() -> String {
        guard let model, let result = model.result else {
            return L10n.tr("Уникальный ключ не определён")
        }
        var lines: [String] = []
        var seen = Set<String>()
        for column in result.columns where !column.table.isEmpty {
            guard let meta = model.tableMeta(for: column, profileID: result.profileID),
                  !meta.primaryKey.isEmpty else { continue }
            let table = [column.catalog, column.schema, column.table]
                .filter { !$0.isEmpty }.joined(separator: ".")
            let key = "\(table)(\(meta.primaryKey.joined(separator: ", ")))"
            guard seen.insert(key).inserted else { continue }
            lines.append(L10n.fmt("Уникальный ключ: %@(%@)", table,
                                  meta.primaryKey.joined(separator: ", ")))
        }
        return lines.isEmpty
            ? L10n.tr("Уникальный ключ не определён")
            : lines.joined(separator: "\n")
    }

    private var headerHeight: CGFloat {
        table?.headerView?.frame.height ?? 24
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        guard let table else { return }
        let header = headerHeight

        // Header strip, aligned with the table's column headers.
        let headerRect = NSRect(x: 0, y: 0, width: bounds.width, height: header)
        NSColor.windowBackgroundColor.setFill()
        headerRect.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]

        let visible = table.visibleRect
        let visibleRows = table.rows(in: visible)
        let count = table.numberOfRows
        let top = max(0, visibleRows.location)
        let bottom = min(count, visibleRows.location + visibleRows.length)
        let selection = model?.gridSelection
        // Numbers of rows scrolled under the header would otherwise be painted
        // over the "№" strip, since the header is filled before the rows.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: header,
                                  width: bounds.width,
                                  height: max(0, bounds.height - header))).addClip()
        if top < bottom {
            for row in top..<bottom {
                let rowRect = table.rect(ofRow: row)
                let y = rowRect.minY - visible.minY
                let selected = selection.map {
                    $0.kind != .columns && $0.rows.contains(row)
                } ?? false
                if selected {
                    NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                    NSRect(x: 0, y: y, width: bounds.width - 1, height: rowRect.height).fill()
                }
                let text = "\(row + 1)" as NSString
                let height = text.size(withAttributes: attrs).height
                let rect = NSRect(x: 0,
                                  y: y + (rowRect.height - height) / 2,
                                  width: bounds.width - 7,
                                  height: height)
                text.draw(in: rect, withAttributes: attrs)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        // Key icon in the corner, aligned with the column headers. It replaces
        // the old "№" label; hovering it explains the unique key.
        if let key = Self.keyImage {
            let side = min(header - 6, 14)
            let rect = NSRect(x: (bounds.width - side) / 2, y: (header - side) / 2,
                              width: side, height: side)
            key.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.85)
        }

        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: header - 1, width: bounds.width, height: 1).fill()
    }
}

/// Container that keeps the row-number gutter outside the horizontally
/// scrolling grid.
final class ResultsPaneView: NSView {
    let scrollView: GridScrollView
    let rowNumbers: RowNumberView
    static let gutterWidth: CGFloat = 52
    /// Tab toggles the grid and the vertical single-row view. The monitor is
    /// installed on the pane, so it keeps working while focus is on the table,
    /// the gutter or any other non-editable child of the result.
    var onToggleSingleRow: (() -> Void)?
    /// ⌘A while the grid has focus selects every cell.
    var onSelectAll: (() -> Void)?
    private var tabMonitor: Any?

    init(scrollView: GridScrollView, rowNumbers: RowNumberView) {
        self.scrollView = scrollView
        self.rowNumbers = rowNumbers
        super.init(frame: .zero)
        addSubview(rowNumbers)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, tabMonitor == nil {
            tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window != nil, self.window?.isKeyWindow == true,
                      NSApp.keyWindow?.attachedSheet == nil,
                      let responder = self.window?.firstResponder as? NSView,
                      responder === self || responder.isDescendant(of: self) else {
                    return event
                }
                // An inline cell editor keeps ⌘A for its own text and Tab for
                // moving between fields.
                if let textView = responder as? NSTextView, textView.isEditable { return event }
                if let textField = responder as? NSTextField, textField.isEditable { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if event.keyCode == 0, flags == .command {
                    self.onSelectAll?()
                    return nil
                }
                guard event.keyCode == 48, flags.isEmpty else { return event }
                self.onToggleSingleRow?()
                return nil
            }
        } else if window == nil, let monitor = tabMonitor {
            NSEvent.removeMonitor(monitor)
            tabMonitor = nil
        }
    }

    deinit {
        if let tabMonitor { NSEvent.removeMonitor(tabMonitor) }
    }

    override func layout() {
        super.layout()
        let gutter = Self.gutterWidth
        rowNumbers.frame = NSRect(x: 0, y: 0, width: gutter, height: bounds.height)
        scrollView.frame = NSRect(x: gutter, y: 0,
                                  width: max(0, bounds.width - gutter), height: bounds.height)
    }
}

struct ResultsView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> ResultsPaneView {
        let table = GridTableView()
        table.usesAlternatingRowBackgroundColors = true
        // Reordering is handled by GridHeaderView, which can move a whole
        // selected block of columns instead of a single one.
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = false
        table.selectionHighlightStyle = .none
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = []

        let scroll = GridScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.onScroll = { [weak coordinator = context.coordinator] in
            coordinator?.handleScroll()
        }

        let header = GridHeaderView()
        header.model = model
        table.headerView = header

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        let gutter = RowNumberView()
        gutter.table = table
        gutter.model = model
        context.coordinator.rowNumbers = gutter
        table.onCellMouse = { [weak coordinator = context.coordinator] event in
            coordinator?.handleMouse(event)
        }
        table.copyHandler = { [weak coordinator = context.coordinator] in
            coordinator?.copySelection()
        }
        table.pasteHandler = { [weak coordinator = context.coordinator] in
            coordinator?.pasteSelection()
        }
        table.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.contextMenu()
        }
        table.onContextClick = { [weak coordinator = context.coordinator] event in
            coordinator?.prepareContextSelection(event)
        }
        table.onZoom = { [weak coordinator = context.coordinator] steps in
            coordinator?.model.stepResultFontSize(steps)
        }
        table.onFocus = { [weak coordinator = context.coordinator] in
            coordinator?.model.focusedPane = .result
        }
        table.onToggleSingleRow = { [weak coordinator = context.coordinator] in
            coordinator?.model.toggleSingleRowResult()
        }
        table.selectAllHandler = { [weak coordinator = context.coordinator] in
            coordinator?.model.selectEntireResult()
        }
        // Coming back from the single-row view: give Tab back to the table,
        // otherwise the next Tab walks the window's key view loop into the
        // connection list. The request stays pending until the table really
        // becomes first responder, because the pane may be re-added to its
        // window one run-loop later.
        Self.restoreResultFocus(table, model: model)
        let pane = ResultsPaneView(scrollView: scroll, rowNumbers: gutter)
        pane.onToggleSingleRow = { [weak coordinator = context.coordinator] in
            coordinator?.model.toggleSingleRowResult()
        }
        pane.onSelectAll = { [weak coordinator = context.coordinator] in
            coordinator?.model.selectEntireResult()
        }
        return pane
    }

    /// Repeats `makeFirstResponder` for a short while, until the grid is in a
    /// window and accepted the keyboard. Without the retry the third Tab after
    /// returning from the single-row view could still escape into the sidebar.
    static func restoreResultFocus(_ table: NSTableView, model: AppModel, attempts: Int = 30) {
        guard model.needsResultFocus() else { return }
        DispatchQueue.main.async { [weak table, weak model] in
            guard let table, let model, model.needsResultFocus() else { return }
            guard let window = table.window else {
                guard attempts > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    restoreResultFocus(table, model: model, attempts: attempts - 1)
                }
                return
            }
            if window.firstResponder !== table {
                window.makeFirstResponder(table)
            }
            if window.firstResponder === table {
                model.resultFocusDidApply()
            } else if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    restoreResultFocus(table, model: model, attempts: attempts - 1)
                }
            }
        }
    }

    func updateNSView(_ nsView: ResultsPaneView, context: Context) {
        if let table = nsView.scrollView.documentView as? NSTableView,
           !(table.headerView is GridHeaderView) {
            let header = GridHeaderView()
            header.model = model
            table.headerView = header
        }
        if let table = nsView.scrollView.documentView as? NSTableView {
            Self.restoreResultFocus(table, model: model)
        }
        context.coordinator.update()
        context.coordinator.syncSearch()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: AppModel
        weak var table: NSTableView?
        weak var rowNumbers: RowNumberView?
        private var signature = ""
        private var lastSelectionKey = ""
        private var lastEditsRevision = 0
        private var anchor: (row: Int, col: Int)?
        private var head: (row: Int, col: Int)?

        private struct GridMatch: Hashable {
            let row: Int
            let col: Int
        }

        private var searchMatches: [GridMatch] = []
        private var searchIndex = -1
        private var lastSearchKey = ""
        private var lastSearchNav = 0

        init(model: AppModel) {
            self.model = model
        }

        func update() {
            guard let table else { return }
            let result = model.result
            let columns = result?.columns ?? []
            let rowCount = model.displayedRowCount
            // A revision counter avoids sorting (and copying) the whole
            // selection on every SwiftUI update, which matters after
            // "select all" on a large result.
            let selectionKey = "\(model.gridSelection?.kind == .rows)#\(model.gridSelection?.kind == .columns)#\(model.gridSelectionRevision)"
            let fontKey = "\(model.resultFontName)#\(model.resultFontSize)"
            let autoKey = "\(model.autoColumnWidths)#\(model.maxAutoColumnWidth)"
            let runID = result?.runID
            let queryKey = result?.queryName ?? ""
            let headerKey = "\(model.showTypeInColumnHeader)"
            let timeZoneKey = model.timeZoneIdentifier
            let rowKey = "\(rowCount)"
            if fontKey != lastFontKey || autoKey != lastAutoKey || headerKey != lastHeaderKey
                || timeZoneKey != lastTimeZoneKey {
                widthCache.removeAll()
            }
            let sortKey = "\(model.resultSort?.column ?? -1)#\(model.resultSort?.ascending ?? false)"
            let order = result?.visualColumnOrder ?? []
            let orderKey = order.map(String.init).joined(separator: ",")
            // A new result always gets a new runID, so the column list does not
            // need to be stringified on every SwiftUI update (which happens on
            // each keystroke in the editor).
            let sig = "\(runID?.uuidString ?? "-")#\(rowCount)#\(fontKey)#\(autoKey)"
                + "#\(queryKey)#\(headerKey)#\(sortKey)#\(orderKey)#\(timeZoneKey)#\(rowKey)"

            if sig == signature {
                // Nothing but the selection or a cell edit changed: repaint
                // the affected cells instead of rebuilding the whole table.
                if model.resultEditsRevision != lastEditsRevision {
                    lastEditsRevision = model.resultEditsRevision
                    table.reloadData()
                    rowNumbers?.needsDisplay = true
                }
                if selectionKey != lastSelectionKey {
                    lastSelectionKey = selectionKey
                    applySelectionHighlight()
                    rowNumbers?.needsDisplay = true
                    (table.headerView as? GridHeaderView)?.needsDisplay = true
                }
                return
            }
            lastSelectionKey = selectionKey
            lastEditsRevision = model.resultEditsRevision
            signature = sig
            let columnsChanged = columnsSignature(columns) != columnsSignature(lastColumns)
            // Switching auto widths on or off recomputes them; a font change
            // only matters while the width follows the data.
            let autoAppearanceChanged = autoKey != lastAutoKey
                || (model.autoColumnWidths && fontKey != lastFontKey)
            let headerModeChanged = headerKey != lastHeaderKey
            // The header moves columns live while dragging, so the table may
            // already be in the requested order when the model catches up.
            let orderChanged = orderKey != lastOrderKey && !tableMatchesOrder(order)
            let fontOnly = !columnsChanged && !headerModeChanged && !orderChanged
                && fontKey != lastFontKey && model.autoColumnWidths
            if fontOnly {
                // Same columns, new font: only the fitted widths change.
                // Recreating the columns would retile the whole 20k-row
                // table for nothing.
                refitColumnWidths(columns)
                lastRunID = runID
            } else if columnsChanged || autoAppearanceChanged || headerModeChanged || orderChanged {
                lastColumns = columns
                lastQueryKey = queryKey
                rebuildColumns(columns, order: order)
                lastRunID = runID
            } else if queryKey != lastQueryKey {
                // Same columns, another script: its own saved widths apply.
                lastQueryKey = queryKey
                applyColumnWidths(columns)
                lastRunID = runID
            } else if model.autoColumnWidths, let runID, runID != lastRunID {
                // The same query returned new data: fit the columns to it, so
                // short values do not keep the width of a longer earlier run.
                refitColumnWidths(columns)
                lastRunID = runID
            }
            lastFontKey = fontKey
            lastAutoKey = autoKey
            lastHeaderKey = headerKey
            lastOrderKey = orderKey
            lastTimeZoneKey = timeZoneKey
            applyFont()
            recycleCells()
            table.reloadData()
            rowNumbers?.needsDisplay = true
            rowNumbers?.refreshToolTips()
            (table.headerView as? GridHeaderView)?.refreshToolTips()
            table.headerView?.needsDisplay = true
        }

        // MARK: - search

        func handleScroll() {
            rowNumbers?.needsDisplay = true
            checkLoadMore()
        }

        /// Loads the next page when the user scrolls to the bottom of the grid.
        func checkLoadMore() {
            guard let table,
                  let scroll = table.enclosingScrollView,
                  let result = model.result,
                  !result.done else { return }
            let visible = scroll.contentView.bounds
            let height = table.bounds.height
            guard height > 0 else { return }
            if visible.maxY >= height - 60 {
                // Scrolling can happen during a layout pass; publish the
                // "loading" state outside of the SwiftUI view update.
                DispatchQueue.main.async { [weak self] in
                    self?.model.loadMore()
                }
            }
        }

        /// Recomputes matches when the query, the result or its row count
        /// changes, and steps to the next/previous match on demand.
        func syncSearch() {
            let query = model.resultSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = model.result
            let key = "\(result?.runID.uuidString ?? "-")#\(model.displayedRowCount)#\(result?.columns.count ?? 0)"
            if query != lastQuery || key != lastSearchKey {
                lastQuery = query
                lastSearchKey = key
                recomputeSearch(query: query)
                lastSearchNav = model.resultSearchNav
                return
            }
            let nav = model.resultSearchNav
            guard nav != lastSearchNav else { return }
            let forward = nav > lastSearchNav
            lastSearchNav = nav
            stepSearch(forward: forward)
        }

        private var lastQuery = ""

        private var searchMatchSet: Set<GridMatch> = []

        /// Up to this many cells the scan is quick enough to run inline; larger
        /// results are scanned off the main thread.
        private static let syncSearchCellLimit = 40_000

        /// Incremented on every new query so a slow background scan cannot
        /// overwrite the matches of a newer one.
        private var searchGeneration = 0

        /// Prepared query, also used to highlight visible cells.
        private var lastSearchQuery: SearchMatcher.Query?

        private func recomputeSearch(query: String) {
            searchGeneration += 1
            let generation = searchGeneration
            searchMatches = []
            let hadMatches = !searchMatchSet.isEmpty
            searchMatchSet = []
            searchIndex = -1
            lastSearchQuery = SearchMatcher.query(query)
            guard let prepared = lastSearchQuery, let result = model.result else {
                publishSearchCount(0)
                // A switch to a result with no active search needs no repaint:
                // update() has already reloaded the grid.
                if hadMatches {
                    recycleCells()
                    table?.reloadData()
                }
                return
            }

            let rows = result.rows
            let displayCount = model.displayedRowCount
            // Snapshot the display -> data mapping on the main actor so the
            // background scan does not touch model state.
            let mapping = (0..<displayCount).map { model.dataRow(forDisplayRow: $0) }
            let cells = displayCount * max(1, result.columns.count)
            let scan = { () -> [GridMatch] in
                func matches(in range: Range<Int>) -> [GridMatch] {
                    var found: [GridMatch] = []
                    for displayRow in range {
                        let row = rows[mapping[displayRow]]
                        for (colIndex, value) in row.enumerated() {
                            guard let value, !value.isEmpty, prepared.matches(value) else { continue }
                            found.append(GridMatch(row: displayRow, col: colIndex))
                        }
                    }
                    return found
                }
                // Wide results are split across cores; the pieces are stitched
                // back in row order so navigation still goes top to bottom.
                let chunks = displayCount >= 2_000
                    ? min(8, max(1, ProcessInfo.processInfo.activeProcessorCount))
                    : 1
                guard chunks > 1 else { return matches(in: 0..<displayCount) }
                let lock = NSLock()
                var pieces: [(Int, [GridMatch])] = []
                pieces.reserveCapacity(chunks)
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    let start = displayCount * c / chunks
                    let end = displayCount * (c + 1) / chunks
                    let found = matches(in: start..<end)
                    lock.lock()
                    pieces.append((c, found))
                    lock.unlock()
                }
                return pieces.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
            }

            if cells <= Self.syncSearchCellLimit {
                applySearch(scan(), generation: generation)
            } else {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let found = scan()
                    DispatchQueue.main.async { self?.applySearch(found, generation: generation) }
                }
            }
        }

        private func applySearch(_ found: [GridMatch], generation: Int) {
            guard generation == searchGeneration else { return }
            searchMatches = found
            searchMatchSet = Set(found)
            searchIndex = found.isEmpty ? -1 : 0
            publishSearchCount(found.count)
            table?.reloadData()
            scrollToCurrentMatch()
        }

        private func publishSearchCount(_ count: Int) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.resultSearchCount != count else { return }
                self.model.resultSearchCount = count
            }
        }

        private func stepSearch(forward: Bool) {
            guard !searchMatches.isEmpty else { return }
            let count = searchMatches.count
            searchIndex = (searchIndex + (forward ? 1 : -1) + count) % count
            table?.reloadData()
            scrollToCurrentMatch()
        }

        private func scrollToCurrentMatch() {
            guard let table, searchMatches.indices.contains(searchIndex) else { return }
            let match = searchMatches[searchIndex]
            table.scrollRowToVisible(match.row)
            table.scrollColumnToVisible(match.col)
        }

        private func isCurrentMatch(row: Int, col: Int) -> Bool {
            searchMatches.indices.contains(searchIndex)
                && searchMatches[searchIndex] == GridMatch(row: row, col: col)
        }

        private func isAnyMatch(row: Int, col: Int) -> Bool {
            searchMatchSet.contains(GridMatch(row: row, col: col))
        }

        private var lastColumns: [ColumnInfo] = []
        private var lastQueryKey = ""
        private var lastFontKey = ""
        private var lastAutoKey = ""
        private var lastRunID: UUID?
        private var lastHeaderKey = ""
        private var lastOrderKey = ""
        private var lastTimeZoneKey = ""
        private var restoringWidths = false
        /// Cell views taken from the table just before a reload. AppKit does not
        /// reuse them across `reloadData`, and creating a text field for every
        /// visible cell was what made a tab switch feel slow.
        private var cellPool: [GridCellView] = []

        private func recycleCells() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            let end = min(table.numberOfRows, visible.location + visible.length)
            guard visible.location < end else { return }
            // Cells go back into the pool detached and only once. Keeping them
            // in their row views meant a reload could hand the same view out
            // again while AppKit was still showing it in the old row: the old
            // row kept a stale copy of the text (it looked like that row had
            // slid down), and the pool grew with duplicates on every rebuild.
            var seen = Set(cellPool.map(ObjectIdentifier.init))
            for row in visible.location..<end {
                guard let rowView = table.rowView(atRow: row, makeIfNecessary: false) else { continue }
                for view in rowView.subviews {
                    guard let cell = view as? GridCellView, !cell.isEditing else { continue }
                    let id = ObjectIdentifier(cell)
                    guard seen.insert(id).inserted else { continue }
                    cell.removeFromSuperview()
                    cellPool.append(cell)
                }
            }
            // Keep the pool bounded when the column count shrinks.
            if cellPool.count > 800 {
                cellPool.removeFirst(cellPool.count - 800)
            }
        }

        private func columnsSignature(_ columns: [ColumnInfo]) -> String {
            columns.map { "\($0.name):\($0.type)" }.joined(separator: "|")
        }

        /// True when the table already shows the columns in the given order,
        /// which is the case right after a drag moved them live.
        private func tableMatchesOrder(_ order: [Int]) -> Bool {
            guard let table, table.tableColumns.count == order.count else { return false }
            return table.tableColumns.map { $0.identifier.rawValue } == order.map { "c\($0)" }
        }

        private func rebuildColumns(_ columns: [ColumnInfo], order: [Int]) {
            guard let table else { return }
            restoringWidths = true
            // Detach the rows while the columns are rebuilt. AppKit recalculates
            // the key view loop of every visible row for each added column, and
            // with a 20-column result that took ~200 ms per tab switch.
            recycleCells()
            let hadDataSource = table.dataSource != nil
            table.dataSource = nil
            defer {
                restoringWidths = false
                if hadDataSource { table.dataSource = self }
            }

            for c in table.tableColumns { table.removeTableColumn(c) }
            let saved = model.columnWidths(for: model.result?.queryName ?? "")
            for i in order {
                guard i >= 0, i < columns.count else { continue }
                let col = columns[i]
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
                c.title = headerTitle(for: col)
                c.minWidth = 50
                if model.autoColumnWidths {
                    c.width = autoWidth(for: col, index: i)
                } else if let width = saved[col.name], width >= c.minWidth {
                    // A width the user chose by dragging always wins.
                    c.width = width
                } else {
                    // Default for a new column: the header estimate, but never
                    // wider than the data needs.
                    let automatic = max(90, min(280, CGFloat(headerTitle(for: col).count * 8 + 62)))
                    c.width = min(automatic, naturalWidth(for: col, index: i))
                }
                c.resizingMask = [.userResizingMask, .autoresizingMask]
                table.addTableColumn(c)
            }
        }

        private func headerTitle(for column: ColumnInfo) -> String {
            model.resultHeaderTitle(for: column)
        }

        /// Measured widths per execution. Switching tabs asked for every width
        /// again, which meant re-measuring hundreds of strings for a result
        /// that had not changed.
        private var widthCache: [UUID: [CGFloat]] = [:]

        /// Fits the widest of the first rows, capped by the user's maximum.
        /// Long values are intentionally truncated instead of stretching the column.
        private func autoWidth(for column: ColumnInfo, index: Int) -> CGFloat {
            if let runID = model.result?.runID,
               let cached = widthCache[runID], cached.indices.contains(index) {
                return cached[index]
            }
            let width = min(naturalWidth(for: column, index: index), model.maxAutoColumnWidth)
            if let runID = model.result?.runID {
                var widths = widthCache[runID] ?? []
                if widths.count <= index {
                    widths.append(contentsOf: repeatElement(-1, count: index - widths.count + 1))
                }
                widths[index] = width
                widthCache[runID] = widths
                if widthCache.count > 24, let oldest = widthCache.keys.first {
                    widthCache.removeValue(forKey: oldest)
                }
            }
            return width
        }

        /// Width that shows the header and the loaded values without truncation.
        private func naturalWidth(for column: ColumnInfo, index: Int) -> CGFloat {
            let font = model.resultFont
            let headerFont = NSFont.systemFont(ofSize: max(10, font.pointSize - 1), weight: .medium)
            let header = headerTitle(for: column) as NSString
            var widest = header.size(withAttributes: [.font: headerFont]).width

            // Measuring the first rows as one multi-line string returns the
            // widest line in a single call, instead of one call per value
            // (2400 text measurements made a font change feel sluggish).
            let result = model.result
            let displayCount = min(model.displayedRowCount, 200)
            var values: [String] = []
            values.reserveCapacity(displayCount)
            var needsIndividual = false
            if let result {
                for display in 0..<displayCount {
                    let dataRow = model.dataRow(forDisplayRow: display)
                    guard dataRow >= 0, dataRow < result.rows.count else { continue }
                    let row = result.rows[dataRow]
                    guard index < row.count else { continue }
                    let text = TimestampDisplay.formatted(row[index], columnType: column.type) ?? "NULL"
                    if text.contains("\n") || text.contains("\r") {
                        needsIndividual = true
                        break
                    }
                    values.append(text)
                }
            }
            if needsIndividual {
                for text in values {
                    widest = max(widest, (text as NSString).size(withAttributes: [.font: font]).width)
                }
            } else if !values.isEmpty {
                let joined = values.joined(separator: "\n") as NSString
                widest = max(widest, joined.size(withAttributes: [.font: font]).width)
            }

            let padded = (widest + 40).rounded(.up) // padding + sort arrow
            return max(padded, 60)
        }

        /// Applies the saved (or default) widths of the active script without
        /// recreating the columns.
        private func applyColumnWidths(_ columns: [ColumnInfo]) {
            guard let table else { return }
            restoringWidths = true
            defer { restoringWidths = false }
            let saved = model.columnWidths(for: model.result?.queryName ?? "")
            for (i, column) in columns.enumerated() {
                guard let c = table.tableColumns.first(where: {
                    $0.identifier.rawValue == "c\(i)"
                }) else { continue }
                if model.autoColumnWidths {
                    c.width = autoWidth(for: column, index: i)
                } else if let width = saved[column.name], width >= c.minWidth {
                    c.width = width
                } else {
                    let automatic = max(90, min(280, CGFloat(headerTitle(for: column).count * 8 + 62)))
                    c.width = min(automatic, naturalWidth(for: column, index: i))
                }
            }
        }

        /// Applies fresh auto widths to existing columns, keeping their order.
        private func refitColumnWidths(_ columns: [ColumnInfo]) {
            guard let table else { return }
            restoringWidths = true
            defer { restoringWidths = false }
            let targets = columns.enumerated().map { i, column in autoWidth(for: column, index: i) }
            for (i, target) in targets.enumerated() {
                let id = NSUserInterfaceItemIdentifier("c\(i)")
                guard let c = table.tableColumns.first(where: { $0.identifier == id }) else { continue }
                guard abs(c.width - target) > 0.5 else { continue }
                c.width = target
            }
        }

        /// Paints the current selection onto the visible cells only.
        private func applySelectionHighlight() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            let selection = model.gridSelection
            let lastRow = min(table.numberOfRows, visible.location + visible.length)
            guard visible.location < lastRow else { return }
            for row in visible.location..<lastRow {
                for position in 0..<table.numberOfColumns {
                    guard let cell = table.view(atColumn: position, row: row,
                                                makeIfNecessary: false) as? GridCellView,
                          let data = columnIndex(ofPosition: position) else { continue }
                    cell.setSelected(selection?.contains(row: row, col: data) ?? false)
                }
            }
        }

        private func applyFont() {
            guard let table else { return }
            let font = model.resultFont
            table.rowHeight = max(18, (font.pointSize + 9).rounded())
            let header = NSFont.systemFont(ofSize: max(10, font.pointSize - 1), weight: .medium)
            for c in table.tableColumns { c.headerCell.font = header }
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !restoringWidths,
                  !model.autoColumnWidths,
                  let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let idx = columnIndex(of: column),
                  let result = model.result,
                  idx < result.columns.count else { return }
            model.setColumnWidth(column.width, forColumn: result.columns[idx].name)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            model.displayedRowCount
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn,
                  let idx = columnIndex(of: tableColumn),
                  let result = model.result,
                  row >= 0, row < model.displayedRowCount else { return nil }
            let dataRow = model.dataRow(forDisplayRow: row)
            guard dataRow >= 0, dataRow < result.rows.count else { return nil }

            let rowValues = result.rows[dataRow]
            let rawValue: String? = idx < rowValues.count ? rowValues[idx] : nil
            let column = idx < result.columns.count ? result.columns[idx] : nil
            let value = TimestampDisplay.formatted(rawValue, columnType: column?.type ?? "")

            let link = linkURL(for: rawValue)
            let baseFont = model.resultFont
            let cellFont = value == nil
                ? (NSFont(name: baseFont.fontName, size: max(8, baseFont.pointSize - 0.5)) ?? baseFont)
                : baseFont

            var highlighted: NSAttributedString?
            if !lastQuery.isEmpty, let value, isAnyMatch(row: row, col: idx) {
                let ranges = lastSearchQuery?.ranges(in: value) ?? []
                if !ranges.isEmpty {
                    let attributed = NSMutableAttributedString(string: value, attributes: [
                        .font: cellFont,
                        .foregroundColor: NSColor.labelColor
                    ])
                    let highlight = isCurrentMatch(row: row, col: idx)
                        ? NSColor.systemOrange.withAlphaComponent(0.65)
                        : NSColor.systemYellow.withAlphaComponent(0.42)
                    for range in ranges {
                        attributed.addAttribute(.backgroundColor, value: highlight, range: range)
                    }
                    highlighted = attributed
                }
            }

            let cell = cellPool.popLast()
                ?? tableView.makeView(withIdentifier: GridCellView.reuseIdentifier,
                                      owner: self) as? GridCellView
                ?? GridCellView()
            cell.linkButton.onClick = { url in NSWorkspace.shared.open(url) }
            cell.configure(value: value, font: cellFont,
                           numeric: column?.isNumeric == true, link: link,
                           highlighted: highlighted,
                           selected: isSelected(row: row, col: idx),
                           current: isCurrentMatch(row: row, col: idx))
            return cell
        }

        private func columnIndex(ofPosition position: Int) -> Int? {
            guard let table, position >= 0, position < table.tableColumns.count else { return nil }
            return columnIndex(of: table.tableColumns[position])
        }

        /// Columns are created with identifiers "c0", "c1", … so the index is
        /// available without scanning the column list for every visible cell.
        private func columnIndex(of column: NSTableColumn) -> Int? {
            let raw = column.identifier.rawValue
            guard raw.first == "c" else { return nil }
            return Int(raw.dropFirst())
        }

        private func isSelected(row: Int, col: Int) -> Bool {
            model.gridSelection?.contains(row: row, col: col) ?? false
        }

        /// Values shaped like `protocol://...` get an "open in system" button.
        private func linkURL(for value: String?) -> URL? {
            guard let value else { return nil }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.contains("://"),
                  let url = URL(string: text),
                  let scheme = url.scheme, !scheme.isEmpty,
                  text.lowercased().hasPrefix(scheme.lowercased() + "://") else { return nil }
            return url
        }

        func handleMouse(_ event: NSEvent) {
            guard let table else { return }
            let p = table.convert(event.locationInWindow, from: nil)
            let row = table.row(at: p)
            let position = table.column(at: p)
            guard row >= 0, let col = columnIndex(ofPosition: position) else { return }

            if event.type == .leftMouseDown {
                if event.modifierFlags.contains(.shift), anchor != nil {
                    head = (row, col)
                } else {
                    anchor = (row, col)
                    head = (row, col)
                }
                applySelection()
                if event.clickCount == 2 {
                    beginEditing(row: row, col: col, position: position)
                }
            } else if event.type == .leftMouseDragged {
                guard anchor != nil else { return }
                head = (row, col)
                applySelection()
            }
        }

        private func beginEditing(row: Int, col: Int, position: Int) {
            guard let table,
                  let result = model.result,
                  row >= 0, row < model.displayedRowCount else { return }
            guard let cell = table.view(atColumn: position, row: row,
                                        makeIfNecessary: true) as? GridCellView else { return }
            let dataRow = model.dataRow(forDisplayRow: row)
            guard dataRow >= 0, dataRow < result.rows.count else { return }
            let rowValues = result.rows[dataRow]
            let value: String? = col < rowValues.count ? rowValues[col] : nil
            cell.onCommitEdit = { [weak self] newValue in
                self?.model.setResultCell(row: row, column: col, value: newValue)
            }
            cell.beginEditing(value: value)
        }

        private func applySelection() {
            guard let a = anchor, let h = head else { return }
            let rows = Set(min(a.row, h.row)...max(a.row, h.row))
            let cols = Set(min(a.col, h.col)...max(a.col, h.col))
            model.gridSelection = GridSelection(kind: .cells, rows: rows, cols: cols)
            model.followValuePanel(row: h.row, col: h.col)
        }

        func copySelection() {
            model.copySelection()
        }

        func pasteSelection() {
            model.pasteSelection(settings: GridClipboardStore.paste)
        }

        /// Right-clicking outside the selection moves the selection to the
        /// clicked cell, like every other Mac grid.
        /// Cell that was right-clicked; the value panel opens exactly this one.
        private var contextCell: (row: Int, col: Int)?

        func prepareContextSelection(_ event: NSEvent) {
            guard let table,
                  let result = model.result else { return }
            let p = table.convert(event.locationInWindow, from: nil)
            let row = table.row(at: p)
            guard row >= 0, row < model.displayedRowCount,
                  let col = columnIndex(ofPosition: table.column(at: p)) else { return }
            contextCell = (row, col)
            if model.gridSelection?.contains(row: row, col: col) != true {
                model.gridSelection = GridSelection(kind: .cells, rows: [row], cols: [col])
                anchor = (row, col)
                head = (row, col)
            }
        }

        func contextMenu() -> NSMenu? {
            guard model.result != nil else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false

            add(to: menu, "Копировать", #selector(ctxCopy(_:)), key: "c")
            let copy = NSMenuItem(title: L10n.tr("Копировать…"), action: nil, keyEquivalent: "")
            copy.submenu = copySubmenu()
            menu.addItem(copy)

            add(to: menu, "Значение", #selector(ctxShowValue(_:)))

            add(to: menu, "Вставить", #selector(ctxPaste(_:)), key: "v")
            let paste = NSMenuItem(title: L10n.tr("Вставить…"), action: nil, keyEquivalent: "")
            paste.submenu = pasteSubmenu()
            menu.addItem(paste)

            let export = NSMenuItem(title: L10n.tr("Экспорт"), action: nil, keyEquivalent: "")
            export.submenu = exportSubmenu()
            menu.addItem(export)

            let open = NSMenuItem(title: L10n.tr("Открыть в…"), action: nil, keyEquivalent: "")
            open.submenu = openSubmenu()
            menu.addItem(open)

            return menu
        }

        private func copySubmenu() -> NSMenu {
            let menu = NSMenu()
            add(to: menu, "Настроить копирование…", #selector(ctxCopySettings(_:)))
            menu.addItem(.separator())
            for format in GridClipboardFormat.allCases {
                add(to: menu, format.title, #selector(ctxCopyAs(_:)),
                    represented: format.rawValue)
            }
            return menu
        }

        private func pasteSubmenu() -> NSMenu {
            let menu = NSMenu()
            add(to: menu, "Вставить", #selector(ctxPaste(_:)))
            add(to: menu, "Вставить без кавычек", #selector(ctxPasteNoQuotes(_:)))
            menu.addItem(.separator())
            add(to: menu, "Дополнительная вставка…", #selector(ctxPasteSettings(_:)))
            return menu
        }

        private func exportSubmenu() -> NSMenu {
            let menu = NSMenu()
            add(to: menu, "CSV…", #selector(ctxExportCSV(_:)))
            add(to: menu, "XML…", #selector(ctxExportXML(_:)))
            add(to: menu, "XLSX…", #selector(ctxExportXLSX(_:)))
            return menu
        }

        private func openSubmenu() -> NSMenu {
            let menu = NSMenu()
            add(to: menu, "Excel", #selector(ctxOpenExcel(_:)))
            add(to: menu, "Браузер", #selector(ctxOpenBrowser(_:)))
            menu.addItem(.separator())
            add(to: menu, "Другое приложение…", #selector(ctxOpenOther(_:)))
            return menu
        }

        @discardableResult
        private func add(to menu: NSMenu, _ title: String, _ action: Selector,
                         key: String = "", represented: Any? = nil,
                         keyModifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: L10n.tr(title), action: action, keyEquivalent: key)
            item.target = self
            if !key.isEmpty { item.keyEquivalentModifierMask = keyModifiers }
            item.representedObject = represented
            menu.addItem(item)
            return item
        }

        @objc private func ctxCopy(_ sender: Any?) {
            model.copySelection()
        }

        @objc private func ctxShowValue(_ sender: Any?) {
            guard let cell = contextCell else { return }
            model.showValuePanel(row: cell.row, col: cell.col)
        }

        @objc private func ctxCopyAs(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let format = GridClipboardFormat(rawValue: raw) else { return }
            model.copySelection(as: format)
        }

        @objc private func ctxCopySettings(_ sender: Any?) {
            DispatchQueue.main.async { [weak self] in self?.model.showCopyDialog = true }
        }

        @objc private func ctxPaste(_ sender: Any?) {
            model.pasteSelection(settings: GridClipboardStore.paste)
        }

        @objc private func ctxPasteNoQuotes(_ sender: Any?) {
            var settings = GridClipboardStore.paste
            settings.ignoreQuotes = true
            model.pasteSelection(settings: settings)
        }

        @objc private func ctxPasteSettings(_ sender: Any?) {
            DispatchQueue.main.async { [weak self] in self?.model.showPasteDialog = true }
        }

        @objc private func ctxExportCSV(_ sender: Any?) {
            model.exportCSVSelection()
        }

        @objc private func ctxExportXML(_ sender: Any?) {
            model.exportXMLSelection()
        }

        @objc private func ctxExportXLSX(_ sender: Any?) {
            model.exportXLSXSelection()
        }

        @objc private func ctxOpenExcel(_ sender: Any?) {
            model.openSelectionIn(.excel)
        }

        @objc private func ctxOpenBrowser(_ sender: Any?) {
            model.openSelectionIn(.browser)
        }

        @objc private func ctxOpenOther(_ sender: Any?) {
            model.openSelectionIn(.otherApplication)
        }
    }
}
