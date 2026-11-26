import SwiftUI
import AppKit

final class SQLTextView: NSTextView {
    var onCommandEnter: (() -> Void)?
    /// Cmd+/ toggles `--` comments on the caret line or selected lines.
    var onToggleComment: (() -> Void)?
    /// Cmd+Shift+/ toggles comments on every line ending with the marker.
    var onToggleMarkedComment: (() -> Void)?
    /// Called with a number of font-size steps when Ctrl + mouse wheel / trackpad is used.
    var onZoom: ((CGFloat) -> Void)?
    /// Called when the editor becomes the first responder.
    var onFocus: (() -> Void)?
    private var zoomAccumulator: CGFloat = 0
    private var magnifyAccumulator: CGFloat = 0

    /// Horizontal position kept while moving the caret up and down. NSTextView
    /// drops it after passing a shorter line, so it is tracked here instead.
    private var desiredColumnX: CGFloat?
    /// Fixed end of a Shift+Up/Down selection.
    private var verticalShiftAnchor: Int?
    private var verticalShiftHeld = false
    /// Guards selection changes made by this class from resetting the column.
    private var isVerticalMove = false

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocus?()
            NotificationCenter.default.post(name: .editorDidTakeFocus, object: self)
        }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command), !mods.contains(.option), !mods.contains(.control) {
            if event.keyCode == 36 || event.keyCode == 76 {
                onCommandEnter?()
                return
            }
            // The bindings are checked through the store, so both shortcuts
            // follow the user's keys and work in every keyboard layout.
            if ShortcutStore.shared.matches(event, action: .toggleComment) {
                onToggleComment?()
                return
            }
            if ShortcutStore.shared.matches(event, action: .toggleMarkedComment) {
                onToggleMarkedComment?()
                return
            }
        }
        // Up/Down keep the remembered column; any other key starts a new one.
        if event.keyCode == 126 || event.keyCode == 125 {
            verticalShiftHeld = event.modifierFlags.contains(.shift)
        } else {
            desiredColumnX = nil
            verticalShiftAnchor = nil
        }
        super.keyDown(with: event)
    }

    override func setSelectedRange(_ charRange: NSRange) {
        if !isVerticalMove {
            desiredColumnX = nil
            verticalShiftAnchor = nil
        }
        super.setSelectedRange(charRange)
    }

    override func moveUp(_ sender: Any?) {
        moveVertically(up: true, sender: sender)
    }

    override func moveDown(_ sender: Any?) {
        moveVertically(up: false, sender: sender)
    }

    /// Moves the caret one visual line while keeping the horizontal position
    /// (the same column when the target line is long enough).
    private func moveVertically(up: Bool, sender: Any?) {
        guard let lm = layoutManager, let tc = textContainer, lm.numberOfGlyphs > 0 else {
            if up { super.moveUp(sender) } else { super.moveDown(sender) }
            return
        }

        let ns = string as NSString
        let shift = verticalShiftHeld || (NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
        let selection = selectedRange()

        // A selection collapses to its leading edge first, like a plain caret.
        if !shift, selection.length > 0 {
            let location = up ? selection.location : NSMaxRange(selection)
            isVerticalMove = true
            setSelectedRange(NSRange(location: location, length: 0))
            isVerticalMove = false
            scrollRangeToVisible(selectedRange())
            return
        }

        var anchor: Int?
        var head = selection.location
        if shift {
            if let fixed = verticalShiftAnchor {
                anchor = fixed
                head = fixed == selection.location ? NSMaxRange(selection) : selection.location
            } else {
                anchor = up ? NSMaxRange(selection) : selection.location
                verticalShiftAnchor = anchor
                head = up ? selection.location : NSMaxRange(selection)
            }
        }
        head = min(max(head, 0), ns.length)

        if desiredColumnX == nil {
            let glyph = lm.glyphIndexForCharacter(at: min(head, max(0, ns.length - 1)))
            desiredColumnX = caretX(location: head, glyphIndex: glyph, in: tc)
        }
        let x = desiredColumnX ?? 0

        var currentGlyphs = NSRange()
        let currentGlyph = lm.glyphIndexForCharacter(at: min(head, max(0, ns.length - 1)))
        _ = lm.lineFragmentRect(forGlyphAt: currentGlyph, effectiveRange: &currentGlyphs)

        var destination: Int
        if up {
            if currentGlyphs.location == 0 {
                destination = 0
            } else {
                let previousGlyph = currentGlyphs.location - 1
                var previousGlyphs = NSRange()
                let rect = lm.lineFragmentRect(forGlyphAt: previousGlyph,
                                               effectiveRange: &previousGlyphs)
                destination = characterIndex(at: x, y: rect.midY, glyphs: previousGlyphs,
                                             layoutManager: lm, container: tc)
            }
        } else {
            if NSMaxRange(currentGlyphs) >= lm.numberOfGlyphs {
                destination = ns.length
            } else {
                let nextGlyph = NSMaxRange(currentGlyphs)
                var nextGlyphs = NSRange()
                let rect = lm.lineFragmentRect(forGlyphAt: nextGlyph,
                                               effectiveRange: &nextGlyphs)
                destination = characterIndex(at: x, y: rect.midY, glyphs: nextGlyphs,
                                             layoutManager: lm, container: tc)
            }
        }
        destination = min(max(destination, 0), ns.length)

        isVerticalMove = true
        if shift, let anchor {
            let range = NSRange(location: min(anchor, destination),
                                length: abs(anchor - destination))
            setSelectedRange(range)
        } else {
            verticalShiftAnchor = nil
            setSelectedRange(NSRange(location: destination, length: 0))
        }
        isVerticalMove = false
        scrollRangeToVisible(selectedRange())
    }

    /// Horizontal caret position in text-container coordinates.
    private func caretX(location: Int, glyphIndex: Int, in container: NSTextContainer) -> CGFloat {
        guard let lm = layoutManager, lm.numberOfGlyphs > 0 else { return 0 }
        let ns = string as NSString
        if location >= ns.length {
            if location == 0 { return 0 }
            let previous = ns.character(at: location - 1)
            if previous == 10 || previous == 13 { return 0 }
            let glyph = lm.glyphIndexForCharacter(at: location - 1)
            return lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                   in: container).maxX
        }
        let character = ns.character(at: location)
        if character == 10 || character == 13 {
            if location == 0 { return 0 }
            let previous = ns.character(at: location - 1)
            if previous == 10 || previous == 13 { return 0 }
            let glyph = lm.glyphIndexForCharacter(at: location - 1)
            return lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                   in: container).maxX
        }
        return lm.location(forGlyphAt: glyphIndex).x
    }

    /// Character index in the given line fragment closest to the wanted x.
    private func characterIndex(at x: CGFloat, y: CGFloat, glyphs: NSRange,
                                layoutManager lm: NSLayoutManager,
                                container: NSTextContainer) -> Int {
        let index = lm.characterIndex(for: NSPoint(x: x, y: y), in: container,
                                      fractionOfDistanceBetweenInsertionPoints: nil)
        let characters = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let ns = string as NSString
        var upper = NSMaxRange(characters)
        // Never step past a line break: the caret at the end of a short line
        // belongs before the newline, not at the start of the next line.
        if upper > characters.location, upper <= ns.length {
            let last = ns.character(at: upper - 1)
            if last == 10 || last == 13 { upper -= 1 }
        }
        return min(max(index, characters.location), max(characters.location, upper))
    }

    /// Bracket pairs completed automatically. Typing an opening bracket inserts
    /// the closing one and keeps the caret between them; typing a closing
    /// bracket that is already right after the caret moves over it instead of
    /// inserting a duplicate.
    private static let bracketPairs: [String: String] = ["(": ")", "[": "]", "{": "}"]
    private static let closingBrackets: Set<String> = [")", "]", "}"]

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? String)
            ?? (insertString as? NSAttributedString)?.string
            ?? ""
        let range = replacementRange.location == NSNotFound
            ? selectedRange()
            : replacementRange

        desiredColumnX = nil
        verticalShiftAnchor = nil

        // Only a single typed character at a caret can be paired.
        guard range.length == 0, text.utf16.count == 1, let typed = text.utf16.first else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        let s = string as NSString
        let caret = range.location
        let next = caret < s.length ? s.character(at: caret) : 0

        // The matching closer is already there: step over it.
        if Self.closingBrackets.contains(text), next == typed {
            setSelectedRange(NSRange(location: caret + 1, length: 0))
            return
        }

        if let closer = Self.bracketPairs[text], let closing = closer.utf16.first {
            if next == closing {
                setSelectedRange(NSRange(location: caret + 1, length: 0))
                return
            }
            super.insertText(text + closer, replacementRange: range)
            setSelectedRange(NSRange(location: caret + 1, length: 0))
            return
        }

        super.insertText(insertString, replacementRange: replacementRange)
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

    /// Trackpad pinch: positive magnification means zoom in.
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

    override func mouseDown(with event: NSEvent) {
        // AppKit's triple-click does not call selectionRange(forProposedRange:)
        // with .selectByParagraph; it jumps straight to the paragraph. Use the
        // caret/word placed by the previous click and select the literal instead.
        if event.clickCount == 3,
           let inner = literalContentsRange(at: selectedRange().location) {
            window?.makeFirstResponder(self)
            setSelectedRange(inner)
            return
        }
        desiredColumnX = nil
        verticalShiftAnchor = nil
        super.mouseDown(with: event)
    }

    override func selectParagraph(_ sender: Any?) {
        let location = selectedRange().location
        if let inner = literalContentsRange(at: location) {
            setSelectedRange(inner)
            return
        }
        super.selectParagraph(sender)
    }

    override func selectionRange(forProposedRange range: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        // Double click selects one word; `-` is a separator, so `a-b` gives
        // either `a` or `b` rather than the whole run.
        if granularity == .selectByWord, let word = wordRange(at: range.location) {
            return word
        }
        // Triple click keeps the old convenience: the contents of a quoted
        // literal, or of the innermost parentheses when not inside quotes.
        if granularity == .selectByParagraph,
           let inner = literalContentsRange(at: range.location) {
            return inner
        }
        return super.selectionRange(forProposedRange: range, granularity: granularity)
    }

    private func wordRange(at location: Int) -> NSRange? {
        TextSelectionRules.wordRange(in: string as NSString, at: location)
    }

    private func quotedContentsRange(at location: Int) -> NSRange? {
        TextSelectionRules.quotedContentsRange(in: string as NSString, at: location)
    }

    /// Triple-click target: quoted contents (without LIKE mask characters when
    /// the literal is a LIKE/ILIKE pattern, and without `%` wildcards), the
    /// innermost parentheses, or the text between `%` delimiters.
    private func literalContentsRange(at location: Int) -> NSRange? {
        let ns = string as NSString
        if let quoted = quotedContentsRange(at: location) {
            let maskTrimmed = SQLText.maskTrimmedRange(quoted, in: string)
            return TextSelectionRules.trimmingPercent(maskTrimmed, in: ns)
        }
        if let paren = parenContentsRange(at: location) {
            return TextSelectionRules.trimmingPercent(paren, in: ns)
        }
        return TextSelectionRules.percentContentsRange(in: ns, at: location)
    }

    private func parenContentsRange(at location: Int) -> NSRange? {
        TextSelectionRules.parenContentsRange(in: string as NSString, at: location)
    }
}

struct SQLEditorView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        let tv = SQLTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 12, height: 12)

        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.font = SQLHighlighter.currentFont
        tv.textColor = .labelColor
        tv.insertionPointColor = .labelColor
        tv.backgroundColor = .textBackgroundColor
        tv.drawsBackground = true

        tv.onCommandEnter = { [weak model] in
            model?.runSelectionOrAll()
        }
        tv.onZoom = { [weak model] steps in
            model?.stepEditorFontSize(steps)
        }
        tv.onToggleComment = { [weak model] in
            model?.editor.toggleComment()
        }
        tv.onToggleMarkedComment = { [weak model] in
            guard let model, model.commentByMarker else { return }
            model.editor.toggleMarkedComment(marker: model.commentMarker)
        }
        tv.onFocus = { [weak model] in
            model?.focusedPane = .editor
            model?.applySmartSelection()
        }

        scroll.documentView = tv
        context.coordinator.textView = tv
        model.editor.textView = tv

        context.coordinator.loadedTabID = model.activeTabID
        model.editor.displayedTabID = model.activeTabID
        tv.string = model.activeTab?.text ?? AppModel.welcomeText
        if let storage = tv.textStorage {
            SQLHighlighter.apply(to: storage)
        }
        let saved = model.activeTab
        let limit = tv.string.utf16.count
        let location = min(saved?.selectionLocation ?? 0, limit)
        let length = min(saved?.selectionLength ?? 0, limit - location)
        tv.setSelectedRange(NSRange(location: location, length: length))
        // Delegate is attached after the initial selection so that setup does
        // not publish model changes in the middle of a SwiftUI view update.
        tv.delegate = context.coordinator
        DispatchQueue.main.async { [weak model] in
            guard let model else { return }
            model.editor.hasSelection = length > 0
            model.updateCaret(location: location, in: tv.string)
        }

        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.syncTabIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: AppModel
        weak var textView: NSTextView?
        var loadedTabID: UUID?
        private var pending: DispatchWorkItem?
        /// True while the editor is being populated programmatically, so the
        /// delegate does not publish model changes during a SwiftUI update.
        private var isSyncing = false

        init(model: AppModel) {
            self.model = model
        }

        func syncTabIfNeeded() {
            guard loadedTabID != model.activeTabID, let tv = textView else { return }
            loadedTabID = model.activeTabID
            model.editor.displayedTabID = model.activeTabID
            let tab = model.activeTab
            isSyncing = true
            tv.string = tab?.text ?? ""
            if let storage = tv.textStorage {
                SQLHighlighter.apply(to: storage)
            }
            let limit = tv.string.utf16.count
            let location = min(tab?.selectionLocation ?? 0, limit)
            let length = min(tab?.selectionLength ?? 0, limit - location)
            tv.setSelectedRange(NSRange(location: location, length: length))
            tv.undoManager?.removeAllActions()
            tv.scrollRangeToVisible(tv.selectedRange())
            isSyncing = false

            // Switching tabs keeps the editor focused, so there is no focus
            // event to hook smart selection to; apply it after the new text is
            // in place instead.
            model.applySmartSelection()

            let text = tv.string
            DispatchQueue.main.async { [weak model] in
                guard let model else { return }
                model.editor.hasSelection = length > 0
                model.updateCaret(location: location, in: text)
                if model.showEditorSearch {
                    model.applyEditorSearch()
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isSyncing, let tv = notification.object as? NSTextView else { return }
            model.editor.text = tv.string
            model.editor.hasSelection = tv.selectedRange().length > 0
            model.updateCaret(location: tv.selectedRange().location, in: tv.string)
            model.editorTextChanged(tv.string)
            scheduleHighlight(tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isSyncing, let tv = notification.object as? NSTextView else { return }
            model.editor.hasSelection = tv.selectedRange().length > 0
            model.updateCaret(location: tv.selectedRange().location, in: tv.string)
        }

        private func scheduleHighlight(_ tv: NSTextView) {
            pending?.cancel()
            let work = DispatchWorkItem { [weak tv] in
                guard let tv, let storage = tv.textStorage else { return }
                let selection = tv.selectedRange()
                SQLHighlighter.apply(to: storage)
                tv.setSelectedRange(selection)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        }
    }
}
