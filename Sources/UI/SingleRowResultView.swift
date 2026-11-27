import SwiftUI
import AppKit

/// Vertical view of one result row: column names on the left, values on the
/// right. Opened with Tab in the grid or the "Результат (Tab)" button in the
/// status bar; Tab again returns to the normal grid.
struct SingleRowResultView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.displayedRowCount == 0 {
                Text(L10n.tr("Нет строк для показа"))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // One text surface for the whole row, so a drag selects across
                // columns and ⌘A selects everything. It is read-only, so Tab
                // still returns to the grid.
                SingleRowText(items: model.singleRowItems(),
                              exportCSV: model.exportCSV,
                              exportXML: model.exportXML,
                              exportXLSX: model.exportXLSX)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .background(TabKeyCatcher { model.toggleSingleRowResult() })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                model.toggleSingleRowResult()
            } label: {
                Label(L10n.tr("Результат"), systemImage: "tablecells")
            }
            .buttonStyle(.borderless)
            .appToolTip(L10n.tr("Вернуться к таблице результатов (Tab)"))
            Divider().frame(height: 14)
            Text(L10n.fmt("Строка №%@", String(model.singleRowDisplayIndex + 1)))
                .font(.system(size: 12, weight: .semibold))
            Text(L10n.fmt("из %@", String(model.displayedRowCount)))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(L10n.tr("Tab — вернуться к таблице"))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

}

/// Whole row as one selectable, read-only text view. Column names sit in a
/// 220 pt column via a tab stop; long values wrap under that column. Native
/// text selection gives drag selection across lines, ⌘A and ⌘C for free.
private struct SingleRowText: NSViewRepresentable {
    let items: [SingleRowItem]
    let exportCSV: () -> Void
    let exportXML: () -> Void
    let exportXLSX: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let view = SingleRowTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 10, height: 8)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.exportCSV = exportCSV
        view.exportXML = exportXML
        view.exportXLSX = exportXLSX
        scroll.documentView = view

        apply(to: view, in: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? SingleRowTextView else { return }
        view.exportCSV = exportCSV
        view.exportXML = exportXML
        view.exportXLSX = exportXLSX
        apply(to: view, in: scroll)
    }

    private func apply(to view: NSTextView, in scroll: NSScrollView) {
        let content = attributedText
        if !view.attributedString().isEqual(to: content) {
            let selected = view.selectedRange()
            view.textStorage?.setAttributedString(content)
            if selected.length > 0, NSMaxRange(selected) <= content.length {
                view.setSelectedRange(selected)
            }
        }
        fit(view, in: scroll)
    }

    private var attributedText: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 220, options: [:])]
        paragraph.headIndent = 220
        paragraph.firstLineHeadIndent = 0
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 4

        let result = NSMutableAttributedString()
        let nameFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let valueFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for (index, item) in items.enumerated() {
            result.append(NSAttributedString(
                string: item.title,
                attributes: [.font: nameFont,
                             .foregroundColor: NSColor.secondaryLabelColor,
                             .paragraphStyle: paragraph]
            ))
            result.append(NSAttributedString(
                string: "\t",
                attributes: [.font: nameFont, .paragraphStyle: paragraph]
            ))
            result.append(NSAttributedString(
                string: item.value ?? "NULL",
                attributes: [.font: valueFont,
                             .foregroundColor: item.value == nil
                                 ? NSColor.tertiaryLabelColor
                                 : NSColor.labelColor,
                             .paragraphStyle: paragraph]
            ))
            if index < items.count - 1 {
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: [.font: valueFont, .paragraphStyle: paragraph]
                ))
            }
        }
        return result
    }

    /// Sizes the document view to the text, wrapping at the pane width.
    private func fit(_ view: NSTextView, in scroll: NSScrollView) {
        guard let container = view.textContainer,
              let layout = view.layoutManager else { return }
        let viewport = scroll.contentSize
        let inset = view.textContainerInset
        let width = max(viewport.width, 1)
        container.containerSize = NSSize(width: max(width - inset.width * 2, 1),
                                         height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let frame = NSRect(x: 0, y: 0,
                           width: width,
                           height: max(used.height + inset.height * 2, viewport.height))
        if view.frame != frame { view.frame = frame }
    }
}

/// Read-only text view with the same word/literal selection rules as the value
/// panel, so double and triple clicks behave consistently across the app.
private final class SingleRowTextView: NSTextView {
    private var claimedFocus = false
    var exportCSV: (() -> Void)?
    var exportXML: (() -> Void)?
    var exportXLSX: (() -> Void)?

    /// Takes the keyboard as soon as the view is on screen, so ⌘A and ⌘C work
    /// immediately after Tab, without a click. The view is read-only, so this
    /// never blocks typing in the editor or in the result search field.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !claimedFocus else { return }
        claimedFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if let field = window.firstResponder as? NSTextField, field.isEditable { return }
            window.makeFirstResponder(self)
        }
    }

    /// Standard text menu (Copy, Select All) plus the same export entries the
    /// grid offers, so a row can be exported without leaving this view.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let exportTitle = L10n.tr("Экспорт")
        guard !menu.items.contains(where: { $0.title == exportTitle && $0.submenu != nil })
        else { return menu }
        let export = NSMenuItem(title: exportTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let entries: [(String, Selector)] = [
            ("CSV…", #selector(exportCSVAction(_:))),
            ("XML…", #selector(exportXMLAction(_:))),
            ("XLSX…", #selector(exportXLSXAction(_:))),
        ]
        for (title, action) in entries {
            let item = NSMenuItem(title: L10n.tr(title), action: action, keyEquivalent: "")
            item.target = self
            submenu.addItem(item)
        }
        export.submenu = submenu
        menu.addItem(.separator())
        menu.addItem(export)
        return menu
    }

    @objc private func exportCSVAction(_ sender: Any?) { exportCSV?() }
    @objc private func exportXMLAction(_ sender: Any?) { exportXML?() }
    @objc private func exportXLSXAction(_ sender: Any?) { exportXLSX?() }

    override func selectionRange(forProposedRange range: NSRange,
                                 granularity: NSSelectionGranularity) -> NSRange {
        if granularity == .selectByWord,
           let word = TextSelectionRules.wordRange(in: string as NSString, at: range.location) {
            return word
        }
        if granularity == .selectByParagraph,
           let inner = TextSelectionRules.literalContentsRange(in: string as NSString,
                                                               at: range.location) {
            return inner
        }
        return super.selectionRange(forProposedRange: range, granularity: granularity)
    }
}

/// Local Tab monitor used only while the vertical single-row view is on screen.
/// It ignores Tab while a text field has focus, so the search field still works.
private struct TabKeyCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
        context.coordinator.install(on: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        var action: () -> Void
        private var monitor: Any?
        private weak var view: NSView?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func install(on view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let view = self.view, view.window != nil,
                      event.keyCode == 48,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                      NSApp.keyWindow?.attachedSheet == nil else { return event }
                let responder = view.window?.firstResponder
                // Editable fields (the result search) keep Tab for focus moves;
                // the read-only text selection in the row view does not.
                if let textView = responder as? NSTextView, textView.isEditable { return event }
                if let textField = responder as? NSTextField, textField.isEditable { return event }
                self.action()
                return nil
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            remove()
        }
    }
}
