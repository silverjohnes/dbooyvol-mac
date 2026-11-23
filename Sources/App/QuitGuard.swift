import AppKit

/// Stops a single Cmd+Q from quitting. The app exits on a second press within
/// a short interval, or while the shortcut is held (key repeat).
final class QuitGuard {
    static let shared = QuitGuard()

    /// Interval in which a second Cmd+Q counts as a deliberate double press.
    private let doublePressInterval: TimeInterval = 1.5
    private var lastPress: TimeInterval = -.infinity
    private var monitor: Any?
    private var notification: NSWindow?
    private var hideWork: DispatchWorkItem?
    private var holdWork: DispatchWorkItem?
    private var isQDown = false
    /// How long Cmd+Q must be held before the app quits.
    private let holdDelay: TimeInterval = 0.8

    /// Replaced in tests; production quits the app.
    var quitAction: () -> Void = { NSApp.terminate(nil) }

    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event: event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        holdWork?.cancel()
        holdWork = nil
        isQDown = false
        hideWork?.cancel()
        hideWork = nil
        notification?.orderOut(nil)
        notification = nil
    }

    /// Consumes Cmd+Q and either quits or shows the hint.
    private func handle(event: NSEvent) -> NSEvent? {
        if event.type == .keyUp {
            if event.keyCode == 12 { // Q released before the hold delay
                isQDown = false
                holdWork?.cancel()
                holdWork = nil
            }
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let extra = flags.subtracting([.command, .capsLock])
        guard event.keyCode == 12, // Q
              flags.contains(.command),
              extra.isEmpty else { return event }

        isQDown = true
        if handlePress(isRepeat: event.isARepeat) {
            isQDown = false
            holdWork?.cancel()
            holdWork = nil
        } else {
            scheduleHoldCheck()
        }
        return nil
    }

    /// Quits if the combination is still held after a short delay, even when
    /// the system does not send key-repeat events for Command shortcuts.
    private func scheduleHoldCheck() {
        holdWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isQDown else { return }
            guard NSEvent.modifierFlags.contains(.command) else {
                self.isQDown = false
                return
            }
            self.isQDown = false
            self.hideNotification(immediately: true)
            self.quitAction()
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
    }

    /// Returns true when the app should terminate.
    @discardableResult
    func handlePress(isRepeat: Bool,
                     now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if isRepeat || now - lastPress <= doublePressInterval {
            lastPress = -.infinity
            hideNotification(immediately: true)
            quitAction()
            return true
        }
        lastPress = now
        showNotification()
        return false
    }

    // MARK: - transparent system-style notification

    private func showNotification() {
        let panel = notificationWindow()
        hideWork?.cancel()

        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                         y: frame.midY - size.height / 2))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            self?.hideNotification()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    private func hideNotification(immediately: Bool = false) {
        hideWork?.cancel()
        hideWork = nil
        guard let panel = notification else { return }
        if immediately {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    private func notificationWindow() -> NSWindow {
        if let notification { return notification }

        let size = NSSize(width: 330, height: 56)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: L10n.tr("Для выхода зажмите CMD+Q"))
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor)
        ])

        panel.contentView = effect
        notification = panel
        return panel
    }
}
