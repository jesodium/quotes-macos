import WidgetKit
import SwiftUI
import AppIntents

// IMPORTANT NOTE: quotes.json is pre-shuffled; zenquotes batches get appended to "extra" and shown before it
let bundled: [(String, String)] = {
    let url = Bundle.main.url(forResource: "quotes", withExtension: "json")!
    let raw = try! JSONDecoder().decode([[String]].self, from: Data(contentsOf: url))
    return raw.map { ($0[0], $0[1]) }
}()

let interval: Double = 180
let perTimeline = 50
let store = UserDefaults.standard

func key(_ q: String) -> String { q.lowercased().filter { $0.isLetter || $0.isNumber } }

// IMPORTANT NOTE: author + keyword blocklist, new zenquotes authors can slip through until added here
let blockedAuthors = ["ali ibn abi talib", "abu bakr", "umar ibn al-khatt", "(r.a"]
let blockedWords = #"\b(allah|islam|islamic|muslims?|qur'?an|koran|masjid|mosque|salah|prophet|jihad|kuffar|taqwaa?|ramadan|hijab|sunnah|hadith|ummah)\b"#

func allowed(_ q: (String, String)) -> Bool {
    let a = q.1.lowercased()
    return !blockedAuthors.contains { a.contains($0) }
        && q.0.range(of: blockedWords, options: [.regularExpression, .caseInsensitive]) == nil
}

struct Zen: Decodable { let q: String; let a: String }

struct Entry: TimelineEntry {
    let date: Date
    let quote: (String, String)
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, quote: bundled[0]) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now, quote: bundled[0])) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        fetchFresh {
            let start = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 / interval).rounded(.down) * interval)
            let entries = upcoming(from: start).enumerated().map {
                Entry(date: start.addingTimeInterval(Double($0.offset) * interval), quote: $0.element)
            }
            completion(Timeline(entries: entries, policy: .atEnd))
        }
    }

    func fetchFresh(_ done: @escaping () -> Void) {
        let req = URLRequest(url: URL(string: "https://zenquotes.io/api/quotes")!, timeoutInterval: 10)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let batch = try? JSONDecoder().decode([Zen].self, from: data) {
                var extra = store.array(forKey: "extra") as? [[String]] ?? []
                var known = Set((bundled.map(\.0) + extra.map { $0[0] }).map(key))
                for z in batch where z.a != "zenquotes.io" && z.q.count <= 180 && known.insert(key(z.q)).inserted {
                    extra.append([z.q, z.a])
                }
                store.set(extra, forKey: "extra")
            }
            done()
        }.resume()
    }

    // IMPORTANT NOTE: a quote only counts as seen once its 3 min slot is over, so reloads keep the current one
    func upcoming(from start: Date) -> [(String, String)] {
        var seen = Set(store.stringArray(forKey: "seen") ?? [])
        let last = store.double(forKey: "lastStart")
        for (i, k) in (store.stringArray(forKey: "lastKeys") ?? []).enumerated()
        where last + Double(i + 1) * interval <= Date.now.timeIntervalSince1970 {
            seen.insert(k)
        }
        let pool = ((store.array(forKey: "extra") as? [[String]] ?? []).map { ($0[0], $0[1]) } + bundled).filter(allowed)
        var fresh = pool.filter { !seen.contains(key($0.0)) }
        if fresh.isEmpty { seen = []; fresh = pool }
        let next = Array(fresh.prefix(perTimeline))
        store.set(Array(seen), forKey: "seen")
        store.set(start.timeIntervalSince1970, forKey: "lastStart")
        store.set(next.map { key($0.0) }, forKey: "lastKeys")
        return next
    }
}

struct NextQuote: AppIntent {
    static var title: LocalizedStringResource = "Next quote"

    // IMPORTANT NOTE: current quote found by time slot, same math as upcoming()
    func perform() async throws -> some IntentResult {
        let keys = store.stringArray(forKey: "lastKeys") ?? []
        let i = Int((Date.now.timeIntervalSince1970 - store.double(forKey: "lastStart")) / interval)
        if keys.indices.contains(i) {
            store.set((store.stringArray(forKey: "seen") ?? []) + [keys[i]], forKey: "seen")
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct Meaning: AppIntent {
    static var title: LocalizedStringResource = "Quote meaning"
    @Parameter(title: "Quote") var quote: String
    @Parameter(title: "Author") var author: String

    init() {}
    init(_ q: (String, String)) { quote = q.0; author = q.1 }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(meaningURL((quote, author))))
    }
}

func meaningURL(_ q: (String, String)) -> URL {
    var c = URLComponents(string: "https://www.google.com/search")!
    c.queryItems = [URLQueryItem(name: "q", value: "\"\(q.0)\" \(q.1) meaning")]
    return c.url!
}

struct QuoteView: View {
    let entry: Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(intent: NextQuote()) {
            Text("\u{201C}\(entry.quote.0.lowercased())\u{201D}")
                .font(.system(size: family == .systemSmall ? 15 : 19, weight: .light))
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .buttonStyle(.plain)
            HStack {
                Text(entry.quote.1.lowercased())
                    .font(.system(size: 10, weight: .regular))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer()
                Button(intent: Meaning(entry.quote)) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

@main
struct QuotesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuotesWidget", provider: Provider()) { entry in
            QuoteView(entry: entry)
        }
            .configurationDisplayName("Quotes")
            .description("A new quote every 3 minutes. Quotes partly from zenquotes.io.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
