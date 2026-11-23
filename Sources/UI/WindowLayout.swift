import SwiftUI
import AppKit

/// Remembers window frames and pane divider positions between launches, and
/// provides a single place to reset the whole layout to its defaults.
enum WindowLayout {
    static let mainName = "DBooyvol.MainWindow"
    static let settingsName = "DBooyvol.SettingsWindow"
    static let shortcutsName = "DBooyvol.ShortcutsWindow"
    static let sidebarSplitName = "DBooyvol.Split.Sidebar"
    static let bottomSplitName = "DBooyvol.Split.Bottom"

    static let defaultWindowSize = NSSize(width: 1280, height: 820)
    static let defaultSettingsSize = NSSize(width: 560, height: 500)
    static let defaultShortcutsSize = NSSize(width: 620, height: 720)
    static let defaultSidebarWidth: CGFloat = 260
    static let defaultEditorFraction: CGFloat = 0.52

    static func attach(to window: NSWindow, name: String, splits: Bool) {
        if window.frameAutosaveName != name {
            window.setFrameAutosaveName(name)
        }
        if name == mainName {
            // The run accessory takes the leading title bar space; the app
            // name is still in the menu bar and the About panel.
            window.titleVisibility = .hidden
        }
        guard splits else { return }
        configureSplits(in: window)
    }

    private static func configureSplits(in window: NSWindow) {
        guard let root = window.contentView else { return }
        for split in splitViews(in: root) {
            let name = split.isVertical ? sidebarSplitName : bottomSplitName
            if split.autosaveName != name {
                split.autosaveName = name
            }
        }
    }

    private static func splitViews(in view: NSView) -> [NSSplitView] {
        var result: [NSSplitView] = []
        if let split = view as? NSSplitView { result.append(split) }
        for sub in view.subviews {
            result.append(contentsOf: splitViews(in: sub))
        }
        return result
    }

    /// Clears the saved geometry and puts the main window, sidebar and
    /// editor/results split back to their default sizes.
    static func resetAll() {
        let defaults = UserDefaults.standard
        for name in [mainName, settingsName, shortcutsName] {
            defaults.removeObject(forKey: frameKey(name))
        }
        for name in [sidebarSplitName, bottomSplitName] {
            defaults.removeObject(forKey: splitKey(name))
        }

        for window in NSApp.windows {
            switch window.frameAutosaveName {
            case mainName:
                resetMainWindow(window)
            case settingsName:
                setFrame(window, size: defaultSettingsSize)
            case shortcutsName:
                setFrame(window, size: defaultShortcutsSize)
            default:
                break
            }
        }
    }

    private static func resetMainWindow(_ window: NSWindow) {
        setFrame(window, size: defaultWindowSize)
        window.contentView?.layoutSubtreeIfNeeded()
        // Let SwiftUI finish its own layout pass before moving the dividers.
        DispatchQueue.main.async {
            guard let root = window.contentView else { return }
            for split in splitViews(in: root) {
                guard split.subviews.count >= 2 else { continue }
                if split.isVertical {
                    let width = min(defaultSidebarWidth, max(190, split.bounds.width - 320))
                    split.setPosition(width, ofDividerAt: 0)
                } else {
                    let usable = max(0, split.bounds.height - split.dividerThickness)
                    let top = max(150, usable * defaultEditorFraction)
                    split.setPosition(top, ofDividerAt: 0)
                }
            }
        }
    }

    private static func setFrame(_ window: NSWindow, size: NSSize) {
        let visible = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let width = min(size.width, max(320, visible.width - 40))
        let height = min(size.height, max(240, visible.height - 40))
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
        window.setFrame(frame, display: true)
    }

    private static func frameKey(_ name: String) -> String { "NSWindow Frame \(name)" }
    private static func splitKey(_ name: String) -> String { "NSSplitView Subview Frames \(name)" }
}

/// Invisible view that configures its hosting NSWindow once it is in a window.
struct WindowConfigurator: NSViewRepresentable {
    let name: String
    var configureSplits = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                WindowLayout.attach(to: window, name: name, splits: configureSplits)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                WindowLayout.attach(to: window, name: name, splits: configureSplits)
            }
        }
    }
}
