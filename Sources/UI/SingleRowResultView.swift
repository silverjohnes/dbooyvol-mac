import SwiftUI
import AppKit

/// Vertical view of one result row: column names on the left, values on the
/// right. Opened with Tab in the grid or the "Результат" button in the filter
/// row; Tab again returns to the normal grid.
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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.singleRowItems().enumerated()), id: \.element.id) { index, item in
                            row(item, alternate: index.isMultiple(of: 2))
                        }
                    }
                    .padding(.vertical, 4)
                }
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

    private func row(_ item: SingleRowItem, alternate: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 220, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .textSelection(.enabled)
            Divider()
            Text(item.value ?? "NULL")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(item.value == nil ? Color(nsColor: .tertiaryLabelColor) : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(alternate ? Color.primary.opacity(0.035) : Color.clear)
    }
}

/// Local Tab monitor used only while the vertical single-row view is on screen.
/// It ignores Tab while a text field has focus, so the filter fields still work.
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
                // Editable fields (filter, search) keep Tab for focus moves;
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
