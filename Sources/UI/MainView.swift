import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                sidebarPane
                    .frame(minWidth: 190, idealWidth: 260, maxWidth: 420)
                    .overlay {
                        if model.profiles.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "cylinder.split.1x2")
                                    .font(.system(size: 22))
                                    .foregroundColor(.secondary)
                                Text("Нет подключений").foregroundColor(.secondary)
                                Button("Добавить (⌘N)") { model.addProfile() }
                                    .controlSize(.small)
                            }
                        }
                    }

                VSplitView {
                    VStack(spacing: 0) {
                        TabBarView(model: model)
                        Divider()
                        if model.showEditorSearch {
                            PaneSearchBar(
                                query: $model.editorSearchQuery,
                                placeholder: L10n.tr("Найти в скрипте — раскладка не важна"),
                                count: model.editorSearchCount,
                                focusToken: model.editorSearchFocusToken,
                                onSubmit: { model.stepEditorSearch(forward: $0) },
                                onClose: { model.closeEditorSearch() }
                            )
                            .onChange(of: model.editorSearchQuery) { _ in
                                DispatchQueue.main.async { model.applyEditorSearch() }
                            }
                            Divider()
                        }
                        SQLEditorView(model: model)
                    }
                    .frame(minHeight: 150, idealHeight: 340)
                    bottomPane
                        .frame(minHeight: 150, idealHeight: 320)
                }
            }
            statusBar
        }
        .toolbar { toolbarContent }
        .background(WindowConfigurator(name: WindowLayout.mainName, configureSplits: true))
        .background {
            TitlebarRunButton(model: model)
                .frame(width: 0, height: 0)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
            loadDroppedFileURLs(providers) { urls in
                guard !urls.isEmpty else { return }
                model.openDroppedFiles(urls, binding: model.activeProfileID)
            }
            return true
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(5)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $model.editingProfile) { profile in
            ConnectionEditorView(profile: profile)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showQuickOpen, onDismiss: { model.quickOpenDidDismiss() }) {
            QuickOpenView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showCopyDialog) {
            GridCopySettingsView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showPasteDialog) {
            GridPasteSettingsView()
                .environmentObject(model)
        }
        .alert("Нет подключения", isPresented: $model.showNoConnectionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Для этого скрипта не выбрано подключение.\nВыберите подключение в строке вкладок или добавьте новое (⇧⌘N).")
        }
        .onAppear {
            DispatchQueue.main.async {
                if model.activeProfileID == nil { model.activeProfileID = model.profiles.first?.id }
            }
        }
    }

    /// Connection tree with the "add connection" button pinned to the bottom
    /// of the list instead of the window toolbar.
    private var sidebarPane: some View {
        VStack(spacing: 0) {
            SidebarView(model: model)
            Divider()
            HStack {
                Button {
                    model.addProfile()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Новое подключение (⌘N)")
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Spacer()
        }

        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                ScriptConnectionPicker(model: model)

                Divider().frame(height: 16)

                Button {
                    AboutPanel.show()
                } label: {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("О программе DBooyvol")
                .accessibilityLabel("О программе DBooyvol")
            }
            .padding(.trailing, 4)
        }
    }

    private var appIcon: NSImage {
        NSApp.applicationIconImage ?? NSImage(named: "AppIcon") ?? NSImage()
    }

    /// Converts the file URLs carried by a drag into real local URLs. The
    /// providers load asynchronously and not necessarily in drag order.
    private func loadDroppedFileURLs(_ providers: [NSItemProvider],
                                     completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [(Int, URL)] = []

        for (index, provider) in providers.enumerated() {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? URL {
                    url = value
                } else if let value = item as? NSURL {
                    url = value as URL
                } else if let string = item as? String {
                    url = URL(string: string)
                }
                guard let url, url.isFileURL else { return }
                lock.lock()
                found.append((index, url))
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            completion(found.sorted { $0.0 < $1.0 }.map(\.1))
        }
    }

    private var bottomPane: some View {
        VStack(spacing: 0) {
            if let err = model.error {
                errorBanner(err)
            }

            if model.bottomTab == .result {
                resultContent
            } else {
                HistoryView()
            }
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        if model.result == nil {
            ZStack {
                // While the first query of a tab runs, the hint would sit
                // behind the progress card, so only the card is shown.
                if !model.isRunning {
                    VStack(spacing: 6) {
                        Image(systemName: "tablecells")
                            .font(.system(size: 22))
                            .foregroundColor(.secondary)
                        Text("Выполните запрос: ⌘R или ⌘↩ (выделение или весь скрипт)")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
                executionOverlay
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ResultsView(model: model)
                    if model.resultEditPhase != .hidden {
                        resultEditBar
                            .transition(.opacity)
                    }
                }
                .overlay { executionOverlay }
                .animation(.easeInOut(duration: 0.3), value: model.resultEditPhase)

                if model.showValuePanel {
                    Divider()
                    ValuePanelView()
                        .environmentObject(model)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.showValuePanel)
        }
    }

    /// A subdued spinner in the middle of the result grid while the active tab
    /// is executing. It never takes clicks, so the run can still be cancelled.
    @ViewBuilder
    private var executionOverlay: some View {
        if model.isRunning {
            ExecutionIndicator()
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.18), value: model.isRunning)
        }
    }

    /// Save/Cancel row under the result grid. It appears as soon as a cell is
    /// edited and fades away two seconds after the changes are cancelled.
    private var resultEditBar: some View {
        HStack(spacing: 10) {
            Button {
                model.saveResultEdits()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Сохранить")
                }
            }
            .disabled(!model.canSaveResultEdits)
            .help("Записать изменения в базу данных")

            Button {
                model.cancelResultEdits()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark.square.fill")
                        .foregroundColor(.red)
                    Text("Отменить")
                }
            }
            .disabled(!model.canCancelResultEdits)
            .help("Отменить несохранённые изменения")

            if !model.resultEditMessage.isEmpty {
                Text(model.resultEditMessage)
                    .font(.caption)
                    .foregroundColor(model.resultEditMessageIsError ? .red : .secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color(nsColor: .separatorColor)),
                 alignment: .top)
    }

    private func errorBanner(_ err: DBError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(err.summary)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.error = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Скрыть сообщение об ошибке")
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .overlay(Rectangle().frame(height: 1).foregroundColor(.orange.opacity(0.3)), alignment: .bottom)
    }

    /// Quiet text switch for the result panel: the selected pane is simply a
    /// little darker with a faint pill, instead of a bright accent-filled
    /// segmented control.
    private var bottomTabSwitch: some View {
        HStack(spacing: 2) {
            ForEach(BottomTab.allCases, id: \.self) { tab in
                let selected = model.bottomTab == tab
                Button {
                    model.bottomTab = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? .primary : .secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selected ? Color.primary.opacity(0.07) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab == .result
                      ? L10n.tr("Результат последнего запроса")
                      : L10n.tr("История выполненных запросов"))
            }
        }
    }

    /// Result/History switch, search, counters, export and the editor status,
    /// all on the single bottom bar of the window.
    private var statusBar: some View {
        HStack(spacing: 8) {
            bottomTabSwitch

            if model.bottomTab == .result {
                if model.showResultSearch {
                    PaneSearchBar(
                        query: $model.resultSearchQuery,
                        placeholder: L10n.tr("Найти в результате — раскладка не важна"),
                        count: model.resultSearchCount,
                        focusToken: model.resultSearchFocusToken,
                        onSubmit: { model.stepResultSearch(forward: $0) },
                        onClose: { model.closeResultSearch() }
                    )
                    .frame(width: 300)
                } else {
                    Button {
                        model.openResultSearch()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Найти в результате (⌘F при фокусе в таблице)")
                }
            }

            Divider().frame(height: 12)

            Circle()
                .fill(isConnected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(model.status)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if model.bottomTab == .result, model.result != nil {
                if let r = model.result, !r.done {
                    Button("Загрузить ещё") { model.loadMore() }
                        .controlSize(.small)
                        .help("Догрузить следующую страницу строк")
                }
                Button("Загрузить все") { model.loadAllRows() }
                    .controlSize(.small)
                    .disabled(!model.canLoadAllResult)
                    .help("Загрузить все оставшиеся строки")
            }

            Spacer(minLength: 8)

            if model.bottomTab == .result, let r = model.result {
                if let sel = model.gridSelection {
                    let rows = sel.effectiveRows(total: r.rows.count).count
                    let cols = sel.effectiveColumns(total: r.columns.count).count
                    Text(L10n.fmt("· выделено %@×%@", String(rows), String(cols)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
                Button("CSV") { model.exportCSV() }
                    .controlSize(.small)
                    .help("Экспорт в CSV (⇧⌘E)")
                Button("XML") { model.exportXML() }
                    .controlSize(.small)
                    .help("Экспорт в XML (⌥⇧⌘E)")
                Button("XLSX") { model.exportXLSX() }
                    .controlSize(.small)
                    .help("Экспорт в XLSX (⌃⇧⌘E)")
                Button {
                    model.toggleValuePanel()
                } label: {
                    Label("Значение", systemImage: "doc.text.magnifyingglass")
                }
                .controlSize(.small)
                .disabled(model.result == nil)
                .help("Показать значение выбранной ячейки")
            }

            Divider().frame(height: 12)

            Text("\(model.caretLine) : \(model.caretColumn) : \(model.caretOffset)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .fixedSize()
                .help("Положение курсора в скрипте: строка : позиция в строке : общая позиция")
            Text(model.displayTimeZoneLabel)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .fixedSize()
                .help(L10n.fmt("Часовой пояс времени: %@", model.displayTimeZoneName))
            if let p = model.activeScriptProfile {
                HStack(spacing: 5) {
                    Image(nsImage: DBIcon.image(for: p.kind, size: 12))
                    Text("\(p.displayName) · \(p.kind.title)")
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(.bar)
        .overlay(Rectangle().frame(height: 1)
            .foregroundColor(Color(nsColor: .separatorColor)), alignment: .top)
    }

    private var isConnected: Bool {
        guard let id = model.activeScriptProfileID else { return false }
        return model.connected.contains(id)
    }
}

/// Quiet progress card shown over the result grid while a query runs: a thin
/// rotating arc on a material background, with the same caption as the status
/// bar. Intentionally low contrast so it does not distract from the data.
private struct ExecutionIndicator: View {
    @State private var spinning = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(Color.secondary.opacity(0.65),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false),
                               value: spinning)
            }
            .frame(width: 26, height: 26)

            Text(L10n.tr("Выполняется…"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
        .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        .onAppear { spinning = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
