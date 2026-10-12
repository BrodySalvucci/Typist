import Foundation

/// The user's own recorded writing, used to make suggestions sound like them.
/// Lives only on this Mac.
public struct WritingSamples: Codable, Equatable {
    public struct Sample: Codable, Equatable {
        public var app: String
        public var text: String
        public var date: Date
    }

    public private(set) var samples: [Sample] = []
    public var capacity = 400
    public var maxSampleLength = 2000
    public var minSampleLength = 40

    public init() {}

    /// Adds a sample. Text that merely extends the previous sample from the
    /// same app (the user kept typing in the same field) replaces it.
    public mutating func add(_ text: String, app: String, date: Date = Date()) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(maxSampleLength))
        guard trimmed.count >= minSampleLength else { return }
        if let index = samples.lastIndex(where: { $0.app == app }),
           trimmed.hasPrefix(samples[index].text) || samples[index].text.hasPrefix(trimmed) {
            if trimmed.count >= samples[index].text.count {
                samples[index] = Sample(app: app, text: trimmed, date: date)
            }
            return
        }
        samples.append(Sample(app: app, text: trimmed, date: date))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    public mutating func removeAll() {
        samples.removeAll()
    }

    /// Most recent samples, preferring ones written in `app`.
    public func relevant(for app: String, limit: Int = 3) -> [String] {
        let sameApp = samples.reversed().filter { $0.app == app }
        let others = samples.reversed().filter { $0.app != app }
        return (sameApp + others).prefix(limit).map(\.text)
    }

    /// Words the user writes often, weighted 0...1. Very common short words
    /// are left out: the model already knows them.
    public func vocabulary(limit: Int = 400) -> [String: Double] {
        var counts: [String: Int] = [:]
        for sample in samples {
            for word in sample.text.split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "’") }) where word.count >= 4 {
                counts[String(word), default: 0] += 1
            }
        }
        let frequent = counts.filter { $0.value >= 2 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit)
        guard let top = frequent.first?.value else { return [:] }
        let scale = log(Double(top) + 1)
        return Dictionary(uniqueKeysWithValues: frequent.map { ($0.key, log(Double($0.value) + 1) / scale) })
    }
}
