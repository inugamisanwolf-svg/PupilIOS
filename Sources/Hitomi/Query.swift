import Foundation

/// Structured search query.
///
/// The plain text a search box takes can only say "these terms, minus those";
/// this tree can also hold an OR, the favourite artists and the read-later
/// list, which is what the app needs to offer a search built from local state.
///
/// `indirect`: the AND/OR nodes hold arrays of queries and NOT holds one, so the
/// type is recursive and the compiler needs the box.
indirect enum SearchQuery: Equatable {
    case tag(namespace: String?, tag: String)
    case and([SearchQuery])
    case or([SearchQuery])
    case not(SearchQuery)
    case favoriteArtists
    case readLater

    /// The plain text spelling, or `""` for a query that has none.
    ///
    /// This is the same function the search history is written with --
    /// `QueryLanguage.text(of:)` -- so a query restored from history parses
    /// back into the query it came from.
    var text: String {
        QueryLanguage.text(of: self) ?? ""
    }

    /// Whether the result has to be put back in the index's order: a union
    /// takes whichever branch reached an ID first, which is an artifact of the
    /// request rather than anything to show a reader.
    var needsRanking: Bool {
        switch self {
        case .tag, .readLater:
            return false
        case .favoriteArtists, .or:
            return true
        case .and(let queries):
            return queries.contains { $0.needsRanking }
        case .not(let query):
            return query.needsRanking
        }
    }

    /// Whether the read-later list decides part of the result, so a change to
    /// it changes the list.
    var usesReadLater: Bool {
        switch self {
        case .readLater:
            return true
        case .tag, .favoriteArtists:
            return false
        case .and(let queries), .or(let queries):
            return queries.contains { $0.usesReadLater }
        case .not(let query):
            return query.usesReadLater
        }
    }

    /// The terms of the top level conjunction, the ones that can be taken out
    /// of it on their own.
    var terms: [SearchQuery] {
        switch self {
        case .and(let queries): return queries
        default: return [self]
        }
    }

    /// The query with `term` taken out of its top level conjunction.
    func removing(_ term: SearchQuery) -> SearchQuery? {
        if self == term { return nil }
        guard case .and(let queries) = self else { return self }
        let rest = queries.filter { $0 != term }
        switch rest.count {
        case 0: return nil
        case 1: return rest[0]
        default: return .and(rest)
        }
    }
}

enum QueryLanguage {
    static let validNamespaces = [
        "female", "male", "artist", "group", "character", "series", "type", "language", "tag",
    ]

    static func normalizeTag(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseTerm(_ term: String) -> ParsedTag? {
        guard let separator = term.firstIndex(of: ":") else {
            let name = normalizeTag(term)
            guard !name.isEmpty else { return nil }
            return ParsedTag(namespace: nil, tag: name)
        }

        let candidate = String(term[term.startIndex..<separator]).lowercased()
        if validNamespaces.contains(candidate) {
            let name = normalizeTag(String(term[term.index(after: separator)...]))
            guard !name.isEmpty else { return nil }
            return ParsedTag(namespace: candidate, tag: name)
        }

        // A colon that names no namespace is just part of the text.
        let name = normalizeTag(term)
        guard !name.isEmpty else { return nil }
        return ParsedTag(namespace: nil, tag: name)
    }

    /// The plain spelling hitomi's own box takes: whitespace separated terms,
    /// `-` to exclude, `namespace:tag`, underscores where a tag has a space.
    static func parse(_ text: String) -> SearchQuery? {
        let pieces = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)

        var terms: [SearchQuery] = []
        for piece in pieces {
            let negated = piece.hasPrefix("-")
            let body = negated ? String(piece.dropFirst()) : piece
            guard let parsed = parseTerm(body) else { continue }
            let term: SearchQuery = .tag(namespace: parsed.namespace, tag: parsed.tag)
            terms.append(negated ? .not(term) : term)
        }

        switch terms.count {
        case 0: return nil
        case 1: return terms[0]
        default: return .and(terms)
        }
    }

    /// **The one spelling.** Anything that turns a query into text -- the search
    /// box, the history, a chip that re-runs an old search -- comes through
    /// here, so `SearchQuery.text` and the stored string cannot drift apart.
    ///
    /// nil for a query with no spelling: an OR group, the favourite artists
    /// and the read-later list all resolve to a list only this app knows.
    static func text(of query: SearchQuery) -> String? {
        switch query {
        case .tag(let namespace, let tag):
            return termText(namespace: namespace, tag: tag)

        case .not(let inner):
            guard case .tag(let namespace, let tag) = inner else { return nil }
            return "-" + termText(namespace: namespace, tag: tag)

        case .and(let queries):
            var out: [String] = []
            out.reserveCapacity(queries.count)
            for child in queries {
                guard let piece = text(of: child) else { return nil }
                out.append(piece)
            }
            return out.joined(separator: " ")

        case .or, .favoriteArtists, .readLater:
            return nil
        }
    }

    /// `namespace:tag` with the tag's spaces written as underscores, which is
    /// what hitomi's own search box and the stored history line use.
    static func termText(namespace: String?, tag: String) -> String {
        let body = tag.replacingOccurrences(of: " ", with: "_")
        guard let namespace = namespace, !namespace.isEmpty else { return body }
        return namespace + ":" + body
    }

    /// The text to keep for a line the user submitted, or nil when the line is
    /// not a search worth offering back.
    ///
    /// A line that parses is re-spelled from the parse, so `Female:Big Breasts`
    /// is stored as `female:big_breasts` and restores into the same query;
    /// a line that does not parse is kept as the user typed it.
    static func canonicalHistoryText(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let query = parse(trimmed), let spelled = text(of: query) {
            return spelled
        }
        return trimmed
    }
}

struct ParsedTag {
    let namespace: String?
    let tag: String

    var text: String {
        QueryLanguage.termText(namespace: namespace, tag: tag)
    }
}

enum IdSet {
    static func intersect(_ first: [Int], _ second: [Int]) -> [Int] {
        if first.isEmpty || second.isEmpty { return [] }
        let keep = Set(second)
        return first.filter { keep.contains($0) }
    }

    static func subtract(_ first: [Int], _ second: [Int]) -> [Int] {
        if first.isEmpty || second.isEmpty { return first }
        let drop = Set(second)
        return first.filter { !drop.contains($0) }
    }

    static func union(_ arrays: [[Int]]) -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        for array in arrays {
            for id in array where !seen.contains(id) {
                seen.insert(id)
                out.append(id)
            }
        }
        return out
    }

    /// Keeps `ids` in the order `order` gives them, appending anything `order`
    /// does not know about (Kotlin: `rankedBy`).
    static func ranked(_ ids: [Int], by order: [Int]) -> [Int] {
        let wanted = Set(ids)
        var remaining = wanted
        var out: [Int] = []
        out.reserveCapacity(ids.count)
        for id in order where remaining.contains(id) {
            remaining.remove(id)
            out.append(id)
        }
        for id in ids where remaining.contains(id) {
            remaining.remove(id)
            out.append(id)
        }
        return out
    }
}

/// What a query may look at besides hitomi: the tags the reader favourited and
/// the galleries they put aside.
struct SearchContext {
    var favoriteTags: [String] = []
    var readLater: [Int] = []

    static let empty = SearchContext()
}

extension HitomiClient {

    /// Every gallery ID in one index listing -- the whole `all` nozomi file.
    ///
    /// Memoised because that file is ~1.25M ids (measured: 4,990,152 bytes, so
    /// ~10 MB as `[Int]`): a query built out of NOT or OR asks for it, and
    /// `evaluate` asks again for ranking, and a search history of two such
    /// queries would hold two copies. The key is the file's own address, which
    /// means `.random` and `.dateAdded` share the single entry they would
    /// otherwise each drag in, and the language is part of the address.
    ///
    /// A caller that arrives while the read is still running waits on it rather
    /// than starting a second one: two concurrent downloads of the same 10 MB
    /// file is the case that gets the app jetsammed, and tapping a negated tag
    /// search twice does exactly that.
    func allGalleryIDs(_ sort: SortMode, language: String = "all") async throws -> [Int] {
        let args = SearchArgs(area: "all", tag: "index", language: language)
        let key = nozomiAddress(args, sort)

        if let cached = indexListingCache[key],
           Date().timeIntervalSince(cached.at) < HitomiClient.indexVersionTTL {
            return cached.ids
        }

        if let running = indexListingInFlight[key] {
            return try await running.value
        }

        let task = Task { [self] in
            try await self.loadIndexListing(args: args, sort: sort, key: key)
        }
        indexListingInFlight[key] = task
        defer { indexListingInFlight[key] = nil }
        return try await task.value
    }

    private func loadIndexListing(args: SearchArgs, sort: SortMode, key: String) async throws -> [Int] {
        let ids = try await galleryIDsFromNozomi(args, sort)
        indexListingCache[key] = (ids, Date())
        evictIndexListingIfNeeded()
        return ids
    }

    /// Keeps `indexListingCache` at `HitomiClient.indexListingCacheLimit`
    /// entries, dropping the one resolved longest ago.
    private func evictIndexListingIfNeeded() {
        while indexListingCache.count > HitomiClient.indexListingCacheLimit {
            var victimKey: String?
            var victimDate: Date?
            for (key, entry) in indexListingCache {
                if let oldest = victimDate {
                    if entry.at < oldest {
                        victimKey = key
                        victimDate = entry.at
                    }
                } else {
                    victimKey = key
                    victimDate = entry.at
                }
            }
            guard let victim = victimKey else { return }
            indexListingCache[victim] = nil
        }
    }

    /// Every favourited `artist:` and `group:` tag, ORed together -- a work is
    /// often credited to the circle rather than the person, so following one
    /// without the other misses half of what it is credited to.
    private func favoriteArtistQueries(_ context: SearchContext) -> [SearchQuery] {
        context.favoriteTags.compactMap { tag -> SearchQuery? in
            guard let separator = tag.firstIndex(of: ":") else { return nil }
            let namespace = String(tag[tag.startIndex..<separator])
            guard namespace == "artist" || namespace == "group" else { return nil }
            let name = String(tag[tag.index(after: separator)...])
            guard !name.isEmpty else { return nil }
            return .tag(namespace: namespace, tag: name)
        }
    }

    private func lookup(namespace: String?, tag: String, sort: SortMode) async throws -> [Int] {
        let text = QueryLanguage.termText(namespace: namespace, tag: tag)
        return try await galleryIDs(forQuery: text.lowercased(), sort: sort)
    }

    /// Resolves a query against hitomi, asking for the whole index only where
    /// the query says nothing about what to include -- a lone negation, or a
    /// conjunction of them.
    func evaluateEverywhere(_ query: SearchQuery, sort: SortMode, context: SearchContext) async throws -> [Int] {
        switch query {
        case .tag(let namespace, let tag):
            return try await lookup(namespace: namespace, tag: tag, sort: sort)

        case .favoriteArtists:
            let artists = favoriteArtistQueries(context)
            if artists.isEmpty { return [] }
            return try await evaluateEverywhere(.or(artists), sort: sort, context: context)

        case .readLater:
            return Array(context.readLater.reversed())

        case .and(let queries):
            let negatives = queries.filter { if case .not = $0 { return true } else { return false } }
            let positives = queries.filter { if case .not = $0 { return false } else { return true } }

            var included: [Int]?
            if positives.isEmpty {
                included = try await allGalleryIDs(sort)
            } else {
                for positive in positives {
                    let ids = try await evaluateEverywhere(positive, sort: sort, context: context)
                    if let current = included {
                        included = IdSet.intersect(current, ids)
                    } else {
                        included = ids
                    }
                }
            }

            var result = included ?? []
            for negative in negatives {
                guard case .not(let inner) = negative else { continue }
                let ids = try await evaluateEverywhere(inner, sort: sort, context: context)
                result = IdSet.subtract(result, ids)
            }
            return result

        case .or(let queries):
            var branches: [[Int]] = []
            branches.reserveCapacity(queries.count)
            for child in queries {
                branches.append(try await evaluateEverywhere(child, sort: sort, context: context))
            }
            return IdSet.union(branches)

        case .not(let inner):
            let index = try await allGalleryIDs(sort)
            let excluded = try await evaluateEverywhere(inner, sort: sort, context: context)
            return IdSet.subtract(index, excluded)
        }
    }

    func evaluate(_ query: SearchQuery, sort: SortMode, context: SearchContext) async throws -> [Int] {
        var ids = try await evaluateEverywhere(query, sort: sort, context: context)
        if ids.isEmpty { return ids }

        if sort == .random {
            ids.shuffle()
            return ids
        }

        if !query.needsRanking { return ids }

        let order = try await allGalleryIDs(sort)
        return IdSet.ranked(ids, by: order)
    }

    /// The search the search box runs: the query text, or the whole index when
    /// the box is empty.
    func search(_ text: String, sort: SortMode, context: SearchContext, language: String = "all") async throws -> [Int] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let query = QueryLanguage.parse(trimmed) else {
            var ids = try await allGalleryIDs(sort, language: language)
            if sort == .random { ids.shuffle() }
            return ids
        }

        return try await evaluate(query, sort: sort, context: context)
    }
}
