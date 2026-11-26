import SwiftUI

/// DBeaver-style local filter panel above the result grid. Every field adds an
/// AND condition to the rows already loaded; the SQL script is never changed.
struct ResultFilterView: View {
    @EnvironmentObject var model: AppModel

    private var columns: [(index: Int, column: ColumnInfo)] {
        guard let result = model.result else { return [] }
        return result.visualColumnOrder.compactMap { index in
            guard index >= 0, index < result.columns.count else { return nil }
            return (index, result.columns[index])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(columns, id: \.index) { item in
                        filterRow(index: item.index, column: item.column)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .frame(minHeight: 64, idealHeight: 140, maxHeight: 220)
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
            .help(L10n.tr("Показать выбранную строку вертикально (Tab)"))

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
            Button(L10n.tr("Очистить")) { model.clearResultFilters() }
                .controlSize(.mini)
                .disabled(model.resultFilters.isEmpty)
                .help(L10n.tr("Снять все условия фильтра"))
            Button {
                model.setShowFilterPanel(false)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(L10n.tr("Скрыть панель фильтра (включается в настройках)"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func filterRow(index: Int, column: ColumnInfo) -> some View {
        HStack(spacing: 6) {
            Text(column.name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(column.name)
            TextField(L10n.tr("Условие…"), text: Binding(
                get: { model.resultFilters[index] ?? "" },
                set: { model.setResultFilter(column: index, text: $0) }
            ))
            .font(.system(size: 11, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .help(L10n.tr("Например: 42, > 10, LIKE '%text%', NULL. Пусто — без условия."))
        }
    }
}
