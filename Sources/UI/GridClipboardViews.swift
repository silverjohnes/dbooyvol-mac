import SwiftUI
import AppKit

/// Editable combo box used by the copy/paste dialogs: standard values can be
/// picked from the list, or a custom one typed in.
struct ComboField: NSViewRepresentable {
    @Binding var value: String
    var options: [String]
    var display: (String) -> String = { $0 }
    var parse: (String) -> String = { $0 }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.isEditable = true
        box.completes = false
        box.numberOfVisibleItems = 8
        box.usesDataSource = false
        box.delegate = context.coordinator
        box.target = context.coordinator
        box.action = #selector(Coordinator.changed(_:))
        box.addItems(withObjectValues: options.map(display))
        box.stringValue = display(value)
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        let items = options.map(display)
        if box.numberOfItems != items.count || (0..<items.count).contains(where: {
            box.itemObjectValue(at: $0) as? String != items[$0]
        }) {
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }
        // Do not fight the user while they are typing.
        if box.currentEditor() == nil, box.stringValue != display(value) {
            box.stringValue = display(value)
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ComboField

        init(_ parent: ComboField) {
            self.parent = parent
        }

        @objc func changed(_ sender: NSComboBox) {
            parent.value = parent.parse(sender.stringValue)
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            parent.value = parent.parse(box.stringValue)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            parent.value = parent.parse(box.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            parent.value = parent.parse(box.stringValue)
        }
    }
}

struct GridCopySettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var settings: GridCopySettings
    @State private var columnText: String
    @State private var rowText: String
    @State private var quoteText: String
    @State private var valueFormat: GridValueFormat

    init() {
        let saved = GridClipboardStore.copy
        _settings = State(initialValue: saved)
        _columnText = State(initialValue: GridClipboard.display(saved.columnDelimiter))
        _rowText = State(initialValue: GridClipboard.display(saved.rowDelimiter))
        _quoteText = State(initialValue: saved.quoteCharacter)
        _valueFormat = State(initialValue: saved.valueFormat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Копировать")
                .font(.headline)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Копировать заголовки столбцов", isOn: $settings.copyHeader)
                    Toggle("Копировать номера строк", isOn: $settings.copyRowNumbers)
                    Toggle("Заключать значения в кавычки", isOn: $settings.quoteValues)
                    Toggle("Всегда заключать в кавычки", isOn: $settings.alwaysQuote)
                        .disabled(!settings.quoteValues)
                    Toggle("Копировать как HTML", isOn: $settings.copyAsHTML)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Value display format")
                        Picker("", selection: $valueFormat) {
                            ForEach(GridValueFormat.allCases, id: \.self) { format in
                                Text(format.title).tag(format)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    Divider()
                        .gridCellColumns(2)
                    GridRow {
                        Text("Разделитель столбцов")
                        ComboField(value: $columnText,
                                   options: settings.columnDelimiterOptions.map(GridClipboard.display),
                                   display: { $0 },
                                   parse: { $0 })
                            .frame(width: 190)
                    }
                    GridRow {
                        Text("Разделитель строк")
                        ComboField(value: $rowText,
                                   options: settings.rowDelimiterOptions.map(GridClipboard.display),
                                   display: { $0 },
                                   parse: { $0 })
                            .frame(width: 190)
                    }
                    GridRow {
                        Text("Символ кавычек")
                        ComboField(value: $quoteText,
                                   options: settings.quoteCharacterOptions,
                                   display: { $0 },
                                   parse: { $0 })
                            .frame(width: 190)
                    }
                }
                .padding(.vertical, 2)
            }

            Text("Отображение — как значение показано в таблице; Редактируемое — в виде, удобном для правки; Как в базе — в исходном представлении драйвера.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Копировать") { copy() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 470)
    }

    private func copy() {
        var updated = settings
        updated.valueFormat = valueFormat
        updated.setColumnDelimiter(GridClipboard.value(fromDisplay: columnText))
        updated.setRowDelimiter(GridClipboard.value(fromDisplay: rowText))
        updated.setQuoteCharacter(quoteText)
        GridClipboardStore.copy = updated
        dismiss()
        model.copySelection(settings: updated)
    }
}

struct GridPasteSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var settings: GridPasteSettings
    @State private var nullText: String

    init() {
        let saved = GridClipboardStore.paste
        _settings = State(initialValue: saved)
        _nullText = State(initialValue: saved.nullMark)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Дополнительная вставка")
                .font(.headline)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Вставлять несколько строк", isOn: $settings.insertMultipleRows)
                    Toggle("Игнорировать кавычки", isOn: $settings.ignoreQuotes)
                    Toggle("Вставлять NULL", isOn: $settings.insertNulls)
                    HStack(spacing: 10) {
                        Text("Метка NULL")
                        ComboField(value: $nullText,
                                   options: settings.nullMarkOptions,
                                   display: { $0.isEmpty ? L10n.tr("Пусто") : $0 },
                                   parse: { $0 == L10n.tr("Пусто") ? "" : $0 })
                            .frame(width: 190)
                            .disabled(!settings.insertNulls)
                    }
                    .padding(.leading, 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Если метка NULL совпадает со значением в буфере обмена, в ячейку вставляется NULL. Пустая метка означает пустую строку.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Вставить") { paste() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 450)
    }

    private func paste() {
        var updated = settings
        updated.setNullMark(nullText)
        GridClipboardStore.paste = updated
        dismiss()
        model.pasteSelection(settings: updated)
    }
}
