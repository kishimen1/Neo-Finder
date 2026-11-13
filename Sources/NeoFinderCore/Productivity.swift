import Foundation

/// Ranks a candidate against a typed query. Matching ignores case, width and diacritics,
/// so 「ｹｲﾘ」 finds 「経理」 only by its own characters but 「KEIRI」 finds 「keiri」.
public enum FuzzyMatcher {
    /// Returns nil when the candidate does not match. A larger value is a better match.
    /// Space-separated terms must all match; their scores are added.
    public static func score(_ candidate: String, query: String) -> Int? {
        let terms = query.split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init)
        if terms.isEmpty { return 0 }
        let text = Array(FileEntry.comparisonKey(candidate))
        var total = 0
        for term in terms {
            guard let value = scoreTerm(text, Array(FileEntry.comparisonKey(term))) else { return nil }
            total += value
        }
        return total
    }

    private static func isBoundary(_ text: [Character], _ index: Int) -> Bool {
        if index == 0 { return true }
        let previous = text[index - 1]
        return previous == "/" || previous == " " || previous == "_" || previous == "-" || previous == "."
    }

    private static func scoreTerm(_ text: [Character], _ term: [Character]) -> Int? {
        if term.isEmpty { return 0 }
        guard term.count <= text.count else { return nil }
        // A contiguous occurrence always beats a scattered one.
        var best: Int?
        if text.count >= term.count {
            for start in 0...(text.count - term.count) where text[start] == term[0] {
                var matches = true
                for offset in 1..<term.count where text[start + offset] != term[offset] {
                    matches = false
                    break
                }
                if matches {
                    let value = 1000 + (isBoundary(text, start) ? 400 : 0) - min(300, start * 4) - min(200, text.count - term.count)
                    if best == nil || value > best! { best = value }
                }
            }
        }
        if let best { return best }
        // Otherwise accept the characters in order, rewarding runs and word starts.
        var position = 0
        var value = 300
        var previousMatch = -2
        for character in term {
            var found: Int?
            while position < text.count {
                if text[position] == character { found = position; break }
                position += 1
            }
            guard let index = found else { return nil }
            if index == previousMatch + 1 { value += 40 }
            if isBoundary(text, index) { value += 60 }
            value -= min(20, index - previousMatch - 1)
            previousMatch = index
            position = index + 1
        }
        return max(1, value - min(100, text.count - term.count))
    }
}

/// A folder the user visited or used as a transfer destination.
public struct RecentLocation: Codable, Sendable, Equatable {
    public var path: String
    public var count: Int
    public var lastUsed: Date

    public init(path: String, count: Int = 1, lastUsed: Date = Date()) {
        self.path = path
        self.count = max(1, count)
        self.lastUsed = lastUsed
    }
}

public enum RecentLocations {
    public static let limit = 200

    /// Frequency weighted by recency: a folder used today outranks one used often last year.
    public static func frecency(_ item: RecentLocation, now: Date = Date()) -> Double {
        let age = now.timeIntervalSince(item.lastUsed)
        let day = 86_400.0
        let recency: Double = age < day ? 4 : age < 7 * day ? 2 : age < 30 * day ? 1 : 0.5
        return Double(min(item.count, 50)) * recency
    }

    public static func record(_ path: String, in list: inout [RecentLocation], weight: Int = 1, now: Date = Date()) {
        guard !path.isEmpty else { return }
        if let index = list.firstIndex(where: { $0.path == path }) {
            list[index].count += max(1, weight)
            list[index].lastUsed = now
        } else {
            list.append(RecentLocation(path: path, count: max(1, weight), lastUsed: now))
        }
        if list.count > limit {
            list.sort { frecency($0, now: now) > frecency($1, now: now) }
            list.removeLast(list.count - limit)
        }
    }
}

/// Paths that follow the calendar, such as 「~/経理/{年度}年度/{MM}月」.
/// A trailing +n / -n inside the braces shifts the date by that many months: {MM-1} is last month.
public enum PathTemplate {
    public static let variables = ["yyyy", "yy", "MM", "M", "dd", "d", "年度", "令和", "令和年度"]

    public static func containsVariable(_ template: String) -> Bool {
        tokens(in: template).contains { variables.contains($0.name) }
    }

    public static func expand(_ template: String, date: Date = Date(),
                              calendar: Calendar = Calendar(identifier: .gregorian),
                              fiscalStartMonth: Int = 4) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result.append(contentsOf: rest[rest.startIndex..<open])
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else {
                result.append(contentsOf: rest[open...])
                return result
            }
            let inner = String(rest[afterOpen..<close])
            let (name, shift) = split(inner)
            if let value = value(of: name, shift: shift, date: date, calendar: calendar, fiscalStartMonth: fiscalStartMonth) {
                result += value
            } else {
                result += "{" + inner + "}"
            }
            rest = rest[rest.index(after: close)...]
        }
        result.append(contentsOf: rest)
        return result
    }

    /// Proposes a template by replacing the parts of a path that equal today's year, fiscal year or month.
    /// Returns nil when the path has no such part.
    public static func suggest(for path: String, date: Date = Date(),
                               calendar: Calendar = Calendar(identifier: .gregorian),
                               fiscalStartMonth: Int = 4) -> String? {
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return nil }
        let fiscal = month >= fiscalStartMonth ? year : year - 1
        let padded = month < 10 ? "0\(month)" : "\(month)"
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let replaced = components.map { component -> String in
            var text = component
            text = text.replacingOccurrences(of: "令和\(fiscal - 2018)年度", with: "令和{令和年度}年度")
            text = text.replacingOccurrences(of: "\(fiscal)年度", with: "{年度}年度")
            text = text.replacingOccurrences(of: "\(year)年", with: "{yyyy}年")
            for separator in ["-", "_", "."] {
                text = text.replacingOccurrences(of: "\(year)\(separator)\(padded)", with: "{yyyy}\(separator){MM}")
            }
            text = text.replacingOccurrences(of: "\(year)\(padded)", with: "{yyyy}{MM}")
            if text.contains("\(padded)月") {
                text = text.replacingOccurrences(of: "\(padded)月", with: "{MM}月")
            } else if month < 10, let range = text.range(of: "\(month)月") {
                // 「1月」 inside 「11月」 is a different month.
                let precededByDigit = range.lowerBound > text.startIndex && text[text.index(before: range.lowerBound)].isNumber
                if !precededByDigit { text.replaceSubrange(range, with: "{M}月") }
            }
            if text == "\(year)" { text = "{yyyy}" }
            if text == padded { text = "{MM}" }
            return text
        }.joined(separator: "/")
        return replaced == path ? nil : replaced
    }

    private static func tokens(in template: String) -> [(name: String, shift: Int)] {
        var found: [(name: String, shift: Int)] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else { break }
            found.append(split(String(rest[afterOpen..<close])))
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    private static func split(_ inner: String) -> (name: String, shift: Int) {
        guard let signIndex = inner.lastIndex(where: { $0 == "+" || $0 == "-" }), signIndex != inner.startIndex,
              let amount = Int(inner[inner.index(after: signIndex)...]) else { return (inner, 0) }
        return (String(inner[..<signIndex]), inner[signIndex] == "-" ? -amount : amount)
    }

    private static func value(of name: String, shift: Int, date: Date, calendar: Calendar, fiscalStartMonth: Int) -> String? {
        guard variables.contains(name),
              let shifted = calendar.date(byAdding: .month, value: shift, to: date) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: shifted)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        let fiscal = month >= fiscalStartMonth ? year : year - 1
        switch name {
        case "yyyy": return "\(year)"
        case "yy": return twoDigits(year % 100)
        case "MM": return twoDigits(month)
        case "M": return "\(month)"
        case "dd": return twoDigits(day)
        case "d": return "\(day)"
        case "年度": return "\(fiscal)"
        case "令和": return "\(year - 2018)"
        case "令和年度": return "\(fiscal - 2018)"
        default: return nil
        }
    }

    private static func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
}

public enum CompareStatus: String, Sendable {
    /// Present only on this side.
    case onlyHere
    /// Both sides have it; this side was modified later.
    case newer
    /// Both sides have it; this side was modified earlier.
    case older
    /// Same modification time but a different size or kind.
    case different
    case same
}

public enum FolderComparison {
    /// Compares by displayed name, size and modification date. File contents are not read and
    /// folders are matched by name only. Returned keys are `FileEntry.name`.
    public static func statuses(for entries: [FileEntry], against other: [FileEntry]) -> [String: CompareStatus] {
        var lookup: [String: FileEntry] = [:]
        for entry in other { lookup[entry.name.precomposedStringWithCanonicalMapping] = entry }
        var result: [String: CompareStatus] = [:]
        for entry in entries {
            guard let match = lookup[entry.name.precomposedStringWithCanonicalMapping] else {
                result[entry.name] = .onlyHere
                continue
            }
            let folder = entry.isDirectory && !entry.isPackage
            let matchFolder = match.isDirectory && !match.isPackage
            if folder != matchFolder { result[entry.name] = .different; continue }
            if folder { result[entry.name] = .same; continue }
            // File systems round timestamps differently; two seconds covers FAT-family volumes.
            let gap = (entry.modifiedAt ?? .distantPast).timeIntervalSince(match.modifiedAt ?? .distantPast)
            if gap >= 2 { result[entry.name] = .newer }
            else if gap <= -2 { result[entry.name] = .older }
            else { result[entry.name] = entry.size == match.size ? .same : .different }
        }
        return result
    }
}
