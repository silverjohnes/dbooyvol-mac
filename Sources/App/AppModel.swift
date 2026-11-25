import Foundation
import AppKit
import UniformTypeIdentifiers

/// Run state of a query tab, shown as a small dot in the tab strip.
enum TabRunState: Equatable {
    case idle
    case running
    case succeeded
    case failed
}

enum BottomTab: String, CaseIterable {
    case result = "Результат"
    case history = "История"

    var title: String { L10n.tr(rawValue) }
}

/// Pane that owns the keyboard focus; Cmd+F opens search there.
enum FocusPane {
    case editor
    case result
}

extension Notification.Name {
    /// Posted when the SQL editor takes keyboard focus. The tab strip listens
    /// so it stops treating itself as the scroll target: after jumping to a
    /// query from search, the wheel must scroll that query, not the tabs.
    static let editorDidTakeFocus = Notification.Name("DBooyvol.EditorDidTakeFocus")
}

/// Top-down coordinates for rows placed inside a scroll view.
private final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var profiles: [ConnectionProfile] = []
    @Published var activeProfileID: UUID? {
        didSet {
            guard oldValue != activeProfileID else { return }
            AppSettings.selectedProfileID = activeProfileID
        }
    }
    @Published var result: QueryResult?
    @Published var resultSort: ResultSort?
    @Published var error: DBError?
    @Published var showNoConnectionAlert = false
    @Published var status: String = L10n.tr("Готово")
    /// Run state per tab, so several tabs can execute queries at once.
    @Published private(set) var tabRunStates: [UUID: TabRunState] = [:]
    /// True when the active tab is executing something.
    var isRunning: Bool { tabRunStates[activeTabID] == .running }
    @Published var bottomTab: BottomTab = .result
    @Published var gridSelection: GridSelection? {
        didSet { if gridSelection != oldValue { gridSelectionRevision += 1 } }
    }
    /// Bumped on every selection change so the grid can detect one without
    /// hashing or sorting the selected row/column sets.
    private(set) var gridSelectionRevision = 0
    /// Set after a cell edit, so the grid can repaint just that row.
    @Published private(set) var resultEditsRevision = 0
    @Published var showCopyDialog = false
    @Published var showPasteDialog = false
    /// UI state of the Save/Cancel row under the result grid.
    enum ResultEditPhase: Equatable {
        case hidden
        case pending
        case saving
        case saved
        case failed
        case cancelling
    }
    @Published var resultEditPhase: ResultEditPhase = .hidden
    @Published var resultEditMessage: String = ""
    @Published var resultEditMessageIsError = false
    private var editHideWork: DispatchWorkItem?
    @Published var history: [HistoryEntry] = []
    /// How many days of query history to keep; 0 means forever.
    @Published var historyRetentionDays: Int = AppSettings.historyRetentionDays
    /// Interface language. `.system` follows the macOS language list.
    @Published var appLanguage: AppLanguage = AppLanguage.selected
    /// True after the picker changes; the new language is applied on relaunch.
    @Published var languageNeedsRestart = false
    @Published var showProfileEditor: Bool = false
    @Published var editingProfile: ConnectionProfile?
    @Published var connected: Set<UUID> = []
    @Published var treeRefreshToken: Int = 0
    @Published var tabs: [QueryTab] = []
    @Published var activeTabID: UUID = UUID() {
        didSet { recordTabSwitch(from: oldValue, to: activeTabID) }
    }
    /// The single tab that was active before the current one. Updated on every
    /// switch, including switches caused by opening, closing or duplicating a
    /// tab, so ⌘⇧T can toggle back to the tab the user came from.
    private var previousTabID: UUID?
    @Published var showQuickOpen = false
    /// True when the quick-open sheet is closing because a query was chosen.
    private var quickOpenChoseTab = false
    /// Set when the active tab was opened from Quick Open. Consumed by the next
    /// editor focus, so "Только при поиске" knows where the tab came from.
    private var focusCameFromSearch = false
    @Published var inlineRenameTabID: UUID?
    @Published var showEditorSearch = false
    @Published var editorSearchQuery = ""
    @Published var editorSearchCount = 0
    @Published var editorSearchFocusToken = 0
    @Published var showResultSearch = false
    @Published var resultSearchQuery = ""
    @Published var resultSearchCount = 0
    @Published var resultSearchFocusToken = 0
    /// Incremented for the next result match, decremented for the previous one.
    @Published var resultSearchNav = 0
    /// Last pane that took keyboard focus.
    @Published var focusedPane: FocusPane = .editor
    @Published var editorFontSize: CGFloat = AppSettings.editorFontSize
    /// Enables the separate shortcut that comments every line ending with
    /// `commentMarker`.
    @Published var commentByMarker: Bool = AppSettings.commentByMarker
    /// Editable part of the marker; the full marker is `--` + this string.
    @Published var commentMarkerSuffix: String = AppSettings.commentMarkerSuffix
    @Published var resultFontSize: CGFloat = AppSettings.resultFontSize
    @Published var resultFontName: String = AppSettings.resultFontName
    @Published var autoColumnWidths: Bool = AppSettings.autoColumnWidths
    @Published var maxAutoColumnWidth: CGFloat = AppSettings.maxAutoColumnWidth
    @Published var showTypeInColumnHeader: Bool = AppSettings.showTypeInColumnHeader
    @Published var showTypeOnHeaderHover: Bool = AppSettings.showTypeOnHeaderHover
    /// Empty means the system zone. Changing it repaints the result grid.
    @Published var timeZoneIdentifier: String = AppSettings.timeZoneIdentifier
    /// Watches open files for changes made by other programs. Off by default.
    @Published var checkExternalChanges: Bool = AppSettings.checkExternalChanges
    /// Value inspector on the right side of the result pane.
    @Published var showValuePanel = false
    @Published var valuePanelItem: ValuePanelItem?
    /// `.auto` detects the kind from the value each time the cell changes.
    @Published var valuePanelKind: ValueViewKind = .auto
    @Published var valuePanelWordWrap = true
    @Published var valuePanelAutoFormat = true
    @Published var valuePanelCompact = false
    @Published var valuePanelEncoding: String.Encoding = .utf8
    /// Metadata for header tooltips, keyed by profile + catalog + schema + table.
    var tableMetaCache: [String: TableMeta] = [:]
    private var tableMetaRequests: Set<String> = []
    @Published var pageSize: Int = AppSettings.pageSize
    /// Caret position in the active script, shown in the status bar.
    @Published var caretLine: Int = 1
    @Published var caretColumn: Int = 1
    @Published var caretOffset: Int = 0

    static let minEditorFontSize: CGFloat = 9
    static let maxEditorFontSize: CGFloat = 32
    static let minResultFontSize: CGFloat = 8
    static let maxResultFontSize: CGFloat = 32
    static let minAutoColumnWidth: CGFloat = 60
    static let maxAutoColumnWidthLimit: CGFloat = 1000
    static let minPageSize = 1
    static let maxPageSize = 100_000
    static let defaultPageSize = 200
    /// Fits ~38–40 characters at the default 12 pt monospaced font:
    /// enough for names, e-mails and timestamps, longer JSON/URLs are truncated.
    static let defaultAutoColumnWidth: CGFloat = 280

    let editor = EditorController()
    private var sessions: [UUID: Session] = [:]
    /// Passwords typed for profiles that do not store one. Kept only for this
    /// run and dropped on disconnect, so the next connect asks again.
    private var sessionPasswords: [UUID: String] = [:]
    /// Last values typed for `:name` parameters, per connection. Kept in memory
    /// only, so a repeated run does not start from empty fields.
    private var bindValues: [UUID: [String: Any]] = [:]
    /// Each tab runs its queries on its own JDBC connection, so two tabs can
    /// execute at the same time even when they use the same profile.
    private var tabSessions: [UUID: Session] = [:]
    /// Results are kept per tab, so switching tabs shows what that script ran
    /// last (or an empty grid when it has never been run).
    private var resultsByTab: [UUID: QueryResult] = [:]
    private var sortsByTab: [UUID: ResultSort] = [:]
    private var historyStore = HistoryStore()
    private var tabsSaveWork: DispatchWorkItem?
    private struct RunningQuery {
        let profileID: UUID
        var queryID: String?
        var cancelled = false
    }
    private var runningQueries: [UUID: RunningQuery] = [:]
    private var errorsByTab: [UUID: DBError] = [:]
    /// File content last read from or written to disk, per tab. Used to notice
    /// edits made by another program while the script is open.
    private var diskContents: [UUID: DiskFileState] = [:]
    /// Tabs restored from the previous session whose text has not been compared
    /// with the file on disk yet. They are checked when the tab is activated
    /// (and for the active tab right at launch), so restored unsaved edits are
    /// never silently replaced or ignored.
    private var tabsAwaitingDiskComparison: Set<UUID> = []
    private var isCheckingExternalChanges = false
    private var externalCheckTimer: Timer?
    /// Overrides the conflict dialog in tests: true loads the disk version.
    var confirmExternalChange: ((_ title: String) -> Bool)?
    private var isPromptingExternalChange = false

    static let welcomeText = """
    -- Cmd+R — выполнить или остановить запрос
    -- Cmd+Enter — выполнить выделение или весь скрипт
    -- Cmd+Shift+Enter — запрос под курсором
    -- Cmd+E — поиск по открытым запросам (любая раскладка)
    SELECT 1 AS hello;
    """

    private init() {
        AppSettings.registerDefaults()
        AppPaths.tightenPermissions()
        SecretStore.purgeLegacy()
        profiles = ProfilesStore.load()
        if let saved = AppSettings.selectedProfileID,
           profiles.contains(where: { $0.id == saved }) {
            activeProfileID = saved
        } else {
            activeProfileID = profiles.first?.id
        }
        historyRetentionDays = AppSettings.historyRetentionDays
        historyStore.setRetention(days: historyRetentionDays)
        history = historyStore.entries
        restoreTabs()
    }

    var activeProfile: ConnectionProfile? {
        guard let id = activeProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Connection used by the active script: its own binding, otherwise the selected one.
    var activeScriptProfileID: UUID? {
        if let id = activeTab?.profileID, profiles.contains(where: { $0.id == id }) { return id }
        return activeProfileID
    }

    var activeScriptProfile: ConnectionProfile? {
        guard let id = activeScriptProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    func setActiveScriptProfile(_ id: UUID?) {
        guard let idx = activeTabIndex else { return }
        if tabs[idx].profileID != id {
            tabs[idx].profileID = id
            scheduleTabsSave()
            // The tab's own query connection belongs to the old profile.
            if let session = tabSessions[activeTabID], session.profile.id != id {
                session.disconnect()
                tabSessions[activeTabID] = nil
            }
        }
        if let id { activeProfileID = id }
    }

    // MARK: - profiles

    func addProfile() {
        var p = ConnectionProfile()
        p.name = L10n.tr("Новое подключение")
        p.port = p.kind.defaultPort
        editingProfile = p
        showProfileEditor = true
    }

    func editProfile(_ p: ConnectionProfile) {
        editingProfile = p
        showProfileEditor = true
    }

    func duplicateProfile(_ p: ConnectionProfile) {
        var copy = p
        copy.id = UUID()
        copy.name = p.name + " " + L10n.tr("(копия)")
        profiles.append(copy)
        AppSettings.markConnectionCollapsed("conn:\(copy.id)", for: copy.id)
        if p.storesPassword, let password = try? SecretStore.load(p.id.uuidString), !password.isEmpty {
            try? SecretStore.save(password, for: copy.id.uuidString)
        }
        persist()
    }

    func saveProfile(_ p: ConnectionProfile, password: String) {
        if let idx = profiles.firstIndex(where: { $0.id == p.id }) {
            let old = profiles[idx]
            if old != p { disconnect(old.id) }
            profiles[idx] = p
        } else {
            profiles.append(p)
            // Do not auto-open a brand-new (usually still empty) connection.
            AppSettings.markConnectionCollapsed("conn:\(p.id)", for: p.id)
        }
        if p.storesPassword {
            do {
                try SecretStore.save(password, for: p.id.uuidString)
            } catch {
                status = error.localizedDescription
            }
            sessionPasswords[p.id] = nil
        } else {
            SecretStore.delete(p.id.uuidString)
            sessionPasswords[p.id] = password.isEmpty ? nil : password
        }
        if activeProfileID == nil { activeProfileID = p.id }
        persist()
    }

    func deleteProfile(_ id: UUID) {
        disconnect(id)
        profiles.removeAll { $0.id == id }
        SecretStore.delete(id.uuidString)
        for i in tabs.indices where tabs[i].profileID == id {
            tabs[i].profileID = nil
        }
        if activeProfileID == id { activeProfileID = profiles.first?.id }
        persist()
        scheduleTabsSave()
    }

    func renameProfile(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        guard profiles[idx].name != trimmed else { return }
        profiles[idx].name = trimmed
        persist()
    }

    func promptRenameProfile(_ profile: ConnectionProfile) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Переименовать подключение")
        alert.informativeText = L10n.tr("Имя отображается в списке подключений.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = profile.name
        field.placeholderString = L10n.tr("Имя подключения")
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("Переименовать"))
        alert.addButton(withTitle: L10n.tr("Отмена"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        renameProfile(profile.id, to: field.stringValue)
    }

    func promptDeleteProfile(_ profile: ConnectionProfile) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L10n.tr("Удалить подключение «%@»?"), profile.displayName)
        alert.informativeText = L10n.tr("Сохранённый пароль будет удалён. Открытые вкладки останутся.")
        alert.addButton(withTitle: L10n.tr("Удалить"))
        alert.addButton(withTitle: L10n.tr("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteProfile(profile.id)
    }

    func isConnected(_ id: UUID) -> Bool {
        connected.contains(id)
    }

    func profile(for tab: QueryTab) -> ConnectionProfile? {
        guard let id = tab.profileID else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Schema of the last result of a script, for the tab tooltip.
    func resultSchema(for tab: QueryTab) -> String? {
        guard let result = resultsByTab[tab.id] else { return nil }
        return result.columns.first(where: { !$0.schema.isEmpty })?.schema
    }

    private func persist() {
        ProfilesStore.save(profiles)
    }

    func password(for id: UUID) -> String {
        (try? SecretStore.load(id.uuidString)) ?? ""
    }

    /// Asks for a password when the profile does not store one. The checkbox in
    /// the same window decides whether the answer is saved. The answer is cached
    /// for this run, so parallel tabs do not prompt repeatedly.
    func passwordForConnect(_ profile: ConnectionProfile) -> String? {
        if profile.kind.isFileBased { return "" }
        if let cached = sessionPasswords[profile.id] { return cached }

        let alert = NSAlert()
        alert.messageText = L10n.fmt("Введите пароль от «%@»", profile.displayName)
        alert.addButton(withTitle: L10n.tr("Подключиться"))
        alert.addButton(withTitle: L10n.tr("Отмена"))

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 32, width: 320, height: 24))
        field.placeholderString = L10n.tr("Пароль")
        let saveBox = NSButton(checkboxWithTitle: L10n.tr("Сохранить пароль"),
                               target: nil, action: nil)
        saveBox.state = profile.storesPassword ? .on : .off
        saveBox.frame = NSRect(x: 0, y: 4, width: 320, height: 20)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 60))
        container.addSubview(field)
        container.addSubview(saveBox)
        alert.accessoryView = container
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let password = field.stringValue
        let shouldSave = saveBox.state == .on
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }),
           profiles[idx].storesPassword != shouldSave {
            profiles[idx].savePassword = shouldSave
            persist()
        }
        if shouldSave {
            do {
                try SecretStore.save(password, for: profile.id.uuidString)
            } catch {
                status = error.localizedDescription
            }
            sessionPasswords[profile.id] = nil
        } else {
            SecretStore.delete(profile.id.uuidString)
            sessionPasswords[profile.id] = password
        }
        return password
    }

    // MARK: - sessions

    func session(for profile: ConnectionProfile) -> Session {
        if let s = sessions[profile.id] { return s }
        let s = Session(profile: profile, passwordProvider: { [weak self] in
            self?.passwordForConnect(profile)
        })
        sessions[profile.id] = s
        return s
    }

    /// Dedicated query connection for one tab. Tabs on the same profile do not
    /// share a connection, which is what makes parallel execution possible.
    private func querySession(for tabID: UUID, profile: ConnectionProfile) -> Session {
        if let s = tabSessions[tabID], s.profile.id == profile.id { return s }
        tabSessions[tabID]?.disconnect()
        let s = Session(profile: profile, passwordProvider: { [weak self] in
            self?.passwordForConnect(profile)
        })
        tabSessions[tabID] = s
        return s
    }

    func disconnect(_ id: UUID) {
        sessionPasswords[id] = nil
        sessions[id]?.disconnect()
        sessions[id] = nil
        for (tabID, session) in tabSessions where session.profile.id == id {
            session.disconnect()
            tabSessions[tabID] = nil
        }
        connected.remove(id)
    }

    func disconnectActive() {
        guard let id = activeProfileID else { return }
        disconnect(id)
        status = L10n.tr("Отключено")
    }

    func connectActive() {
        guard let profile = activeProfile else { return }
        status = L10n.fmt("Подключение: %@…", profile.displayName)
        Task { @MainActor in
            _ = await children(profile: profile, path: [])
            if isConnected(profile.id) {
                status = L10n.fmt("Подключено: %@", profile.displayName)
                refreshTree()
            } else {
                status = L10n.fmt("Не удалось подключиться: %@", profile.displayName)
            }
        }
    }

    func children(profile: ConnectionProfile, path: [String]) async -> [TreeNode] {
        do {
            let s = session(for: profile)
            let nodes = try await s.tree(path: path)
            connected.insert(profile.id)
            return nodes
        } catch {
            self.error = (error as? SidecarError)?.dbError ?? DBError(message: error.localizedDescription)
            noteConnectionFailure(error, profile: profile)
            return []
        }
    }

    /// A dead JDBC connection is retried inside Session; if the retry also fails,
    /// the green "connected" dot must not keep lying.
    private func noteConnectionFailure(_ error: Error, profile: ConnectionProfile) {
        if let se = error as? SidecarError, se.isConnectionLost {
            connected.remove(profile.id)
        }
    }

    // MARK: - editor font

    func setEditorFontSize(_ size: CGFloat) {
        let clamped = min(max(size.rounded(), Self.minEditorFontSize), Self.maxEditorFontSize)
        guard clamped != editorFontSize else { return }
        editorFontSize = clamped
        AppSettings.editorFontSize = clamped
        editor.applyFontSize(clamped)
        status = L10n.fmt("Шрифт редактора: %@ pt", String(Int(clamped)))
    }

    /// Ctrl + mouse wheel: one notch or a few trackpad points per step.
    func stepEditorFontSize(_ steps: CGFloat) {
        guard steps != 0 else { return }
        setEditorFontSize(editorFontSize + steps)
    }

    func increaseEditorFontSize() { setEditorFontSize(editorFontSize + 1) }

    func decreaseEditorFontSize() { setEditorFontSize(editorFontSize - 1) }

    func resetEditorFontSize() {
        setEditorFontSize(SQLHighlighter.defaultFontSize)
    }

    // MARK: - comment marker

    /// Full marker: the fixed `--` plus the user's suffix.
    var commentMarker: String { "--" + commentMarkerSuffix }

    func setCommentByMarker(_ enabled: Bool) {
        guard enabled != commentByMarker else { return }
        commentByMarker = enabled
        AppSettings.commentByMarker = enabled
        status = enabled
            ? L10n.tr("Комментирование по специальному ключу включено")
            : L10n.tr("Комментирование по специальному ключу выключено")
    }

    func setCommentMarkerSuffix(_ suffix: String) {
        // A newline would split the marker across lines; everything else is
        // allowed, including an empty suffix (the shortcut then does nothing).
        let cleaned = suffix.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard cleaned != commentMarkerSuffix else { return }
        commentMarkerSuffix = cleaned
        AppSettings.commentMarkerSuffix = cleaned
    }

    // MARK: - result font

    var resultFont: NSFont {
        if !resultFontName.isEmpty {
            if let font = NSFont(name: resultFontName, size: resultFontSize) {
                return font
            }
            // Older builds could store a family name instead of a PostScript name.
            if let font = NSFontManager.shared.font(
                withFamily: resultFontName,
                traits: [],
                weight: 5,
                size: resultFontSize
            ) {
                return font
            }
        }
        return .monospacedSystemFont(ofSize: resultFontSize, weight: .regular)
    }

    func setResultFontName(_ name: String) {
        guard name != resultFontName else { return }
        resultFontName = name
        AppSettings.resultFontName = name
        status = L10n.fmt("Шрифт результатов: %@",
                          name.isEmpty ? L10n.tr("системный моноширинный") : ResultFontCatalog.displayName(name))
    }

    func setResultFontSize(_ size: CGFloat) {
        let clamped = min(max(size.rounded(), Self.minResultFontSize), Self.maxResultFontSize)
        guard clamped != resultFontSize else { return }
        resultFontSize = clamped
        AppSettings.resultFontSize = clamped
        status = L10n.fmt("Шрифт результатов: %@ pt", String(Int(clamped)))
    }

    func stepResultFontSize(_ steps: CGFloat) {
        guard steps != 0 else { return }
        setResultFontSize(resultFontSize + steps)
    }

    func increaseResultFontSize() { setResultFontSize(resultFontSize + 1) }

    func decreaseResultFontSize() { setResultFontSize(resultFontSize - 1) }

    func resetResultFontSize() { setResultFontSize(12) }

    // MARK: - time zone

    var displayTimeZone: TimeZone { TimeZones.selected }

    var displayTimeZoneLabel: String { TimeZones.shortLabel(for: displayTimeZone) }

    var displayTimeZoneName: String { TimeZones.displayName(for: displayTimeZone) }

    func setTimeZone(_ identifier: String) {
        guard identifier != timeZoneIdentifier else { return }
        timeZoneIdentifier = identifier
        AppSettings.timeZoneIdentifier = identifier
        status = L10n.fmt("Часовой пояс времени: %@", TimeZones.displayName(for: TimeZones.zone(for: identifier)))
    }

    // MARK: - external file checks

    func setCheckExternalChanges(_ enabled: Bool) {
        guard enabled != checkExternalChanges else { return }
        checkExternalChanges = enabled
        AppSettings.checkExternalChanges = enabled
        if enabled {
            startWatchingExternalChanges()
            checkForExternalChanges()
        } else {
            stopWatchingExternalChanges()
            tabsAwaitingDiskComparison.removeAll()
        }
        status = enabled
            ? L10n.tr("Проверка изменений файлов на диске включена")
            : L10n.tr("Проверка изменений файлов на диске выключена")
    }

    // MARK: - column widths

    var activeQueryName: String { activeTab?.title ?? "" }

    func columnWidths(for query: String) -> [String: CGFloat] {
        ColumnWidthStore.shared.widths(for: query)
    }

    func setColumnWidth(_ width: CGFloat, forColumn column: String) {
        let query = result?.queryName.isEmpty == false ? (result?.queryName ?? "") : activeQueryName
        ColumnWidthStore.shared.set(width, for: column, query: query)
    }

    // MARK: - grid selection and sorting

    /// Anchor of the last row/column click, used by Shift to extend a range.
    private var gridRowAnchor: Int?
    private var gridColumnAnchor: Int?

    /// Selects a whole column. Shift extends from the previous column click;
    /// Ctrl/Cmd adds or removes a single column without clearing the rest.
    func selectResultColumn(_ index: Int, extend: Bool = false, toggle: Bool = false) {
        guard let r = result, index >= 0, index < r.columns.count else { return }
        let wasColumns = gridSelection?.kind == .columns
        var cols: Set<Int>
        if toggle {
            cols = wasColumns ? (gridSelection?.cols ?? []) : []
            if cols.contains(index) {
                cols.remove(index)
            } else {
                cols.insert(index)
            }
            gridColumnAnchor = index
        } else if extend, wasColumns, let anchor = gridColumnAnchor {
            cols = Set(min(anchor, index)...max(anchor, index))
        } else {
            cols = [index]
            gridColumnAnchor = index
        }
        gridSelection = cols.isEmpty ? nil : GridSelection(kind: .columns, cols: cols)
        focusedPane = .result
    }

    /// Selects a whole row (Shift extends, Ctrl/Cmd toggles).
    func selectResultRow(_ row: Int, extend: Bool = false, toggle: Bool = false) {
        guard let r = result, row >= 0, row < r.rows.count else { return }
        let wasRows = gridSelection?.kind == .rows
        var rows: Set<Int>
        if toggle {
            rows = wasRows ? (gridSelection?.rows ?? []) : []
            if rows.contains(row) {
                rows.remove(row)
            } else {
                rows.insert(row)
            }
            gridRowAnchor = row
        } else if extend, wasRows, let anchor = gridRowAnchor {
            rows = Set(min(anchor, row)...max(anchor, row))
        } else {
            rows = [row]
            gridRowAnchor = row
        }
        gridSelection = rows.isEmpty ? nil : GridSelection(kind: .rows, rows: rows)
        focusedPane = .result
    }

    /// Row-number header click: every row and every column.
    func selectEntireResult() {
        guard let r = result, !r.rows.isEmpty, !r.columns.isEmpty else { return }
        gridSelection = GridSelection(kind: .cells,
                                      rows: Set(0..<r.rows.count),
                                      cols: Set(0..<r.columns.count))
        focusedPane = .result
    }

    /// Remembers the visual order of the columns after a header drag. The
    /// order is kept in the result itself, so sorting does not reset it, and
    /// it is discarded when the script is executed again.
    func setResultColumnOrder(_ order: [Int]) {
        guard var r = result else { return }
        guard order.count == r.columns.count,
              Set(order) == Set(r.columns.indices) else { return }
        guard order != r.visualColumnOrder else { return }
        r.columnOrder = order
        result = r
        resultsByTab[activeTabID] = r
        status = L10n.tr("Столбцы переставлены")
    }

    /// First click on a column sorts it descending, the next one ascending, and
    /// so on. Sorting is local to the rows already fetched.
    func toggleResultSort(column index: Int) {
        guard let r = result, index >= 0, index < r.columns.count, !r.rows.isEmpty else { return }
        let ascending: Bool
        if let current = resultSort, current.column == index {
            ascending = !current.ascending
        } else {
            ascending = false
        }
        let sort = ResultSort(column: index, ascending: ascending)
        var updated = r
        let order = Self.sortedOrder(r.rows, column: index, columns: r.columns, sort: sort)
        updated.rows = order.map { r.rows[$0] }
        if updated.rowIDs.count == r.rows.count {
            updated.rowIDs = order.map { r.rowIDs[$0] }
        }
        // Invalidate cached search matches: row positions changed.
        updated.runID = UUID()
        resultSort = sort
        result = updated
        resultsByTab[activeTabID] = updated
        sortsByTab[activeTabID] = sort
        status = L10n.fmt("Сортировка: %@ %@", r.columns[index].name,
                          ascending ? L10n.tr("↑ по возрастанию") : L10n.tr("↓ по убыванию"))
    }

    private static func sortedOrder(
        _ rows: [[String?]],
        column: Int,
        columns: [ColumnInfo],
        sort: ResultSort
    ) -> [Int] {
        let numeric = column < columns.count && columns[column].isNumeric
        // Parse each key once instead of twice per comparison: sorting 100k
        // numeric rows otherwise runs ~1.7M Decimal parses.
        let posix = Locale(identifier: "en_US_POSIX")
        let keyed = rows.enumerated().map { offset, row -> SortKey in
            let value = column < row.count ? row[column] : nil
            let number = numeric ? value.flatMap { Decimal(string: $0, locale: posix) } : nil
            return SortKey(offset: offset, row: row, value: value, number: number)
        }
        return keyed
            .sorted { a, b in
                let order: Int
                switch (a.value, b.value) {
                case (nil, nil): order = 0
                case (nil, _): order = 1   // NULLs last when ascending
                case (_, nil): order = -1
                case let (x?, y?):
                    if let dx = a.number, let dy = b.number {
                        order = dx == dy ? 0 : (dx < dy ? -1 : 1)
                    } else {
                        order = x.localizedStandardCompare(y).rawValue
                    }
                }
                if order == 0 { return a.offset < b.offset }
                return sort.ascending ? order < 0 : order > 0
            }
            .map { $0.offset }
    }

    private struct SortKey {
        let offset: Int
        let row: [String?]
        let value: String?
        let number: Decimal?
    }

    private static func compareValues(_ a: String?, _ b: String?, numeric: Bool) -> Int {
        switch (a, b) {
        case (nil, nil): return 0
        case (nil, _): return 1   // NULLs last when ascending
        case (_, nil): return -1
        case let (x?, y?):
            if numeric,
               let dx = Decimal(string: x, locale: Locale(identifier: "en_US_POSIX")),
               let dy = Decimal(string: y, locale: Locale(identifier: "en_US_POSIX")) {
                if dx == dy { return 0 }
                return dx < dy ? -1 : 1
            }
            return x.localizedStandardCompare(y).rawValue
        }
    }

    func setAutoColumnWidths(_ enabled: Bool) {
        guard enabled != autoColumnWidths else { return }
        autoColumnWidths = enabled
        AppSettings.autoColumnWidths = enabled
        status = enabled ? L10n.tr("Авто-ширина столбцов включена")
            : L10n.tr("Ширина столбцов сохраняется вручную")
    }

    func setMaxAutoColumnWidth(_ width: CGFloat) {
        let clamped = min(max(width.rounded(), Self.minAutoColumnWidth), Self.maxAutoColumnWidthLimit)
        guard clamped != maxAutoColumnWidth else { return }
        maxAutoColumnWidth = clamped
        AppSettings.maxAutoColumnWidth = clamped
        status = L10n.fmt("Максимальная авто-ширина: %@ pt", String(Int(clamped)))
    }

    func resetMaxAutoColumnWidth() {
        setMaxAutoColumnWidth(Self.defaultAutoColumnWidth)
    }

    func setPageSize(_ size: Int) {
        let clamped = min(max(size, Self.minPageSize), Self.maxPageSize)
        guard clamped != pageSize else { return }
        pageSize = clamped
        AppSettings.pageSize = clamped
        status = L10n.fmt("Строк за загрузку: %@", String(clamped))
    }

    func resetPageSize() {
        setPageSize(Self.defaultPageSize)
    }

    func setShowTypeInColumnHeader(_ enabled: Bool) {
        guard enabled != showTypeInColumnHeader else { return }
        showTypeInColumnHeader = enabled
        AppSettings.showTypeInColumnHeader = enabled
        status = enabled ? L10n.tr("Тип данных показан в названии столбца")
            : L10n.tr("Тип данных скрыт из названия столбца")
    }

    func setShowTypeOnHeaderHover(_ enabled: Bool) {
        guard enabled != showTypeOnHeaderHover else { return }
        showTypeOnHeaderHover = enabled
        AppSettings.showTypeOnHeaderHover = enabled
        status = enabled ? L10n.tr("Тип данных показывается при наведении")
            : L10n.tr("Подсказка с типом данных отключена")
    }

    // MARK: - running

    /// DBeaver-style prompt for `:name` values: one field per parameter, plus a
    /// NULL checkbox. The last values are prefilled. Returns nil on cancel.
    private func promptForBindValues(_ names: [String],
                                     profile: ConnectionProfile) -> [String: Any]? {
        let rowHeight: CGFloat = 30
        let width: CGFloat = 430
        let labelWidth: CGFloat = 150
        let fieldWidth: CGFloat = 190
        let height = CGFloat(names.count) * rowHeight

        let content = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var rows: [String: (field: NSTextField, isNull: NSButton)] = [:]
        let previous = bindValues[profile.id] ?? [:]

        for (index, name) in names.enumerated() {
            let y = CGFloat(index) * rowHeight

            let label = NSTextField(labelWithString: ":\(name)")
            label.frame = NSRect(x: 0, y: y + 5, width: labelWidth - 8, height: 20)
            label.alignment = .right
            label.lineBreakMode = .byTruncatingMiddle
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.toolTip = name
            content.addSubview(label)

            let field = NSTextField(frame: NSRect(x: labelWidth, y: y + 3,
                                                 width: fieldWidth, height: 24))
            field.placeholderString = L10n.tr("Значение")
            let old = previous[name]
            field.stringValue = (old as? String) ?? ""
            content.addSubview(field)

            let isNull = NSButton(checkboxWithTitle: "NULL", target: nil, action: nil)
            isNull.frame = NSRect(x: labelWidth + fieldWidth + 12, y: y + 5, width: 60, height: 20)
            isNull.state = old is NSNull ? .on : .off
            content.addSubview(isNull)

            rows[name] = (field, isNull)
        }

        let accessory: NSView
        if height > 240 {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 240))
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.documentView = content
            accessory = scroll
        } else {
            accessory = content
        }

        let alert = NSAlert()
        alert.messageText = L10n.tr("Параметры запроса")
        alert.informativeText = profile.displayName
        alert.addButton(withTitle: L10n.tr("Выполнить"))
        alert.addButton(withTitle: L10n.tr("Отмена"))
        alert.accessoryView = accessory
        if let first = names.first, let row = rows[first] {
            alert.window.initialFirstResponder = row.field
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        var values: [String: Any] = [:]
        for name in names {
            guard let row = rows[name] else { continue }
            values[name] = row.isNull.state == .on ? NSNull() : row.field.stringValue
        }
        bindValues[profile.id] = values
        return values
    }

    func runSelectionOrAll() {
        let selected = editor.selectedText()
        if let selected, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            run(sql: selected)
        } else {
            run(sql: editor.allText())
        }
    }

    func runAll() {
        run(sql: editor.allText())
    }

    func runStatementAtCursor() {
        if let sql = editor.statementAtCursor(), !sql.isEmpty {
            run(sql: sql)
        }
    }

    func run(sql: String) {
        let text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let tabID = activeTabID
        guard let profile = activeScriptProfile else {
            error = DBError(message: L10n.tr("Выберите подключение для этого скрипта"))
            showNoConnectionAlert = true
            bottomTab = .result
            return
        }
        // A tab can only run one query at a time, but other tabs may already
        // be running their own queries.
        guard tabRunStates[tabID] != .running else { return }

        // Ask for `:name` values before switching to the running state, so the
        // dialog is not hidden behind a spinner.
        let parameterNames = SQLText.parameters(in: text)
        var bindValuesForRun: [String: Any] = [:]
        if !parameterNames.isEmpty {
            guard let entered = promptForBindValues(parameterNames, profile: profile) else { return }
            bindValuesForRun = entered
        }

        // Pin the script to the connection it runs against, so the choice is remembered.
        if let idx = activeTabIndex, tabs[idx].profileID == nil {
            tabs[idx].profileID = profile.id
            scheduleTabsSave()
        }

        setRunState(.running, for: tabID)
        runningQueries[tabID] = RunningQuery(profileID: profile.id)
        errorsByTab[tabID] = nil
        error = nil
        bottomTab = .result
        gridSelection = nil
        resetResultEditUI()
        status = L10n.tr("Выполняется…")
        let queryName = activeTab?.title ?? ""

        Task {
            let s = querySession(for: tabID, profile: profile)
            do {
                var r = try await s.execute(text, pageSize: pageSize, params: bindValuesForRun)
                // The tab may have been closed while the query was running.
                guard tabs.contains(where: { $0.id == tabID }) else {
                    if !r.done, let qid = r.queryId { s.cancel(qid) }
                    runningQueries[tabID] = nil
                    setRunState(.idle, for: tabID)
                    return
                }
                r.queryName = queryName
                r.profileID = profile.id
                r.rowIDs = Self.makeRowIDs(count: r.rows.count)
                connected.insert(profile.id)
                resultsByTab[tabID] = r
                sortsByTab[tabID] = nil
                loadTableMeta(for: r)
                if tabID == activeTabID {
                    result = r
                    resultSort = nil
                }
                let cancelled = runningQueries[tabID]?.cancelled ?? false
                runningQueries[tabID] = nil
                setRunState(cancelled ? .idle : .succeeded, for: tabID)
                if tabID == activeTabID {
                    if let uc = r.updateCount {
                        status = L10n.fmt("Готово: изменено строк %@ · %@ мс", String(uc), String(r.durationMs))
                    } else {
                        status = Self.runStatus(rows: r.rows.count, done: r.done,
                                                durationMs: r.durationMs, total: nil)
                    }
                }
                appendHistory(profile: profile, sql: text, result: r, error: nil)

                // The total is counted in the background, after the first page
                // is already on screen, and only when the result is larger than
                // what was loaded.
                if r.updateCount == nil, !r.columns.isEmpty, !r.done || r.truncated,
                   let countSQL = Self.countSQL(for: text) {
                    countTotalRows(countSQL, originalSQL: r.sql, session: s,
                                   tabID: tabID, params: bindValuesForRun)
                }
            } catch {
                let cancelled = runningQueries[tabID]?.cancelled ?? false
                runningQueries[tabID] = nil
                guard tabs.contains(where: { $0.id == tabID }) else {
                    setRunState(.idle, for: tabID)
                    return
                }
                setRunState(cancelled ? .idle : .failed, for: tabID)
                let dbError = (error as? SidecarError)?.dbError ?? DBError(message: error.localizedDescription)
                if !cancelled {
                    errorsByTab[tabID] = dbError
                }
                if tabID == activeTabID {
                    if !cancelled { self.error = dbError }
                    status = cancelled ? L10n.tr("Отменено") : L10n.tr("Ошибка")
                }
                noteConnectionFailure(error, profile: profile)
                appendHistory(profile: profile, sql: text, result: nil,
                              error: cancelled ? nil : dbError.message)
            }
        }
    }

    private func setRunState(_ state: TabRunState, for tabID: UUID) {
        // A finished query leaves no marker on the tab the user is already
        // looking at: the dot means "there is a result you have not seen yet".
        if state == .idle || (tabID == activeTabID && state != .running) {
            tabRunStates.removeValue(forKey: tabID)
        } else {
            tabRunStates[tabID] = state
        }
    }

    /// "Готово: 200+ строк · 737 мс (всего 12 345 строк)".
    static func runStatus(rows: Int, done: Bool, durationMs: Int, total: Int?) -> String {
        var text = L10n.fmt("Готово: %@%@ строк · %@ мс",
                            String(rows), done ? "" : "+", String(durationMs))
        if let total {
            text += " " + L10n.fmt("(всего %@ строк)", String(total))
        }
        return text
    }

    /// Wraps the first statement of the script into `select count(*) from (…)`.
    /// Only row-returning statements are worth counting.
    static func countSQL(for sql: String) -> String? {
        guard let first = SQLText.statements(in: sql).first?.text else { return nil }
        var body = first.trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasSuffix(";") { body.removeLast() }
        guard !body.isEmpty, startsWithSelect(body) else { return nil }
        return "SELECT count(*) FROM (\n\(body)\n) dbooyvol_count"
    }

    /// True for SELECT/WITH/VALUES/TABLE, ignoring leading comments.
    private static func startsWithSelect(_ sql: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: "^(?:\\s+|--[^\\n]*\\n?|/\\*.*?\\*/)*(select|with|values|table)\\b",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return false }
        let range = NSRange(location: 0, length: (sql as NSString).length)
        return regex.firstMatch(in: sql, options: [], range: range) != nil
    }

    private func countTotalRows(_ countSQL: String, originalSQL: String,
                                session: Session, tabID: UUID, params: [String: Any] = [:]) {
        Task {
            guard let total = try? await session.countRows(countSQL, params: params) else { return }
            applyTotalRows(total, originalSQL: originalSQL, tabID: tabID)
        }
    }

    /// Stores the counted total on the result it belongs to, if that result is
    /// still the one shown for the tab.
    private func applyTotalRows(_ total: Int, originalSQL: String, tabID: UUID) {
        guard var r = resultsByTab[tabID], r.sql == originalSQL else { return }
        r.totalRows = total
        resultsByTab[tabID] = r
        guard tabID == activeTabID, result?.sql == originalSQL, result?.updateCount == nil else { return }
        result?.totalRows = total
        status = Self.runStatus(rows: r.rows.count, done: r.done,
                                durationMs: r.durationMs, total: total)
    }

    /// Cmd+R: runs the selection (or the whole script), or stops the query
    /// that is running in this tab.
    func runOrStop() {
        if isRunning {
            cancel()
        } else {
            runSelectionOrAll()
        }
    }

    func cancel() {
        let tabID = activeTabID
        guard var query = runningQueries[tabID] else { return }
        query.cancelled = true
        runningQueries[tabID] = query
        if let session = tabSessions[tabID] ?? sessions[query.profileID] {
            if let qid = query.queryID {
                session.cancel(qid)
            } else {
                session.cancelConnection()
            }
        }
        status = L10n.tr("Отмена…")
    }

    func loadMore() {
        let tabID = activeTabID
        guard let r = resultsByTab[tabID], let qid = r.queryId, !r.done,
              tabRunStates[tabID] != .running else { return }
        guard let profile = profiles.first(where: { $0.id == r.profileID }) ?? activeScriptProfile else { return }
        let querySession = querySession(for: tabID, profile: profile)
        setRunState(.running, for: tabID)
        Task {
            do {
                let page = try await querySession.fetch(qid, count: pageSize)
                guard tabs.contains(where: { $0.id == tabID }) else {
                    setRunState(.idle, for: tabID)
                    return
                }
                var updated = resultsByTab[tabID] ?? r
                updated.rows.append(contentsOf: page.rows)
                updated.rowIDs.append(contentsOf: Self.makeRowIDs(count: page.rows.count))
                updated.done = page.done
                updated.queryId = page.done ? nil : qid
                if let sort = sortsByTab[tabID] ?? resultSort {
                    let order = Self.sortedOrder(updated.rows, column: sort.column,
                                                 columns: updated.columns, sort: sort)
                    updated.rows = order.map { updated.rows[$0] }
                    if updated.rowIDs.count == updated.rows.count {
                        updated.rowIDs = order.map { updated.rowIDs[$0] }
                    }
                    updated.runID = UUID()
                }
                resultsByTab[tabID] = updated
                if tabID == activeTabID {
                    result = updated
                    if let total = updated.totalRows {
                        status = L10n.fmt("Загружено %@ строк (всего %@ строк)",
                                          String(updated.rows.count), String(total))
                    } else {
                        status = L10n.fmt("Загружено %@ строк", String(updated.rows.count))
                    }
                }
                setRunState(.succeeded, for: tabID)
            } catch {
                let dbError = (error as? SidecarError)?.dbError ?? DBError(message: error.localizedDescription)
                errorsByTab[tabID] = dbError
                if tabID == activeTabID { self.error = dbError }
                setRunState(.failed, for: tabID)
            }
        }
    }

    private func appendHistory(profile: ConnectionProfile, sql: String, result: QueryResult?, error: String?) {
        var entry = HistoryEntry()
        entry.profile = profile.displayName
        entry.sql = sql
        entry.durationMs = result?.durationMs ?? 0
        entry.rowCount = result?.rows.count ?? 0
        entry.error = error
        entry.columns = result?.columns.map { $0.name } ?? []
        entry.rows = (result?.rows.prefix(200) ?? []).map { row in
            row.map { $0.map { String($0.prefix(1000)) } }
        }
        historyStore.append(entry)
        history = historyStore.entries
    }

    func clearHistory() {
        historyStore.clear()
        history = []
        status = L10n.tr("История запросов очищена")
    }

    /// Changes how deep the history goes. Shortening the period removes old
    /// entries immediately, both from the list and from the file.
    func setHistoryRetentionDays(_ days: Int) {
        let value = max(0, days)
        guard value != historyRetentionDays else { return }
        historyRetentionDays = value
        AppSettings.historyRetentionDays = value
        historyStore.setRetention(days: value)
        history = historyStore.entries
        if let option = HistoryRetention(rawValue: value) {
            status = L10n.fmt("История: %@", option.title)
        } else {
            status = L10n.fmt("История: %@ дней", String(value))
        }
    }

    func loadHistoryIntoEditor(_ entry: HistoryEntry) {
        newTab(text: entry.sql)
    }

    // MARK: - value panel

    /// Opens the value inspector for one cell. Called from the grid context
    /// menu, so the panel always shows exactly the cell that was clicked.
    func showValuePanel(row: Int, col: Int) {
        guard let item = valuePanelItem(row: row, col: col) else { return }
        valuePanelItem = item
        valuePanelKind = .auto
        showValuePanel = true
    }

    /// Header button: shows the current cell, or hides the panel when it is
    /// already open.
    func toggleValuePanel() {
        if showValuePanel {
            showValuePanel = false
            return
        }
        guard let result else { return }
        let row = gridSelection?.rows.sorted().first ?? 0
        let col = gridSelection?.cols.sorted().first ?? 0
        guard row < result.rows.count, col < result.columns.count else { return }
        showValuePanel(row: row, col: col)
    }

    /// Keeps the open panel in sync while the user moves around the grid.
    func followValuePanel(row: Int, col: Int) {
        guard showValuePanel, let item = valuePanelItem(row: row, col: col) else { return }
        if item != valuePanelItem { valuePanelItem = item }
    }

    private func valuePanelItem(row: Int, col: Int) -> ValuePanelItem? {
        guard let result, row >= 0, row < result.rows.count,
              col >= 0, col < result.columns.count else { return nil }
        let values = result.rows[row]
        let column = result.columns[col]
        return ValuePanelItem(
            row: row,
            column: col,
            columnName: column.name,
            columnType: column.type,
            value: col < values.count ? values[col] : nil,
            rowNumber: row + 1
        )
    }

    // MARK: - table metadata

    func tableMetaKey(profileID: UUID?, catalog: String, schema: String, table: String) -> String {
        "\(profileID?.uuidString ?? "-")|\(catalog)|\(schema)|\(table)"
    }

    /// Loads metadata for every table that contributed a column to the
    /// result, so header tooltips can be shown without waiting.
    func loadTableMeta(for result: QueryResult) {
        guard let profileID = result.profileID,
              let profile = profiles.first(where: { $0.id == profileID }) else { return }
        var tables: [String: ColumnInfo] = [:]
        for column in result.columns where !column.table.isEmpty {
            let key = tableMetaKey(profileID: profileID, catalog: column.catalog,
                                   schema: column.schema, table: column.table)
            tables[key] = column
        }
        for (key, column) in tables where tableMetaCache[key] == nil && !tableMetaRequests.contains(key) {
            tableMetaRequests.insert(key)
            let s = session(for: profile)
            Task { @MainActor in
                defer { self.tableMetaRequests.remove(key) }
                guard let meta = try? await s.tableMeta(catalog: column.catalog,
                                                        schema: column.schema,
                                                        table: column.table) else { return }
                self.tableMetaCache[key] = meta
            }
        }
    }

    func tableMeta(for column: ColumnInfo, profileID: UUID?) -> TableMeta? {
        guard !column.table.isEmpty else { return nil }
        return tableMetaCache[tableMetaKey(profileID: profileID, catalog: column.catalog,
                                           schema: column.schema, table: column.table)]
    }

    // MARK: - language

    func setAppLanguage(_ language: AppLanguage) {
        guard language != appLanguage else { return }
        appLanguage = language
        AppLanguage.store(language)
        languageNeedsRestart = true
        status = language == .system
            ? L10n.tr("Язык: системный — перезапустите приложение")
            : L10n.fmt("Язык: %@ — перезапустите приложение", language.nativeName)
    }

    /// Saves the open scripts and starts a fresh copy of the app, so the new
    /// `AppleLanguages` value is picked up.
    func relaunchForLanguage() {
        flushTabs()
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - tabs

    var activeTab: QueryTab? {
        tabs.first { $0.id == activeTabID }
    }

    var activeTabIndex: Int? {
        tabs.firstIndex { $0.id == activeTabID }
    }

    var autosaveEnabled: Bool { AppSettings.autosaveTabs }

    private func restoreTabs() {
        if autosaveEnabled, let snap = TabsStore.load(), !snap.tabs.isEmpty {
            tabs = snap.tabs
            // Untitled tabs store the title in the language that was active
            // when they were created, so switching the UI language left them
            // in the old language (for example "SQL-Abfrage 1" on Russian).
            // Re-render only auto-named tabs; a manual rename sets
            // `customTitle` and is never touched.
            localizeUntitledTitles()
            // A restored tab keeps the text it had in the previous session.
            // When disk checking is enabled, compare it with the file it was
            // opened from: the text may be an unsaved edit (or a completely
            // different draft), and that has to be reported when the tab is
            // opened, not silently forgotten.
            if checkExternalChanges {
                for i in tabs.indices {
                    tabs[i].isDirty = false
                    guard let path = tabs[i].filePath,
                          let diskText = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                    diskContents[tabs[i].id] = Self.fileState(of: path, text: diskText)
                    if tabs[i].text != diskText {
                        tabs[i].isDirty = true
                        tabsAwaitingDiskComparison.insert(tabs[i].id)
                    }
                }
            }
            if let id = snap.activeID, tabs.contains(where: { $0.id == id }) {
                activeTabID = id
            } else {
                activeTabID = tabs[0].id
            }
            if let bound = activeTab?.profileID, profiles.contains(where: { $0.id == bound }) {
                activeProfileID = bound
            }
        } else {
            let tab = QueryTab(title: Self.untitledTitle(1), text: Self.welcomeText)
            tabs = [tab]
            activeTabID = tab.id
        }
    }

    func newTab(text: String? = nil, filePath: String? = nil, title: String? = nil, activate: Bool = true) {
        syncActiveTab()
        var tab = QueryTab()
        tab.text = text ?? ""
        tab.filePath = filePath
        tab.title = title ?? nextUntitledTitle()
        tab.customTitle = title != nil
        tab.profileID = activeScriptProfileID ?? activeProfileID
        tabs.append(tab)
        if activate {
            activeTabID = tab.id
            applyResultForActiveTab()
        }
        scheduleTabsSave()
        if activate { DispatchQueue.main.async { [weak self] in self?.editor.focus() } }
    }

    private func nextUntitledTitle() -> String {
        var n = 1
        while tabs.contains(where: { $0.title == Self.untitledTitle(n) }) { n += 1 }
        return Self.untitledTitle(n)
    }

    private static func untitledTitle(_ number: Int) -> String {
        L10n.fmt("Запрос %@", String(number))
    }

    /// Rewrites auto-generated tab titles in the current UI language. Only the
    /// label changes; the query text is never touched. Manually renamed tabs
    /// and tabs opened from a file keep their titles.
    private func localizeUntitledTitles() {
        var changed = false
        for i in tabs.indices {
            guard !tabs[i].customTitle, tabs[i].filePath == nil,
                  let number = Self.trailingNumber(in: tabs[i].title) else { continue }
            let localized = Self.untitledTitle(number)
            if tabs[i].title != localized {
                tabs[i].title = localized
                changed = true
            }
        }
        if changed { scheduleTabsSave() }
    }

    /// Trailing number of an auto-generated title ("Запрос 12", "SQL-Abfrage 3").
    /// A number glued to a word is left alone, so "Query2" is not treated as
    /// an untitled tab.
    private static func trailingNumber(in title: String) -> Int? {
        let digits = title.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let prefix = title.dropLast(digits.count)
        guard prefix.hasSuffix(" "), let value = Int(String(digits.reversed())) else { return nil }
        return value
    }

    func selectTab(_ id: UUID) {
        guard id != activeTabID, tabs.contains(where: { $0.id == id }) else { return }
        syncActiveTab()
        inlineRenameTabID = nil
        activeTabID = id
        applyResultForActiveTab()
        if let bound = tabs.first(where: { $0.id == id })?.profileID,
           profiles.contains(where: { $0.id == bound }) {
            activeProfileID = bound
        }
        scheduleTabsSave()
        _ = checkExternalChange(for: id)
        DispatchQueue.main.async { [weak self] in self?.editor.focus() }
    }

    /// A click on a tab. When the tab is already active nothing changes — no
    /// text reload and no focus event — so smart selection would never run.
    /// Re-apply it explicitly so clicking the active tab focuses the filter
    /// value again.
    func clickTab(_ id: UUID) {
        let wasActive = id == activeTabID
        selectTab(id)
        guard wasActive else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.editor.focus()
            self.applySmartSelection()
        }
    }

    /// Shows the result that belongs to the active tab.
    private func applyResultForActiveTab() {
        let id = activeTabID
        // The result is on screen now, so the "unseen result" dot is done.
        if tabRunStates[id] == .succeeded || tabRunStates[id] == .failed {
            tabRunStates.removeValue(forKey: id)
        }
        result = resultsByTab[id]
        resultSort = sortsByTab[id]
        error = errorsByTab[id]
        gridSelection = nil
        if showResultSearch {
            closeResultSearch()
        }
        // Unsaved edits belong to the tab, not to the window.
        if let r = result, !r.editedCells.isEmpty || !r.insertedRowIDs.isEmpty {
            cancelEditHide()
            resultEditPhase = .pending
            resultEditMessage = ""
            resultEditMessageIsError = false
        } else if resultEditPhase != .saving {
            resetResultEditUI()
        }

        // The status bar belongs to the tab that is visible now.
        if tabRunStates[id] == .running {
            status = L10n.tr("Выполняется…")
        } else if errorsByTab[id] != nil {
            status = L10n.tr("Ошибка")
        } else if let r = result {
            if let uc = r.updateCount {
                status = L10n.fmt("Готово: изменено строк %@ · %@ мс", String(uc), String(r.durationMs))
            } else {
                status = Self.runStatus(rows: r.rows.count, done: r.done,
                                        durationMs: r.durationMs, total: r.totalRows)
            }
        } else {
            status = L10n.tr("Готово")
        }
    }

    func selectNextTab() {
        guard tabs.count > 1, let idx = activeTabIndex else { return }
        selectTab(tabs[(idx + 1) % tabs.count].id)
    }

    func selectPreviousTab() {
        guard tabs.count > 1, let idx = activeTabIndex else { return }
        selectTab(tabs[(idx - 1 + tabs.count) % tabs.count].id)
    }

    /// ⌘⇧T: returns to the tab that was active before the current one. The
    /// shortcut itself updates the remembered tab, so pressing it again goes
    /// back, i.e. toggles between the two most recent tabs.
    func selectPreviouslyOpenedTab() {
        guard let id = previousTabID, id != activeTabID,
              tabs.contains(where: { $0.id == id }) else {
            previousTabID = nil
            return
        }
        selectTab(id)
    }

    private func recordTabSwitch(from old: UUID, to new: UUID) {
        guard old != new, tabs.contains(where: { $0.id == old }) else { return }
        previousTabID = old
    }

    func closeTab(_ id: UUID) {
        syncActiveTab()
        if inlineRenameTabID == id { inlineRenameTabID = nil }
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        if needsCloseConfirmation(tab) {
            let alert = NSAlert()
            alert.messageText = String(format: L10n.tr("Закрыть «%@»?"), tab.title)
            alert.informativeText = L10n.tr("Есть несохранённые изменения.")
            alert.addButton(withTitle: L10n.tr("Сохранить"))
            alert.addButton(withTitle: L10n.tr("Закрыть без сохранения"))
            alert.addButton(withTitle: L10n.tr("Отмена"))
            let response = alert.runModal()
            if response == .alertThirdButtonReturn { return }
            if response == .alertFirstButtonReturn {
                guard saveTab(id) else { return }
            }
        }
        if let query = runningQueries[id],
           let session = tabSessions[id] ?? sessions[query.profileID] {
            if let qid = query.queryID {
                session.cancel(qid)
            } else {
                session.cancelConnection()
            }
        }
        tabSessions[id]?.disconnect()
        tabSessions[id] = nil
        runningQueries[id] = nil
        tabRunStates[id] = nil
        errorsByTab[id] = nil
        tabsAwaitingDiskComparison.remove(id)
        tabs.remove(at: idx)
        resultsByTab[id] = nil
        sortsByTab[id] = nil
        diskContents[id] = nil
        if tabs.isEmpty {
            let tab = QueryTab(title: Self.untitledTitle(1), text: "")
            tabs = [tab]
            activeTabID = tab.id
        } else if activeTabID == id {
            activeTabID = tabs[min(idx, tabs.count - 1)].id
            applyResultForActiveTab()
        }
        scheduleTabsSave()
        DispatchQueue.main.async { [weak self] in self?.editor.focus() }
    }

    /// Moves a tab into an insertion slot of the current order (`0...count`),
    /// which is what dragging a chip between other chips produces.
    func moveTab(_ id: UUID, to slot: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(slot, tabs.count))
        guard target != from, target != from + 1 else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: target > from ? target - 1 : target)
        scheduleTabsSave()
    }

    func closeOtherTabs(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        for (tabID, query) in runningQueries where tabID != id {
            if let session = tabSessions[tabID] ?? sessions[query.profileID] {
                if let qid = query.queryID {
                    session.cancel(qid)
                } else {
                    session.cancelConnection()
                }
            }
        }
        tabs = tabs.filter { $0.id == id }
        resultsByTab = resultsByTab.filter { $0.key == id }
        sortsByTab = sortsByTab.filter { $0.key == id }
        diskContents = diskContents.filter { $0.key == id }
        for (tabID, session) in tabSessions where tabID != id {
            session.disconnect()
        }
        tabSessions = tabSessions.filter { $0.key == id }
        runningQueries = runningQueries.filter { $0.key == id }
        tabRunStates = tabRunStates.filter { $0.key == id }
        errorsByTab = errorsByTab.filter { $0.key == id }
        tabsAwaitingDiskComparison = tabsAwaitingDiskComparison.filter { $0 == id }
        activeTabID = id
        applyResultForActiveTab()
        inlineRenameTabID = nil
        scheduleTabsSave()
    }

    func closeAllTabs() {
        for tab in tabs {
            closeTab(tab.id)
        }
    }

    /// Duplicates a tab under "<name> 2" (then 3, 4, … if that name is taken).
    /// The copy is not bound to the original file, so saving it never overwrites the source.
    func duplicateTab(_ id: UUID) {
        syncActiveTab()
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let source = tabs[idx]
        var copy = source
        copy.id = UUID()
        copy.title = nextDuplicateTitle(source.title)
        copy.filePath = nil
        copy.customTitle = true
        copy.isDirty = !source.text.isEmpty
        copy.selectionLocation = 0
        copy.selectionLength = 0
        tabs.insert(copy, at: idx + 1)
        activeTabID = copy.id
        inlineRenameTabID = nil
        scheduleTabsSave()
        DispatchQueue.main.async { [weak self] in self?.editor.focus() }
    }

    private func nextDuplicateTitle(_ title: String) -> String {
        var n = 2
        while tabs.contains(where: { $0.title == "\(title) \(n)" }) { n += 1 }
        return "\(title) \(n)"
    }

    private func needsCloseConfirmation(_ tab: QueryTab) -> Bool {
        if tab.filePath != nil { return tab.isDirty }
        guard !autosaveEnabled else { return false }
        return !tab.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func beginRename(_ tab: QueryTab) {
        inlineRenameTabID = tab.id
    }

    func applyRename(_ id: UUID, title: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if inlineRenameTabID == id { inlineRenameTabID = nil }
            return
        }
        let oldTitle = tabs[idx].title

        // A tab opened from a file renames that file on disk as well.
        if let oldPath = tabs[idx].filePath {
            let directory = URL(fileURLWithPath: oldPath).deletingLastPathComponent()
            let oldExtension = (oldPath as NSString).pathExtension
            var newName = trimmed
            if !oldExtension.isEmpty, (newName as NSString).pathExtension.isEmpty {
                newName += ".\(oldExtension)"
            }
            let newPath = directory.appendingPathComponent(newName).path
            if newPath != oldPath {
                guard !FileManager.default.fileExists(atPath: newPath) else {
                    error = DBError(message: L10n.fmt("Файл «%@» уже существует", newName))
                    return
                }
                do {
                    try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
                    tabs[idx].filePath = newPath
                } catch {
                    self.error = DBError(message: L10n.fmt("Не удалось переименовать файл: %@", error.localizedDescription))
                    return
                }
            }
            tabs[idx].title = newName
        } else {
            tabs[idx].title = trimmed
        }

        tabs[idx].customTitle = true
        let finalTitle = tabs[idx].title
        if oldTitle != finalTitle { ColumnWidthStore.shared.rename(from: oldTitle, to: finalTitle) }
        if inlineRenameTabID == id { inlineRenameTabID = nil }
        scheduleTabsSave()
    }

    /// Pulls the current text view content into the active tab model.
    func syncActiveTab() {
        guard let tv = editor.textView, let idx = activeTabIndex else { return }
        // The editor updates asynchronously after a tab switch. If it still
        // shows another tab, its text must not overwrite the new tab (this is
        // what made several files opened at once share one script).
        guard editor.displayedTabID == activeTabID else { return }
        let range = tv.selectedRange()
        if tabs[idx].text != tv.string {
            tabs[idx].text = tv.string
            tabs[idx].isDirty = true
        }
        tabs[idx].selectionLocation = range.location
        tabs[idx].selectionLength = range.length
    }

    /// Recomputes the caret line/column/offset shown in the status bar.
    func updateCaret(location: Int, in text: String) {
        let ns = text as NSString
        let loc = min(max(0, location), ns.length)
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                        for: NSRange(location: loc, length: 0))
        var line = 1
        var i = 0
        while i < lineStart {
            if ns.character(at: i) == 10 { line += 1 }
            i += 1
        }
        let column = loc - lineStart + 1
        if caretLine != line { caretLine = line }
        if caretColumn != column { caretColumn = column }
        if caretOffset != loc { caretOffset = loc }
    }

    /// Called by the editor on every user edit.
    func editorTextChanged(_ text: String) {
        guard let idx = activeTabIndex else { return }
        guard tabs[idx].text != text else { return }
        tabs[idx].text = text
        tabs[idx].isDirty = true
        if !tabs[idx].customTitle {
            tabs[idx].title = Self.deriveTitle(text, fallback: tabs[idx].title)
        }
        scheduleTabsSave()
    }

    static func deriveTitle(_ text: String, fallback: String) -> String {
        for line in text.split(separator: "\n", maxSplits: 12) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("--") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                continue
            }
            let single = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return single.count > 28 ? String(single.prefix(28)) + "…" : single
        }
        return fallback
    }

    /// Replaces the active tab content (history, tree double click, "clear").
    func setActiveTabText(_ text: String) {
        guard let idx = activeTabIndex else { return }
        tabs[idx].text = text
        tabs[idx].isDirty = true
        if !tabs[idx].customTitle {
            tabs[idx].title = Self.deriveTitle(text, fallback: tabs[idx].title)
        }
        editor.setText(text)
        editor.focus()
        scheduleTabsSave()
    }

    private func scheduleTabsSave() {
        guard autosaveEnabled else { return }
        tabsSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistTabs() }
        tabsSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func persistTabs() {
        guard autosaveEnabled else { return }
        syncActiveTab()
        TabsStore.save(TabsSnapshot(tabs: tabs, activeID: activeTabID))
    }

    func flushTabs() {
        tabsSaveWork?.cancel()
        persistTabs()
        ColumnWidthStore.shared.flush()
    }

    // MARK: - quick open

    func openQuickOpen() {
        quickOpenChoseTab = false
        showQuickOpen = true
    }

    func selectTabFromSearch(_ id: UUID) {
        quickOpenChoseTab = true
        focusCameFromSearch = true
        if id != activeTabID {
            selectTab(id)
        }
        showQuickOpen = false
    }

    /// Runs after the quick-open sheet has actually disappeared. Focusing the
    /// editor earlier is not enough: AppKit restores the previous responder
    /// (often the tab strip) while the sheet is still being dismissed.
    func quickOpenDidDismiss() {
        guard quickOpenChoseTab else { return }
        quickOpenChoseTab = false
        focusEditor()
    }

    /// Gives the editor the keyboard and releases the tab strip's scroll
    /// target, so a wheel gesture right after a jump scrolls the query.
    func focusEditor() {
        focusedPane = .editor
        editor.focus()
        NotificationCenter.default.post(name: .editorDidTakeFocus, object: nil)
        applySmartSelection()
    }

    /// "Умное выделение": select the value of the first quoted filter
    /// parameter in WHERE. Called when the editor gets focus and when another
    /// tab is opened, because switching tabs keeps the editor focused and
    /// therefore produces no focus event. Deferred by one run-loop tick, so a
    /// mouse click that caused the focus does not move the caret back.
    func applySmartSelection() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppSettings.smartSelectionKey) else {
            focusCameFromSearch = false
            return
        }
        let onlyInSearch = defaults.bool(forKey: AppSettings.smartSelectionOnlyInSearchKey)
        let tabID = activeTabID
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeTabID == tabID,
                  self.editor.displayedTabID == tabID,
                  let tv = self.editor.textView,
                  let range = SQLText.firstQuotedFilterValue(in: tv.string),
                  range.length > 0 else { return }
            // Consume the search flag only when the selection is actually
            // applied. If the editor has not loaded the tab yet, the sync hook
            // calls us again and the flag must still be there.
            if onlyInSearch, !self.focusCameFromSearch { return }
            self.focusCameFromSearch = false
            tv.setSelectedRange(range)
            tv.scrollRangeToVisible(range)
        }
    }

    // MARK: - editor actions

    func refreshTree() {
        treeRefreshToken += 1
    }

    func clearEditor() {
        setActiveTabText("")
    }

    /// Cmd+F: opens search in the pane that currently has focus.
    func findFocusedPane() {
        switch focusedPane {
        case .editor:
            if let tv = editor.textView {
                let sel = tv.selectedRange()
                if sel.length > 0, sel.length <= 200 {
                    editorSearchQuery = (tv.string as NSString).substring(with: sel)
                }
            }
            showEditorSearch = true
            editorSearchFocusToken += 1
            applyEditorSearch()
        case .result:
            openResultSearch()
        }
    }

    /// Highlights every layout-aware match in the active script and selects
    /// the first one. Returns the number of matches.
    @discardableResult
    func applyEditorSearch() -> Int {
        let query = editorSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            editor.clearSearchHighlight()
            editorSearchCount = 0
            return 0
        }
        let count = editor.highlightSearch(query)
        editorSearchCount = count
        return count
    }

    func stepEditorSearch(forward: Bool) {
        if editorSearchCount == 0, !editorSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyEditorSearch()
            return
        }
        editor.selectSearchMatch(forward: forward)
    }

    func closeEditorSearch() {
        showEditorSearch = false
        editorSearchQuery = ""
        editorSearchCount = 0
        editor.clearSearchHighlight()
    }

    func openResultSearch() {
        bottomTab = .result
        showResultSearch = true
        resultSearchFocusToken += 1
    }

    func stepResultSearch(forward: Bool) {
        resultSearchNav += forward ? 1 : -1
    }

    func closeResultSearch() {
        showResultSearch = false
        resultSearchQuery = ""
        resultSearchCount = 0
        resultSearchNav = 0
    }

    /// Files opened with ⌘O are routed by extension: database files become
    /// connections, everything else opens as a script.
    static let databaseExtensions: Set<String> = ["db", "sqlite", "sqlite3", "s3db", "db3"]

    static func isDatabaseFile(_ url: URL) -> Bool {
        databaseExtensions.contains(url.pathExtension.lowercased())
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .sourceCode, .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Скрипты .sql открываются во вкладке, базы .db / .sqlite — как подключение"
        guard panel.runModal() == .OK else { return }
        // Remember the connection selected in the tree once: opening an
        // already-open tab must not change where the remaining files go.
        let selected = activeProfileID
        for url in panel.urls {
            openFile(url, binding: selected)
        }
    }

    func openFile(_ url: URL) {
        openFile(url, binding: activeProfileID)
    }

    /// Files dropped onto the window. A drop on a connection binds the opened
    /// scripts to that connection; anywhere else uses the selected one.
    func openDroppedFiles(_ urls: [URL], binding: UUID?) {
        guard !urls.isEmpty else { return }
        let target = binding ?? activeProfileID
        if let target, profiles.contains(where: { $0.id == target }) {
            activeProfileID = target
        }
        for url in urls {
            openFile(url, binding: target, forceBinding: true)
        }
    }

    private func openFile(_ url: URL, binding: UUID?, forceBinding: Bool = false) {
        if Self.isDatabaseFile(url) {
            openDatabaseFile(url)
        } else {
            openScriptFile(url, binding: binding, forceBinding: forceBinding)
        }
    }

    /// Opens a .db/.sqlite file as a SQLite connection instead of a script.
    func openDatabaseFile(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let existing = profiles.first(where: { $0.kind.isFileBased && $0.database == path }) {
            activeProfileID = existing.id
            refreshTree()
            status = L10n.fmt("Открыта база %@", url.lastPathComponent)
            return
        }

        var profile = ConnectionProfile()
        profile.kind = .sqlite
        profile.name = url.lastPathComponent
        profile.database = path
        profile.host = ""
        profile.port = 0
        profile.user = ""
        profile.driverPath = ""
        saveProfile(profile, password: "")
        activeProfileID = profile.id
        refreshTree()
        status = L10n.fmt("Открыта база %@", url.lastPathComponent)

        // A .db file is not necessarily SQLite. Keep the connection only if the
        // file can actually be read, otherwise show why it was rejected.
        Task { @MainActor in
            do {
                // Opening a file is lazy in sqlite-jdbc: only a real query
                // tells a SQLite database apart from any other .db file.
                _ = try await Session(profile: profile).execute("SELECT count(*) FROM sqlite_master")
            } catch {
                if profiles.contains(where: { $0.id == profile.id }) {
                    deleteProfile(profile.id)
                }
                let message = (error as? SidecarError)?.dbError.message ?? error.localizedDescription
                self.error = DBError(message: L10n.fmt("Не удалось открыть %@: %@", url.lastPathComponent, message))
                status = L10n.fmt("Не удалось открыть %@", url.lastPathComponent)
            }
        }
    }

    private func openScriptFile(_ url: URL, binding: UUID?, forceBinding: Bool) {
        if let existing = tabs.first(where: { $0.filePath == url.path }) {
            if let idx = tabs.firstIndex(where: { $0.id == existing.id }),
               forceBinding || tabs[idx].profileID == nil {
                tabs[idx].profileID = binding
                scheduleTabsSave()
            }
            selectTab(existing.id)
            _ = checkExternalChange(for: existing.id)
            return
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            error = DBError(message: L10n.fmt("Не удалось прочитать %@ как текст", url.lastPathComponent))
            return
        }
        newTab(text: text, filePath: url.path, title: url.lastPathComponent)
        // A script opened from disk belongs to the connection selected in the
        // tree at that moment, not to the connection of the previous tab.
        if let idx = tabs.firstIndex(where: { $0.filePath == url.path }) {
            tabs[idx].profileID = binding
            diskContents[tabs[idx].id] = Self.fileState(of: url.path, text: text)
        }
        status = L10n.fmt("Открыт %@", url.lastPathComponent)
        scheduleTabsSave()
    }

    func saveSQLFile() {
        guard let id = activeTabID as UUID? else { return }
        _ = saveTab(id)
    }

    func saveSQLFileAs() {
        guard let id = activeTabID as UUID? else { return }
        _ = saveTabAs(id)
    }

    @discardableResult
    func saveTab(_ id: UUID) -> Bool {
        syncActiveTab()
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return false }
        if tabs[idx].filePath == nil { return saveTabAs(id) }
        return writeTab(id)
    }

    /// Always asks for a path, even when the tab is already linked to a file.
    @discardableResult
    func saveTabAs(_ id: UUID) -> Bool {
        syncActiveTab()
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return false }
        var tab = tabs[idx]

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let base = tab.title.isEmpty ? "query" : tab.title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = base.hasSuffix(".sql") ? base : base + ".sql"
        if let current = tab.filePath {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        tab.filePath = url.path
        tab.title = url.lastPathComponent
        tab.customTitle = true
        tabs[idx] = tab
        // Saving under a new name is an explicit choice of the target file.
        diskContents[id] = nil
        tabsAwaitingDiskComparison.remove(id)
        return writeTab(id)
    }

    private func writeTab(_ id: UUID) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return false }
        var tab = tabs[idx]
        guard let path = tab.filePath else { return false }

        // Do not silently overwrite a file that another program changed.
        if let known = diskContents[id],
           let diskText = try? String(contentsOfFile: path, encoding: .utf8),
           diskText != known.text {
            if !promptExternalChange(for: id, diskText: diskText) {
                return false
            }
            guard let refreshed = tabs.first(where: { $0.id == id }) else { return false }
            tab = refreshed
        }

        do {
            try tab.text.write(toFile: path, atomically: true, encoding: .utf8)
            tab.isDirty = false
            tabs[idx] = tab
            diskContents[id] = Self.fileState(of: path, text: tab.text)
            status = L10n.fmt("Сохранено: %@", (path as NSString).lastPathComponent)
            scheduleTabsSave()
            return true
        } catch {
            self.error = DBError(message: L10n.fmt("Не удалось сохранить: %@", error.localizedDescription))
            return false
        }
    }

    // MARK: - external file changes

    /// Content and modification date of the file as the app last saw it.
    private struct DiskFileState {
        var text: String
        var modified: Date?
        var size: Int
    }

    /// Called when the app becomes active and when switching tabs.
    func checkForExternalChanges() {
        guard checkExternalChanges, !isCheckingExternalChanges else { return }
        isCheckingExternalChanges = true
        defer { isCheckingExternalChanges = false }
        syncActiveTab()
        for id in tabs.map(\.id) {
            // Restored tabs that still have to be compared with their file are
            // reported when the user opens them, so a launch does not produce
            // a stack of dialogs for every tab at once.
            if tabsAwaitingDiskComparison.contains(id), id != activeTabID { continue }
            _ = checkExternalChange(for: id)
        }
    }

    /// Watches open files while the app is in front, so a change made by
    /// another program is noticed without switching tabs.
    func startWatchingExternalChanges() {
        guard checkExternalChanges, externalCheckTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop; hop to the main actor
            // explicitly so the call is not made from a nonisolated context.
            Task { @MainActor in
                guard let self, NSApp.isActive else { return }
                self.checkForExternalChanges()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        externalCheckTimer = timer
    }

    func stopWatchingExternalChanges() {
        externalCheckTimer?.invalidate()
        externalCheckTimer = nil
    }

    /// Returns false when the user chose to load the disk version.
    @discardableResult
    private func checkExternalChange(for id: UUID) -> Bool {
        guard checkExternalChanges else { return true }
        guard let tab = tabs.first(where: { $0.id == id }),
              let path = tab.filePath else { return true }

        // Restored from the previous session: ask before the draft is lost.
        if tabsAwaitingDiskComparison.contains(id) {
            guard let diskText = try? String(contentsOfFile: path, encoding: .utf8) else { return true }
            tabsAwaitingDiskComparison.remove(id)
            guard diskText != tab.text else {
                diskContents[id] = Self.fileState(of: path, text: diskText)
                return true
            }
            return promptExternalChange(for: id, diskText: diskText)
        }

        let modified = Self.modificationDate(of: path)
        let size = Self.fileSize(of: path)
        guard let state = diskContents[id] else {
            // First sight of the file in this session: adopt the disk content
            // as the baseline without interrupting the user.
            if let diskText = try? String(contentsOfFile: path, encoding: .utf8) {
                diskContents[id] = Self.fileState(of: path, text: diskText)
            }
            return true
        }

        // Reading every open file on every tick is wasteful; an unchanged
        // modification date and size mean an unchanged file.
        if let modified, let known = state.modified, modified <= known,
           let size, size == state.size {
            return true
        }
        guard let diskText = try? String(contentsOfFile: path, encoding: .utf8) else {
            return true
        }
        guard diskText != state.text else {
            diskContents[id] = Self.fileState(of: path, text: diskText)
            return true
        }
        return promptExternalChange(for: id, diskText: diskText)
    }

    private static func fileState(of path: String, text: String) -> DiskFileState {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return DiskFileState(text: text,
                             modified: attributes?[.modificationDate] as? Date,
                             size: (attributes?[.size] as? NSNumber)?.intValue ?? 0)
    }

    private static func modificationDate(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func fileSize(of path: String) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue
    }

    /// Shows the conflict dialog. The first button is the default one.
    /// Returns false when the tab was reloaded from disk.
    @discardableResult
    private func promptExternalChange(for id: UUID, diskText: String) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return true }
        // A modal alert can let the app activate again; do not stack dialogs.
        guard !isPromptingExternalChange else { return true }
        isPromptingExternalChange = true
        defer { isPromptingExternalChange = false }

        let title = tabs[idx].title
        let hasEdits = tabs[idx].isDirty || tabs[idx].text != diskContents[id]?.text
        let loadFromDisk: Bool
        if let confirmExternalChange {
            loadFromDisk = confirmExternalChange(title)
        } else {
            loadFromDisk = Self.externalChangeAlert(title: title, hasUnsavedEdits: hasEdits)
                .runModal() == .alertFirstButtonReturn
        }

        if loadFromDisk {
            reloadTabFromDisk(id, text: diskText)
            return false
        }

        // Keep the editor version. Remember the disk state so the same change
        // is not reported again; the tab now differs from the file on purpose.
        if let path = tabs[idx].filePath {
            diskContents[id] = Self.fileState(of: path, text: diskText)
        }
        tabs[idx].isDirty = tabs[idx].text != diskText
        status = L10n.fmt("Оставлена версия в редакторе: %@", title)
        return true
    }

    /// The conflict dialog: loading from disk is the default choice.
    static func externalChangeAlert(title: String, hasUnsavedEdits: Bool = false) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("Файл изменён на диске")
        var info = String(format: L10n.tr("Содержимое «%@» отличается от сохранённого на диске.\nЗагрузить версию с диска или оставить текст в редакторе?"), title)
        if hasUnsavedEdits {
            info += "\n\n" + L10n.tr("В редакторе есть несохранённые изменения: загрузка с диска их заменит.")
        }
        alert.informativeText = info
        let load = alert.addButton(withTitle: L10n.tr("Загрузить с диска"))
        alert.addButton(withTitle: L10n.tr("Оставить отличающийся"))
        load.keyEquivalent = "\r"
        alert.window.initialFirstResponder = load
        return alert
    }

    /// Replaces the tab (and the editor, when active) with the disk version.
    private func reloadTabFromDisk(_ id: UUID, text: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = id == activeTabID
        if wasActive { syncActiveTab() }

        tabs[idx].text = text
        tabs[idx].isDirty = false
        tabs[idx].selectionLocation = 0
        tabs[idx].selectionLength = 0
        if let path = tabs[idx].filePath {
            diskContents[id] = Self.fileState(of: path, text: text)
        }

        if wasActive {
            editor.setText(text)
            editor.applyFontSize(editorFontSize)
            let start = NSRange(location: 0, length: 0)
            editor.textView?.setSelectedRange(start)
            editor.textView?.scrollRangeToVisible(start)
            updateCaret(location: 0, in: text)
        }
        scheduleTabsSave()
        status = L10n.fmt("Загружено с диска: %@", tabs[idx].title)
    }

    func revealActiveTabInFinder() {
        guard let path = activeTab?.filePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - grid clipboard

    /// Selected cells (or the whole result when nothing is selected) in the
    /// shape the clipboard formatters expect.
    func clipboardPayload() -> GridClipboardPayload? {
        guard let r = result, !r.rows.isEmpty, !r.columns.isEmpty else { return nil }
        var rowIdx = Array(0..<r.rows.count)
        var colIdx = Array(0..<r.columns.count)
        if let sel = gridSelection {
            let rows = sel.effectiveRows(total: r.rows.count).filter { $0 >= 0 && $0 < r.rows.count }
            let cols = sel.effectiveColumns(total: r.columns.count).filter { $0 >= 0 && $0 < r.columns.count }
            if !rows.isEmpty, !cols.isEmpty {
                rowIdx = rows
                colIdx = cols
            }
        }
        let rows = rowIdx.map { i in colIdx.map { c in c < r.rows[i].count ? r.rows[i][c] : nil } }
        return GridClipboardPayload(columns: colIdx.map { r.columns[$0].name },
                                    rows: rows,
                                    rowNumbers: rowIdx.map { $0 + 1 },
                                    columnInfo: colIdx.map { r.columns[$0] })
    }

    func copySelection() {
        copySelection(settings: GridClipboardStore.copy)
    }

    func copySelection(settings: GridCopySettings) {
        guard let payload = clipboardPayload() else {
            status = L10n.tr("Нет данных для копирования")
            return
        }
        let text = GridClipboard.text(payload, settings: settings)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if settings.copyAsHTML {
            let html = GridClipboard.formatted(.html, payload: payload,
                                               tableName: resultTableName,
                                               valueFormat: settings.valueFormat)
            pasteboard.setString(html, forType: .html)
        }
        status = L10n.fmt("Скопировано: %@ строк", String(payload.rows.count))
    }

    func copySelection(as format: GridClipboardFormat) {
        guard let payload = clipboardPayload() else {
            status = L10n.tr("Нет данных для копирования")
            return
        }
        let text = GridClipboard.formatted(format, payload: payload, tableName: resultTableName,
                                           valueFormat: GridClipboardStore.copy.valueFormat)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        status = L10n.fmt("Скопировано (%@): %@ строк", format.title.lowercased(), String(payload.rows.count))
    }

    // MARK: - result editing

    private struct EditTable: Hashable {
        var catalog: String
        var schema: String
        var table: String
    }

    private static func makeRowIDs(count: Int) -> [UUID] {
        guard count > 0 else { return [] }
        return (0..<count).map { _ in UUID() }
    }

    private func ensureRowIDs(_ r: inout QueryResult) {
        if r.rowIDs.count < r.rows.count {
            r.rowIDs.append(contentsOf: Self.makeRowIDs(count: r.rows.count - r.rowIDs.count))
        } else if r.rowIDs.count > r.rows.count {
            r.rowIDs = Array(r.rowIDs.prefix(r.rows.count))
        }
    }

    var hasPendingResultEdits: Bool {
        guard let r = result else { return false }
        return !r.editedCells.isEmpty || !r.insertedRowIDs.isEmpty
    }

    var canSaveResultEdits: Bool {
        hasPendingResultEdits && (resultEditPhase == .pending || resultEditPhase == .failed)
    }

    var canCancelResultEdits: Bool {
        hasPendingResultEdits && (resultEditPhase == .pending || resultEditPhase == .failed)
    }

    private func cancelEditHide() {
        editHideWork?.cancel()
        editHideWork = nil
    }

    func resetResultEditUI() {
        cancelEditHide()
        resultEditPhase = .hidden
        resultEditMessage = ""
        resultEditMessageIsError = false
    }

    private func markResultEdited() {
        guard hasPendingResultEdits else { return }
        cancelEditHide()
        resultEditMessage = ""
        resultEditMessageIsError = false
        if resultEditPhase != .saving {
            resultEditPhase = .pending
        }
    }

    private func failResultEdit(_ message: String) {
        resultEditPhase = .failed
        resultEditMessage = message
        resultEditMessageIsError = true
        status = message
    }

    /// Stores the original value of one cell. Reverting a cell to its original
    /// value removes the edit, so the row is not written back at all.
    private func recordEdit(in r: inout QueryResult, rowID: UUID, column: Int,
                            newValue: String?) {
        guard let originalRow = r.originalRows[rowID] else { return }
        let original: String? = column < originalRow.count ? originalRow[column] : nil
        let key = ResultCellKey(rowID: rowID, column: column)
        if newValue == original {
            r.editedCells.removeValue(forKey: key)
        } else {
            r.editedCells[key] = ResultCellEdit(rowID: rowID, column: column,
                                                original: original, new: newValue)
        }
        if !r.editedCells.keys.contains(where: { $0.rowID == rowID }) {
            r.originalRows[rowID] = nil
        }
    }

    func pasteSelection(settings: GridPasteSettings) {
        guard resultEditPhase != .saving else { return }
        guard var r = result, !r.columns.isEmpty else {
            status = L10n.tr("Нет данных для вставки")
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            status = L10n.tr("Буфер обмена пуст")
            return
        }
        let parsed = GridClipboard.parse(text, settings: settings, copy: GridClipboardStore.copy)
        guard !parsed.isEmpty else { return }
        ensureRowIDs(&r)

        var startRow = 0
        var startCol = 0
        if let sel = gridSelection {
            if let row = sel.effectiveRows(total: r.rows.count).first { startRow = row }
            if let col = sel.effectiveColumns(total: r.columns.count).first { startCol = col }
        }

        let width = r.columns.count
        let rowsToPaste = settings.insertMultipleRows ? parsed : Array(parsed.prefix(1))
        for (offset, row) in rowsToPaste.enumerated() {
            let target = startRow + offset
            var isNewRow = false
            if target >= r.rows.count {
                while r.rows.count <= target {
                    r.rows.append(Array(repeating: nil, count: width))
                    let id = UUID()
                    r.rowIDs.append(id)
                    r.insertedRowIDs.insert(id)
                }
                isNewRow = true
            } else {
                while r.rows[target].count < width {
                    r.rows[target].append(nil)
                }
            }

            let rowID = r.rowIDs[target]
            if !isNewRow, r.originalRows[rowID] == nil {
                r.originalRows[rowID] = r.rows[target]
            }
            for (columnOffset, value) in row.enumerated() {
                let column = startCol + columnOffset
                guard column >= 0, column < width else { break }
                r.rows[target][column] = value
                if !isNewRow {
                    recordEdit(in: &r, rowID: rowID, column: column, newValue: value)
                }
            }
        }

        result = r
        resultsByTab[activeTabID] = r
        resultEditsRevision += 1
        if hasPendingResultEdits {
            markResultEdited()
        } else if resultEditPhase == .pending {
            resultEditPhase = .hidden
        }
        status = L10n.fmt("Вставлено: %@ строк", String(rowsToPaste.count))
    }

    /// Applies an edit made directly in a result cell. The change is kept in
    /// memory until the user presses "Сохранить".
    func setResultCell(row: Int, column: Int, value: String?) {
        guard resultEditPhase != .saving else { return }
        guard var r = result,
              row >= 0, row < r.rows.count,
              column >= 0, column < r.columns.count else { return }
        ensureRowIDs(&r)
        while r.rows[row].count <= column {
            r.rows[row].append(nil)
        }
        guard r.rows[row][column] != value else { return }
        let rowID = r.rowIDs[row]
        if r.originalRows[rowID] == nil {
            r.originalRows[rowID] = r.rows[row]
        }
        r.rows[row][column] = value
        recordEdit(in: &r, rowID: rowID, column: column, newValue: value)

        result = r
        resultsByTab[activeTabID] = r
        resultEditsRevision += 1
        if hasPendingResultEdits {
            markResultEdited()
        } else if resultEditPhase == .pending {
            resultEditPhase = .hidden
        }
        status = L10n.tr("Ячейка изменена — нажмите «Сохранить», чтобы записать в БД")
    }

    /// Discards all unsaved changes and restores the original rows. The buttons
    /// stay visible for two seconds and then fade out.
    func cancelResultEdits() {
        guard var r = result, hasPendingResultEdits else { return }
        guard resultEditPhase == .pending || resultEditPhase == .failed else { return }

        if !r.insertedRowIDs.isEmpty {
            let keep = r.rowIDs.indices.filter { !r.insertedRowIDs.contains(r.rowIDs[$0]) }
            r.rows = keep.map { r.rows[$0] }
            r.rowIDs = keep.map { r.rowIDs[$0] }
        }
        for (rowID, original) in r.originalRows {
            if let index = r.rowIDs.firstIndex(of: rowID) {
                r.rows[index] = original
            }
        }
        r.editedCells.removeAll()
        r.originalRows.removeAll()
        r.insertedRowIDs.removeAll()

        result = r
        resultsByTab[activeTabID] = r
        gridSelection = nil
        resultEditsRevision += 1
        resultEditPhase = .cancelling
        resultEditMessage = "Изменения отменены"
        resultEditMessageIsError = false
        status = resultEditMessage

        cancelEditHide()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.resultEditPhase == .cancelling else { return }
            self.resultEditPhase = .hidden
            self.resultEditMessage = ""
        }
        editHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Writes unsaved cell edits to the database. Existing rows are updated by
    /// primary key; rows pasted below the data are inserted.
    func saveResultEdits() {
        guard let r = result, hasPendingResultEdits else { return }
        guard resultEditPhase == .pending || resultEditPhase == .failed else { return }

        // All edits must belong to one table; a result of a join with changes
        // in several tables cannot be written back unambiguously.
        var table: EditTable?
        for edit in r.editedCells.values {
            guard edit.column >= 0, edit.column < r.columns.count else { continue }
            let c = r.columns[edit.column]
            let key = EditTable(catalog: c.catalog, schema: c.schema, table: c.table)
            if let table, table != key {
                failResultEdit("Изменения относятся к разным таблицам — сохранить нельзя")
                return
            }
            table = key
        }
        if table == nil {
            for c in r.columns where !c.table.isEmpty {
                let key = EditTable(catalog: c.catalog, schema: c.schema, table: c.table)
                if let table, table != key {
                    failResultEdit("Результат содержит столбцы разных таблиц — сохранить нельзя")
                    return
                }
                table = key
            }
        }
        guard let tableKey = table, !tableKey.table.isEmpty else {
            failResultEdit("Не удалось определить таблицу результата")
            return
        }
        guard let profileID = r.profileID ?? activeScriptProfileID,
              let profile = profiles.first(where: { $0.id == profileID }) else {
            failResultEdit("Не удалось определить подключение результата")
            return
        }

        var byRow: [UUID: [ResultCellEdit]] = [:]
        for edit in r.editedCells.values {
            byRow[edit.rowID, default: []].append(edit)
        }
        var rowIndexByID: [UUID: Int] = [:]
        for (index, id) in r.rowIDs.enumerated() {
            rowIndexByID[id] = index
        }

        var inserts: [[String: Any]] = []
        for rowID in r.insertedRowIDs {
            guard let index = rowIndexByID[rowID], index < r.rows.count else { continue }
            var values: [String: Any] = [:]
            for (column, value) in r.rows[index].enumerated() where value != nil {
                guard column < r.columns.count else { continue }
                values[r.columns[column].name] = value!
            }
            guard !values.isEmpty else {
                failResultEdit("Новая строка не содержит значений")
                return
            }
            inserts.append(values)
        }
        guard !byRow.isEmpty || !inserts.isEmpty else { return }

        resultEditPhase = .saving
        resultEditMessage = "Сохранение…"
        resultEditMessageIsError = false
        status = L10n.tr("Сохранение изменений…")
        let tabID = activeTabID
        let runID = r.runID
        let editedCount = r.editedCells.count
        let session = session(for: profile)

        Task {
            do {
                var updates: [[String: Any]] = []
                if !byRow.isEmpty {
                    let primaryKeys = try await session.primaryKeys(catalog: tableKey.catalog,
                                                                   schema: tableKey.schema,
                                                                   table: tableKey.table)
                    guard !primaryKeys.isEmpty else {
                        throw DBError(message: L10n.fmt("У таблицы %@ нет первичного ключа — изменения нельзя сохранить", tableKey.table))
                    }
                    var keyIndices: [Int] = []
                    for name in primaryKeys {
                        guard let index = r.columns.firstIndex(where: {
                            $0.name.caseInsensitiveCompare(name) == .orderedSame
                                && ($0.table.isEmpty || $0.table == tableKey.table)
                        }) else {
                            throw DBError(message: L10n.fmt("В результате нет столбца первичного ключа «%@»", name))
                        }
                        keyIndices.append(index)
                    }
                    for (rowID, edits) in byRow {
                        guard let original = r.originalRows[rowID] else {
                            throw DBError(message: "Нет исходных значений строки")
                        }
                        var keys: [String: Any] = [:]
                        for index in keyIndices {
                            let name = r.columns[index].name
                            let value = index < original.count ? original[index] : nil
                            guard let value else {
                                throw DBError(message: L10n.fmt("Пустой первичный ключ «%@»", name))
                            }
                            keys[name] = value
                        }
                        var values: [String: Any] = [:]
                        for edit in edits {
                            values[r.columns[edit.column].name] = edit.new ?? NSNull()
                        }
                        updates.append(["keys": keys, "values": values])
                    }
                }

                let counts = try await session.updateRows(catalog: tableKey.catalog,
                                                          schema: tableKey.schema,
                                                          table: tableKey.table,
                                                          updates: updates,
                                                          inserts: inserts)
                guard var stored = resultsByTab[tabID], stored.runID == runID else { return }
                stored.editedCells.removeAll()
                stored.originalRows.removeAll()
                stored.insertedRowIDs.removeAll()
                resultsByTab[tabID] = stored
                guard tabID == activeTabID, result?.runID == runID else { return }
                result = stored
                resultEditsRevision += 1
                resultEditPhase = .saved
                let rows = counts.updated + counts.inserted
                resultEditMessage = L10n.fmt("Сохранено: %@ строк, %@ ячеек", String(rows), String(editedCount))
                resultEditMessageIsError = false
                status = resultEditMessage
            } catch {
                guard tabID == activeTabID, result?.runID == runID else { return }
                let message = (error as? SidecarError)?.message ?? error.localizedDescription
                resultEditPhase = .failed
                resultEditMessage = L10n.fmt("Ошибка: %@", message)
                resultEditMessageIsError = true
                status = L10n.tr("Ошибка сохранения")
            }
        }
    }

    var resultTableName: String {
        let name = result?.queryName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "result" : (name as NSString).deletingPathExtension
    }

    enum OpenTarget {
        case excel
        case browser
        case otherApplication
    }

    /// Writes the selection to a temporary file and hands it to another app.
    func openSelectionIn(_ target: OpenTarget) {
        guard let payload = clipboardPayload() else {
            status = L10n.tr("Нет данных для открытия")
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "dbooyvol-\(stamp)"

        let url: URL
        do {
            switch target {
            case .excel, .browser:
                // HTML keeps the table structure and Cyrillic text intact in
                // both Excel and a browser; a comma-separated CSV would be
                // split wrongly by Excel with a semicolon list separator.
                let html = GridClipboard.htmlDocument(payload, tableName: resultTableName,
                                                      valueFormat: GridClipboardStore.copy.valueFormat)
                url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".html")
                try html.write(to: url, atomically: true, encoding: .utf8)
            case .otherApplication:
                // The BOM makes Excel read Cyrillic as UTF-8.
                let csv = "\u{FEFF}" + GridClipboard.formatted(.csv, payload: payload,
                                                               tableName: resultTableName,
                                                               valueFormat: GridClipboardStore.copy.valueFormat)
                url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".csv")
                try csv.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            self.error = DBError(message: L10n.fmt("Не удалось создать файл: %@", error.localizedDescription))
            return
        }

        switch target {
        case .browser:
            NSWorkspace.shared.open(url)
        case .excel:
            if let excel = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Excel") {
                open(url, with: excel)
            } else {
                NSWorkspace.shared.open(url)
            }
        case .otherApplication:
            let panel = NSOpenPanel()
            panel.title = "Открыть в приложении"
            panel.prompt = "Открыть"
            panel.allowedContentTypes = [.application]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            guard panel.runModal() == .OK, let app = panel.url else { return }
            open(url, with: app)
        }
    }

    private func open(_ file: URL, with application: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([file], withApplicationAt: application,
                                configuration: configuration) { _, error in
            guard let error else { return }
            Task { @MainActor in
                self.error = DBError(message: L10n.fmt("Не удалось открыть файл: %@", error.localizedDescription))
            }
        }
    }

    // MARK: - export

    private enum ExportFormat {
        case csv, xml
        var ext: String { self == .csv ? "csv" : "xml" }
        var type: UTType { self == .csv ? .commaSeparatedText : .xml }
    }

    private func exportPayload() -> (columns: [ColumnInfo], rows: [[String?]]) {
        guard let r = result else { return ([], []) }
        if let sel = gridSelection, !r.rows.isEmpty, !r.columns.isEmpty {
            let rowIdx = sel.effectiveRows(total: r.rows.count).filter { $0 < r.rows.count }
            let colIdx = sel.effectiveColumns(total: r.columns.count).filter { $0 < r.columns.count }
            guard !rowIdx.isEmpty, !colIdx.isEmpty else { return (r.columns, r.rows) }
            let subset = rowIdx.map { i in colIdx.map { c in c < r.rows[i].count ? r.rows[i][c] : nil } }
            return (colIdx.map { r.columns[$0] }, subset)
        }
        return (r.columns, r.rows)
    }

    func exportCSV() { export(.csv) }
    func exportXML() { export(.xml) }

    private func export(_ format: ExportFormat) {
        let (columns, rows) = exportPayload()
        guard !columns.isEmpty else {
            error = DBError(message: "Нет данных для экспорта")
            return
        }
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "query-\(stamp).\(format.ext)"
        panel.allowedContentTypes = [format.type]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let text = format == .csv
                ? Exporter.csv(columns: columns, rows: rows)
                : Exporter.xml(columns: columns, rows: rows)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                Task { @MainActor in self.status = L10n.fmt("Экспортировано: %@", url.lastPathComponent) }
            } catch {
                Task { @MainActor in self.error = DBError(message: L10n.fmt("Не удалось записать файл: %@", error.localizedDescription)) }
            }
        }
    }
}

extension ClosedRange where Bound == Int {
    func indices(within range: ClosedRange<Int>) -> [Int] {
        let lower = Swift.max(self.lowerBound, range.lowerBound)
        let upper = Swift.min(self.upperBound, range.upperBound)
        guard lower <= upper else { return [] }
        return Array(lower...upper)
    }
}
