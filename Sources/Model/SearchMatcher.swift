import Foundation

/// Layout-independent search: "ghbkf" finds "Прила" and vice versa.
/// Script of a piece of text, used to prefer results written in the same
/// language as the search string.
enum TextLanguage {
    case cyrillic
    case latin
    case none

    static func of(_ text: String) -> TextLanguage {
        var cyrillic = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0400...0x04FF:
                cyrillic += 1
            case 0x41...0x5A, 0x61...0x7A:
                latin += 1
            default:
                break
            }
        }
        if cyrillic == 0 && latin == 0 { return .none }
        if cyrillic == latin { return .none }
        return cyrillic > latin ? .cyrillic : .latin
    }
}

enum SearchMatcher {
    private static let enToRu: [Character: Character] = [
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н", "u": "г",
        "i": "ш", "o": "щ", "p": "з", "[": "х", "]": "ъ",
        "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р", "j": "о",
        "k": "л", "l": "д", ";": "ж", "'": "э",
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т", "m": "ь",
        ",": "б", ".": "ю", "`": "ё"
    ]

    private static let ruToEn: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (en, ru) in enToRu { map[ru] = en }
        return map
    }()

    /// A prepared query: the layout variants are computed once, so scanning
    /// hundreds of thousands of cells does not rebuild them for every cell.
    struct Query {
        let raw: String
        let variants: [String]

        /// Cheap case-insensitive test used while scanning a whole result.
        /// Searching the NSString directly is about twice as fast as lowercasing
        /// every cell first, and allocates nothing per cell.
        func matches(_ text: String) -> Bool {
            guard !text.isEmpty else { return false }
            let ns = text as NSString
            for variant in variants
            where ns.range(of: variant, options: [.caseInsensitive]).location != NSNotFound {
                return true
            }
            return false
        }

        /// First match and the layout variant that produced it, so a caller can
        /// tell whether the hit was in the searched script or its twin.
        func firstMatch(in text: String) -> (range: NSRange, variant: String)? {
            guard !text.isEmpty else { return nil }
            let ns = text as NSString
            var best: (NSRange, String)?
            for variant in variants {
                let r = ns.range(of: variant, options: [.caseInsensitive])
                guard r.location != NSNotFound else { continue }
                if best == nil || r.location < best!.0.location {
                    best = (r, variant)
                }
            }
            return best.map { (range: $0.0, variant: $0.1) }
        }

        /// All matches with their exact ranges, for drawing a cell.
        func ranges(in text: String) -> [NSRange] {
            guard !text.isEmpty else { return [] }
            let ns = text as NSString
            var found: [NSRange] = []
            for variant in variants {
                var location = 0
                while location < ns.length {
                    let searchRange = NSRange(location: location, length: ns.length - location)
                    let r = ns.range(of: variant, options: [.caseInsensitive], range: searchRange)
                    if r.location == NSNotFound { break }
                    found.append(r)
                    location = r.location + max(r.length, 1)
                }
            }
            found.sort { $0.location < $1.location }
            var merged: [NSRange] = []
            for r in found {
                if let last = merged.last, r.location <= last.location + last.length {
                    let end = max(last.location + last.length, r.location + r.length)
                    merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
                } else {
                    merged.append(r)
                }
            }
            return merged
        }
    }

    /// Prepares a query; returns nil for an empty search string.
    static func query(_ input: String) -> Query? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // The layout twins are often identical to the original ("abc"), so keep
        // each variant once: every extra copy doubles the scan.
        var seen = Set<String>()
        let unique = variants(trimmed).filter { !$0.isEmpty && seen.insert($0).inserted }
        return Query(raw: trimmed, variants: unique)
    }

    private static func variants(_ input: String) -> [String] {
        let lower = input.lowercased()
        var toRu = ""
        var toEn = ""
        toRu.reserveCapacity(lower.count)
        toEn.reserveCapacity(lower.count)
        for ch in lower {
            toRu.append(enToRu[ch] ?? ch)
            toEn.append(ruToEn[ch] ?? ch)
        }
        return [lower, toRu, toEn]
    }

    static func matches(_ haystack: String, _ needle: String) -> Bool {
        let query = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return true }
        let haystackVariants = variants(haystack)
        for variant in variants(query) where !variant.isEmpty {
            for hay in haystackVariants where hay.contains(variant) {
                return true
            }
        }
        return false
    }

    /// Highlights the first match of the query (or its layout twin) inside the text.
    static func firstMatchRange(in text: String, query: String) -> NSRange? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let ns = text as NSString
        for variant in variants(q) where !variant.isEmpty {
            let r = ns.range(of: variant, options: [.caseInsensitive])
            if r.location != NSNotFound { return r }
        }
        return nil
    }

    /// All matches of the query and its layout twins, merged and sorted.
    static func allRanges(in text: String, query: String) -> [NSRange] {
        SearchMatcher.query(query)?.ranges(in: text) ?? []
    }
}
