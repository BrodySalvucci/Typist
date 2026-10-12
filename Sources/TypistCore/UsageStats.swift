import Foundation

/// Per-day counters, shown in the Statistics pane.
public struct UsageStats: Codable, Equatable {
    public struct Day: Codable, Equatable {
        public var shown = 0
        public var accepted = 0
        public var wordsCompleted = 0
        public var charactersSaved = 0

        public init() {}
    }

    /// Keyed by ISO day ("2026-10-11").
    public var days: [String: Day] = [:]

    public init() {}

    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public func day(_ date: Date = Date()) -> Day {
        days[Self.key(for: date)] ?? Day()
    }

    public mutating func recordShown(on date: Date = Date()) {
        days[Self.key(for: date), default: Day()].shown += 1
    }

    /// - Parameter firstOfSuggestion: `false` for the 2nd, 3rd… word accepted from the same suggestion.
    public mutating func recordAccepted(_ text: String, firstOfSuggestion: Bool, on date: Date = Date()) {
        var day = days[Self.key(for: date), default: Day()]
        if firstOfSuggestion { day.accepted += 1 }
        day.wordsCompleted += text.wordCount
        day.charactersSaved += text.count
        days[Self.key(for: date)] = day
    }

    public var totalWords: Int { days.values.reduce(0) { $0 + $1.wordsCompleted } }
    public var totalShown: Int { days.values.reduce(0) { $0 + $1.shown } }
    public var totalAccepted: Int { days.values.reduce(0) { $0 + $1.accepted } }

    /// The most recent `count` days, oldest first, including days without activity.
    public func recent(_ count: Int, endingAt end: Date = Date(), calendar: Calendar = .current) -> [(date: Date, day: Day)] {
        (0..<count).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: end).map { ($0, day($0)) }
        }
    }
}
