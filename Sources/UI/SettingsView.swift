import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppSettings.sshDirectoryKey) private var sshDirectory = "/Users/silver/.ssh"
    @AppStorage(AppSettings.autosaveTabsKey) private var autosaveTabs = true
    @AppStorage(AppSettings.smartSelectionKey) private var smartSelection = false
    @AppStorage(AppSettings.smartSelectionOnlyInSearchKey) private var smartSelectionOnlyInSearch = false
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some View {
        Form {
            Section("Язык") {
                Picker(
                    "Язык интерфейса",
                    selection: Binding(
                        get: { model.appLanguage },
                        set: { model.setAppLanguage($0) }
                    )
                ) {
                    Text("Системный").tag(AppLanguage.system)
                    ForEach(AppLanguage.allCases.filter { $0 != .system }) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                .help(L10n.tr("Язык интерфейса; применяется после перезапуска"))
                if model.languageNeedsRestart {
                    HStack {
                        Text("Новый язык применится после перезапуска приложения.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Перезапустить") { model.relaunchForLanguage() }
                            .controlSize(.small)
                            .help("Перезапустить приложение с новым языком")
                    }
                } else {
                    Text("По умолчанию — язык системы. Украинский пока показывает русские тексты.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Управление") {
                Button("Горячие клавиши…") { openWindow(id: "shortcuts") }
                    .help(L10n.fmt("Открыть список горячих клавиш (%@)",
                                   shortcuts.binding(for: .shortcutsHelp)?.display ?? ""))
                Text(L10n.fmt("Также открывается из меню «Справка» по %@.",
                              shortcuts.binding(for: .shortcutsHelp)?.display ?? ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Пароли") {
                Text("Сохранённые пароли шифруются AES-256-GCM. Мастер-ключ хранится в связке ключей macOS и привязан к подписи приложения, поэтому копия папки с данными без связки ключей бесполезна.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Button("Перешифровать пароли") {
                        do {
                            try SecretStore.rotateMasterKey()
                            model.status = L10n.tr("Пароли перешифрованы новым мастер-ключом")
                        } catch {
                            model.status = error.localizedDescription
                        }
                    }
                    .help("Создать новый мастер-ключ и заново зашифровать все сохранённые пароли")
                    Spacer()
                }
                Text("Если пароль подключения не нужно хранить, выключите «Сохранять пароль» в его настройках — тогда он запрашивается при подключении.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Удалить старые пароли из связки ключей") {
                    let removed = SecretStore.deleteLegacyKeychain()
                    model.status = removed
                        ? L10n.tr("Старые пароли удалены из связки ключей")
                        : L10n.tr("Не удалось удалить старые пароли — разрешите доступ в запросе macOS")
                }
                .help("Удалить элементы прежней версии (служба ru.evotor.sqldesk), где пароли хранились открытым текстом")
            }

            Section("Редактор") {
                HStack {
                    Stepper(
                        value: Binding(
                            get: { model.editorFontSize },
                            set: { model.setEditorFontSize($0) }
                        ),
                        in: AppModel.minEditorFontSize...AppModel.maxEditorFontSize,
                        step: 1
                    ) {
                        Text(L10n.fmt("Размер шрифта: %@ pt", String(Int(model.editorFontSize))))
                    }
                    .help(L10n.tr("Размер шрифта в редакторе SQL"))
                    Button("По умолчанию") { model.resetEditorFontSize() }
                        .help("Вернуть стандартный размер шрифта редактора")
                }
                Text("Ctrl + колесо мыши в редакторе тоже меняет размер. Клавиши: ⌘+ / ⌘− / ⌘0 (меню «Вид»).")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Умное выделение", isOn: $smartSelection)
                    .help(L10n.tr("Автоматически выделять первый параметр в WHERE при открытии скрипта"))
                Text("При открытии скрипта автоматически выделять текст первого параметра в WHERE.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle("Только при поиске", isOn: $smartSelectionOnlyInSearch)
                    .disabled(!smartSelection)
                    .help(L10n.tr("Выделять параметр только при открытии через поиск (⌘E)"))
                Text("Выделять только тогда, когда запрос открыт через поиск (⌘E).")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                Toggle(
                    "Комментирование по специальному ключу",
                    isOn: Binding(
                        get: { model.commentByMarker },
                        set: { model.setCommentByMarker($0) }
                    )
                )
                .help(L10n.tr("Включает комментирование строк по ключу в конце строки"))
                HStack(spacing: 6) {
                    Text("Ключ:")
                    HStack(spacing: 0) {
                        Text("--")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                        Divider().frame(height: 16)
                        TextField("!#", text: Binding(
                            get: { model.commentMarkerSuffix },
                            set: { model.setCommentMarkerSuffix($0) }
                        ))
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 6)
                        .frame(width: 120)
                        .help(L10n.tr("Продолжение ключа после «--»; пустое значение отключает комбинацию"))
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
                    .disabled(!model.commentByMarker)
                    Text(L10n.fmt("По умолчанию: %@", "--" + AppSettings.defaultCommentMarkerSuffix))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(L10n.fmt("Специальным ключом можно пометить строку или строки: сочетание %@ комментирует и раскомментирует все такие строки сразу, не трогая остальной скрипт.",
                              shortcuts.binding(for: .toggleMarkedComment)?.display ?? ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Ключ состоит из фиксированного «--» и любого продолжения. Строка считается помеченной, если ключ стоит в самом конце строки; пустое продолжение отключает сочетание.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Файлы") {
                Toggle(
                    "Проверять изменения файлов на диске",
                    isOn: Binding(
                        get: { model.checkExternalChanges },
                        set: { model.setCheckExternalChanges($0) }
                    )
                )
                .help(L10n.tr("Следить за изменениями открытых файлов и предлагать перезагрузить версию с диска"))
                Text("Следить за открытыми файлами и предлагать загрузить версию с диска, если файл изменился другой программой. Когда выключено, файлы на диске не читаются и не сравниваются.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Данные в результате") {
                Picker(
                    "Шрифт",
                    selection: Binding(
                        get: { model.resultFontName },
                        set: { model.setResultFontName($0) }
                    )
                ) {
                    Text("Системный моноширинный").tag("")
                    if !model.resultFontName.isEmpty,
                       !ResultFontCatalog.names.contains(model.resultFontName) {
                        Text(ResultFontCatalog.displayName(model.resultFontName))
                            .tag(model.resultFontName)
                    }
                    ForEach(ResultFontCatalog.entries) { entry in
                        Text(entry.family)
                            .font(.custom(entry.postScriptName, size: 13))
                            .tag(entry.postScriptName)
                    }
                }
                .help(L10n.tr("Шрифт таблицы результатов"))
                HStack {
                    Stepper(
                        value: Binding(
                            get: { model.resultFontSize },
                            set: { model.setResultFontSize($0) }
                        ),
                        in: AppModel.minResultFontSize...AppModel.maxResultFontSize,
                        step: 1
                    ) {
                        Text(L10n.fmt("Размер: %@ pt", String(Int(model.resultFontSize))))
                    }
                    .help(L10n.tr("Размер шрифта таблицы результатов"))
                    Button("По умолчанию") { model.resetResultFontSize() }
                        .help("Вернуть стандартный размер шрифта таблицы")
                }
                Text("Ctrl + колесо мыши и pinch на тачпаде меняют размер шрифта в таблице результатов.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Тип данных столбца")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Toggle(
                        "В названии столбца",
                        isOn: Binding(
                            get: { model.showTypeInColumnHeader },
                            set: { model.setShowTypeInColumnHeader($0) }
                        )
                    )
                    .help(L10n.tr("Показывать тип данных рядом с именем столбца"))
                    Toggle(
                        "При наведении на название столбца",
                        isOn: Binding(
                            get: { model.showTypeOnHeaderHover },
                            set: { model.setShowTypeOnHeaderHover($0) }
                        )
                    )
                    .help(L10n.tr("Показывать тип данных во всплывающей подсказке заголовка"))
                    Text("По умолчанию тип показывается во всплывающей подсказке при наведении на заголовок. Можно включить оба варианта или отключить оба.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Toggle(
                    "Автоматическая ширина столбцов",
                    isOn: Binding(
                        get: { model.autoColumnWidths },
                        set: { model.setAutoColumnWidths($0) }
                    )
                )
                .help(L10n.tr("Подбирать ширину столбцов по содержимому"))
                if model.autoColumnWidths {
                    HStack {
                        Text("Максимум ширины:")
                        TextField("", value: maxAutoWidth, format: .number)
                            .frame(width: 80)
                            .help(L10n.tr("Предел автоматической ширины столбца в pt"))
                        Text("pt")
                        Stepper("", value: maxAutoWidth, in: 60...1000, step: 10)
                            .labelsHidden()
                            .help(L10n.tr("Изменить предел ширины столбца"))
                        Button("По умолчанию") { model.resetMaxAutoColumnWidth() }
                            .help("Вернуть стандартную максимальную ширину столбца")
                    }
                    Text(L10n.fmt("Ширина подстраивается под данные до %@ pt, более длинные значения обрезаются. Ориентир: 280 pt ≈ 38–40 символов при 12 pt.",
                                  String(Int(model.maxAutoColumnWidth))))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Ширина запоминается по имени запроса; новые столбцы подстраиваются под данные. Ширину, заданную вручную, программа не меняет.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Время") {
                Picker(
                    "Часовой пояс",
                    selection: Binding(
                        get: { model.timeZoneIdentifier },
                        set: { model.setTimeZone($0) }
                    )
                ) {
                    Text(L10n.fmt("Системный · %@", TimeZones.shortLabel(for: .current))).tag("")
                    ForEach(TimeZones.pickerOptions(for: model.timeZoneIdentifier)) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .help(L10n.tr("Пояс, в котором показываются значения timestamp"))
                Text("Время в столбцах timestamp показывается в этом поясе; время без указания пояса считается UTC. Короткое обозначение пояса видно в нижней строке окна.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Загрузка данных") {
                HStack {
                    Text("Строк за одну загрузку:")
                    TextField("", value: pageSizeBinding, format: .number)
                        .frame(width: 80)
                        .help(L10n.tr("Сколько строк запрашивать за один раз"))
                    Stepper("", value: pageSizeBinding, in: AppModel.minPageSize...AppModel.maxPageSize, step: 50)
                        .labelsHidden()
                        .help(L10n.tr("Изменить размер страницы"))
                    Button("По умолчанию") { model.resetPageSize() }
                        .help("Вернуть 200 строк на страницу")
                }
                Text("По умолчанию 200. Если строк в результате больше, при прокрутке до конца таблицы автоматически загружается ещё столько же. Кнопка «Загрузить ещё» делает то же самое.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Запросы") {
                Toggle("Автосохранение открытых запросов между сессиями", isOn: $autosaveTabs)
                    .help(L10n.tr("Сохранять вкладки и их текст в tabs.json между запусками"))
                Text("При включении открытые вкладки и их текст сохраняются в tabs.json и восстанавливаются при запуске.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("История запросов") {
                Picker(
                    "Хранить историю",
                    selection: Binding(
                        get: { model.historyRetentionDays },
                        set: { model.setHistoryRetentionDays($0) }
                    )
                ) {
                    ForEach(HistoryRetention.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .help(L10n.tr("Срок хранения истории запросов"))
                Text("По умолчанию — 1 месяц. Записи старше выбранного срока удаляются автоматически при запуске и сразу при уменьшении срока; файл истории при этом сжимается.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Text(L10n.fmt("Записей в истории: %@", String(model.history.count)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Очистить историю", role: .destructive) {
                        model.clearHistory()
                    }
                    .help("Удалить всю историю запросов")
                }
            }

            Section("SSH") {
                HStack {
                    TextField("Каталог ~/.ssh", text: $sshDirectory)
                        .help(L10n.tr("Каталог с файлом config для SSH-подключений"))
                    Button("Выбрать…") { chooseDirectory { sshDirectory = $0 } }
                        .help("Выбрать каталог с файлом config")
                }
                Text(L10n.fmt("Используется файл config из этого каталога: %@",
                              AppSettings.sshConfigPath ?? L10n.tr("не найден")))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        }
        .formStyle(.grouped)
        .frame(width: 560, height: 580)
        .background(WindowConfigurator(name: WindowLayout.settingsName))
    }

    private func chooseDirectory(_ apply: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { apply(url.path) }
    }

    private var maxAutoWidth: Binding<Double> {
        Binding(
            get: { Double(model.maxAutoColumnWidth) },
            set: { model.setMaxAutoColumnWidth(CGFloat($0)) }
        )
    }

    private var pageSizeBinding: Binding<Int> {
        Binding(
            get: { model.pageSize },
            set: { model.setPageSize($0) }
        )
    }

    private func chooseFile(_ apply: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { apply(url.path) }
    }
}

struct ConnectionEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ConnectionProfile
    @State private var password: String = ""
    @State private var testState: TestState?

    private enum TestState: Equatable {
        case running
        case success(String)
        case failure(String)

        var icon: String {
            switch self {
            case .running: return "hourglass"
            case .success: return "checkmark.circle.fill"
            case .failure: return "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .running: return .secondary
            case .success: return .green
            case .failure: return .red
            }
        }

        var text: String {
            switch self {
            case .running: return L10n.tr("Проверка подключения…")
            case .success(let message): return message
            case .failure(let message): return message
            }
        }

        var isFailure: Bool {
            if case .failure = self { return true }
            return false
        }
    }

    init(profile: ConnectionProfile) {
        _draft = State(initialValue: profile)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Подключение") {
                    TextField("Имя", text: $draft.name)
                    Picker("Тип", selection: $draft.kind) {
                        ForEach(DBKind.allCases) { kind in
                            Label {
                                Text(kind.title)
                            } icon: {
                                Image(nsImage: DBIcon.image(for: kind, size: 14))
                            }
                            .tag(kind)
                        }
                    }
                    .help(L10n.tr("Тип базы данных"))
                    .onChange(of: draft.kind) { newKind in
                        draft.port = newKind.defaultPort
                    }
                }

                Section("Сервер") {
                    if draft.kind == .sqlite {
                        HStack {
                            TextField("Файл базы (.db / .sqlite)", text: $draft.database)
                            Button("Выбрать…") { chooseDatabaseFile { draft.database = $0 } }
                                .help("Выбрать файл базы SQLite")
                        }
                        Text("Локальный файл SQLite открывается напрямую, сервер не нужен.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                    if draft.kind == .oracle {
                        Picker("Способ подключения", selection: $draft.oracleMode) {
                            ForEach(OracleNetMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .help(L10n.tr("EZ Connect, TNS или LDAP"))
                    }
                    if draft.kind != .oracle || draft.oracleMode == .easy {
                        HStack {
                            TextField("Хост", text: $draft.host)
                            TextField("Порт", value: $draft.port, format: .number)
                                .frame(width: 90)
                                .help(L10n.tr("Порт сервера базы данных"))
                        }
                        TextField(
                            draft.kind == .oracle ? L10n.tr("Имя сервиса / SID")
                                : draft.kind == .clickhouse ? L10n.tr("База данных (database)")
                                : L10n.tr("База данных"),
                            text: $draft.database
                        )
                    }
                    if draft.kind == .oracle, draft.oracleMode != .easy {
                        TextField(
                            draft.oracleMode == .tns ? L10n.tr("TNS-алиас (из tnsnames.ora)")
                                : L10n.tr("Имя сервиса в LDAP"),
                            text: $draft.oracleAlias
                        )
                    }
                    TextField("Пользователь", text: $draft.user)
                        .help(L10n.tr("Имя пользователя базы данных"))
                    SecureField("Пароль", text: $password)
                        .help(L10n.tr("Пароль пользователя базы данных"))
                    Toggle("Сохранять пароль", isOn: Binding(
                        get: { draft.storesPassword },
                        set: { draft.savePassword = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .help(L10n.tr("Хранить пароль в зашифрованном виде в связке ключей"))
                    if !draft.storesPassword {
                        Text("Пароль будет запрашиваться при подключении и храниться только до конца сеанса.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    }
                }

                if draft.kind == .oracle {
                    oracleNetSection
                }

                Section("JDBC-драйвер") {
                    HStack {
                        TextField("Путь к jar", text: $draft.driverPath)
                        Button("Выбрать…") { chooseJar { draft.driverPath = $0 } }
                            .help("Выбрать JDBC-драйвер (.jar)")
                    }
                    Text(draft.kind.defaultDriverHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("JDBC URL (переопределить, необязательно)", text: $draft.jdbcUrl)
                        .font(.system(size: 11, design: .monospaced))
                    if draft.jdbcURLContainsCredentials {
                        Text("В URL указан пароль — он попадёт в profiles.json открытым текстом. Уберите его из URL и используйте поле «Пароль».")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    if draft.kind == .oracle, draft.oracleMode == .easy {
                        Toggle("Подключаться по SID (иначе service name)", isOn: $draft.oracleSid)
                            .help(L10n.tr("Использовать SID вместо имени сервиса"))
                    }
                    if draft.kind == .oracle {
                        HStack {
                            TextField("Instant Client", text: $draft.instantClientDir)
                                .help("Папка Instant Client: из неё берутся ojdbc*.jar и network/admin")
                            Button {
                                chooseDirectory {
                                    draft.instantClientDir = $0
                                    applyInstantClient($0)
                                }
                            } label: {
                                Image(systemName: "folder")
                            }
                            .help("Взять ojdbc*.jar и network/admin из папки Instant Client")
                        }
                        Text("Из папки берутся ojdbc*.jar и network/admin. Dylib-библиотеки не нужны: тонкий драйвер не грузит нативные библиотеки.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if !draft.kind.isFileBased {
                Section("SSH-туннель") {
                    Toggle("Использовать SSH", isOn: $draft.ssh.enabled)
                        .help(L10n.tr("Подключаться к базе через SSH-туннель"))
                    if draft.kind == .oracle && draft.oracleMode != .easy {
                        Text("Для TNS/LDAP туннель не используется: алиас раскрывается в реальный хост, а не в localhost. Выберите EZ Connect, если нужен SSH.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if draft.ssh.enabled {
                        if draft.ssh.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Хост SSH не указан: тест и подключение вернут ошибку. Укажите хост/алиас или выключите SSH.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        TextField("Хост (алиас из ~/.ssh/config)", text: $draft.ssh.host)
                        HStack {
                            TextField("Порт", value: $draft.ssh.port, format: .number).frame(width: 90)
                            TextField("Пользователь (необязательно)", text: $draft.ssh.user)
                        }
                        HStack {
                            TextField("Ключ (необязательно)", text: $draft.ssh.keyPath)
                            Button("Выбрать…") { chooseKey { draft.ssh.keyPath = $0 } }
                                .help(L10n.tr("Выбрать файл приватного ключа SSH"))
                        }
                        Text("config: \(AppSettings.sshConfigPath ?? "не найден — проверьте настройки")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                }
            }
            .formStyle(.grouped)

            if let testState {
                HStack(alignment: .top, spacing: 7) {
                    if testState == .running {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 1)
                    } else {
                        Image(systemName: testState.icon)
                            .foregroundColor(testState.tint)
                            .padding(.top, 1)
                    }
                    Text(testState.text)
                        .font(.system(size: 12))
                        .foregroundColor(testState.isFailure ? .red : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(testState.tint.opacity(0.08))
            }

            Divider()
            HStack {
                Button("Удалить") {
                    model.deleteProfile(draft.id)
                    dismiss()
                }
                .foregroundColor(.red)
                .help("Удалить это подключение и сохранённый пароль")
                .disabled(!model.profiles.contains(where: { $0.id == draft.id }))

                Button {
                    testConnection()
                } label: {
                    HStack(spacing: 5) {
                        if testState == .running {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Тест")
                    }
                }
                .disabled(testState == .running || !canTest)
                .help("Проверить подключение с введёнными параметрами, не сохраняя их")

                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Закрыть без сохранения")
                Button("Сохранить") {
                    if draft.jdbcURLContainsCredentials {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = L10n.tr("В JDBC URL указан пароль")
                        alert.informativeText = L10n.tr("Логин и пароль из URL сохраняются открытым текстом. Уберите их из URL и используйте поля «Пользователь» и «Пароль».")
                        alert.addButton(withTitle: L10n.tr("Понятно"))
                        alert.runModal()
                        return
                    }
                    if draft.name.isEmpty { draft.name = draft.suggestedName }
                    model.saveProfile(draft, password: password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .help("Сохранить подключение")
            }
            .padding(12)
        }
        .frame(width: 640, height: draft.kind.isFileBased ? 540 : 780)
        .onAppear {
            password = draft.storesPassword ? model.password(for: draft.id) : ""
        }
        .onChange(of: draft) { _ in
            if testState != .running { testState = nil }
        }
    }

    @ViewBuilder
    private var oracleNetSection: some View {
        Section("Oracle Net") {
            if draft.oracleMode != .easy {
                HStack {
                    TextField("TNS_ADMIN", text: $draft.tnsAdmin)
                        .help("Папка network/admin с tnsnames.ora, ldap.ora и sqlnet.ora")
                    Button {
                        chooseDirectory { draft.tnsAdmin = $0; readOracleConfig() }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Выбрать папку network/admin")
                    Button("Прочитать") { readOracleConfig() }
                        .help("Перечитать tnsnames.ora и ldap.ora")
                        .disabled(draft.tnsAdmin.isEmpty)
                        .help("Прочитать ldap.ora и sqlnet.ora и заполнить поля ниже")
                }
                if let hint = oracleConfigHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if draft.oracleMode == .ldap {
                HStack {
                    TextField("LDAP-сервер", text: $draft.ldapHost)
                    TextField("Порт", value: $draft.ldapPort, format: .number)
                        .frame(width: 90)
                    Toggle("SSL", isOn: $draft.ldapSSL)
                        .help(L10n.tr("Использовать SSL для LDAP"))
                }
                TextField("DEFAULT_ADMIN_CONTEXT", text: $draft.ldapContext)
                Text("Например, dc=evotor,dc=ru. cn=OracleContext добавляется автоматически.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            TextField("Сервисы аутентификации (необязательно)", text: $draft.oracleAuthServices)
            Text("RADIUS — вход по одноразовому коду: в поле «Пароль» указывается код с токена. Thin-драйвер берёт настройку из подключения, а не из sqlnet.ora.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Short summary of what was read from ldap.ora / sqlnet.ora.
    private var oracleConfigHint: String? {
        let dir = draft.tnsAdmin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return nil }
        let config = OracleConfigReader.read(directory: dir)
        var parts: [String] = []
        if config.ldapFound {
            parts.append(L10n.fmt("ldap.ora: %@", config.ldapHost.isEmpty
                ? L10n.tr("сервер не указан") : "\(config.ldapHost):\(config.ldapPort)"))
        } else {
            parts.append(L10n.tr("ldap.ora не найден"))
        }
        if config.sqlnetFound {
            if !config.authServices.isEmpty { parts.append("auth: \(config.authServices)") }
            if !config.directoryPath.isEmpty { parts.append(L10n.fmt("путь: %@", config.directoryPath.joined(separator: ", "))) }
        } else {
            parts.append(L10n.tr("sqlnet.ora не найден"))
        }
        if config.tnsnamesFound { parts.append(L10n.tr("tnsnames.ora есть")) }
        return parts.joined(separator: " · ")
    }

    private func readOracleConfig() {
        let config = OracleConfigReader.read(directory: draft.tnsAdmin)
        if config.ldapFound {
            if !config.ldapHost.isEmpty { draft.ldapHost = config.ldapHost }
            draft.ldapPort = config.ldapPort
            if !config.ldapContext.isEmpty { draft.ldapContext = config.ldapContext }
        }
        if config.sqlnetFound, !config.authServices.isEmpty {
            draft.oracleAuthServices = config.authServices
        }
    }

    /// A chosen Instant Client folder fills the driver, TNS_ADMIN and LDAP fields.
    private func applyInstantClient(_ directory: String) {
        if let jar = OracleConfigReader.jdbcJar(in: directory) { draft.driverPath = jar }
        if let admin = OracleConfigReader.networkAdmin(in: directory) {
            draft.tnsAdmin = admin
            readOracleConfig()
        }
    }

    private func testConnection() {
        testState = .running
        var profile = draft
        if profile.name.isEmpty { profile.name = profile.suggestedName }
        let candidatePassword = password

        Task { @MainActor in
            // An empty field with no stored password must ask instead of
            // trying to connect with an empty password.
            let session = Session(
                profile: profile,
                password: candidatePassword.isEmpty ? nil : candidatePassword,
                passwordProvider: { model.passwordForConnect(profile) }
            )
            do {
                try await session.connect()
                let info = session.serverInfo
                session.disconnect()
                testState = .success(
                    info.isEmpty ? L10n.tr("Подключение успешно")
                        : L10n.fmt("Подключение успешно — %@", info)
                )
            } catch {
                let dbError = (error as? SidecarError)?.dbError
                testState = .failure(dbError?.message ?? error.localizedDescription)
            }
        }
    }

    private var canTest: Bool {
        if draft.kind.isFileBased { return !draft.database.isEmpty }
        guard draft.kind == .oracle else { return !draft.host.isEmpty }
        switch draft.oracleMode {
        case .easy: return !draft.host.isEmpty
        case .tns: return !draft.oracleAlias.isEmpty
        case .ldap: return !draft.oracleAlias.isEmpty && !draft.ldapHost.isEmpty
        }
    }

    private func chooseDatabaseFile(_ apply: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.message = L10n.tr("Выберите файл базы SQLite")
        if panel.runModal() == .OK, let url = panel.url { apply(url.path) }
    }

    private func chooseDirectory(_ apply: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { apply(url.path) }
    }

    private func chooseJar(_ apply: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "jar") ?? .data]
        if panel.runModal() == .OK, let url = panel.url { apply(url.path) }
    }

    private func chooseKey(_ apply: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: (AppSettings.sshDirectory as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { apply(url.path) }
    }
}
