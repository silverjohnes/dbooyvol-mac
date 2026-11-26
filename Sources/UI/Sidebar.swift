import SwiftUI
import AppKit

final class TreeItem: NSObject {
    let node: TreeNode
    let profile: ConnectionProfile?
    let path: [String]
    var children: [TreeItem]?
    var isLoading = false

    init(node: TreeNode, profile: ConnectionProfile?, path: [String]) {
        self.node = node
        self.profile = profile
        self.path = path
    }
}

/// Outline view that maps the Delete key to "delete connection" (DBeaver style),
/// and only when a connection row is selected — never while editing text.
final class ConnectionOutlineView: NSOutlineView {
    var onDeleteKey: (() -> Bool)?
    /// Files dropped onto a row; the row is -1 when the drop is below the tree.
    var onDropFiles: (([URL], Int) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if ShortcutStore.shared.matches(event, action: .deleteConnection), onDeleteKey?() == true {
            return
        }
        super.keyDown(with: event)
    }

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    private func dropRow(for info: NSDraggingInfo) -> Int {
        row(at: convert(info.draggingLocation, from: nil))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        updateDropRow(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        updateDropRow(sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropRow(-1, dropOperation: .on)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let row = dropRow(for: sender)
        let urls = fileURLs(from: sender)
        setDropRow(-1, dropOperation: .on)
        return onDropFiles?(urls, row) ?? false
    }

    private func updateDropRow(_ sender: NSDraggingInfo) {
        let row = dropRow(for: sender)
        setDropRow(row, dropOperation: .on)
    }
}

struct SidebarView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = ConnectionOutlineView()
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.style = .sourceList
        outline.indentationPerLevel = 12
        outline.allowsMultipleSelection = false
        outline.floatsGroupRows = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.openItem(_:))

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu

        outline.onDeleteKey = { [weak coordinator = context.coordinator] in
            coordinator?.deleteSelectedIfConnection() ?? false
        }
        outline.registerForDraggedTypes([.fileURL])
        outline.onDropFiles = { [weak coordinator = context.coordinator] urls, row in
            coordinator?.handleDroppedFiles(urls, row: row) ?? false
        }

        context.coordinator.outline = outline
        context.coordinator.reloadRoots()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.syncIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        let model: AppModel
        weak var outline: ConnectionOutlineView?
        var roots: [TreeItem] = []
        private var signature = ""
        private var lastSelectedRow = -1
        /// reloadData() collapses rows; those notifications must not erase the saved state.
        private var suppressExpansionSaving = false

        init(model: AppModel) {
            self.model = model
        }

        func syncIfNeeded() {
            if lastRefreshToken != model.treeRefreshToken {
                lastRefreshToken = model.treeRefreshToken
                reloadRoots()
                return
            }
            let newSignature = model.profiles.map { "\($0.id)|\($0.displayName)" }.joined(separator: ",")
            if newSignature != signature {
                signature = newSignature
                reloadRoots()
            }
            syncSelection()
        }

        private var lastRefreshToken = 0
        /// True while the tree selection is set programmatically. The outline
        /// view reports that as a user selection, which must not publish model
        /// changes in the middle of a SwiftUI update.
        private var suppressSelectionPublishing = false

        private func syncSelection() {
            guard let outline, let id = model.activeProfileID,
                  let row = roots.firstIndex(where: { $0.profile?.id == id }) else { return }
            if outline.selectedRow != row {
                suppressSelectionPublishing = true
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                suppressSelectionPublishing = false
                outline.scrollRowToVisible(row)
            }
        }

        func reloadRoots() {
            suppressExpansionSaving = true
            suppressSelectionPublishing = true
            defer {
                suppressExpansionSaving = false
                suppressSelectionPublishing = false
            }
            signature = model.profiles.map { "\($0.id)|\($0.displayName)" }.joined(separator: ",")
            roots = model.profiles.map { p in
                TreeItem(
                    node: TreeNode(
                        id: "conn:\(p.id)",
                        label: p.displayName,
                        kind: "conn",
                        hasChildren: true,
                        detail: p.kind.title
                    ),
                    profile: p,
                    path: []
                )
            }
            outline?.reloadData()
            for (index, item) in roots.enumerated() {
                let profileID = model.profiles[index].id
                // Only a connection the user explicitly opened is reopened.
                // A closed (or never opened) connection must stay closed when
                // profiles are added or reloaded.
                let collapsed = AppSettings.collapsedConnections(for: profileID)
                let expanded = AppSettings.expandedTreeItems(for: profileID)
                if !collapsed.contains(item.node.id), expanded.contains(item.node.id) {
                    outline?.expandItem(item)
                }
            }
            syncSelection()
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item = item as? TreeItem else { return roots.count }
            return item.children?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let item = item as? TreeItem else { return roots[index] }
            return item.children?[index] ?? NSNull()
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? TreeItem)?.node.hasChildren ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            if let item = item as? TreeItem { load(item) }
            return true
        }

        private func load(_ item: TreeItem) {
            guard let profile = item.profile, item.children == nil, !item.isLoading else { return }
            item.isLoading = true
            let path = item.path
            Task { @MainActor in
                let nodes = await model.children(profile: profile, path: path)
                item.children = nodes.map { node in
                    TreeItem(node: node, profile: profile, path: Self.childPath(node, parent: path))
                }
                item.isLoading = false
                outline?.reloadItem(item, reloadChildren: true)
                outline?.expandItem(item)

                // Restore the sub-tree that was open when the app last quit.
                let saved = AppSettings.expandedTreeItems(for: profile.id)
                for child in item.children ?? [] where saved.contains(child.node.id) {
                    outline?.expandItem(child)
                }
            }
        }

        // MARK: - expansion persistence

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !suppressExpansionSaving,
                  let item = notification.userInfo?["NSObject"] as? TreeItem,
                  let profile = item.profile else { return }
            var saved = AppSettings.expandedTreeItems(for: profile.id)
            saved.insert(item.node.id)
            AppSettings.setExpandedTreeItems(saved, for: profile.id)
            if item.node.kind == "conn" {
                AppSettings.markConnectionExpanded(item.node.id, for: profile.id)
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !suppressExpansionSaving,
                  let item = notification.userInfo?["NSObject"] as? TreeItem,
                  let profile = item.profile else { return }
            var saved = AppSettings.expandedTreeItems(for: profile.id)
            saved.remove(item.node.id)
            AppSettings.setExpandedTreeItems(saved, for: profile.id)
            if item.node.kind == "conn" {
                AppSettings.markConnectionCollapsed(item.node.id, for: profile.id)
            }
        }

        static func childPath(_ node: TreeNode, parent: [String]) -> [String] {
            switch node.kind {
            case "schema":
                return [node.label]
            case "folder":
                return node.id.components(separatedBy: "|")
            case "table", "view":
                let parts = node.id.components(separatedBy: "|")
                if parts.count >= 2 { return [parts[0], "", parts[1]] }
                return parent + [node.label]
            default:
                return parent + [node.label]
            }
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? TreeItem else { return nil }
            let cell = NSTableCellView()

            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            if item.node.kind == "conn", let profile = item.profile {
                icon.image = DBIcon.image(for: profile.kind, size: 14)
                icon.contentTintColor = nil
            } else {
                icon.image = NSImage(systemSymbolName: Self.symbol(for: item.node.kind), accessibilityDescription: nil)
                icon.contentTintColor = Self.color(for: item.node.kind)
            }
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)

            let label = NSTextField(labelWithString: item.node.label)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 12.5, weight: item.node.primary ? .semibold : .regular)
            label.lineBreakMode = .byTruncatingTail
            let row = outlineView.row(forItem: item)
            label.textColor = (row >= 0 && outlineView.selectedRow == row) ? .white : .labelColor
            cell.textField = label

            let stack = NSStackView(views: [icon, label])
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.alignment = .centerY

            if let detail = item.node.detail, item.node.kind == "column" {
                let d = NSTextField(labelWithString: detail)
                d.font = .systemFont(ofSize: 10.5)
                d.textColor = .secondaryLabelColor
                stack.addArrangedSubview(d)
            }

            if item.node.kind == "conn", let profile = item.profile {
                let tip = L10n.fmt("Имя: %@", profile.displayName) + "\n"
                    + L10n.fmt("URL: %@", profile.displayURL) + "\n"
                    + L10n.fmt("Пользователь: %@", profile.user)
                cell.appTooltipText = tip
                stack.appTooltipText = tip
                label.appTooltipText = tip
            }

            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.heightAnchor.constraint(equalToConstant: 14),
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        static func symbol(for kind: String) -> String {
            switch kind {
            case "conn": return "cylinder.split.1x2"
            case "schema": return "square.stack.3d.up"
            case "folder": return "folder"
            case "table": return "tablecells"
            case "view": return "eye"
            case "column": return "smallcircle.filled.circle"
            default: return "circle"
            }
        }

        static func color(for kind: String) -> NSColor {
            switch kind {
            case "conn": return .systemBlue
            case "schema": return .systemIndigo
            case "table": return .systemTeal
            case "view": return .systemPurple
            default: return .secondaryLabelColor
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline else { return }
            let selected = outline.selectedRow
            var rows = IndexSet()
            if lastSelectedRow >= 0 { rows.insert(lastSelectedRow) }
            if selected >= 0 { rows.insert(selected) }
            if !rows.isEmpty {
                outline.reloadData(forRowIndexes: rows,
                                   columnIndexes: IndexSet(integer: 0))
            }
            lastSelectedRow = selected

            guard let item = outline.item(atRow: selected) as? TreeItem,
                  let profile = item.profile else { return }
            guard !suppressSelectionPublishing else { return }
            // Selecting a connection in the tree only changes what is browsed.
            // The database a script runs against is chosen in the tab bar
            // (top right) and must not change here.
            if model.activeProfileID != profile.id {
                model.activeProfileID = profile.id
            }
        }

        // MARK: - double click

        @objc func openItem(_ sender: Any?) {
            guard let item = outline?.item(atRow: outline?.selectedRow ?? -1) as? TreeItem else { return }
            activate(item)
        }

        private func activate(_ item: TreeItem) {
            switch item.node.kind {
            case "conn":
                guard let profile = item.profile else { return }
                model.activeProfileID = profile.id
                model.editProfile(profile)
            case "schema", "folder":
                guard let outline else { return }
                if outline.isItemExpanded(item) {
                    outline.collapseItem(item)
                } else {
                    outline.expandItem(item)
                }
            case "table", "view":
                openSelect(for: item)
            default:
                break
            }
        }

        private func openSelect(for item: TreeItem) {
            guard let profile = item.profile else { return }
            let parts = item.node.id.components(separatedBy: "|")
            guard parts.count >= 2 else { return }
            let schema = parts[0]
            let table = parts[1]
            let sql: String
            if profile.kind == .oracle {
                sql = "SELECT *\n  FROM \(schema).\(table);\n"
            } else {
                sql = "SELECT *\n  FROM \"\(schema)\".\"\(table)\";\n"
            }
            model.activeProfileID = profile.id
            model.newTab(text: sql)
            model.setActiveScriptProfile(profile.id)
            model.editor.focus()
        }

        // MARK: - context menu

        private func add(
            _ menu: NSMenu,
            _ title: String,
            _ action: Selector,
            _ item: TreeItem?,
            key: String = "",
            modifiers: NSEvent.ModifierFlags = []
        ) {
            let entry = NSMenuItem(title: L10n.tr(title), action: action, keyEquivalent: key)
            if !key.isEmpty { entry.keyEquivalentModifierMask = modifiers }
            entry.target = self
            entry.representedObject = item
            menu.addItem(entry)
        }

        /// Key equivalents mirror DBeaver: F4 edit, F2 rename, F5 refresh, Del delete.
        private static let f2 = String(UnicodeScalar(0xF705)!)
        private static let f4 = String(UnicodeScalar(0xF707)!)
        private static let f5 = String(UnicodeScalar(0xF708)!)

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            add(menu, "Создать новое подключение…", #selector(ctxNewProfile(_:)), nil,
                key: "n", modifiers: [.command])

            let clicked = outline?.clickedRow ?? -1
            let row = clicked >= 0 ? clicked : (outline?.selectedRow ?? -1)
            guard row >= 0, let item = outline?.item(atRow: row) as? TreeItem else { return }

            menu.addItem(.separator())

            if item.node.kind == "conn", let profile = item.profile {
                add(menu, "Изменить…", #selector(ctxEdit(_:)), item, key: Self.f4, modifiers: [])
                add(menu, "Переименовать…", #selector(ctxRename(_:)), item, key: Self.f2, modifiers: [])
                add(menu, "Дублировать", #selector(ctxDuplicate(_:)), item, key: "d", modifiers: [.command, .option])
                menu.addItem(.separator())
                if model.isConnected(profile.id) {
                    add(menu, "Отключиться", #selector(ctxDisconnect(_:)), item,
                        key: "d", modifiers: [.command, .shift])
                } else {
                    add(menu, "Подключиться", #selector(ctxConnect(_:)), item,
                        key: "c", modifiers: [.command, .shift])
                }
                add(menu, "Обновить", #selector(ctxRefresh(_:)), item, key: Self.f5, modifiers: [])
                menu.addItem(.separator())
                add(menu, "Удалить…", #selector(ctxDelete(_:)), item, key: "\u{8}", modifiers: [])
            } else if item.node.kind == "table" || item.node.kind == "view" {
                add(menu, "SELECT таблицы", #selector(ctxOpenSelect(_:)), item)
                add(menu, "Копировать названия столбцов", #selector(ctxCopyColumns(_:)), item)
                add(menu, "Копировать имя", #selector(ctxCopyName(_:)), item)
            } else {
                add(menu, "Обновить", #selector(ctxRefresh(_:)), item, key: Self.f5, modifiers: [])
            }
        }

        /// A file dropped on a connection (or any row belonging to it) is
        /// opened and bound to that connection. Drops elsewhere use the
        /// connection selected in the tree.
        func handleDroppedFiles(_ urls: [URL], row: Int) -> Bool {
            guard !urls.isEmpty else { return false }
            var binding = model.activeProfileID
            if row >= 0, let item = outline?.item(atRow: row) as? TreeItem,
               let profile = item.profile {
                binding = profile.id
                model.activeProfileID = profile.id
            }
            model.openDroppedFiles(urls, binding: binding)
            return true
        }

        /// Delete key in the tree: only for connection rows.
        func deleteSelectedIfConnection() -> Bool {
            guard let item = outline?.item(atRow: outline?.selectedRow ?? -1) as? TreeItem,
                  item.node.kind == "conn", let profile = item.profile else { return false }
            model.promptDeleteProfile(profile)
            return true
        }

        @objc private func ctxNewProfile(_ sender: NSMenuItem) {
            model.addProfile()
        }

        @objc private func ctxEdit(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? TreeItem, let profile = item.profile else { return }
            model.activeProfileID = profile.id
            model.editProfile(profile)
        }

        @objc private func ctxRename(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? TreeItem, let profile = item.profile else { return }
            model.promptRenameProfile(profile)
        }

        @objc private func ctxDuplicate(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? TreeItem, let profile = item.profile else { return }
            model.duplicateProfile(profile)
        }

        @objc private func ctxDelete(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? TreeItem, let profile = item.profile else { return }
            model.promptDeleteProfile(profile)
        }

        @objc private func ctxDisconnect(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? TreeItem, let profile = item.profile else { return }
            model.disconnect(profile.id)
            item.children = nil
            outline?.reloadItem(item, reloadChildren: true)
            model.status = L10n.fmt("Отключено: %@", profile.displayName)
        }

        @objc private func ctxConnect(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? TreeItem else { return }
            item.children = nil
            outline?.collapseItem(item)
            outline?.expandItem(item)
        }

        @objc private func ctxRefresh(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? TreeItem else { return }
            item.children = nil
            outline?.reloadItem(item, reloadChildren: true)
            outline?.expandItem(item)
        }

        @objc private func ctxOpenSelect(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? TreeItem else { return }
            openSelect(for: item)
        }

        @objc private func ctxCopyName(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? TreeItem else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(item.node.label, forType: .string)
        }

        @objc private func ctxCopyColumns(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? TreeItem,
                  let profile = item.profile else { return }
            Task { @MainActor in
                let nodes: [TreeNode]
                if let children = item.children {
                    nodes = children.map(\.node)
                } else {
                    nodes = await model.children(profile: profile, path: item.path)
                }
                let names = nodes.filter { $0.kind == "column" }.map(\.label)
                guard !names.isEmpty else {
                    model.status = L10n.fmt("Не удалось получить столбцы %@", item.node.label)
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(names.joined(separator: "\n"), forType: .string)
                model.status = L10n.fmt("Скопировано столбцов: %@", String(names.count))
            }
        }
    }
}
