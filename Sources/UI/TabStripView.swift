import SwiftUI
import AppKit

/// Horizontally scrolling strip of query tabs. Implemented in AppKit so that
/// dragging a tab can auto-scroll the strip near its edges, which is what
/// makes reordering usable when many tabs are open.
struct TabStripView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> TabStripContainer {
        TabStripContainer(model: model)
    }

    func updateNSView(_ nsView: TabStripContainer, context: Context) {
        nsView.sync()
    }
}

final class TabStripContainer: NSView {
    private let scroll = TabStripScrollView()
    private let canvas: TabStripCanvas
    private let indicator = TabScrollIndicator()
    private var scrollMonitor: Any?
    private var clickMonitor: Any?
    /// True while the tab strip is the scroll target. It survives scrolling
    /// in other panes and is cleared by a click outside the strip or by the
    /// editor taking focus (for example after a quick-open jump).
    private var ownsScroll = false

    init(model: AppModel) {
        canvas = TabStripCanvas(model: model)
        super.init(frame: .zero)

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // The system scroller is too thick and covers tab titles. Draw a
        // two-pixel indicator instead.
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.contentView.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.documentView = canvas
        scroll.owner = self
        canvas.scrollView = scroll
        addSubview(scroll)
        addSubview(indicator)
        indicator.isHidden = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        // Focus can move to the editor without a click in it (for example
        // after choosing a query in search). The wheel must follow the editor
        // from that moment, so drop the sticky tab-strip scroll target.
        NotificationCenter.default.addObserver(
            self, selector: #selector(editorDidTakeFocus),
            name: .editorDidTakeFocus, object: nil)

        // Scrolling over the tabs makes the strip the scroll target. From
        // then on, scrolling anywhere else keeps scrolling the tabs until the
        // user clicks another pane or the editor takes focus.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            let inside = self.containsStripPoint(event)
            guard self.ownsScroll, event.window === self.window, !inside else {
                return event
            }
            self.scroll.scrollWheel(with: event)
            return nil
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.noteClick(atWindowPoint: event.locationInWindow)
            return event
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 30) }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        indicator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 3)
        canvas.visibleSizeChanged()
        updateIndicator()
    }

    func sync() {
        canvas.sync()
    }

    private func containsStripPoint(_ event: NSEvent) -> Bool {
        guard window != nil else { return false }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }

    func noteScroll(_ event: NSEvent) {
        // The scroll view only receives events when the pointer is over it.
        ownsScroll = true
    }

    /// Clicks inside the strip keep it as the scroll target; clicks anywhere
    /// else hand scrolling back to that pane.
    func noteClick(atWindowPoint point: NSPoint) {
        ownsScroll = bounds.contains(convert(point, from: nil))
    }

    /// The editor took focus, so the next wheel gesture belongs to it.
    @objc private func editorDidTakeFocus() {
        ownsScroll = false
    }

    var isScrollOwner: Bool { ownsScroll }

    @objc private func clipBoundsChanged() {
        updateIndicator()
    }

    private func updateIndicator() {
        let clip = scroll.contentView
        let visible = clip.bounds.width
        let document = max(canvas.frame.width, 1)
        guard document > visible + 0.5, visible > 1 else {
            indicator.isHidden = true
            return
        }
        indicator.isHidden = false
        let track = bounds.width
        let width = max(28, track * visible / document)
        let maxOrigin = max(1, document - visible)
        let x = clip.bounds.origin.x / maxOrigin * (track - width)
        indicator.knob = NSRect(x: x, y: 0, width: width, height: 3)
        indicator.needsDisplay = true
    }
}

/// Thin scroll indicator drawn over the tab strip instead of a system scroller.
final class TabScrollIndicator: NSView {
    var knob: NSRect = .zero

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !knob.isEmpty else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: knob, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// Lets a plain vertical wheel scroll the tab strip horizontally, which is the
/// natural gesture when a mouse (rather than a trackpad) is used.
final class TabStripScrollView: NSScrollView {
    weak var owner: TabStripContainer?

    override func scrollWheel(with event: NSEvent) {
        owner?.noteScroll(event)
        let verticalOnly = abs(event.scrollingDeltaX) < 0.01
            && abs(event.scrollingDeltaY) > 0.01
            && !event.modifierFlags.contains(.shift)
        guard verticalOnly, let document = documentView else {
            super.scrollWheel(with: event)
            return
        }
        let clip = contentView
        var origin = clip.bounds.origin
        origin.x -= event.scrollingDeltaY
        let maxX = max(0, document.frame.width - clip.bounds.width)
        origin.x = min(max(0, origin.x), maxX)
        guard origin.x != clip.bounds.origin.x else { return }
        clip.scroll(to: origin)
        reflectScrolledClipView(clip)
    }
}

final class TabStripCanvas: NSView, NSTextFieldDelegate {
    private let model: AppModel
    weak var scrollView: NSScrollView?

    private struct Chip {
        let id: UUID
        let title: String
        let filePath: String?
        let isDirty: Bool
        var runState: TabRunState
        var frame: NSRect
        var textRect: NSRect
        var closeRect: NSRect
    }

    private var chips: [Chip] = []
    private var contentWidth: CGFloat = 0
    private var layoutHeight: CGFloat = 0
    private var isRebuilding = false
    private var signature = ""
    private var lastActiveID: UUID?

    private var hoveredID: UUID?
    private var hoveredClose = false
    private var trackingArea: NSTrackingArea?

    private var dragCandidateID: UUID?
    private var dragID: UUID?
    private var dragStart: NSPoint = .zero
    private var dragGhost: DragGhost?
    private var insertionSlot: Int?
    private var autoscrollTimer: Timer?

    private var renameField: NSTextField?
    private var editingTabID: UUID?
    private var blinkTimer: Timer?
    private var blinkVisible = true

    private let chipFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private let leftPadding: CGFloat = 6
    private let chipSpacing: CGFloat = 2
    private let horizontalPadding: CGFloat = 9
    private let iconWidth: CGFloat = 11
    private let gap: CGFloat = 6
    private let closeWidth: CGFloat = 14
    private let statusSlot: CGFloat = 9
    private let maxTextWidth: CGFloat = 170

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        autoresizingMask = [.height]
        lastActiveID = model.activeTabID
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        blinkTimer?.invalidate()
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    // MARK: - sync

    func sync() {
        let newSignature = signature(for: model.tabs)
        if newSignature != signature {
            signature = newSignature
            rebuildLayout()
            needsDisplay = true
        }

        if model.inlineRenameTabID != editingTabID {
            // Starting/ending inline editing moves the first responder, which
            // can publish model changes; keep it out of the view update.
            DispatchQueue.main.async { [weak self] in
                self?.syncRenameState()
            }
        }

        if model.activeTabID != lastActiveID {
            lastActiveID = model.activeTabID
            scrollActiveIntoView()
            needsDisplay = true
        }

        updateRunStates()
        visibleSizeChanged()
    }

    private func syncRenameState() {
        let target = model.inlineRenameTabID
        guard target != editingTabID else { return }
        if let id = target, chips.contains(where: { $0.id == id }) {
            beginRename(id)
        } else if target == nil {
            endRenameField()
        }
    }

    private func signature(for tabs: [QueryTab]) -> String {
        tabs.map { "\($0.id)|\($0.title)|\($0.isDirty)|\($0.filePath ?? "")" }
            .joined(separator: "\n")
    }

    func visibleSizeChanged() {
        guard let scrollView else { return }
        let visible = scrollView.contentView.bounds.size
        let width = max(contentWidth, visible.width)
        let height = max(1, visible.height)
        if abs(frame.width - width) > 0.5 || abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: width, height: height))
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
        clampScroll()
    }

    private func clampScroll() {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let maxX = max(0, frame.width - clip.bounds.width)
        if clip.bounds.origin.x > maxX {
            clip.scroll(to: NSPoint(x: maxX, y: 0))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !isRebuilding, abs(newSize.height - layoutHeight) > 0.5 {
            rebuildLayout()
        }
    }

    private func rebuildLayout() {
        isRebuilding = true
        layoutHeight = bounds.height
        let height = max(20, bounds.height - 6)
        var x = leftPadding
        var result: [Chip] = []
        for tab in model.tabs {
            let textWidth = min(maxTextWidth,
                                ceil((tab.title as NSString).size(withAttributes: [.font: chipFont]).width) + 2)
            let width = horizontalPadding + iconWidth + gap + statusSlot + gap + textWidth + gap
                + (tab.isDirty ? 11 : 0) + closeWidth + horizontalPadding
            let frame = NSRect(x: x, y: 3, width: width, height: height)
            let textRect = NSRect(x: frame.minX + horizontalPadding + iconWidth + gap + statusSlot + gap,
                                  y: frame.minY + (height - 15) / 2,
                                  width: textWidth,
                                  height: 15)
            let closeRect = NSRect(x: frame.maxX - horizontalPadding - closeWidth,
                                   y: frame.minY + (height - 16) / 2,
                                   width: closeWidth,
                                   height: 16)
            result.append(Chip(id: tab.id, title: tab.title, filePath: tab.filePath,
                               isDirty: tab.isDirty,
                               runState: model.tabRunStates[tab.id] ?? .idle,
                               frame: frame, textRect: textRect, closeRect: closeRect))
            x += width + chipSpacing
        }
        chips = result
        contentWidth = chips.isEmpty ? leftPadding * 2 : x - chipSpacing + leftPadding

        appTooltipProvider = { [weak self] point in
            self?.tooltip(at: point)
        }
        window?.invalidateCursorRects(for: self)
        if let id = editingTabID,
           let chip = chips.first(where: { $0.id == id }) {
            positionRenameField(over: chip)
        } else if editingTabID != nil {
            endRenameField()
        }
        visibleSizeChanged()
        isRebuilding = false
    }

    private func chip(at point: NSPoint) -> Chip? {
        chips.first { $0.frame.contains(point) }
    }

    /// Copies the run state of every tab into the chips and keeps the blink
    /// timer running while at least one query is executing.
    private func updateRunStates() {
        var changed = false
        for i in chips.indices {
            let state = model.tabRunStates[chips[i].id] ?? .idle
            if chips[i].runState != state {
                chips[i].runState = state
                changed = true
            }
        }
        if changed { needsDisplay = true }
        updateBlinkTimer()
    }

    private func updateBlinkTimer() {
        let anyRunning = chips.contains { $0.runState == .running }
        if anyRunning, blinkTimer == nil {
            blinkVisible = true
            let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.blinkVisible.toggle()
                self.needsDisplay = true
            }
            RunLoop.main.add(timer, forMode: .common)
            blinkTimer = timer
        } else if !anyRunning {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkVisible = true
        }
    }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        for chip in chips {
            let isActive = chip.id == model.activeTabID
            let isHovered = chip.id == hoveredID
            let isDragging = chip.id == dragID
            let alpha: CGFloat = isDragging ? 0.35 : 1

            if isActive || isHovered {
                NSColor.controlAccentColor
                    .withAlphaComponent(isActive ? 0.16 : 0.08)
                    .setFill()
                NSBezierPath(roundedRect: chip.frame, xRadius: 6, yRadius: 6).fill()
            }

            let iconColor: NSColor = isActive ? .controlAccentColor : .secondaryLabelColor
            if let icon = Self.symbol(chip.filePath == nil ? "doc.text" : "doc",
                                      size: 9, weight: .regular, color: iconColor) {
                let rect = NSRect(x: chip.frame.minX + horizontalPadding,
                                  y: chip.frame.midY - 5,
                                  width: iconWidth, height: 11)
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            }

            if chip.runState != .idle {
                let dot = NSRect(x: chip.frame.minX + horizontalPadding + iconWidth + gap
                                    + (statusSlot - 6) / 2,
                                 y: chip.frame.midY - 3, width: 6, height: 6)
                switch chip.runState {
                case .running:
                    let pulse = blinkVisible ? 0.8 : 0.2
                    NSColor.secondaryLabelColor.withAlphaComponent(pulse * alpha).setFill()
                case .succeeded:
                    NSColor.systemGreen.withAlphaComponent(alpha).setFill()
                case .failed:
                    NSColor.systemRed.withAlphaComponent(alpha).setFill()
                case .idle:
                    break
                }
                NSBezierPath(ovalIn: dot).fill()
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let textColor: NSColor = isActive ? .labelColor : .secondaryLabelColor
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: isActive ? .semibold : .regular),
                .foregroundColor: textColor.withAlphaComponent(alpha),
                .paragraphStyle: paragraph
            ]
            (chip.title as NSString).draw(in: chip.textRect, withAttributes: attributes)

            if chip.isDirty {
                let dot = NSRect(x: chip.textRect.maxX + gap + 1,
                                 y: chip.frame.midY - 2.5, width: 5, height: 5)
                NSColor.secondaryLabelColor.withAlphaComponent(0.8 * alpha).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }

            let closeColor: NSColor = (isHovered && hoveredClose) ? .labelColor : .secondaryLabelColor
            if let close = Self.symbol("xmark", size: 8, weight: .bold, color: closeColor) {
                let rect = NSRect(x: chip.closeRect.midX - 4,
                                  y: chip.closeRect.midY - 4,
                                  width: 8, height: 8)
                close.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            }
        }

        if let slot = insertionSlot {
            NSColor.controlAccentColor.setFill()
            let x = insertionX(slot)
            NSRect(x: x - 1, y: 3, width: 2, height: max(0, bounds.height - 6)).fill()
        }
    }

    private func insertionX(_ slot: Int) -> CGFloat {
        if chips.isEmpty { return leftPadding }
        if slot >= chips.count { return chips[chips.count - 1].frame.maxX + 1 }
        return chips[slot].frame.minX - 1
    }

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight,
                               color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    // MARK: - mouse

    /// Middle click closes the tab under the pointer.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        closeChip(at: convert(event.locationInWindow, from: nil))
    }

    func closeChip(at point: NSPoint) {
        guard let chip = chip(at: point) else { return }
        model.closeTab(chip.id)
    }

    override func mouseDown(with event: NSEvent) {
        endDragGhost()
        let point = convert(event.locationInWindow, from: nil)
        // Clicking anywhere outside the rename field commits it.
        if renameField != nil { window?.makeFirstResponder(nil) }
        guard let chip = chip(at: point) else {
            DispatchQueue.main.async { [weak model] in model?.editor.focus() }
            return
        }

        if chip.closeRect.contains(point) {
            model.closeTab(chip.id)
            return
        }

        if event.clickCount == 2 {
            model.selectTab(chip.id)
            if let tab = model.tabs.first(where: { $0.id == chip.id }) {
                model.beginRename(tab)
            }
            beginRename(chip.id)
            return
        }

        model.clickTab(chip.id)
        dragCandidateID = chip.id
        dragStart = point
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if dragID == nil, let id = dragCandidateID {
            guard hypot(point.x - dragStart.x, point.y - dragStart.y) >= 4 else { return }
            beginDragGhost(for: id)
            dragID = id
            startAutoscroll()
        }
        guard dragID != nil else { return }

        moveDragGhost(to: point)
        updateInsertion(at: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
        endDragGhost()
        let id = dragID
        let slot = insertionSlot
        dragID = nil
        dragCandidateID = nil
        insertionSlot = nil
        if let id, let slot {
            model.moveTab(id, to: slot)
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let chip = chip(at: point)
        let close = chip.map { $0.closeRect.contains(point) } ?? false
        if chip?.id != hoveredID || close != hoveredClose {
            hoveredID = chip?.id
            hoveredClose = close
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredID != nil else { return }
        hoveredID = nil
        hoveredClose = false
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        for chip in chips {
            addCursorRect(chip.closeRect, cursor: .pointingHand)
        }
    }

    // MARK: - drag reordering

    /// Snapshot of the tab under the cursor, shown semi-transparent while the
    /// tab is dragged. Captured before the chip is drawn faded.
    private func beginDragGhost(for id: UUID) {
        endDragGhost()
        guard let chip = chips.first(where: { $0.id == id }) else { return }
        let image = DragGhost.snapshot(of: self, rect: chip.frame)
        let grab = DragGhost.grabOffset(imageRect: chip.frame, grabPoint: dragStart, in: self)
        dragGhost = DragGhost(image: image, grab: grab)
        if let point = DragGhost.screenPoint(dragStart, in: self) {
            dragGhost?.show(at: point)
        }
    }

    private func moveDragGhost(to point: NSPoint) {
        guard let screen = DragGhost.screenPoint(point, in: self) else { return }
        dragGhost?.move(toScreen: screen)
    }

    private func endDragGhost() {
        dragGhost?.close()
        dragGhost = nil
    }

    private func updateInsertion(at point: NSPoint) {
        guard let id = dragID,
              let from = chips.firstIndex(where: { $0.id == id }) else {
            insertionSlot = nil
            return
        }
        var slot = chips.count
        for (index, chip) in chips.enumerated() where point.x < chip.frame.midX {
            slot = index
            break
        }
        // No marker where dropping would not change the order.
        insertionSlot = (slot == from || slot == from + 1) ? nil : slot
    }

    private func startAutoscroll() {
        stopAutoscroll()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.autoscrollTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        autoscrollTimer = timer
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    private func autoscrollTick() {
        guard dragID != nil, let window, let scrollView else {
            stopAutoscroll()
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let clip = scrollView.contentView
        let visible = clip.bounds
        let maxX = max(0, frame.width - visible.width)
        let edge: CGFloat = 30
        var delta: CGFloat = 0
        if point.x < visible.minX + edge {
            delta = -(visible.minX + edge - point.x) * 0.35
        } else if point.x > visible.maxX - edge {
            delta = (point.x - (visible.maxX - edge)) * 0.35
        }
        if delta != 0 {
            let clamped = min(18, max(-18, delta))
            var origin = visible.origin
            origin.x = min(max(0, origin.x + clamped), maxX)
            if origin.x != clip.bounds.origin.x {
                clip.scroll(to: origin)
                scrollView.reflectScrolledClipView(clip)
            }
        }
        moveDragGhost(to: point)
        updateInsertion(at: point)
        needsDisplay = true
    }

    private func scrollActiveIntoView() {
        guard let scrollView,
              let chip = chips.first(where: { $0.id == model.activeTabID }) else { return }
        let clip = scrollView.contentView
        let visible = clip.bounds
        let maxX = max(0, frame.width - visible.width)
        var origin = visible.origin
        if chip.frame.minX < visible.minX + 4 {
            origin.x = chip.frame.minX - 4
        } else if chip.frame.maxX > visible.maxX - 4 {
            origin.x = chip.frame.maxX - visible.width + 4
        } else {
            return
        }
        origin.x = min(max(0, origin.x), maxX)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - tooltips

    func tooltip(at point: NSPoint) -> String {
        guard let chip = chip(at: point),
              let tab = model.tabs.first(where: { $0.id == chip.id }) else { return "" }
        var parts: [String] = []
        if let path = tab.filePath {
            parts.append(L10n.fmt("Скрипт: %@", (path as NSString).lastPathComponent))
            if let folder = Self.shortFolder((path as NSString).deletingLastPathComponent) {
                parts.append(L10n.fmt("Папка: %@", folder))
            }
        } else {
            parts.append(L10n.fmt("Скрипт: %@", tab.title))
        }
        if let profile = model.profile(for: tab) {
            parts.append(L10n.fmt("Подключение: %@", profile.displayName))
            parts.append(L10n.fmt("Тип: %@", profile.kind.title))
            parts.append(L10n.fmt("URL: %@", profile.displayURL))
            if !profile.database.isEmpty {
                parts.append(L10n.fmt("База данных: %@", profile.database))
            }
            if let schema = model.resultSchema(for: tab), !schema.isEmpty {
                parts.append(L10n.fmt("Схема: %@", schema))
            }
        } else {
            parts.append(L10n.tr("Подключение: по выбору в дереве"))
        }
        return parts.joined(separator: "\n")
    }

    /// Keeps the tooltip on one line: home is shown as `~` and only the last
    /// two folders survive. The full path is still available in the context
    /// menu ("Показать в Finder").
    private static func shortFolder(_ path: String) -> String? {
        guard !path.isEmpty, path != "/" else { return nil }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        var rest = path
        var prefix = ""
        if rest.hasPrefix(home + "/") {
            rest = String(rest.dropFirst(home.count + 1))
            prefix = "~/"
        }
        let components = rest.split(separator: "/").map(String.init)
        if components.isEmpty { return nil }
        if components.count <= 2 { return prefix + components.joined(separator: "/") }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    // MARK: - inline rename

    private func beginRename(_ id: UUID) {
        guard editingTabID != id,
              let chip = chips.first(where: { $0.id == id }) else { return }
        endRenameField()
        editingTabID = id

        let field = NSTextField()
        field.stringValue = chip.title
        field.font = chipFont
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        addSubview(field)
        renameField = field
        positionRenameField(over: chip)

        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    private func positionRenameField(over chip: Chip) {
        guard let field = renameField else { return }
        let x = chip.textRect.minX - 4
        let width = max(90, chip.frame.maxX - x - 6)
        field.frame = NSRect(x: x, y: chip.textRect.minY - 2.5, width: width, height: 20)
    }

    private func endRenameField() {
        renameField?.removeFromSuperview()
        renameField = nil
        editingTabID = nil
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === renameField else { return }
        let movement = (notification.userInfo?["NSTextMovement"] as? Int)
            .flatMap(NSTextMovement.init(rawValue:))
        let id = editingTabID
        let value = field.stringValue
        endRenameField()
        guard let id else { return }
        if movement == .cancel {
            model.inlineRenameTabID = nil
            return
        }
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            model.inlineRenameTabID = nil
        } else {
            model.applyRename(id, title: title)
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAutoscroll()
            endRenameField()
        }
    }

    // MARK: - context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let chip = chip(at: point),
              let tab = model.tabs.first(where: { $0.id == chip.id }) else { return nil }
        model.selectTab(chip.id)

        let menu = NSMenu()
        menu.addItem(item("Переименовать…", "l", .command, #selector(renameTab(_:)), tab.id))
        menu.addItem(item("Дублировать", "d", .command, #selector(duplicateTab(_:)), tab.id))
        menu.addItem(.separator())
        menu.addItem(item("Сохранить", "s", .command, #selector(saveTab(_:)), tab.id))
        menu.addItem(item("Сохранить как…", "s", [.command, .shift], #selector(saveTabAs(_:)), tab.id))
        if tab.filePath != nil {
            menu.addItem(item("Показать в Finder", "r", [.command, .shift], #selector(revealTab(_:)), tab.id))
        }
        menu.addItem(.separator())
        menu.addItem(item("Закрыть", "w", .command, #selector(closeTab(_:)), tab.id))
        menu.addItem(item("Закрыть остальные", "", [], #selector(closeOtherTabs(_:)), tab.id))
        return menu
    }

    private func item(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags,
                      _ action: Selector, _ id: UUID) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.tr(title), action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.representedObject = id
        return item
    }

    private func tabID(_ sender: NSMenuItem) -> UUID? {
        sender.representedObject as? UUID
    }

    @objc private func renameTab(_ sender: NSMenuItem) {
        guard let id = tabID(sender),
              let tab = model.tabs.first(where: { $0.id == id }) else { return }
        model.beginRename(tab)
    }

    @objc private func duplicateTab(_ sender: NSMenuItem) {
        guard let id = tabID(sender) else { return }
        model.duplicateTab(id)
    }

    @objc private func saveTab(_ sender: NSMenuItem) {
        guard let id = tabID(sender) else { return }
        _ = model.saveTab(id)
    }

    @objc private func saveTabAs(_ sender: NSMenuItem) {
        guard let id = tabID(sender) else { return }
        _ = model.saveTabAs(id)
    }

    @objc private func revealTab(_ sender: NSMenuItem) {
        guard let id = tabID(sender),
              let path = model.tabs.first(where: { $0.id == id })?.filePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func closeTab(_ sender: NSMenuItem) {
        guard let id = tabID(sender) else { return }
        model.closeTab(id)
    }

    @objc private func closeOtherTabs(_ sender: NSMenuItem) {
        guard let id = tabID(sender) else { return }
        model.closeOtherTabs(id)
    }
}
