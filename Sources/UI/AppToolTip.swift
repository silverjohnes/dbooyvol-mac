import SwiftUI
import AppKit
import ObjectiveC

private var appTooltipTextKey: UInt8 = 0
private var appTooltipProviderKey: UInt8 = 0

private final class TooltipProviderBox {
    let provider: (NSPoint) -> String?
    init(_ provider: @escaping (NSPoint) -> String?) {
        self.provider = provider
    }
}

extension NSView {
    /// Tooltip text owned by `TooltipCenter`. Setting it clears AppKit's own
    /// tooltip so the system cannot show it earlier than our one-second delay.
    var appTooltipText: String? {
        get { objc_getAssociatedObject(self, &appTooltipTextKey) as? String }
        set {
            objc_setAssociatedObject(self, &appTooltipTextKey, newValue,
                                     .OBJC_ASSOCIATION_COPY_NONATOMIC)
            toolTip = nil
        }
    }

    /// Dynamic tooltip for views that contain several regions, such as the
    /// row-number gutter (key icon vs. rows) or the tab strip.
    var appTooltipProvider: ((NSPoint) -> String?)? {
        get { (objc_getAssociatedObject(self, &appTooltipProviderKey) as? TooltipProviderBox)?.provider }
        set {
            let box = newValue.map(TooltipProviderBox.init)
            objc_setAssociatedObject(self, &appTooltipProviderKey, box,
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            toolTip = nil
        }
    }
}

/// Transparent anchor used behind a SwiftUI control. It never takes part in
/// hit testing, so clicks and drags still reach the control; `TooltipCenter`
/// finds it by walking the view frames.
private struct TooltipAnchor: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.appTooltipText = text
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.appTooltipText = text
    }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isOpaque: Bool { false }
        override func draw(_ dirtyRect: NSRect) {}
    }
}

extension View {
    /// Replacement for `.help` that waits a full second and works on plain
    /// labels as well as on controls. The native `.help` tooltip is not used,
    /// because AppKit's delay is shorter and is not configurable on current
    /// macOS versions.
    func appToolTip(_ text: String) -> some View {
        background(TooltipAnchor(text: text))
            .accessibilityHint(Text(text))
    }
}

/// One tooltip panel for the whole app. It follows the pointer after a
/// one-second hover and hides as soon as the pointer leaves the target or the
/// user clicks, scrolls or types.
final class TooltipCenter {
    static let shared = TooltipCenter()

    private var moveMonitor: Any?
    private var hideMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var timer: Timer?
    private weak var target: NSView?
    private var pendingText: String?
    private var screenPoint: NSPoint = .zero
    private var panel: TooltipPanel?

    private init() {}

    func start() {
        guard moveMonitor == nil else { return }
        moveMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] event in
            self?.mouseMoved(event)
            return event
        }
        hideMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                       .scrollWheel, .keyDown]
        ) { [weak self] event in
            self?.hide()
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.hide()
        }
        // Without this AppKit does not deliver mouse-moved events to the
        // monitor unless a tracking area happens to request them.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { notification in
            (notification.object as? NSWindow)?.acceptsMouseMovedEvents = true
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            for window in NSApp.windows {
                window.acceptsMouseMovedEvents = true
            }
        }
        for window in NSApp.windows {
            window.acceptsMouseMovedEvents = true
        }
    }

    private func mouseMoved(_ event: NSEvent) {
        guard NSApp.isActive, let window = event.window,
              window.isVisible, window.attachedSheet == nil,
              let content = window.contentView else {
            hide()
            return
        }
        let pointInContent = content.convert(event.locationInWindow, from: nil)
        guard let hit = findTarget(in: content, point: pointInContent) else {
            hide()
            return
        }
        if hit.view === target {
            // Keep the original hover start; moving inside the same control
            // must not restart the one-second countdown.
            return
        }
        hide()
        target = hit.view
        pendingText = hit.text
        screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self, let text = self.pendingText else { return }
            self.show(text: text, at: self.screenPoint)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func findTarget(in root: NSView, point: NSPoint) -> (view: NSView, text: String)? {
        var best: (view: NSView, text: String, area: CGFloat)?
        func visit(_ view: NSView, pointInView: NSPoint) {
            guard !view.isHidden, view.alphaValue > 0.01 else { return }
            if let text = view.appTooltipText, !text.isEmpty {
                let area = view.bounds.width * view.bounds.height
                if best == nil || area < best!.area {
                    best = (view, text, area)
                }
            }
            if let provider = view.appTooltipProvider,
               let text = provider(pointInView), !text.isEmpty {
                let area = view.bounds.width * view.bounds.height
                if best == nil || area < best!.area {
                    best = (view, text, area)
                }
            }
            for sub in view.subviews {
                let local = sub.convert(pointInView, from: view)
                if sub.bounds.contains(local) {
                    visit(sub, pointInView: local)
                }
            }
        }
        visit(root, pointInView: point)
        return best.map { ($0.view, $0.text) }
    }

    private func show(text: String, at point: NSPoint) {
        timer = nil
        if panel == nil { panel = TooltipPanel() }
        panel?.show(text: text, at: point)
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        pendingText = nil
        target = nil
        panel?.orderOut(nil)
    }
}

private final class TooltipPanel: NSPanel {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let container = NSView()
    private let padding: CGFloat = 8
    private let maxWidth: CGFloat = 380

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 30),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 6
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 12
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: padding - 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding + 2)
        ])
        contentView = container
    }

    func show(text: String, at point: NSPoint) {
        label.stringValue = text
        label.preferredMaxLayoutWidth = maxWidth - padding * 2
        let fitting = container.fittingSize
        let width = min(maxWidth, max(80, fitting.width))
        let height = max(20, fitting.height)
        setContentSize(NSSize(width: width, height: height))

        var origin = NSPoint(x: point.x + 12, y: point.y - 18)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - width - 4)
            if origin.y - height < screen.minY {
                origin.y = point.y + 22 + height
            }
        }
        setFrameTopLeftPoint(origin)
        orderFront(nil)
    }
}
