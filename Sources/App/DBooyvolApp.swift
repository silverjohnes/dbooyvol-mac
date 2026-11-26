import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var functionKeyMonitor: Any?
    private var commentMarkerMonitor: Any?
    private var menuTimer: Timer?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        QuitGuard.shared.stop()
        AppModel.shared.stopWatchingExternalChanges()
        if let functionKeyMonitor { NSEvent.removeMonitor(functionKeyMonitor) }
        if let commentMarkerMonitor { NSEvent.removeMonitor(commentMarkerMonitor) }
        menuTimer?.invalidate()
        AppModel.shared.flushTabs()
        SidecarClient.shared.shutdown()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        localizeMenus()
        ShortcutMenuSync.apply()
        AppModel.shared.checkForExternalChanges()
    }

    /// Opens the shortcuts window from the F1 monitor. SwiftUI owns the window,
    /// so reuse it when it already exists and otherwise activate the Help menu
    /// item that creates it.
    private func openShortcutsWindow() {
        if let window = NSApp.windows.first(where: {
            $0.frameAutosaveName == WindowLayout.shortcutsName
        }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let menu = NSApp.helpMenu ?? NSApp.mainMenu?.items.last?.submenu else { return }
        let localized = L10n.tr("Горячие клавиши")
        guard let index = menu.items.firstIndex(where: {
            $0.title == localized || $0.title == "Горячие клавиши"
        }) else { return }
        menu.performActionForItem(at: index)
    }

    /// Translates the standard macOS menus that SwiftUI creates in the system
    /// language, so the whole menu bar is Russian.
    private func localizeMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Standard AppKit menus follow the application language. Only Russian
        // needs the explicit map; other languages are localized by macOS.
        let language = AppLanguage.selected
        let systemIsRussian = Locale.preferredLanguages.first?.hasPrefix("ru") == true
        // Ukrainian intentionally shows the Russian interface for now.
        let translateToRussian = language == .russian || language == .ukrainian
            || (language == .system && systemIsRussian)

        let topTitles = ["File": "Файл", "Edit": "Правка", "View": "Вид", "Window": "Окно", "Help": "Справка"]
        let titles: [String: String] = [
            "About DBooyvol": "О программе DBooyvol",
            "Settings…": "Настройки…",
            "Services": "Службы",
            "Hide DBooyvol": "Скрыть DBooyvol",
            "Hide Others": "Скрыть остальные",
            "Show All": "Показать все",
            "Quit DBooyvol": "Завершить DBooyvol",
            "Quit and Close All Windows": "Завершить и закрыть все окна",
            "Show Tab Bar": "Показать панель вкладок",
            "Show All Tabs": "Показать все вкладки",
            "Enter Full Screen": "Во весь экран",
            "Exit Full Screen": "Выйти из полноэкранного режима",
            "Undo": "Отменить",
            "Redo": "Повторить",
            "Cut": "Вырезать",
            "Copy": "Копировать",
            "Paste": "Вставить",
            "Delete": "Удалить",
            "Select All": "Выбрать всё",
            "AutoFill": "Автозаполнение",
            "Contact…": "Контакт…",
            "Passwords…": "Пароли…",
            "Credit Card…": "Банковская карта…",
            "Start Dictation…": "Начать диктовку…",
            "Emoji & Symbols": "Эмодзи и символы",
            "Minimize": "Свернуть",
            "Minimize All": "Свернуть все",
            "Zoom": "Масштаб",
            "Zoom All": "Масштабировать все",
            "Bring All to Front": "Все окна на передний план",
            "Arrange in Front": "Расположить на переднем плане",
            "Fill": "Заполнить",
            "Center": "По центру",
            "Move & Resize": "Переместить и изменить размер",
            "Halves": "Половинки",
            "Left": "Слева",
            "Right": "Справа",
            "Top": "Сверху",
            "Bottom": "Снизу",
            "Quarters": "Четверти",
            "Top Left": "Сверху слева",
            "Top Right": "Сверху справа",
            "Bottom Left": "Снизу слева",
            "Bottom Right": "Снизу справа",
            "Arrange": "Расположить",
            "Left & Right": "Слева и справа",
            "Left & Quarters": "Слева и четверти",
            "Right & Left": "Справа и слева",
            "Right & Quarters": "Справа и четверти",
            "Top & Bottom": "Сверху и снизу",
            "Top & Quarters": "Сверху и четверти",
            "Bottom & Top": "Снизу и сверху",
            "Bottom & Quarters": "Снизу и четверти",
            "Return to Previous Size": "Вернуть прежний размер",
            "Full Screen Tile": "Полноэкранная мозаика",
            "Left of Screen": "Слева на экране",
            "Right of Screen": "Справа на экране",
            "Remove Window from Set": "Убрать окно из набора",
            "Show Previous Tab": "Показать предыдущую вкладку",
            "Show Next Tab": "Показать следующую вкладку",
            "Move Tab to New Window": "Переместить вкладку в новое окно",
            "Merge All Windows": "Объединить все окна",
            "DBooyvol Help": "Справка DBooyvol",
            "Toggle Sidebar": "Показать/скрыть боковую панель",
            "Close": "Закрыть окно",
            "Close All": "Закрыть все окна"
        ]

        func apply(_ menu: NSMenu) {
            for item in menu.items {
                if let translated = titles[item.title] { item.title = translated }
                if let submenu = item.submenu { apply(submenu) }
            }
        }

        if translateToRussian {
            for top in mainMenu.items {
                if let translated = topTitles[top.title] { top.title = translated }
                if let submenu = top.submenu { apply(submenu) }
            }
        }

        // The tab commands live in File; remove the default window Close items
        // that SwiftUI may still add there.
        if let file = mainMenu.items.first(where: {
            $0.title == "Файл" || $0.title == "File"
        })?.submenu {
            for item in file.items where item.action == #selector(NSWindow.performClose(_:)) {
                file.removeItem(item)
            }
        }

        // SwiftUI may also drop the shortcuts item into the Window menu.
        if let window = mainMenu.items.first(where: {
            $0.title == "Окно" || $0.title == "Window"
        })?.submenu {
            for item in window.items where item.title == "Горячие клавиши" && item.keyEquivalent.isEmpty {
                window.removeItem(item)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // A single Cmd+Q only shows a hint; a double press or holding it quits.
        QuitGuard.shared.start()
        AppModel.shared.startWatchingExternalChanges()

        // F4 edits the active connection and F1 opens the shortcuts window.
        // Handled here (not as menu key equivalents) so they also work when
        // F-keys are remapped and while the tree or editor has focus.
        functionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let extra = flags.subtracting([.function, .numericPad, .capsLock])
            guard extra.isEmpty else { return event }
            guard NSApp.modalWindow == nil else { return event }
            if let key = NSApp.keyWindow, key.attachedSheet != nil { return event }
            switch event.keyCode {
            case 118:
                guard let profile = AppModel.shared.activeProfile else { return event }
                AppModel.shared.editProfile(profile)
                return nil
            case 122:
                guard let binding = ShortcutStore.shared.binding(for: .shortcutsHelp),
                      binding.modifiers == 0,
                      binding.key == "\u{F704}" else { return event }
                self?.openShortcutsWindow()
                return nil
            default:
                return event
            }
        }

        // Cmd+Shift+/ is also the system Help shortcut, and AppKit's menu
        // matching is unreliable for shifted punctuation. A local monitor
        // runs before the menu, so the marker shortcut always reaches the
        // editor and still works in every keyboard layout.
        commentMarkerMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.modalWindow == nil else { return event }
            guard let keyWindow = NSApp.keyWindow, keyWindow.attachedSheet == nil else { return event }
            // The shortcuts window records keys itself; the settings fields
            // must keep their own typing.
            guard keyWindow.frameAutosaveName != WindowLayout.shortcutsName,
                  keyWindow.frameAutosaveName != WindowLayout.settingsName else { return event }
            guard let editorWindow = AppModel.shared.editor.textView?.window,
                  editorWindow === keyWindow else { return event }
            guard ShortcutStore.shared.matches(event, action: .toggleMarkedComment),
                  AppModel.shared.commentByMarker else { return event }
            AppModel.shared.editor.toggleMarkedComment(marker: AppModel.shared.commentMarker)
            return nil
        }

        // Free Cmd+W for "close tab" and localize the standard macOS menus.
        // SwiftUI rebuilds the menu bar shortly after launch, so keep translating
        // for the first seconds instead of relying on a single delayed pass.
        menuTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.localizeMenus()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.menuTimer?.invalidate()
            self?.menuTimer = nil
            self?.localizeMenus()
        }

        // Dev aid: --dump-menus prints the main menu with key equivalents and exits.
        if CommandLine.arguments.contains("--dump-menus") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                func dump(_ menu: NSMenu, _ indent: String) {
                    for item in menu.items {
                        if item.isSeparatorItem { continue }
                        var key = ""
                        if !item.keyEquivalent.isEmpty {
                            let codes = item.keyEquivalent.unicodeScalars
                                .map { String(format: "U+%04X", $0.value) }
                                .joined(separator: ",")
                            key = "  [\(codes) mods=\(item.keyEquivalentModifierMask.rawValue)]"
                        }
                        print("\(indent)\(item.title)\(key)")
                        if let sub = item.submenu { dump(sub, indent + "  ") }
                    }
                }
                if let menu = NSApp.mainMenu { dump(menu, "") }
                NSApp.terminate(nil)
            }
        }

        // Dev aid: --secrets-status prints the master-key id and stale accounts.
        if CommandLine.arguments.contains("--secrets-status") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let accounts = AppModel.shared.profiles
                    .filter { $0.storesPassword && !$0.kind.isFileBased }
                    .map { $0.id.uuidString }
                let d = SecretStore.diagnostics(accounts: accounts)
                print("keyid=\(d.keyID ?? "nil") stale=\(d.stale.count) error=\(d.error ?? "none")")
                NSApp.terminate(nil)
            }
        }

        // Dev aid: --snapshot /tmp/app.png runs the editor query and saves a PNG of the window.
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot"), idx + 1 < CommandLine.arguments.count {            let path = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let window = NSApp.windows.first(where: { $0.contentView != nil }) {
                    window.deminiaturize(nil)
                    window.makeKeyAndOrderFront(nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                AppModel.shared.runSelectionOrAll()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                // Capture the theme frame, not just the content view, so the
                // title bar and toolbar are visible too.
                if let window = NSApp.windows.first(where: { $0.isVisible }),
                   let view = window.contentView?.superview ?? window.contentView {
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        if let data = rep.representation(using: .png, properties: [:]) {
                            try? data.write(to: URL(fileURLWithPath: path))
                        }
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }
}

struct DBooyvolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @StateObject private var shortcuts = ShortcutStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("О программе DBooyvol") { AboutPanel.show() }
            }

            CommandGroup(replacing: .newItem) {
                Button("Новый скрипт") { model.newTab() }
                    .appShortcut(shortcuts.binding(for: .newScript))
                Button("Новое подключение…") { model.addProfile() }
                    .appShortcut(shortcuts.binding(for: .newConnection))
                Divider()
                Button("Открыть файл…") { model.openFile() }
                    .appShortcut(shortcuts.binding(for: .openFile))
            }

            CommandGroup(replacing: .saveItem) {
                Button("Сохранить") { model.saveSQLFile() }
                    .appShortcut(shortcuts.binding(for: .save))
                Button("Сохранить как…") { model.saveSQLFileAs() }
                    .appShortcut(shortcuts.binding(for: .saveAs))
                Button("Показать вкладку в Finder") { model.revealActiveTabInFinder() }
                    .appShortcut(shortcuts.binding(for: .revealTab))
                Divider()
                Button("Очистить редактор") { model.clearEditor() }
                    .appShortcut(shortcuts.binding(for: .clearEditor))
                Divider()
                Button("Закрыть вкладку") { model.closeTab(model.activeTabID) }
                    .appShortcut(shortcuts.binding(for: .closeTab))
                Button("Закрыть остальные вкладки") {
                    if let id = model.activeTabID as UUID? { model.closeOtherTabs(id) }
                }
                .appShortcut(shortcuts.binding(for: .closeOtherTabs))
                Button("Закрыть все вкладки") { model.closeAllTabs() }
                    .appShortcut(shortcuts.binding(for: .closeAllTabs))
            }

            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Найти") { model.findFocusedPane() }
                    .appShortcut(shortcuts.binding(for: .find))
            }

            CommandMenu("Запрос") {
                Button("Выполнить / остановить") { model.runOrStop() }
                    .appShortcut(shortcuts.binding(for: .runOrStop))
                Divider()
                Button("Выполнить выделение / всё") { model.runSelectionOrAll() }
                    .appShortcut(shortcuts.binding(for: .runSelection))
                Button("Выполнить всё") { model.runAll() }
                    .appShortcut(shortcuts.binding(for: .runAll))
                Button("Выполнить запрос под курсором") { model.runStatementAtCursor() }
                    .appShortcut(shortcuts.binding(for: .runUnderCursor))
                Divider()
                Button("Отменить запрос") { model.cancel() }
                    .appShortcut(shortcuts.binding(for: .cancelQuery))
                Button("Загрузить ещё") { model.loadMore() }
                    .appShortcut(shortcuts.binding(for: .loadMore))
                    .disabled(model.result?.done != false)
                Divider()
                Button("Комментировать / раскомментировать") { model.editor.toggleComment() }
                    .appShortcut(shortcuts.binding(for: .toggleComment))
                Button("Комментировать по специальному ключу") {
                    guard model.commentByMarker else { return }
                    model.editor.toggleMarkedComment(marker: model.commentMarker)
                }
                .appShortcut(shortcuts.binding(for: .toggleMarkedComment))
                .disabled(!model.commentByMarker)
                Divider()
                Button("Экспорт CSV…") { model.exportCSV() }
                    .appShortcut(shortcuts.binding(for: .exportCSV))
                Button("Экспорт XML…") { model.exportXML() }
                    .appShortcut(shortcuts.binding(for: .exportXML))
                Button("Экспорт XLSX…") { model.exportXLSX() }
                    .appShortcut(shortcuts.binding(for: .exportXLSX))
            }

            CommandMenu("Вкладки") {
                Button("Новый запрос") { model.newTab() }
                    .appShortcut(shortcuts.binding(for: .newQuery))
                Button("Дублировать вкладку") {
                    if let id = model.activeTabID as UUID? { model.duplicateTab(id) }
                }
                .appShortcut(shortcuts.binding(for: .duplicateTab))
                Button("Переименовать вкладку…") {
                    if let tab = model.activeTab { model.beginRename(tab) }
                }
                .appShortcut(shortcuts.binding(for: .renameTab))
                Divider()
                Button("Найти запрос…") { model.openQuickOpen() }
                    .appShortcut(shortcuts.binding(for: .quickOpen))
                Divider()
                Button("Следующая вкладка") { model.selectNextTab() }
                    .appShortcut(shortcuts.binding(for: .nextTab))
                Button("Предыдущая вкладка") { model.selectPreviousTab() }
                    .appShortcut(shortcuts.binding(for: .previousTab))
                Button("Предыдущая открытая вкладка") { model.selectPreviouslyOpenedTab() }
                    .appShortcut(shortcuts.binding(for: .previousOpenedTab))
            }

            CommandMenu("Подключение") {
                Button("Создать новое подключение…") { model.addProfile() }
                Button("Изменить подключение…") {
                    if let p = model.activeProfile { model.editProfile(p) }
                }
                .appShortcut(shortcuts.binding(for: .editConnection))
                Button("Переименовать подключение…") {
                    if let p = model.activeProfile { model.promptRenameProfile(p) }
                }
                .appShortcut(shortcuts.binding(for: .renameConnection))
                Button("Дублировать подключение") {
                    if let p = model.activeProfile { model.duplicateProfile(p) }
                }
                .appShortcut(shortcuts.binding(for: .duplicateConnection))
                Divider()
                Button("Подключиться") { model.connectActive() }
                    .appShortcut(shortcuts.binding(for: .connect))
                Button("Отключиться") { model.disconnectActive() }
                    .appShortcut(shortcuts.binding(for: .disconnect))
                Divider()
                Button("Обновить дерево") { model.refreshTree() }
                    .appShortcut(shortcuts.binding(for: .refreshTree))
                Button("Удалить подключение…") {
                    if let p = model.activeProfile { model.promptDeleteProfile(p) }
                }
            }

            CommandGroup(after: .toolbar) {
                Button("Результат") { model.bottomTab = .result }
                    .appShortcut(shortcuts.binding(for: .showResult))
                Button("История") { model.bottomTab = .history }
                    .appShortcut(shortcuts.binding(for: .showHistory))
                Divider()
                Button("Увеличить шрифт") { model.increaseEditorFontSize() }
                    .appShortcut(shortcuts.binding(for: .increaseFont))
                Button("Уменьшить шрифт") { model.decreaseEditorFontSize() }
                    .appShortcut(shortcuts.binding(for: .decreaseFont))
                Button("Шрифт по умолчанию") { model.resetEditorFontSize() }
                    .appShortcut(shortcuts.binding(for: .resetFont))
                Divider()
                Button("Строка вертикально / таблица") { model.toggleSingleRowResult() }
                    .disabled(model.result == nil)
                Button("Калькулятор") { model.toggleCalcPanel() }
                Button("Панель фильтра") { model.setShowFilterPanel(!model.showFilterPanel) }
                Divider()
                Button("Сбросить вид") { WindowLayout.resetAll() }
                Divider()
                Button("Во весь экран") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .appShortcut(shortcuts.binding(for: .fullScreen))
            }

            CommandGroup(after: .windowSize) {
                Button("Закрыть окно") { NSApp.keyWindow?.performClose(nil) }
                    .appShortcut(shortcuts.binding(for: .closeWindow))
            }

            CommandGroup(replacing: .help) {
                Button("Горячие клавиши") { openWindow(id: "shortcuts") }
                    .appShortcut(shortcuts.binding(for: .shortcutsHelp))
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        Window("Горячие клавиши", id: "shortcuts") {
            ShortcutsView()
                .environmentObject(model)
        }
        .defaultSize(width: 620, height: 720)
    }
}
