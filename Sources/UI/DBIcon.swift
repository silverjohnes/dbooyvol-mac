import AppKit

/// Small rounded badges that tell database types apart in the tree, pickers and tab bar.
enum DBIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for kind: DBKind, size: CGFloat = 14) -> NSImage {
        let key = "\(kind.rawValue)-\(size)"
        if let cached = cache[key] { return cached }

        let color: NSColor
        let letters: String
        switch kind {
        case .postgres:
            color = NSColor(srgbRed: 0.20, green: 0.40, blue: 0.57, alpha: 1) // #336791
            letters = "PG"
        case .oracle:
            color = NSColor(srgbRed: 0.78, green: 0.27, blue: 0.20, alpha: 1) // #C74634
            letters = "O"
        case .clickhouse:
            color = NSColor(srgbRed: 0.97, green: 0.80, blue: 0.04, alpha: 1) // #FFCC01
            letters = "CH"
        case .sqlite:
            color = NSColor(srgbRed: 0.02, green: 0.27, blue: 0.40, alpha: 1) // #0F4C75
            letters = "SQ"
        }

        let textColor: NSColor = kind == .clickhouse ? .black : .white

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let badge = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: size * 0.26,
                yRadius: size * 0.26
            )
            color.setFill()
            badge.fill()

            let font = NSFont.systemFont(ofSize: size * (letters.count > 1 ? 0.50 : 0.62), weight: .bold)
            let text = letters as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }
}
