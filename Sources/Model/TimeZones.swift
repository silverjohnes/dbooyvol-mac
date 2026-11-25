import Foundation

/// Time zones available for displaying timestamp values, and their short
/// labels for the status bar. An empty identifier means the system zone.
///
/// The picker is deliberately curated instead of listing every identifier the
/// system knows: that list has hundreds of aliases and repeats the same city
/// under several names. One recognizable city per main offset is enough, plus
/// the Russian zones this app is normally used from.
enum TimeZones {
    struct Option: Identifiable, Hashable {
        let id: String
        let city: String
        /// Russian code; it is a localization key, so every language shows the
        /// abbreviation of the city name in that language.
        let short: String

        var name: String { "\(L10n.tr(city)) · \(L10n.tr(short))" }
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

    /// Ordered west to east. Short labels are the three-letter city codes
    /// shown in the bottom bar.
    static let options: [Option] = [
        Option(id: "Pacific/Honolulu", city: "Гонолулу", short: "ГОН"),
        Option(id: "America/Anchorage", city: "Анкоридж", short: "АНК"),
        Option(id: "America/Los_Angeles", city: "Лос-Анджелес", short: "ЛОС"),
        Option(id: "America/Denver", city: "Денвер", short: "ДЕН"),
        Option(id: "America/Chicago", city: "Чикаго", short: "ЧИК"),
        Option(id: "America/New_York", city: "Нью-Йорк", short: "НЬЮ"),
        Option(id: "America/Caracas", city: "Каракас", short: "КАР"),
        Option(id: "America/Argentina/Buenos_Aires", city: "Буэнос-Айрес", short: "БУЭ"),
        Option(id: "UTC", city: "UTC", short: "UTC"),
        Option(id: "Europe/London", city: "Лондон", short: "ЛОН"),
        Option(id: "Europe/Berlin", city: "Берлин", short: "БЕР"),
        Option(id: "Africa/Cairo", city: "Каир", short: "КАИ"),
        Option(id: "Europe/Kaliningrad", city: "Калининград", short: "КЛГ"),
        Option(id: "Europe/Moscow", city: "Москва", short: "МСК"),
        Option(id: "Europe/Istanbul", city: "Стамбул", short: "СТА"),
        Option(id: "Asia/Dubai", city: "Дубай", short: "ДУБ"),
        Option(id: "Europe/Samara", city: "Самара", short: "САМ"),
        Option(id: "Asia/Yekaterinburg", city: "Екатеринбург", short: "ЕКБ"),
        Option(id: "Asia/Kolkata", city: "Дели", short: "ДЕЛ"),
        Option(id: "Asia/Omsk", city: "Омск", short: "ОМС"),
        Option(id: "Asia/Novosibirsk", city: "Новосибирск", short: "НСК"),
        Option(id: "Asia/Bangkok", city: "Бангкок", short: "БАН"),
        Option(id: "Asia/Krasnoyarsk", city: "Красноярск", short: "КРС"),
        Option(id: "Asia/Irkutsk", city: "Иркутск", short: "ИРК"),
        Option(id: "Asia/Shanghai", city: "Пекин", short: "ПЕК"),
        Option(id: "Asia/Yakutsk", city: "Якутск", short: "ЯКТ"),
        Option(id: "Asia/Tokyo", city: "Токио", short: "ТОК"),
        Option(id: "Asia/Vladivostok", city: "Владивосток", short: "ВЛД"),
        Option(id: "Asia/Magadan", city: "Магадан", short: "МАГ"),
        Option(id: "Asia/Kamchatka", city: "Камчатка", short: "КАМ"),
        Option(id: "Pacific/Apia", city: "Апиа", short: "АПИ"),
        Option(id: "Pacific/Kiritimati", city: "Киритимати", short: "КИР")
    ]

    private static let optionById: [String: Option] = Dictionary(
        uniqueKeysWithValues: options.map { ($0.id, $0) }
    )

    /// The curated list, plus the currently stored zone when it is not part of
    /// it (an older version could have saved any system identifier).
    static func pickerOptions(for selected: String) -> [Option] {
        guard !selected.isEmpty, optionById[selected] == nil else { return options }
        let zone = zone(for: selected)
        let legacy = Option(id: selected, city: cityName(for: zone), short: shortLabel(for: zone))
        return [legacy] + options
    }

    static func displayName(for zone: TimeZone) -> String {
        if let option = optionById[zone.identifier] { return option.name }
        return "\(cityName(for: zone)) · \(shortLabel(for: zone))"
    }

    /// `Europe/Moscow` → «Москва», using the system localization of the zone.
    /// The generic name often carries a suffix such as «, стандартное время»;
    /// only the place name is useful in a picker.
    private static func cityName(for zone: TimeZone) -> String {
        if let localized = zone.localizedName(for: .generic, locale: .current) {
            let city = localized.components(separatedBy: ", ").first ?? localized
            if !city.isEmpty { return city }
        }
        let tail = zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier
        return tail.replacingOccurrences(of: "_", with: " ")
    }

    /// Short label for the status bar: the curated three-letter code for known
    /// cities, the abbreviation of the mapped city for the other Russian zones,
    /// and a `UTC+3` style label for everything else.
    static func shortLabel(for zone: TimeZone) -> String {
        if let option = optionById[zone.identifier] { return L10n.tr(option.short) }
        if let known = fallbackLabels[zone.identifier] { return L10n.tr(known) }
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

    /// Zones that are not in the curated picker but can still be the system
    /// zone. Each one borrows the code of the curated city in the same offset,
    /// so the bottom bar shows a localized abbreviation instead of Russian.
    private static let fallbackLabels: [String: String] = [
        "Europe/Kirov": "МСК",
        "Europe/Volgograd": "МСК",
        "Europe/Minsk": "МСК",
        "Europe/Saratov": "САМ",
        "Europe/Ulyanovsk": "САМ",
        "Europe/Astrakhan": "САМ",
        "Asia/Tyumen": "ЕКБ",
        "Asia/Barnaul": "НСК",
        "Asia/Tomsk": "НСК",
        "Asia/Novokuznetsk": "НСК",
        "Asia/Chita": "ЯКТ",
        "Asia/Ust-Nera": "ВЛД",
        "Asia/Sakhalin": "МАГ",
        "Asia/Anadyr": "КАМ"
    ]
}
