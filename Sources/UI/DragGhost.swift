import AppKit

/// Semi-transparent snapshot that follows the pointer while a tab or a block
/// of result columns is dragged. Both places use manual mouse tracking rather
/// than NSDraggingSession, so the ghost is a borderless, click-through window.
final class DragGhost {
    private let window: NSWindow
    /// Distance from the image's bottom-left corner to the grab point.
    private let grab: NSPoint

    init?(image: NSImage?, grab: NSPoint) {
        guard let image, image.size.width > 1, image.size.height > 1 else { return nil }
        self.grab = grab
        window = NSWindow(contentRect: NSRect(origin: .zero, size: image.size),
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        window.isReleasedWhenClosed = false

        let view = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        view.image = image
        view.imageScaling = .scaleNone
        view.alphaValue = 0.72
        window.contentView = view
    }

    /// Places the image so the point that was grabbed stays under the pointer.
    func move(toScreen point: NSPoint) {
        window.setFrameOrigin(NSPoint(x: point.x - grab.x, y: point.y - grab.y))
    }

    /// Shows the ghost without the initial flash at the window origin.
    func show(at point: NSPoint) {
        move(toScreen: point)
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
    }

    // MARK: - snapshots

    /// Renders one region of a view into an image, preserving Retina scale.
    static func snapshot(of view: NSView, rect: NSRect) -> NSImage? {
        guard rect.width > 1, rect.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    /// Renders several (possibly non-contiguous) regions into one image,
    /// keeping their relative positions and leaving the gaps transparent.
    static func snapshot(of view: NSView, rects: [NSRect]) -> NSImage? {
        let valid = rects.filter { $0.width > 1 && $0.height > 1 }
        guard !valid.isEmpty else { return nil }
        if valid.count == 1 { return snapshot(of: view, rect: valid[0]) }
        let union = valid.dropFirst().reduce(valid[0]) { $0.union($1) }
        let image = NSImage(size: union.size)
        image.lockFocus()
        for rect in valid {
            snapshot(of: view, rect: rect)?.draw(in: NSRect(
                x: rect.minX - union.minX,
                y: rect.minY - union.minY,
                width: rect.width,
                height: rect.height
            ))
        }
        image.unlockFocus()
        return image
    }

    /// Screen-space rectangle of `rect` (given in `view` coordinates).
    static func screenRect(_ rect: NSRect, in view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    /// Screen-space point of `point` (given in `view` coordinates).
    static func screenPoint(_ point: NSPoint, in view: NSView) -> NSPoint? {
        guard let window = view.window else { return nil }
        return window.convertPoint(toScreen: view.convert(point, to: nil))
    }

    /// Offset from the image's bottom-left corner to the grab point, so the
    /// ghost keeps the same part of the content under the cursor.
    static func grabOffset(imageRect: NSRect, grabPoint: NSPoint,
                           in view: NSView) -> NSPoint {
        guard let screen = screenRect(imageRect, in: view),
              let point = screenPoint(grabPoint, in: view) else { return .zero }
        return NSPoint(x: point.x - screen.minX, y: point.y - screen.minY)
    }
}
