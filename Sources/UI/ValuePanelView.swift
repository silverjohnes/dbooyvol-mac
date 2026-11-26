import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// DBeaver-style "Value" inspector for the cell selected in the result grid.
/// The kind is detected from the content (JSON, XML, binary) and can be
/// overridden from the gear menu.
struct ValuePanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var saveMessage: String?

    private var item: ValuePanelItem? { model.valuePanelItem }
    private var effectiveKind: ValueViewKind {
        model.valuePanelKind == .auto
            ? ValueViewKind.detect(item?.value)
            : model.valuePanelKind
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: 240, idealWidth: 340, maxWidth: 620)
    }

    private var header: some View {
        HStack(spacing: 6) {
            settingsMenu
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundColor(.secondary)
            Text("Значение")
                .font(.system(size: 12, weight: .semibold))
            if let item {
                Text("· \(item.columnName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                model.showValuePanel = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .appToolTip("Закрыть панель значения")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var settingsMenu: some View {
        Menu {
            ForEach([ValueViewKind.auto, .binary, .json, .text, .xml]) { kind in
                Toggle(kind.title, isOn: Binding(
                    get: { model.valuePanelKind == kind },
                    set: { on in if on { model.valuePanelKind = kind } }
                ))
            }
            Divider()
            Toggle("Перенос строк", isOn: $model.valuePanelWordWrap)
            Toggle("Автоформат", isOn: $model.valuePanelAutoFormat)
            Toggle("Сохранять сжатое значение", isOn: $model.valuePanelCompact)
            Menu("Кодировка…") {
                ForEach(Self.encodings, id: \.encoding.rawValue) { entry in
                    Toggle(entry.name, isOn: Binding(
                        get: { model.valuePanelEncoding == entry.encoding },
                        set: { on in if on { model.valuePanelEncoding = entry.encoding } }
                    ))
                }
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .appToolTip("Тип данных, перенос строк, форматирование и кодировка")
    }

    @ViewBuilder
    private var content: some View {
        if let item {
            let text = displayText(for: item)
            ValueText(content: Self.attributed(text, kind: effectiveKind),
                      wrap: model.valuePanelWordWrap)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "cursorarrow.click.2")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
                Text("Выберите ячейку и нажмите «Значение»")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let item {
                HStack(spacing: 4) {
                    Text(L10n.tr("Строка") + " \(item.rowNumber) · \(item.columnType)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Button {
                        copyToPasteboard(item.columnType)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(item.columnType.isEmpty)
                    .appToolTip("Скопировать тип данных")
                }
                if let saveMessage {
                    Text(saveMessage)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("Копировать") {
                guard let item else { return }
                copyToPasteboard(displayText(for: item))
            }
            .controlSize(.small)
            .disabled(item == nil)
            .appToolTip("Скопировать показанное значение")

            Button("Сохранить…") {
                save()
            }
            .controlSize(.small)
            .disabled(item == nil)
            .appToolTip("Сохранить значение в файл")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    // MARK: - rendering

    private func displayText(for item: ValuePanelItem) -> String {
        guard let value = item.value else { return "NULL" }
        switch effectiveKind {
        case .json:
            guard model.valuePanelAutoFormat else { return value }
            return Self.prettyJSON(value) ?? value
        case .xml:
            guard model.valuePanelAutoFormat else { return value }
            return Self.prettyXML(value)
        case .binary:
            return Self.hexDump(Self.binaryData(value), encoding: model.valuePanelEncoding)
        case .text, .auto:
            return TimestampDisplay.formatted(value, columnType: item.columnType) ?? value
        }
    }

    /// The value text with the monospaced font applied, ready for the text
    /// view. Selection and copy work on this exact string.
    private static func attributed(_ text: String, kind: ValueViewKind) -> NSAttributedString {
        let result = NSMutableAttributedString(
            attributedString: NSAttributedString(highlighted(text, kind: kind))
        )
        if result.length > 0 {
            result.addAttribute(.font,
                                value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    /// JSON colours: keys, strings, numbers, literals and punctuation. Only
    /// the JSON view is highlighted; other kinds stay plain.
    private static func highlighted(_ text: String, kind: ValueViewKind) -> AttributedString {
        let plain = Color(nsColor: .labelColor)
        guard kind == .json else {
            var result = AttributedString(text)
            result.foregroundColor = plain
            return result
        }
        let keyColor = Color(nsColor: .systemPurple)
        let stringColor = Color(nsColor: .systemRed)
        let numberColor = Color(nsColor: .systemBlue)
        let literalColor = Color(nsColor: .systemTeal)
        let punctuation = Color(nsColor: .secondaryLabelColor)

        var result = AttributedString()
        func append(_ slice: Substring, _ color: Color?) {
            var piece = AttributedString(String(slice))
            piece.foregroundColor = color ?? plain
            result.append(piece)
        }

        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" {
                var j = text.index(after: i)
                var escaped = false
                while j < text.endIndex {
                    let ch = text[j]
                    if escaped { escaped = false }
                    else if ch == "\\" { escaped = true }
                    else if ch == "\"" { j = text.index(after: j); break }
                    j = text.index(after: j)
                }
                var k = j
                while k < text.endIndex, text[k] == " " || text[k] == "\t" {
                    k = text.index(after: k)
                }
                let isKey = k < text.endIndex && text[k] == ":"
                append(text[i..<j], isKey ? keyColor : stringColor)
                i = j
            } else if c.isNumber {
                var j = i
                while j < text.endIndex, "0123456789.eE+-".contains(text[j]) {
                    j = text.index(after: j)
                }
                append(text[i..<j], numberColor)
                i = j
            } else if c.isLetter {
                var j = i
                while j < text.endIndex, text[j].isLetter { j = text.index(after: j) }
                append(text[i..<j], literalColor)
                i = j
            } else if "{}[],:".contains(c) {
                append(text[i...i], punctuation)
                i = text.index(after: i)
            } else {
                append(text[i...i], nil)
                i = text.index(after: i)
            }
        }
        return result
    }

    private static func binaryData(_ value: String) -> Data {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: trimmed) { return data }
        return Data(value.utf8)
    }

    private static func hexDump(_ data: Data, encoding: String.Encoding) -> String {
        guard !data.isEmpty else { return "" }
        let bytes = [UInt8](data.prefix(200_000))
        var lines: [String] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 16, bytes.count)
            let chunk = bytes[offset..<end]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let padded = hex.padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
            let ascii = chunk.map { byte -> Character in
                (byte >= 32 && byte < 127) ? Character(UnicodeScalar(byte)) : "."
            }
            lines.append(String(format: "%08x  ", offset) + padded + "  |" + String(ascii) + "|")
            offset = end
        }
        if let decoded = String(data: data, encoding: encoding), !decoded.isEmpty {
            lines.append("")
            lines.append(L10n.fmt("— текст (%@) —", name(of: encoding)))
            lines.append(decoded)
        }
        return lines.joined(separator: "\n")
    }

    private static func prettyJSON(_ value: String) -> String? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .withoutEscapingSlashes]
              ) else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    /// Minimal XML indenter: breaks between tags and tracks nesting. Text
    /// nodes and attributes stay on their line.
    private static func prettyXML(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: "><", with: ">\n<")
        var depth = 0
        var lines: [String] = []
        for raw in compact.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("</") { depth = max(0, depth - 1) }
            lines.append(String(repeating: "  ", count: depth) + line)
            let opens = line.hasPrefix("<") && !line.hasPrefix("</")
                && !line.hasPrefix("<?") && !line.hasPrefix("<!") && !line.hasSuffix("/>")
            let closes = line.contains("</")
            if opens && !closes { depth += 1 }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - saving

    private func save() {
        guard let item else { return }
        var text = displayText(for: item)
        if model.valuePanelCompact {
            switch effectiveKind {
            case .json:
                if let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data),
                   let compact = try? JSONSerialization.data(withJSONObject: object),
                   let string = String(data: compact, encoding: .utf8) {
                    text = string
                }
            case .xml:
                text = text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined()
            default:
                break
            }
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(item.columnName)-\(item.rowNumber).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            saveMessage = L10n.tr("Сохранено")
        } catch {
            saveMessage = L10n.fmt("Ошибка: %@", error.localizedDescription)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if saveMessage == L10n.tr("Сохранено") { saveMessage = nil }
        }
    }

    // MARK: - encodings

    private static let encodings: [(name: String, encoding: String.Encoding)] = [
        ("UTF-8", .utf8),
        ("UTF-16", .utf16),
        ("Windows-1251", .windowsCP1251),
        ("ISO Latin-1", .isoLatin1),
        ("macOS Roman", .macOSRoman)
    ]

    private static func name(of encoding: String.Encoding) -> String {
        encodings.first { $0.encoding == encoding }?.name ?? "UTF-8"
    }
}


/// Selectable, non-editable text view with the same double/triple click rules
/// as the SQL editor: a word on double click, the contents of a quoted literal
/// or of the innermost parentheses on triple click.
private final class ValueTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 3,
           let inner = TextSelectionRules.literalContentsRange(in: string as NSString,
                                                               at: selectedRange().location) {
            window?.makeFirstResponder(self)
            setSelectedRange(inner)
            return
        }
        super.mouseDown(with: event)
    }

    override func selectParagraph(_ sender: Any?) {
        if let inner = TextSelectionRules.literalContentsRange(in: string as NSString,
                                                               at: selectedRange().location) {
            setSelectedRange(inner)
            return
        }
        super.selectParagraph(sender)
    }

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

/// Scrollable value text. Word wrap toggles between tracking the pane width
/// and growing horizontally with the longest line.
private struct ValueText: NSViewRepresentable {
    let content: NSAttributedString
    let wrap: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let view = ValueTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.textContainer?.lineFragmentPadding = 0
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        scroll.documentView = view

        apply(to: view, in: scroll)
        view.textStorage?.setAttributedString(content)
        context.coordinator.lastText = content.string
        fit(view, in: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ValueTextView else { return }
        apply(to: view, in: scroll)
        let changed = !view.attributedString().isEqual(to: content)
        if changed {
            let selected = view.selectedRange()
            view.textStorage?.setAttributedString(content)
            if selected.length > 0, NSMaxRange(selected) <= content.length {
                view.setSelectedRange(selected)
            }
        }
        fit(view, in: scroll)
        if context.coordinator.lastText != content.string {
            context.coordinator.lastText = content.string
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func apply(to view: NSTextView, in scroll: NSScrollView) {
        guard let container = view.textContainer else { return }
        scroll.hasHorizontalScroller = !wrap
        container.widthTracksTextView = wrap
        if wrap {
            view.isHorizontallyResizable = false
            view.autoresizingMask = [.width]
        } else {
            view.isHorizontallyResizable = true
            view.autoresizingMask = []
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                             height: CGFloat.greatestFiniteMagnitude)
        }
    }

    /// Sizes the document view to the text so the scroll view knows how far it
    /// can scroll, both with and without wrapping.
    private func fit(_ view: NSTextView, in scroll: NSScrollView) {
        guard let container = view.textContainer,
              let layout = view.layoutManager else { return }
        let viewport = scroll.contentSize
        let inset = view.textContainerInset
        if wrap {
            let width = max(viewport.width, 1)
            container.containerSize = NSSize(width: max(width - inset.width * 2, 1),
                                             height: CGFloat.greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let width = wrap
            ? max(viewport.width, 1)
            : max(used.width + inset.width * 2, viewport.width)
        let height = max(used.height + inset.height * 2, viewport.height)
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        if view.frame != frame { view.frame = frame }
    }

    final class Coordinator {
        var lastText: String?
    }
}
