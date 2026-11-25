import Foundation

/// Time zones available for displaying timestamp values, and their short
/// labels for the status bar. An empty identifier means the system zone.
enum TimeZones {
    struct Option: Identifiable, Hashable {
        let id: String
        let name: String
        let short: String
    }

    static var selectedIdentifier: String {
        AppSettings.timeZoneIdentifier
    }

    /// The zone timestamps are converted to.
    static var selected: TimeZone {
        zone(for: selectedIdentifier)
    }

    static func zone(for identifier: String) -> TimeZone {
        guard !identifier.isEmpty, let zone = TimeZone(identifier: identifier) else {
            return .current
        }
        return zone
    }

    /// All zones, sorted by their localized name. Built once: the list has
    /// several hundred entries and the settings window must not rebuild it on
    /// every keystroke elsewhere in the app.
    static let options: [Option] = {
        let list = TimeZone.knownTimeZoneIdentifiers.compactMap { id -> Option? in
            guard let zone = TimeZone(identifier: id) else { return nil }
            return Option(id: id, name: displayName(for: zone), short: shortLabel(for: zone))
        }
        return list.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }()

    static func displayName(for zone: TimeZone) -> String {
        let city = cityName(for: zone)
        return "\(city) · \(shortLabel(for: zone))"
    }

    /// `Europe/Moscow` → «Москва», using the system localization of the zone.
    /// The generic name often carries a suffix such as «, стандартное время»;
    /// only the place name is useful in a picker.
    private static func cityName(for zone: TimeZone) -> String {
        if let localized = zone.localizedName(for: .generic, locale: .current) {
            let city = localized.components(separatedBy: ", ").first ?? localized
            if !city.isEmpty { return city }
        }
        // Fallback: the last identifier component, with underscores removed.
        let tail = zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier
        return tail.replacingOccurrences(of: "_", with: " ")
    }

    /// Short label for the status bar: «МСК» for Moscow, «ЕКБ» for Yekaterinburg,
    /// and a `UTC+3` style label for every other zone.
    static func shortLabel(for zone: TimeZone) -> String {
        if let known = russianLabels[zone.identifier] { return known }
        if ["UTC", "Etc/UTC", "GMT", "Etc/GMT"].contains(zone.identifier) { return "UTC" }
        let seconds = zone.secondsFromGMT(for: Date())
        let sign = seconds < 0 ? "−" : "+"
        let totalMinutes = abs(seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if minutes == 0 {
            return "UTC\(sign)\(hours)"
        }
        return String(format: "UTC%@%d:%02d", sign, hours, minutes)
    }

    /// Common Russian abbreviations. Zones that share an offset but have their
    /// own name (Krasnoyarsk and Novosibirsk, for example) keep separate labels.
    private static let russianLabels: [String: String] = [
        "Europe/Kaliningrad": "КЛГ",
        "Europe/Moscow": "МСК",
        "Europe/Kirov": "МСК",
        "Europe/Volgograd": "МСК",
        "Europe/Minsk": "МСК",
        "Europe/Samara": "САМ",
        "Europe/Saratov": "САМ",
        "Europe/Ulyanovsk": "САМ",
        "Europe/Astrakhan": "САМ",
        "Asia/Yekaterinburg": "ЕКБ",
        "Asia/Tyumen": "ЕКБ",
        "Asia/Omsk": "ОМСК",
        "Asia/Novosibirsk": "НСК",
        "Asia/Barnaul": "НСК",
        "Asia/Tomsk": "НСК",
        "Asia/Novokuznetsk": "НСК",
        "Asia/Krasnoyarsk": "КРСК",
        "Asia/Irkutsk": "ИРК",
        "Asia/Chita": "ЯКТ",
        "Asia/Yakutsk": "ЯКТ",
        "Asia/Vladivostok": "ВЛД",
        "Asia/Ust-Nera": "ВЛД",
        "Asia/Magadan": "МАГ",
        "Asia/Sakhalin": "СХЛ",
        "Asia/Kamchatka": "КАМ",
        "Asia/Anadyr": "КАМ"
    ]
}
