import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""

    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return model.history }
        return model.history.filter {
            $0.sql.localizedCaseInsensitiveContains(query) || $0.profile.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Поиск по истории", text: $query)
                    .textFieldStyle(.plain)
                    .help(L10n.tr("Искать по тексту запроса или имени подключения"))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .help("Сбросить поиск по истории")
                }
                Spacer()
                Text("\(filtered.count)").font(.caption).foregroundColor(.secondary)
                Button("Очистить") { model.clearHistory() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Удалить всю историю запросов")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            if filtered.isEmpty {
                Text("История пуста").foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { entry in
                    HistoryRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture { model.loadHistoryIntoEditor(entry) }
                        .help(L10n.tr("Открыть запрос в редакторе"))
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if entry.error != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.caption)
                }
                Text(entry.profile).font(.caption).foregroundColor(.secondary)
                Text(entry.date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text(L10n.fmt("%@ стр · %@ мс", String(entry.rowCount), String(entry.durationMs)))
                    .font(.caption2).foregroundColor(.secondary)
            }
            Text(entry.sql.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(2)
            if let error = entry.error {
                Text(error).font(.caption2).foregroundColor(.orange).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
