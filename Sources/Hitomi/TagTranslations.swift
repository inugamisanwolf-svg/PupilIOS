import Foundation

/// Tag names in the reader's own language, from the same translation files the
/// Android app ships (they are hitomi's community tag translations).
final class TagTranslations {
    static let shared = TagTranslations()

    private var loaded: [String: [String: String]] = [:]

    private init() {}

    static var availableLanguages: [String] {
        Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "tags")?.compactMap { url in
            url.deletingPathExtension().lastPathComponent
        }.sorted() ?? []
    }

    func table(_ language: String) -> [String: String] {
        if let cached = loaded[language] { return cached }

        guard let url = Bundle.main.url(forResource: language, withExtension: "json", subdirectory: "tags"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            loaded[language] = [:]
            return [:]
        }

        let filtered = decoded.filter { !$0.value.isEmpty }
        loaded[language] = filtered
        return filtered
    }

    /// The translation of a hitomi tag name, if the reader's language has one.
    func translation(of tag: String, language: String) -> String? {
        guard !language.isEmpty else { return nil }
        let table = table(language)
        if let hit = table[tag] { return hit }
        return table[tag.lowercased()]
    }

    /// The English tag names whose translation contains `term`, closest match
    /// first -- a reader searching in their own language has to be pointed back
    /// at the name hitomi's index knows.
    func tagsMatching(_ term: String, language: String, limit: Int = 5) -> [String] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty, !language.isEmpty else { return [] }

        var hits: [(offset: Int, tag: String)] = []
        for (tag, translation) in table(language) {
            if let range = translation.lowercased().range(of: needle) {
                let offset = translation.distance(from: translation.startIndex, to: range.lowerBound)
                hits.append((offset, tag))
            }
        }

        hits.sort { lhs, rhs in
            if lhs.offset != rhs.offset { return lhs.offset < rhs.offset }
            return lhs.tag < rhs.tag
        }

        return hits.prefix(limit).map { $0.tag }
    }
}
