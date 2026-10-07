import Foundation

struct MoneyRateResult {
    let rates: [MoneyRate]
    let missingCurrencies: [String]
}
enum ExchangeRates {
    static func dayString(_ date: Date, timeZone: TimeZone = .current) -> String {
        let zone = timeZone, storage = Thread.current.threadDictionary
        let key = "Tally.exchangeRateDayFormatter"
        let f: DateFormatter
        if let cached = storage[key] as? DateFormatter, cached.timeZone == zone { f = cached }
        else {
            f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"
            storage[key] = f
        }
        return f.string(from: date)
    }
    static func fetch(base: String, quotes: [String], date: Date? = nil) async throws -> [MoneyRate] {
        let result = try await fetchAvailable(base: base, quotes: quotes, date: date)
        guard result.missingCurrencies.isEmpty else { throw URLError(.cannotParseResponse) }
        return result.rates
    }
    static func fetchAvailable(base: String, quotes: [String], date: Date? = nil) async throws -> MoneyRateResult {
        let targets = Set(quotes).filter { $0 != base }.sorted()
        guard Money.currencies.contains(base), targets.allSatisfy(Money.currencies.contains) else { throw URLError(.badURL) }
        if targets.isEmpty { return MoneyRateResult(rates: [], missingCurrencies: []) }
        let selected = min(date ?? Date(), Date())
        let archive = selected < Date().addingTimeInterval(-80 * 86400) ? "eurofxref-hist.xml" : "eurofxref-hist-90d.xml"
        var request = URLRequest(url: URL(string: "https://www.ecb.europa.eu/stats/eurofxref/" + archive)!); request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 20_000_000 else { throw URLError(.badServerResponse) }
        return try parseAvailable(data, base: base, quotes: targets, onOrBefore: dayString(selected))
    }
    static func parse(_ data: Data, base: String, quotes: [String], onOrBefore date: String) throws -> [MoneyRate] {
        let result = try parseAvailable(data, base: base, quotes: quotes, onOrBefore: date)
        guard result.missingCurrencies.isEmpty else { throw URLError(.cannotParseResponse) }
        return result.rates
    }
    static func parseAvailable(_ data: Data, base: String, quotes: [String], onOrBefore date: String) throws -> MoneyRateResult {
        let delegate = ECBRatesParser(limit: date), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), let day = delegate.days.keys.max(), let values = delegate.days[day] else { throw URLError(.cannotParseResponse) }
        var rates: [MoneyRate] = [], missing: [String] = []
        for quote in Set(quotes).filter({ $0 != base }).sorted() {
            guard let source = values[base], source > 0, let value = values[quote], value > 0,
                  MoneyRate.valid(value / source) else { missing.append(quote); continue }
            rates.append(MoneyRate(base: base, quote: quote, rate: value / source, date: day, source: "ECB"))
        }
        return MoneyRateResult(rates: rates, missingCurrencies: missing)
    }
}
/// Daily ECB reference rates (per euro), so reports can convert each entry at the rate of its own day.
struct RateHistory: Codable, Equatable, Sendable {
    var days: [String: [String: Decimal]] = [:] // "yyyy-MM-dd" → currency → units per euro
    var fetchedAt = Date.distantPast
    var sortedDays: [String] { days.keys.sorted() }
    /// Crossing a local calendar day must refresh coverage even when the six-hour cache has not expired.
    func isFresh(since day: String, at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return days.keys.min().map { $0 <= day } == true && age >= 0 && age < 6 * 3600
            && ExchangeRates.dayString(fetchedAt) == ExchangeRates.dayString(now)
    }
    /// Units of `to` per one unit of `from` on the latest published day on or before `day`.
    func rate(from: String, to: String, on day: String, sorted: [String]? = nil) -> (rate: Decimal, day: String)? {
        if from == to { return (1, day) }
        let keys = sorted ?? sortedDays
        var low = 0, high = keys.count - 1, found: String?
        while low <= high {
            let mid = (low + high) / 2
            if keys[mid] <= day { found = keys[mid]; low = mid + 1 } else { high = mid - 1 }
        }
        guard let found, let values = days[found], let a = values[from], let b = values[to], a > 0 else { return nil }
        return (b / a, found)
    }
    /// A recent short-range request must not discard older coverage or replace newer quotes.
    func merging(_ incoming: Self) -> Self {
        let preferIncoming = incoming.fetchedAt >= fetchedAt
        return Self(days: days.merging(incoming.days) { preferIncoming ? $1 : $0 }, fetchedAt: max(fetchedAt, incoming.fetchedAt))
    }
    static func parse(_ data: Data, since: String) throws -> Self {
        let delegate = ECBRatesParser(limit: "9999-12-31"), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.days.isEmpty else { throw URLError(.cannotParseResponse) }
        // Keep one earlier day so the first requested date still has a rate on or before it.
        let keys = delegate.days.keys.sorted()
        let first = keys.last { $0 < since } ?? keys.first!
        return Self(days: delegate.days.filter { $0.key >= first }, fetchedAt: Date())
    }
}

/// Downloads daily rates once and keeps them on disk; rates are public data, nothing about the ledger is sent.
actor RateHistoryStore {
    private static let shared = RateHistoryStore()
    private var memory: RateHistory?
    private var diskLoaded = false
    private var inFlight: (id: UUID, start: String, task: Task<RateHistory, Error>)?
    private var file: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("JianshiRates", isDirectory: true).appendingPathComponent("ecb-daily.json")
    }
    static var cached: RateHistory? { get async { await shared.readCache() } }
    private func readCache() -> RateHistory? {
        guard !diskLoaded else { return memory }
        diskLoaded = true
        if let file, let data = try? Data(contentsOf: file) { memory = try? JSONDecoder().decode(RateHistory.self, from: data) }
        return memory
    }
    static func load(since: Date) async throws -> RateHistory { try await shared.history(since: since) }
    /// Actor serialization keeps file IO and JSON work off the UI thread and orders writes.
    /// Concurrent callers share a download; a wider request follows a narrower one only when needed.
    private func history(since: Date) async throws -> RateHistory {
        let start = ExchangeRates.dayString(since)
        if let cached = readCache(), cached.isFresh(since: start) { return cached }
        while true {
            if inFlight == nil {
                inFlight = (UUID(), start, Task {
                    let archive = since < Date().addingTimeInterval(-80 * 86400) ? "eurofxref-hist.xml" : "eurofxref-hist-90d.xml"
                    var request = URLRequest(url: URL(string: "https://www.ecb.europa.eu/stats/eurofxref/" + archive)!); request.timeoutInterval = 30
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 40_000_000 else { throw URLError(.badServerResponse) }
                    return try RateHistory.parse(data, since: start)
                })
            }
            let pending = inFlight!
            do {
                let value = try await pending.task.value
                if inFlight?.id == pending.id {
                    let merged = memory?.merging(value) ?? value
                    memory = merged; inFlight = nil
                    if let file {
                        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? JSONEncoder().encode(merged).write(to: file, options: .atomic)
                    }
                }
                if pending.start <= start { return memory ?? value }
                if let memory, memory.isFresh(since: start) { return memory }
            } catch {
                if inFlight?.id == pending.id { inFlight = nil }
                if let memory { return memory }
                throw error
            }
        }
    }
}

private final class ECBRatesParser: NSObject, XMLParserDelegate {
    let limit: String
    var days: [String: [String: Decimal]] = [:]
    var current: String?
    init(limit: String) { self.limit = limit }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard elementName == "Cube" else { return }
        if let day = attributes["time"] {
            current = day <= limit && day.count == 10 ? day : nil
            if let current { days[current] = ["EUR": 1] }
        } else if let current, let currency = attributes["currency"], Money.currencies.contains(currency),
                  let text = attributes["rate"], let rate = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !rate.isNaN && rate > 0 && rate < 1_000_000_000 {
            days[current]?[currency] = rate
        }
    }
}
