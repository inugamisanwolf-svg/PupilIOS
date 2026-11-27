import Foundation

/// Tag names in the reader's own language, from the same translation files the
/// Android app ships (hitomi's community tag translations, one JSON object of
/// `"english tag": "translation"` per language).
final class TagTranslations {
    static let shared = TagTranslations()

    /// The languages `Resources/tags/` is expected to carry. Used to describe the
    /// picker when the bundle cannot be enumerated, so the setting still lists
    /// something the user can pick.
    static let knownLanguages = ["es", "id", "ko", "zh"]

    private var loaded: [String: [String: String]] = [:]
    private let lock = NSLock()

    private init() {}

    /// The languages actually present in the app bundle.
    static var availableLanguages: [String] {
        var found = Set<String>()

        // A folder reference keeps `tags/` as a directory, which is what
        // `subdirectory:` needs; a plain group flattens the files into the
        // bundle root. Ask for both, so either way of adding Resources works.
        if let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "tags") {
            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent
                if !name.isEmpty { found.insert(name) }
            }
        }
        for language in knownLanguages where Bundle.main.url(forResource: language, withExtension: "json") != nil {
            found.insert(language)
        }

        return found.sorted()
    }

    private static func bundledURL(for language: String) -> URL? {
        if let url = Bundle.main.url(forResource: language, withExtension: "json", subdirectory: "tags") {
            return url
        }
        return Bundle.main.url(forResource: language, withExtension: "json")
    }

    func table(_ language: String) -> [String: String] {
        lock.lock()
        if let cached = loaded[language] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var table: [String: String] = [:]
        if let url = Self.bundledURL(for: language),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            table = decoded.filter { !$0.value.isEmpty }
        }

        lock.lock()
        loaded[language] = table
        lock.unlock()
        return table
    }

    /// The translations of a hitomi tag name, if the reader's language has one.
    ///
    /// hitomi spells a multi-word tag with spaces; a link or a stored favourite
    /// may well carry it with underscores, so both spellings are tried, and the
    /// lowercase form last.
    func translation(of tag: String, language: String) -> String? {
        guard !language.isEmpty, !tag.isEmpty else { return nil }
        let table = table(language)
        if table.isEmpty { return nil }

        if let hit = table[tag] { return hit }
        let spaced = tag.replacingOccurrences(of: "_", with: " ")
        if let hit = table[spaced] { return hit }
        let underscored = tag.replacingOccurrences(of: " ", with: "_")
        if let hit = table[underscored] { return hit }
        let lowered = spaced.lowercased()
        if let hit = table[lowered] { return hit }
        return nil
    }

    /// The English tag names whose translation contains `term`, closest match
    /// first -- a reader searching in their own language has to be pointed back
    /// at the name hitomi's index knows.
    func tagsMatching(_ term: String, language: String, limit: Int = 5) -> [String] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty, !language.isEmpty, limit > 0 else { return [] }

        var hits: [(offset: Int, tag: String)] = []
        for (tag, translation) in table(language) where !translation.isEmpty {
            guard let range = translation.lowercased().range(of: needle) else { continue }
            let offset = translation.distance(from: translation.startIndex, to: range.lowerBound)
            hits.append((offset: offset, tag: tag))
        }

        hits.sort { lhs, rhs in
            if lhs.offset != rhs.offset { return lhs.offset < rhs.offset }
            return lhs.tag < rhs.tag
        }

        return hits.prefix(limit).map { $0.tag }
    }

    /// The same lookup the other way round: the reader's own spelling of a tag
    /// turned back into the English name hitomi's index knows. nil when the
    /// language has no such entry, so a caller can fall back to what was typed.
    func englishTag(forLocalized text: String, language: String) -> String? {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty, !language.isEmpty else { return nil }

        for (tag, translation) in table(language) where translation.lowercased() == needle {
            return tag
        }
        return nil
    }
}
