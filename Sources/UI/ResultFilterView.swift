import SwiftUI

/// DBeaver-style local filter above the result grid. It is one plain text
/// line: free text searches every visible cell, while `column > 10`,
/// `name LIKE 'A%'` and similar conditions narrow one column. The SQL script
/// and the stored result are never changed.
struct ResultFilterView: View {
    @EnvironmentObject var model: AppModel

    private var columnNames: [String] {
        model.result?.columns.map(\.name) ?? []
    }

    private var numericColumns: Set<String> {
        Set((model.result?.columns ?? [])
            .filter(\.isNumeric)
            .map { $0.name.lowercased() })
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 6) {
                FilterTextField(
                    text: Binding(
                        get: { model.resultFilterText },
                        set: { model.setResultFilterText($0) }
                    ),
                    columns: columnNames,
                    numericColumns: numericColumns,
                    values: { model.filterValueCandidates(for: $0) },
                    placeholder: L10n.tr("Фильтр: текст, столбец > 10, LIKE %…%"),
                    help: L10n.tr("Одна строка: текст ищется во всех столбцах; можно указать столбец и условие, например amount > 10 или name LIKE 'A%'.")
                )
                .frame(height: 22)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .frame(height: 64)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                model.toggleSingleRowResult()
            } label: {
                Label(L10n.tr("Результат"), systemImage: "rectangle.split.2x1")
                    .font(.system(size: 11, weight: model.showSingleRowResult ? .semibold : .regular))
            }
            .buttonStyle(.borderless)
            .foregroundColor(model.showSingleRowResult ? .accentColor : .primary)
            .appToolTip(L10n.tr("Показать выбранную строку вертикально (Tab)"))

            Divider().frame(height: 14)

            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundColor(.secondary)
            Text(L10n.tr("Фильтр"))
                .font(.system(size: 11, weight: .semibold))
            if model.displayedRowCount != (model.result?.rows.count ?? 0) {
                Text(L10n.fmt("· %@ из %@", String(model.displayedRowCount),
                              String(model.result?.rows.count ?? 0)))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(L10n.tr("Очистить")) { model.clearResultFilter() }
                .controlSize(.mini)
                .disabled(model.resultFilterText.isEmpty)
                .appToolTip(L10n.tr("Снять фильтр"))
            Button {
                model.setShowFilterPanel(false)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .appToolTip(L10n.tr("Скрыть панель фильтра (включается в настройках)"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
