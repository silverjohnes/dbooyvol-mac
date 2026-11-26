import SwiftUI
import AppKit

struct QuickOpenView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected = 0
    @State private var monitor: Any?
    @State private var clickMonitor: Any?
    @State private var hostWindow: NSWindow?
    @FocusState private var focused: Bool

    /// Ranked matches. Computed when the query changes, not on every arrow
    /// press: recomputing all hits on each keystroke made navigation sluggish.
    @State private var results: [QueryTab] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Имя или текст запроса — раскладка не важна", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { openSelected() }
                Text("⌘E")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)

            Divider()

            if results.isEmpty {
                VStack(spacing: 6) {
                    Text("Ничего не найдено").foregroundColor(.secondary)
                    Text("«ghbkf» находит «Прила» и наоборот")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, tab in
                                row(tab, index: index)
                                    .id(tab.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selected) { newValue in
                        if newValue >= 0, newValue < results.count {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(results[newValue].id, anchor: .center)
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text("↑ ↓ — выбор · ↩ — открыть · esc — закрыть")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(L10n.fmt("%@ из %@", String(results.count), String(model.tabs.count)))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 640, height: 430)
        .background(WindowReader { hostWindow = $0 })
        .onAppear {
            focused = true
            refreshResults()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // The sheet is the only window that should react, so arrows
                // keep working in the editor behind it if it is not key.
                if let hostWindow, let target = event.window, target !== hostWindow {
                    return event
                }
                switch event.keyCode {
                case 125: // down
                    moveSelection(1)
                    return nil
                case 126: // up
                    moveSelection(-1)
                    return nil
                case 53: // esc
                    dismiss()
                    return nil
                default:
                    return event
                }
            }
            // A click anywhere outside the search panel closes it, not only Esc.
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                if let hostWindow, let target = event.window, target !== hostWindow {
                    dismiss()
                }
                return event
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }
        .onExitCommand { dismiss() }
        .onChange(of: query) { _ in
            selected = 0
            refreshResults()
        }
        .onChange(of: model.tabs.count) { _ in refreshResults() }
    }

    private func refreshResults() {
        results = Self.rankedTabs(query: query, tabs: model.tabs)
    }

    /// Matching tabs with the most useful ones first: a hit in the title beats
    /// a hit in the body, then results written in the language of the match
    /// (so a Russian query prefers Russian scripts even when it was typed in
    /// the other layout), then the earliest occurrence.
    static func rankedTabs(query: String, tabs: [QueryTab]) -> [QueryTab] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let prepared = SearchMatcher.query(trimmed) else { return tabs }

        struct Scored {
            let tab: QueryTab
            let index: Int
            let titleMatch: Bool
            let prefixMatch: Bool
            let languageMatch: Bool
            let position: Int
        }

        var scored: [Scored] = []
        scored.reserveCapacity(tabs.count)
        for (index, tab) in tabs.enumerated() {
            let titleMatch = prepared.firstMatch(in: tab.title)
            let bodyMatch = titleMatch == nil
                ? prepared.firstMatch(in: String(tab.text.prefix(30_000)))
                : nil
            guard let match = titleMatch ?? bodyMatch else { continue }
            // The matched variant may be the layout twin; its script is the
            // language the user actually meant.
            let language = TextLanguage.of(match.variant)
            let tabLanguage = Self.tabLanguage(tab)
            scored.append(Scored(
                tab: tab,
                index: index,
                titleMatch: titleMatch != nil,
                prefixMatch: titleMatch != nil && match.range.location == 0,
                languageMatch: language != .none && language == tabLanguage,
                position: match.range.location
            ))
        }

        return scored.sorted { a, b in
            if a.titleMatch != b.titleMatch { return a.titleMatch }
            if a.languageMatch != b.languageMatch { return a.languageMatch }
            if a.prefixMatch != b.prefixMatch { return a.prefixMatch }
            if a.position != b.position { return a.position < b.position }
            return a.index < b.index
        }.map { $0.tab }
    }

    /// Title language when the title carries letters, otherwise the SQL text.
    private static func tabLanguage(_ tab: QueryTab) -> TextLanguage {
        let title = TextLanguage.of(tab.title)
        if title != .none { return title }
        return TextLanguage.of(String(tab.text.prefix(2_000)))
    }

    private func row(_ tab: QueryTab, index: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let p = model.profile(for: tab) {
                Image(nsImage: DBIcon.image(for: p.kind, size: 14))
                    .padding(.top, 1)
            } else {
                Image(systemName: tab.filePath == nil ? "doc.text" : "doc")
                    .font(.system(size: 11))
                    .foregroundColor(index == selected ? .accentColor : .secondary)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title)
                    .font(.system(size: 13, weight: index == selected ? .semibold : .regular))
                    .lineLimit(1)
                Text(preview(tab))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let name = tab.fileName {
                Text(name)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(index == selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .appToolTip(L10n.tr("Открыть вкладку"))
        .onTapGesture {
            selected = index
            openSelected()
        }
    }

    private func preview(_ tab: QueryTab) -> String {
        Self.previewText(tab.text)
    }

    /// First active statement plus the first `from` target, comments ignored.
    static func previewText(_ text: String) -> String {
        let active = Self.withoutComments(text)
        let firstLine = active
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !firstLine.isEmpty else { return L10n.tr("пусто") }

        var head = firstLine.replacingOccurrences(of: "\\s+", with: " ",
                                                  options: .regularExpression)
        head = head.trimmingCharacters(in: CharacterSet(charactersIn: ", "))

        let lower = head.lowercased()
        let hasFrom = lower.hasPrefix("from ") || lower.contains(" from ")
        if !hasFrom, let table = Self.firstFrom(active) {
            head += " … from " + table
        }
        return String(head.prefix(110))
    }

    /// Drops `--` and `/* … */` comments so the preview shows active SQL only.
    private static func withoutComments(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        let characters = Array(text)
        var index = 0
        var quote: Character?
        var lineComment = false
        var blockComment = false

        while index < characters.count {
            let c = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil

            if lineComment {
                if c == "\n" {
                    lineComment = false
                    output.append(c)
                }
                index += 1
                continue
            }
            if blockComment {
                if c == "*", next == "/" {
                    blockComment = false
                    index += 2
                    continue
                }
                if c == "\n" { output.append(c) }
                index += 1
                continue
            }
            if let activeQuote = quote {
                output.append(c)
                if c == activeQuote {
                    if next == activeQuote {
                        output.append(next!)
                        index += 2
                        continue
                    }
                    quote = nil
                }
                index += 1
                continue
            }
            if c == "-", next == "-" {
                lineComment = true
                index += 2
                continue
            }
            if c == "/", next == "*" {
                blockComment = true
                index += 2
                continue
            }
            if c == "'" || c == "\"" {
                quote = c
            }
            output.append(c)
            index += 1
        }
        return output
    }

    /// First `from <object>` in the active SQL, including `schema.table`.
    private static func firstFrom(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "(?i)\\bfrom\\s+([\\w.\\\"\\[\\]`$]+)",
            options: []
        ) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1 else { return nil }
        let table = (text as NSString).substring(with: match.range(at: 1))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        return table.isEmpty ? nil : table
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = min(max(0, selected + delta), results.count - 1)
    }

    private func openSelected() {
        guard selected >= 0, selected < results.count else { return }
        // The model closes the sheet and focuses the editor in onDismiss, after
        // AppKit has finished restoring the old first responder.
        model.selectTabFromSearch(results[selected].id)
    }
}

/// Reports the window a SwiftUI view is hosted in, so a click in another
/// window can be told apart from a click inside the panel.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}
