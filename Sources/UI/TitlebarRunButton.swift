import SwiftUI
import AppKit

/// Puts the run/stop button into the window title bar, aligned over the first
/// query tab. A toolbar item cannot be positioned freely — the system centers
/// it in the title pill — so this uses a left title bar accessory that grows up
/// to the sidebar edge and pins the button just past it.
struct TitlebarRunButton: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
        context.coordinator.update(isRunning: model.isRunning,
                                   enabled: model.activeScriptProfile != nil)
    }

    final class Coordinator {
        private let model: AppModel
        private var controller: RunAccessoryController?
        private weak var hostWindow: NSWindow?

        init(model: AppModel) { self.model = model }

        func attach(to view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let window = view?.window else { return }
                if self.controller == nil || self.hostWindow !== window {
                    let controller = RunAccessoryController(model: self.model)
                    window.addTitlebarAccessoryViewController(controller)
                    self.controller = controller
                    self.hostWindow = window
                }
            }
        }

        func update(isRunning: Bool, enabled: Bool) {
            controller?.update(isRunning: isRunning, enabled: enabled)
        }
    }
}

private final class RunAccessoryController: NSTitlebarAccessoryViewController {
    private let model: AppModel
    private let button = RunCircleButton()
    private var isRunning = false
    private var isEnabled = true
    private var observers: [NSObjectProtocol] = []

    /// Distance from the sidebar edge to the button's leading edge; matches the
    /// tab strip's own left padding so the glyph starts over the first tab.
    private let leadingGap: CGFloat = 8

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .left
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 272, height: 28))
        container.autoresizingMask = [.height]
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        button.target = self
        button.action = #selector(toggle)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .labelColor
        button.setButtonType(.momentaryChange)
        button.wantsLayer = true
        view.addSubview(button)
        update(isRunning: false, enabled: true)
    }


    override func viewDidAppear() {
        super.viewDidAppear()
        observeWindow()
        positionButton()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        positionButton()
    }

    private func observeWindow() {
        guard observers.isEmpty, let window = view.window else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification,
                                            object: window, queue: .main) { [weak self] _ in
            self?.positionButton()
        })
        observers.append(center.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.positionButton()
        })
    }

    func update(isRunning: Bool, enabled: Bool) {
        self.isRunning = isRunning
        self.isEnabled = enabled
        let symbol = isRunning ? "stop.fill" : "play.fill"
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        button.appTooltipText = isRunning
            ? L10n.tr("Отменить запрос (⌘R)")
            : L10n.tr("Выполнить выделение или весь скрипт (⌘R, ⌘↩)")
        button.isEnabled = enabled || isRunning
        positionButton()
    }

    /// Grows the accessory up to the first tab and pins the button to its right
    /// edge, so the glyph lands over the first tab regardless of the sidebar
    /// width or window size.
    private func positionButton() {
        guard let window = view.window else { return }
        let originX = view.convert(view.bounds, to: nil).minX
        let sidebarEdge = currentSidebarEdge() ?? 0
        let targetX = sidebarEdge + leadingGap
        let side: CGFloat = 26
        let margin: CGFloat = 2
        let width = max(side + margin * 2, targetX - originX + side + margin)
        if abs(view.frame.width - width) > 0.5 {
            view.frame.size.width = width
        }
        let height = view.bounds.height
        button.frame = NSRect(x: width - side - margin,
                              y: (height - side) / 2,
                              width: side,
                              height: side)
        button.applyCircleStyle()
        _ = window
    }

    /// Leading edge of the content pane (right side of the connection tree) in
    /// window coordinates. The SwiftUI preference can lag behind the split view
    /// restoring its saved width, so this reads the live split geometry.
    private func currentSidebarEdge() -> CGFloat? {
        guard let content = view.window?.contentView else { return nil }
        for split in Self.verticalSplitViews(in: content) {
            guard let first = split.arrangedSubviews.first else { continue }
            return first.convert(first.bounds, to: nil).maxX
        }
        return nil
    }

    private static func verticalSplitViews(in view: NSView) -> [NSSplitView] {
        var result: [NSSplitView] = []
        if let split = view as? NSSplitView, split.isVertical { result.append(split) }
        for sub in view.subviews {
            result.append(contentsOf: verticalSplitViews(in: sub))
        }
        return result
    }

    @objc private func toggle() {
        model.runOrStop()
    }
}


/// Run/stop control drawn inside its own light circle, like the original
/// button that lived in the tab strip.
private final class RunCircleButton: NSButton {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCircleStyle()
    }

    func applyCircleStyle() {
        guard let layer else { return }
        layer.cornerRadius = bounds.height / 2
        layer.masksToBounds = true
        layer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        layer.borderWidth = 1
        layer.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    }
}
