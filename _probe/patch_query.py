import sys

p = r'C:\Users\kaito\Documents\PupilIOS\Sources\Hitomi\Query.swift'
s = open(p, encoding='utf-8').read()

pairs = [
("    static func parseTerm(_ term: String) -> SearchQuery.Tag? {",
 "    static func parseTerm(_ term: String) -> ParsedTag? {"),
("""            guard !name.isEmpty else { return nil }
            return SearchQuery.Tag(namespace: namespaceCandidate, tag: name)
        }

        let name = normalizeTag(term)
        guard !name.isEmpty else { return nil }
        return SearchQuery.Tag(namespace: nil, tag: name)""",
 """            guard !name.isEmpty else { return nil }
            return ParsedTag(namespace: namespaceCandidate, tag: name)
        }

        let name = normalizeTag(term)
        guard !name.isEmpty else { return nil }
        return ParsedTag(namespace: nil, tag: name)"""),
("""            guard let tag = parseTerm(body) else { continue }
            terms.append(negated ? .not(.tag(namespace: tag.namespace, tag: tag.tag)) : .tag(namespace: tag.namespace, tag: tag.tag))""",
 """            guard let parsed = parseTerm(body) else { continue }
            let term: SearchQuery = .tag(namespace: parsed.namespace, tag: parsed.tag)
            terms.append(negated ? .not(term) : term)"""),
("""    private func lookup(_ tag: SearchQuery.Tag, sort: SortMode) async throws -> [Int] {
        let text = (tag.namespace.map { "\\($0):" } ?? "") + tag.tag
        return try await galleryIDs(forQuery: text.lowercased(), sort: sort)
    }""",
 """    private func lookup(namespace: String?, tag: String, sort: SortMode) async throws -> [Int] {
        let text = (namespace.map { "\\($0):" } ?? "") + tag
        return try await galleryIDs(forQuery: text.lowercased(), sort: sort)
    }"""),
("            return try await lookup(SearchQuery.Tag(namespace: namespace, tag: tag), sort: sort)",
 "            return try await lookup(namespace: namespace, tag: tag, sort: sort)"),
]

for old, new in pairs:
    if old not in s:
        print('MISS:', old.splitlines()[0][:70])
    s = s.replace(old, new)

open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('ParsedTag refs:', s.count('ParsedTag'))
print('leftover SearchQuery.Tag(:', s.count('SearchQuery.Tag('))
