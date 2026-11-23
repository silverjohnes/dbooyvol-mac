import AppKit

enum AboutPanel {
    static let repositoryURL = URL(string: "https://github.com/silverjohnes/dbooyvol-mac")!

    static func show() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"

        let credits = NSMutableAttributedString(
            string: L10n.tr("Простой клиент для баз данных") + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
        credits.append(NSAttributedString(
            string: repositoryURL.absoluteString,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: repositoryURL
            ]
        ))

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "DBooyvol",
            .applicationVersion: version,
            .version: build,
            .credits: credits
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
