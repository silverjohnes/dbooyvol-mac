import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A user-visible key combination. The key is one character: a letter, a
/// digit, punctuation or a function-key scalar from the private-use range.
struct ShortcutBinding: Codable, Equatable, Hashable {
    var key: String
    /// SwiftUI's EventModifiers raw value with only ⌃⌥⇧⌘ kept.
    var modifiers: Int

    static let modifierMask: Int = SwiftUI.EventModifiers.command.rawValue
        | SwiftUI.EventModifiers.option.rawValue
        | SwiftUI.EventModifiers.control.rawValue
        | SwiftUI.EventModifiers.shift.rawValue

    /// AppKit flags use different bits than SwiftUI's EventModifiers.
    static func eventModifiers(from flags: NSEvent.ModifierFlags) -> SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    init(key: String, modifiers: Int) {
        self.key = key
        self.modifiers = modifiers & Self.modifierMask
    }

    init(key: String, modifiers: SwiftUI.EventModifiers) {
        self.init(key: key, modifiers: modifiers.rawValue)
    }

    init(key: Character, modifiers: SwiftUI.EventModifiers = .command) {
        self.init(key: String(key), modifiers: modifiers.rawValue)
    }

    var eventModifiers: SwiftUI.EventModifiers { SwiftUI.EventModifiers(rawValue: modifiers) }

    var keyEquivalent: KeyEquivalent? {
        guard key.count == 1, let character = key.first else { return nil }
        return KeyEquivalent(character)
    }

    /// "⇧⌘R", "F5", "⌘↩".
    var display: String {
        var result = ""
        let flags = SwiftUI.EventModifiers(rawValue: modifiers)
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        result += Self.keyName(key)
        return result
    }

    static func keyName(_ key: String) -> String {
        if key == " " { return L10n.tr("Пробел") }
        if let scalar = key.unicodeScalars.first, key.count == 1,
           (0xF704...0xF726).contains(scalar.value) {
            return "F\(scalar.value - 0xF704 + 1)"
        }
        let names: [String: String] = [
            "\r": "↩", "\u{3}": "⌤", "\t": "⇥", "\u{1B}": "⎋",
            "\u{7F}": "⌫", "\u{8}": "⌫", "\u{F728}": "⌦",
            "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
            "\u{F729}": "↖", "\u{F72B}": "↘", "\u{F72C}": "⇞", "\u{F72D}": "⇟",
            "\u{F72A}": "↗"
        ]
        if let name = names[key] { return name }
        if key.count == 1, let scalar = key.unicodeScalars.first, scalar.properties.isAlphabetic {
            return key.uppercased()
        }
        return key
    }

    // MARK: - Reading a key event

    static func isFunctionKey(_ event: NSEvent) -> Bool {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        return (0xF700...0xF726).contains(scalar.value)
    }

    /// The character a menu item's key equivalent would use: function keys keep
    /// their private-use scalar, letters and punctuation are taken without
    /// Shift so ⇧⌘1 is stored as "1" + Shift.
    static func key(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36, 76: return "\r"
        case 48: return "\t"
        case 51: return "\u{7F}"
        case 53: return "\u{1B}"
        case 49: return " "
        case 117: return "\u{F728}"
        default: break
        }
        if let characters = event.charactersIgnoringModifiers,
           let scalar = characters.unicodeScalars.first,
           (0xF700...0xF8FF).contains(scalar.value) {
            return String(Character(scalar))
        }
        if let translated = unmodifiedCharacter(keyCode: event.keyCode), !translated.isEmpty {
            return translated
        }
        return event.charactersIgnoringModifiers
    }

    /// Translates a physical key with no modifiers through the US layout, so a
    /// shortcut is stored as ⌘R even when the Russian layout is active.
    private static func unmodifiedCharacter(keyCode: UInt16) -> String? {
        let english = TISCopyInputSourceForLanguage("en-US" as CFString)?.takeRetainedValue()
        let current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let source = [english, current].compactMap({ $0 }).first(where: {
            TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) != nil
        }),
        let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDown),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return characters.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return String(utf16CodeUnits: base, count: length)
        }
    }
}

/// Everything the user can rebind. The raw value is the persistence key, so
/// never rename a case.
enum ShortcutAction: String, CaseIterable, Identifiable {
    // Файл
    case newScript, newConnection, openFile, save, saveAs, revealTab
    case clearEditor, closeTab, closeOtherTabs, closeAllTabs
    // Правка
    case find, toggleComment
    // Запрос
    case runOrStop, runSelection, runAll, runUnderCursor, cancelQuery
    case loadMore, exportCSV, exportXML
    // Вкладки
    case newQuery, duplicateTab, renameTab, quickOpen, nextTab, previousTab
    // Подключение
    case editConnection, renameConnection, duplicateConnection, connect
    case disconnect, refreshTree, deleteConnection
    // Вид
    case showResult, showHistory, increaseFont, decreaseFont, resetFont, fullScreen
    // Окно и справка
    case closeWindow, shortcutsHelp

    var id: String { rawValue }

    /// The same Russian literal the menu uses, so it doubles as a
    /// localization key.
    var title: String {
        switch self {
        case .newScript: return "Новый скрипт"
        case .newConnection: return "Новое подключение…"
        case .openFile: return "Открыть файл…"
        case .save: return "Сохранить"
        case .saveAs: return "Сохранить как…"
        case .revealTab: return "Показать вкладку в Finder"
        case .clearEditor: return "Очистить редактор"
        case .closeTab: return "Закрыть вкладку"
        case .closeOtherTabs: return "Закрыть остальные вкладки"
        case .closeAllTabs: return "Закрыть все вкладки"
        case .find: return "Найти"
        case .toggleComment: return "Комментировать / раскомментировать"
        case .runOrStop: return "Выполнить / остановить"
        case .runSelection: return "Выполнить выделение / всё"
        case .runAll: return "Выполнить всё"
        case .runUnderCursor: return "Выполнить запрос под курсором"
        case .cancelQuery: return "Отменить запрос"
        case .loadMore: return "Загрузить ещё"
        case .exportCSV: return "Экспорт CSV…"
        case .exportXML: return "Экспорт XML…"
        case .newQuery: return "Новый запрос"
        case .duplicateTab: return "Дублировать вкладку"
        case .renameTab: return "Переименовать вкладку…"
        case .quickOpen: return "Найти запрос…"
        case .nextTab: return "Следующая вкладка"
        case .previousTab: return "Предыдущая вкладка"
        case .editConnection: return "Изменить подключение…"
        case .renameConnection: return "Переименовать подключение…"
        case .duplicateConnection: return "Дублировать подключение"
        case .connect: return "Подключиться"
        case .disconnect: return "Отключиться"
        case .refreshTree: return "Обновить дерево"
        case .deleteConnection: return "Удалить подключение…"
        case .showResult: return "Результат"
        case .showHistory: return "История"
        case .increaseFont: return "Увеличить шрифт"
        case .decreaseFont: return "Уменьшить шрифт"
        case .resetFont: return "Шрифт по умолчанию"
        case .fullScreen: return "Во весь экран"
        case .closeWindow: return "Закрыть окно"
        case .shortcutsHelp: return "Горячие клавиши"
        }
    }

    /// Shown next to the title for actions that only work in the tree.
    var note: String? {
        self == .deleteConnection ? "в дереве" : nil
    }

    var defaultBinding: ShortcutBinding? {
        switch self {
        case .newScript: return ShortcutBinding(key: "n", modifiers: .command)
        case .newConnection: return ShortcutBinding(key: "n", modifiers: [.command, .shift])
        case .openFile: return ShortcutBinding(key: "o", modifiers: .command)
        case .save: return ShortcutBinding(key: "s", modifiers: .command)
        case .saveAs: return ShortcutBinding(key: "s", modifiers: [.command, .shift])
        case .revealTab: return ShortcutBinding(key: "r", modifiers: [.command, .shift])
        case .clearEditor: return ShortcutBinding(key: "k", modifiers: .command)
        case .closeTab: return ShortcutBinding(key: "w", modifiers: .command)
        case .closeOtherTabs: return ShortcutBinding(key: "w", modifiers: [.command, .option])
        case .closeAllTabs: return ShortcutBinding(key: "w", modifiers: [.command, .shift])
        case .find: return ShortcutBinding(key: "f", modifiers: .command)
        case .toggleComment: return ShortcutBinding(key: "/", modifiers: .command)
        case .runOrStop: return ShortcutBinding(key: "r", modifiers: .command)
        case .runSelection: return ShortcutBinding(key: "\r", modifiers: .command)
        case .runAll: return ShortcutBinding(key: "\r", modifiers: [.command, .option])
        case .runUnderCursor: return ShortcutBinding(key: "\r", modifiers: [.command, .shift])
        case .cancelQuery: return ShortcutBinding(key: ".", modifiers: [.command, .shift])
        case .loadMore: return ShortcutBinding(key: "l", modifiers: [.command, .option])
        case .exportCSV: return ShortcutBinding(key: "e", modifiers: [.command, .shift])
        case .exportXML: return ShortcutBinding(key: "e", modifiers: [.command, .option, .shift])
        case .newQuery: return ShortcutBinding(key: "t", modifiers: .command)
        case .duplicateTab: return ShortcutBinding(key: "d", modifiers: .command)
        case .renameTab: return ShortcutBinding(key: "l", modifiers: .command)
        case .quickOpen: return ShortcutBinding(key: "e", modifiers: .command)
        case .nextTab: return ShortcutBinding(key: "]", modifiers: [.command, .shift])
        case .previousTab: return ShortcutBinding(key: "[", modifiers: [.command, .shift])
        case .editConnection: return ShortcutBinding(key: "\u{F707}", modifiers: [])
        case .renameConnection: return ShortcutBinding(key: "\u{F705}", modifiers: [])
        case .duplicateConnection: return ShortcutBinding(key: "d", modifiers: [.command, .option])
        case .connect: return ShortcutBinding(key: "c", modifiers: [.command, .shift])
        case .disconnect: return ShortcutBinding(key: "d", modifiers: [.command, .shift])
        case .refreshTree: return ShortcutBinding(key: "\u{F708}", modifiers: [])
        case .deleteConnection: return ShortcutBinding(key: "\u{7F}", modifiers: [])
        case .showResult: return ShortcutBinding(key: "1", modifiers: [.command, .shift])
        case .showHistory: return ShortcutBinding(key: "2", modifiers: [.command, .shift])
        case .increaseFont: return ShortcutBinding(key: "+", modifiers: .command)
        case .decreaseFont: return ShortcutBinding(key: "-", modifiers: .command)
        case .resetFont: return ShortcutBinding(key: "0", modifiers: .command)
        case .fullScreen: return ShortcutBinding(key: "f", modifiers: [.command, .control])
        case .closeWindow: return ShortcutBinding(key: "w", modifiers: [.control, .command])
        case .shortcutsHelp: return ShortcutBinding(key: "/", modifiers: [.command, .shift])
        }
    }

    /// Combinations owned by macOS itself; assigning them would break the
    /// standard Edit and app menus.
    static let reserved: [(title: String, binding: ShortcutBinding)] = [
        ("Отменить", ShortcutBinding(key: "z", modifiers: .command)),
        ("Повторить", ShortcutBinding(key: "z", modifiers: [.command, .shift])),
        ("Вырезать", ShortcutBinding(key: "x", modifiers: .command)),
        ("Копировать", ShortcutBinding(key: "c", modifiers: .command)),
        ("Вставить", ShortcutBinding(key: "v", modifiers: .command)),
        ("Выбрать всё", ShortcutBinding(key: "a", modifiers: .command)),
        ("Свернуть окно", ShortcutBinding(key: "m", modifiers: .command)),
        ("Настройки", ShortcutBinding(key: ",", modifiers: .command))
    ]
}

/// Custom bindings live in UserDefaults as one JSON blob. Only actions the user
/// actually changed are stored, so new defaults reach existing installs.
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    private static let defaultsKey = "shortcutOverrides"

    @Published private(set) var overrides: [String: ShortcutBinding] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            overrides = decoded
        }
    }

    func binding(for action: ShortcutAction) -> ShortcutBinding? {
        overrides[action.rawValue] ?? action.defaultBinding
    }

    func isCustomized(_ action: ShortcutAction) -> Bool {
        overrides[action.rawValue] != nil
    }

    var hasOverrides: Bool { !overrides.isEmpty }

    func set(_ binding: ShortcutBinding, for action: ShortcutAction) {
        if binding == action.defaultBinding {
            overrides.removeValue(forKey: action.rawValue)
        } else {
            overrides[action.rawValue] = binding
        }
        save()
    }

    func reset(_ action: ShortcutAction) {
        overrides.removeValue(forKey: action.rawValue)
        save()
    }

    func resetAll() {
        overrides.removeAll()
        save()
    }

    /// Used by views that handle keys themselves (the tree's Delete key).
    func matches(_ event: NSEvent, action: ShortcutAction) -> Bool {
        guard let binding = binding(for: action) else { return false }
        let flags = ShortcutBinding.eventModifiers(from: event.modifierFlags).rawValue
        guard flags == binding.modifiers else { return false }
        return ShortcutBinding.key(for: event) == binding.key
    }

    /// Returns a human-readable owner of the combination, or nil when free.
    func conflict(with binding: ShortcutBinding, excluding action: ShortcutAction) -> String? {
        for other in ShortcutAction.allCases where other != action {
            if self.binding(for: other) == binding {
                return L10n.tr(other.title)
            }
        }
        if binding.key == "\u{7F}", binding.modifiers == 0, action != .deleteConnection {
            return L10n.tr("Удалить")
        }
        if let reserved = ShortcutAction.reserved.first(where: { $0.binding == binding }) {
            return L10n.tr(reserved.title)
        }
        return nil
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        // SwiftUI does not always re-register menu key equivalents when a
        // command's shortcut changes, so the AppKit menu is patched too.
        DispatchQueue.main.async { ShortcutMenuSync.apply() }
    }
}

/// Keeps the real NSMenu in sync with the store. SwiftUI builds the items and
/// their titles; only the key equivalents are rewritten here.
enum ShortcutMenuSync {
    static func apply() {
        guard let mainMenu = NSApp.mainMenu else { return }
        var actions: [String: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            actions[L10n.tr(action.title)] = action
        }
        patch(mainMenu, actions: actions)
    }

    private static func patch(_ menu: NSMenu, actions: [String: ShortcutAction]) {
        for item in menu.items {
            if let action = actions[item.title] {
                let binding = ShortcutStore.shared.binding(for: action)
                item.keyEquivalent = binding?.keyEquivalent.map { String($0.character) } ?? ""
                item.keyEquivalentModifierMask = appKitModifiers(binding)
            }
            if let submenu = item.submenu {
                patch(submenu, actions: actions)
            }
        }
    }

    private static func appKitModifiers(_ binding: ShortcutBinding?) -> NSEvent.ModifierFlags {
        guard let binding else { return [] }
        var flags: NSEvent.ModifierFlags = []
        if binding.eventModifiers.contains(.control) { flags.insert(.control) }
        if binding.eventModifiers.contains(.option) { flags.insert(.option) }
        if binding.eventModifiers.contains(.shift) { flags.insert(.shift) }
        if binding.eventModifiers.contains(.command) { flags.insert(.command) }
        return flags
    }
}

extension View {
    /// Applies a shortcut only when one is assigned.
    @ViewBuilder
    func appShortcut(_ binding: ShortcutBinding?) -> some View {
        if let binding, let key = binding.keyEquivalent {
            self.keyboardShortcut(key, modifiers: binding.eventModifiers)
        } else {
            self
        }
    }
}
