import SwiftUI
import AppKit

/// Compact find bar used above the editor and in the result pane.
/// Matching is done by `SearchMatcher`, so the query works in any keyboard
/// layout ("ghbkf" finds "Прила" and vice versa).
struct PaneSearchBar: View {
    @Binding var query: String
    var placeholder: String
    var count: Int
    /// Incremented by the caller to move keyboard focus into the field.
    var focusToken: Int = 0
    /// `true` for the next match, `false` for the previous one.
    var onSubmit: (Bool) -> Void
    var onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit {
                    // Shift+Enter walks the matches backwards.
                    onSubmit(!NSEvent.modifierFlags.contains(.shift))
                }
                .onExitCommand { onClose() }

            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(count == 0 ? .secondary : .primary)
                .frame(minWidth: 18, alignment: .trailing)

            Button { onSubmit(false) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(count == 0)
            .appToolTip("Предыдущее совпадение (⇧↩)")

            Button { onSubmit(true) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(count == 0)
            .appToolTip("Следующее совпадение (↩)")

            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .appToolTip("Закрыть поиск (esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: focusToken) { _ in
            DispatchQueue.main.async { focused = true }
        }
    }
}
