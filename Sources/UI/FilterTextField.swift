import SwiftUI
import AppKit

/// The single-line result filter. It is an `NSTextField` rather than a
/// SwiftUI `TextField` so the caret position is available for suggestions and
/// Up/Down/Enter/Tab can be routed to the suggestion list without moving the
/// keyboard focus out of the field.
struct FilterTextField: NSViewRepresentable {
    @Binding var text: String
    var columns: [String]
    var numericColumns: Set<String>
    var values: (String) -> [String]
    var placeholder: String
    var help: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.placeholderString = placeholder
        field.appTooltipText = help
        field.stringValue = text
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.appTooltipText = help
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
        if field.stringValue != text {
            field.stringValue = text
            context.coordinator.hideSuggestions()
        }
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.hideSuggestions()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FilterTextField
        weak var field: NSTextField?
        private let popup = SQLCompletionPopup()
        private var context: ResultFilter.SuggestionContext?

        init(_ parent: FilterTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            refreshSuggestions()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field else { return }
            parent.text = field.stringValue
            refreshSuggestions()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            hideSuggestions()
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            guard popup.isVisible else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                popup.moveSelection(by: 1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                popup.moveSelection(by: -1)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)):
                commitSelected()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                hideSuggestions()
                return true
            default:
                return false
            }
        }

        // MARK: - suggestions

        private func refreshSuggestions() {
            guard let field, let editor = field.currentEditor() as? NSTextView,
                  field.window?.firstResponder === editor else {
                hideSuggestions()
                return
            }
            let text = field.stringValue
            let caret = editor.selectedRange.location
            guard let context = ResultFilter.suggestionContext(
                in: text as NSString, caret: caret, columns: parent.columns
            ) else {
                hideSuggestions()
                return
            }

            let candidates: [String]
            switch context.kind {
            case .columns:
                candidates = parent.columns
            case .operators:
                candidates = ResultFilter.operatorSuggestions
            case .values(let column):
                candidates = parent.values(column)
            }
            let filtered = SQLCompletion.filter(candidates, prefix: context.prefix)
            guard !filtered.isEmpty, let point = caretPoint(for: field, editor: editor) else {
                hideSuggestions()
                return
            }

            self.context = context
            popup.onCommit = { [weak self] item in self?.insert(item) }
            popup.show(items: filtered, at: point)
        }

        private func commitSelected() {
            guard let item = popup.selectedItem else {
                hideSuggestions()
                return
            }
            insert(item)
        }

        private func insert(_ item: String) {
            guard let field, let context else {
                hideSuggestions()
                return
            }
            let replacement: String
            if case .values(let column) = context.kind {
                replacement = literal(item, column: column)
            } else {
                replacement = item
            }
            let current = field.stringValue as NSString
            guard context.range.location >= 0,
                  NSMaxRange(context.range) <= current.length else {
                hideSuggestions()
                return
            }
            let updated = current.replacingCharacters(in: context.range, with: replacement)
            field.stringValue = updated
            parent.text = updated
            let caret = context.range.location + (replacement as NSString).length
            if let editor = field.currentEditor() as? NSTextView {
                editor.selectedRange = NSRange(location: caret, length: 0)
            }
            hideSuggestions()
        }

        /// Text values are quoted as SQL literals; numeric values are inserted
        /// as typed so `> 10` and similar conditions keep working.
        private func literal(_ value: String, column: String) -> String {
            let numeric = parent.numericColumns.contains(column.lowercased())
            if numeric, NumericText.isNumeric(value) {
                return value
            }
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }

        func hideSuggestions() {
            context = nil
            popup.hide()
        }

        /// Bottom-left corner of the caret in screen coordinates.
        private func caretPoint(for field: NSTextField, editor: NSTextView) -> NSPoint? {
            guard let window = field.window else { return nil }
            let caret = editor.selectedRange().location
            var rect = editor.firstRect(
                forCharacterRange: NSRange(location: caret, length: 0),
                actualRange: nil
            )
            if !rect.origin.x.isFinite || !rect.origin.y.isFinite || rect.isNull {
                let inWindow = field.convert(field.bounds, to: nil)
                rect = window.convertToScreen(inWindow)
            }
            return NSPoint(x: rect.minX, y: rect.minY)
        }
    }
}
