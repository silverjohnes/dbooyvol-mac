import SwiftUI
import AppKit

/// One row in the shortcuts window: either a rebindable action or a fixed
/// system shortcut shown for reference.
enum ShortcutItem: Identifiable {
    case action(ShortcutAction)
    case fixed(title: String, keys: String)

    var id: String {
        switch self {
        case .action(let action): return action.rawValue
        case .fixed(let title, _): return "fixed:\(title)"
        }
    }

    var title: String {
        switch self {
        case .action(let action): return action.title
        case .fixed(let title, _): return title
        }
    }
}

struct ShortcutSection: Identifiable {
    let id: String
    let title: String
    let items: [ShortcutItem]
}

enum ShortcutCatalog {
    static let sections: [ShortcutSection] = [
        ShortcutSection(id: "file", title: "Файл", items: [
            .action(.newScript), .action(.newConnection), .action(.openFile),
            .action(.save), .action(.saveAs), .action(.revealTab),
            .action(.clearEditor), .action(.closeTab),
            .action(.closeOtherTabs), .action(.closeAllTabs)
        ]),
        ShortcutSection(id: "edit", title: "Правка", items: [
            .fixed(title: "Отменить", keys: "⌘Z"),
            .fixed(title: "Повторить", keys: "⇧⌘Z"),
            .fixed(title: "Вырезать", keys: "⌘X"),
            .fixed(title: "Копировать", keys: "⌘C"),
            .fixed(title: "Вставить", keys: "⌘V"),
            .fixed(title: "Удалить", keys: "⌫"),
            .fixed(title: "Выбрать всё", keys: "⌘A"),
            .action(.find), .action(.toggleComment), .action(.toggleMarkedComment)
        ]),
        ShortcutSection(id: "query", title: "Запрос", items: [
            .action(.runOrStop), .action(.runSelection), .action(.runAll),
            .action(.runUnderCursor), .action(.cancelQuery), .action(.loadMore),
            .action(.exportCSV), .action(.exportXML), .action(.exportXLSX)
        ]),
        ShortcutSection(id: "tabs", title: "Вкладки", items: [
            .action(.newQuery), .action(.duplicateTab), .action(.renameTab),
            .action(.quickOpen), .action(.nextTab), .action(.previousTab),
            .action(.previousOpenedTab)
        ]),
        ShortcutSection(id: "connections", title: "Подключения и дерево", items: [
            .action(.editConnection), .action(.renameConnection),
            .action(.duplicateConnection), .action(.connect),
            .action(.disconnect), .action(.refreshTree), .action(.deleteConnection)
        ]),
        ShortcutSection(id: "view", title: "Вид", items: [
            .action(.showResult), .action(.showHistory),
            .action(.increaseFont), .action(.decreaseFont), .action(.resetFont),
            .action(.fullScreen),
            .fixed(title: "Сбросить вид", keys: "—"),
            .fixed(title: "Настройки", keys: "⌘,"),
            .fixed(title: "Свернуть окно", keys: "⌘M")
        ]),
        ShortcutSection(id: "window", title: "Окно и справка", items: [
            .action(.closeWindow), .action(.shortcutsHelp)
        ])
    ]
}

struct ShortcutsView: View {
    @ObservedObject private var store = ShortcutStore.shared
    @State private var recording: ShortcutAction?
    @State private var message: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Нажмите на сочетание, чтобы изменить его.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Spacer(minLength: 12)
                Button("По умолчанию") { resetAll() }
                    .disabled(!store.hasOverrides)
                    .help(L10n.tr("Сбросить все сочетания к стандартным"))
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(ShortcutCatalog.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(18)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(WindowConfigurator(name: WindowLayout.shortcutsName))
        .onChange(of: recording) { value in
            removeMonitor()
            guard let action = value else { return }
            // A local monitor runs before menu key equivalents, so recording
            // works even for combinations the app already uses.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handle(event, for: action)
                return nil
            }
        }
        .onDisappear { removeMonitor() }
    }

    private func sectionView(_ section: ShortcutSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr(section.title))
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    row(item)
                    if index < section.items.count - 1 {
                        Divider().padding(.leading, 10)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func row(_ item: ShortcutItem) -> some View {
        HStack(spacing: 10) {
            Text(L10n.tr(item.title))
            Spacer(minLength: 16)
            switch item {
            case .fixed(_, let keys):
                if keys != "—" {
                    keyBadge(keys)
                } else {
                    Text(keys).foregroundColor(.secondary)
                }
            case .action(let action):
                if let note = action.note {
                    Text(L10n.tr(note))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if store.isCustomized(action) {
                    Button {
                        store.reset(action)
                        message = nil
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help(L10n.tr("Вернуть по умолчанию"))
                }
                recorderButton(for: action)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
    }

    private func recorderButton(for action: ShortcutAction) -> some View {
        let active = recording == action
        let title = active
            ? L10n.tr("Нажмите сочетание…")
            : (store.binding(for: action)?.display ?? "—")
        return Button {
            message = nil
            recording = active ? nil : action
        } label: {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .medium, design: .rounded))
                .foregroundColor(active ? .accentColor : .primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(minWidth: 64)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(active ? Color.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(L10n.tr("Изменить сочетание"))
    }

    private func keyBadge(_ keys: String) -> some View {
        Text(keys)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.14))
            )
    }

    private func resetAll() {
        recording = nil
        message = nil
        store.resetAll()
    }

    private func handle(_ event: NSEvent, for action: ShortcutAction) {
        let flags = ShortcutBinding.eventModifiers(from: event.modifierFlags)
        if event.keyCode == 53, flags.isEmpty {
            recording = nil
            return
        }
        let isFunction = ShortcutBinding.isFunctionKey(event)
        let isTreeDelete = action == .deleteConnection && event.keyCode == 51 && flags.isEmpty
        if flags.isEmpty, !isFunction, !isTreeDelete {
            NSSound.beep()
            return
        }
        guard let key = ShortcutBinding.key(for: event) else {
            NSSound.beep()
            return
        }
        let binding = ShortcutBinding(key: key, modifiers: flags.rawValue)
        if let conflict = store.conflict(with: binding, excluding: action) {
            message = L10n.fmt("Сочетание уже используется: %@", conflict)
            NSSound.beep()
            recording = nil
            return
        }
        store.set(binding, for: action)
        message = nil
        recording = nil
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
