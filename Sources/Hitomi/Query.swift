import Foundation

enum SearchQuery: Equatable {
    case tag(namespace: String?, tag: String)
    case and([SearchQuery])
    case or([SearchQuery])
    case not(SearchQuery)
    case favoriteArtists
    case readLater

    var text: String {
        switch self {
        case .tag(let namespace, let tag):
            guard let namespace, !namespace.isEmpty else { return tag }
            return "\(namespace):\(tag)"
        case .and(let queries):
            return queries.map { $0.text }.joined(separator: " ")
        case .or(let queries):
            return "(" + queries.map { $0.text }.joined(separator: " | ") + ")"
        case .not(let query):
            return "-" + query.text
        case .favoriteArtists:
            return "favoriteArtists"
        case .readLater:
            return "readLater"
        }
    }

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

    var terms: [SearchQuery] {
        switch self {
        case .and(let queries): return queries
        default: return [self]
        }
    }
}

enum QueryLanguage {
    static let validNamespaces = [
        "female", "male", "artist", "group", "character", "series", "type", "language", "tag",
    ]

    static func normalizeTag(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseTerm(_ term: String) -> ParsedTag? {
        let separator = term.firstIndex(of: ":")
        let namespaceCandidate = separator.map { String(term[term.startIndex..<$0]).lowercased() } ?? ""

        if let separator, validNamespaces.contains(namespaceCandidate) {
            let name = normalizeTag(String(term[term.index(after: separator)...]))
            guard !name.isEmpty else { return nil }
            return ParsedTag(namespace: namespaceCandidate, tag: name)
        }

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

    static func text(of query: SearchQuery) -> String? {
        switch query {
        case .tag(let namespace, let tag):
            let term = (namespace.map { "\($0):" } ?? "") + tag
            return term.replacingOccurrences(of: " ", with: "_")
        case .not(let inner):
            guard case .tag(let namespace, let tag) = inner else { return nil }
            let term = (namespace.map { "\($0):" } ?? "") + tag
            return "-" + term.replacingOccurrences(of: " ", with: "_")
        case .and(let queries):
            var out: [String] = []
            for query in queries {
                guard let piece = text(of: query) else { return nil }
                out.append(piece)
            }
            return out.joined(separator: " ")
        case .or, .favoriteArtists, .readLater:
            return nil
        }
    }
}

struct ParsedTag {
    let namespace: String?
    let tag: String

    var text: String {
        guard let namespace, !namespace.isEmpty else { return tag }
        return "\(namespace):\(tag)"
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
    /// does not know about.
    static func ranked(_ ids: [Int], by order: [Int]) -> [Int] {
        let wanted = Set(ids)
        var remaining = wanted
        var out: [Int] = []
        for id in order where wanted.contains(id) && remaining.contains(id) {
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

struct SearchContext {
    var favoriteTags: [String] = []
    var readLater: [Int] = []
}

extension HitomiClient {

    func allGalleryIDs(_ sort: SortMode, language: String = "all") async throws -> [Int] {
        try await galleryIDsFromNozomi(SearchArgs(area: "all", tag: "index", language: language), sort)
    }

    private func favoriteArtistQueries(_ context: SearchContext) -> [SearchQuery] {
        context.favoriteTags.compactMap { tag in
            let parts = tag.components(separatedBy: ":")
            guard parts.count >= 2 else { return nil }
            let namespace = parts[0]
            guard namespace == "artist" || namespace == "group" else { return nil }
            let name = parts.dropFirst().joined(separator: ":")
            return SearchQuery.tag(namespace: namespace, tag: name)
        }
    }

    private func lookup(namespace: String?, tag: String, sort: SortMode) async throws -> [Int] {
        let text = (namespace.map { "\($0):" } ?? "") + tag
        return try await galleryIDs(forQuery: text.lowercased(), sort: sort)
    }

    /// Resolves a query against hitomi, with `all` asked for only where a query
    /// says nothing about what to include.
    func evaluateEverywhere(_ query: SearchQuery, sort: SortMode, context: SearchContext) async throws -> [Int] {
        switch query {
        case .tag(let namespace, let tag):
            return try await lookup(namespace: namespace, tag: tag, sort: sort)

        case .favoriteArtists:
            let artists = favoriteArtistQueries(context)
            if artists.isEmpty { return [] }
            return try await evaluateEverywhere(.or(artists), sort: sort, context: context)

        case .readLater:
            return context.readLater.reversed()

        case .and(let queries):
            let negatives = queries.filter { if case .not = $0 { return true } else { return false } }
            let positives = queries.filter { if case .not = $0 { return false } else { return true } }

            var included: [Int]?
            if positives.isEmpty {
                included = try await allGalleryIDs(sort)
            } else {
                for positive in positives {
                    let ids = try await evaluateEverywhere(positive, sort: sort, context: context)
                    included = included.map { IdSet.intersect($0, ids) } ?? ids
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
            for query in queries {
                branches.append(try await evaluateEverywhere(query, sort: sort, context: context))
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
