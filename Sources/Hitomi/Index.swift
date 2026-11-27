import Foundation
import CryptoKit

enum SortMode: String, CaseIterable, Identifiable {
    case dateAdded
    case datePublished
    case popularToday
    case popularWeek
    case popularMonth
    case popularYear
    case random

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateAdded: return "追加日"
        case .datePublished: return "公開日"
        case .popularToday: return "本日の人気"
        case .popularWeek: return "週間人気"
        case .popularMonth: return "月間人気"
        case .popularYear: return "年間人気"
        case .random: return "ランダム"
        }
    }

    var orderBy: String {
        switch self {
        case .dateAdded, .datePublished, .random: return "date"
        case .popularToday, .popularWeek, .popularMonth, .popularYear: return "popular"
        }
    }

    var orderByKey: String {
        switch self {
        case .dateAdded, .random: return "added"
        case .datePublished: return "published"
        case .popularToday: return "today"
        case .popularWeek: return "week"
        case .popularMonth: return "month"
        case .popularYear: return "year"
        }
    }

    /// Only these two have a nozomi file of their own; every other sort reads
    /// one of the popularity listings.
    var isNozomiSorted: Bool { self == .dateAdded || self == .random }
}

struct SearchArgs {
    var area: String?
    var tag: String
    var language: String

    /// `namespace:rest` as the search box spells it.
    ///
    /// Kotlin destructures `query.split(':')` into exactly two halves, which
    /// throws on a third colon; here everything after the first colon belongs
    /// to the tag, so `artist:foo:bar` still resolves.
    static func fromQuery(_ query: String) -> SearchArgs? {
        guard let separator = query.firstIndex(of: ":") else { return nil }

        let left = String(query[query.startIndex..<separator])
        let right = String(query[query.index(after: separator)...])

        switch left {
        case "male", "female":
            return SearchArgs(area: "tag", tag: query, language: "all")
        case "language":
            return SearchArgs(area: "all", tag: "index", language: right)
        default:
            return SearchArgs(area: left, tag: right, language: "all")
        }
    }
}

struct BTreeNode {
    let keys: [[UInt8]]
    let datas: [(offset: Int64, length: Int32)]
    let subNodeAddresses: [Int64]

    var isLeaf: Bool {
        !subNodeAddresses.contains { $0 != 0 }
    }
}

extension HitomiClient {

    // MARK: - Index versions

    /// The version naming the b-tree files, which hitomi republishes under a
    /// new one whenever the index is rebuilt. A single query walks the tree
    /// over many reads that all have to address the one snapshot.
    func indexVersion(_ name: String, revalidate: Bool = false) async throws -> String {
        if !revalidate,
           let cached = indexVersions[name],
           Date().timeIntervalSince(cached.at) < HitomiClient.indexVersionTTL {
            return cached.value
        }

        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let text = try await getText(
            try hitomiURL("https://\(HitomiEndpoint.domain)/\(name)/version?_=\(stamp)"),
            revalidate: true
        )
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw HitomiError.malformed("\(name) のバージョンが空です") }
        indexVersions[name] = (value, Date())
        return value
    }

    /// Drops what a refresh has to look at again; both caches outlive a single query.
    func invalidateCaches() {
        indexVersions.removeAll()
        suggestionCache.removeAll()
    }

    // MARK: - Nozomi

    /// Kotlin: `nozomiAddressFromArgs`. The `n` prefix is the whole of the
    /// `compressed_nozomi_prefix` constant, not a path variable.
    func nozomiAddress(_ args: SearchArgs, _ sort: SortMode) -> String {
        let base = "https://\(HitomiEndpoint.domain)/n"
        let ext = HitomiEndpoint.nozomiExtension
        let tag = HitomiPath.segment(args.tag)
        let language = HitomiPath.segment(args.language)

        if !sort.isNozomiSorted {
            if args.area == "all" {
                return "\(base)/\(sort.orderBy)/\(sort.orderByKey)-\(language)\(ext)"
            }
            return "\(base)/\(HitomiPath.segment(args.area ?? ""))/\(sort.orderBy)/\(sort.orderByKey)/\(tag)-\(language)\(ext)"
        }

        if args.area == "all" {
            return "\(base)/\(tag)-\(language)\(ext)"
        }
        return "\(base)/\(HitomiPath.segment(args.area ?? ""))/\(tag)-\(language)\(ext)"
    }

    /// The whole nozomi file as gallery IDs.
    func galleryIDsFromNozomi(_ args: SearchArgs, _ sort: SortMode) async throws -> [Int] {
        let url = try hitomiURL(nozomiAddress(args, sort))
        let (data, _) = try await binary(url)
        return Self.decodeIDs(data)
    }

    /// One window of a nozomi file, with the file's total from `Content-Range`
    /// so a list can page through it without ever holding all of it.
    ///
    /// A nozomi entry is four bytes, so offset 10 count 8 is bytes 40..<72 --
    /// which becomes the inclusive header `bytes=40-71`.
    func nozomiWindow(_ args: SearchArgs, _ sort: SortMode, offset: Int, count: Int) async throws -> (ids: [Int], total: Int) {
        guard count > 0, offset >= 0 else { return ([], 0) }

        let url = try hitomiURL(nozomiAddress(args, sort))
        let start = offset * 4
        let end = start + count * 4
        let (data, response) = try await binary(url, range: start..<end)

        let ids = Self.decodeIDs(data)
        // `Content-Range: bytes 40-71/4990152` counts bytes; a nozomi entry is
        // the four of them. When the server ignores the range and sends the
        // whole file there is no header, and what arrived is the total.
        let total = Self.totalFromContentRange(response.value(forHTTPHeaderField: "Content-Range"))
            ?? (offset + ids.count)
        return (ids, total)
    }

    static func totalFromContentRange(_ header: String?) -> Int? {
        guard let header = header, let slash = header.lastIndex(of: "/") else { return nil }
        let totalText = header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard let bytes = Int(totalText), bytes > 0 else { return nil }
        return bytes / 4
    }

    static func decodeIDs(_ data: Data) -> [Int] {
        let bytes = data.bytes
        let count = bytes.count / 4
        var ids: [Int] = []
        ids.reserveCapacity(count)
        for index in 0..<count {
            if let value = bytes.int32(at: index * 4) {
                ids.append(Int(value))
            }
        }
        return ids
    }

    // MARK: - Tag index (text search)

    /// SHA-256 of the term, first four bytes: the b-tree key.
    static func hashTerm(_ term: String) -> [UInt8] {
        let digest = SHA256.hash(data: Data(term.utf8))
        return Array(digest.prefix(4))
    }

    private func nodeAddress(field: String, version: String) -> String {
        switch field {
        case "galleries", "languages", "nozomiurl":
            return "https://\(HitomiEndpoint.domain)/\(HitomiEndpoint.galleriesIndexDirectory)/\(field).\(version).index"
        default:
            return "https://\(HitomiEndpoint.domain)/\(HitomiEndpoint.tagIndexDirectory)/\(field).\(version).index"
        }
    }

    func node(field: String, address: Int64) async throws -> BTreeNode {
        guard address >= 0 else { throw HitomiError.malformed("負のノードアドレス \(address)") }
        let isGalleryField = field == "galleries" || field == "languages" || field == "nozomiurl"
        let version = try await indexVersion(isGalleryField ? HitomiEndpoint.galleriesIndexDirectory : HitomiEndpoint.tagIndexDirectory)

        let url = try hitomiURL(nodeAddress(field: field, version: version))
        let start = Int(address)
        let end = start + HitomiEndpoint.maxNodeSize
        let (data, _) = try await binary(url, range: start..<end)
        return try Self.decodeNode(data)
    }

    /// int32 key count, then (int32 length + bytes) per key, then int32 data
    /// count, then (int64 offset + int32 length) per entry, then B+1 subnode
    /// addresses. Kotlin: `decodeNode`.
    static func decodeNode(_ data: Data) throws -> BTreeNode {
        let bytes = data.bytes
        var position = 0

        guard let keyCount = bytes.int32(at: position) else {
            throw HitomiError.malformed("ノード: ヘッダが切れています")
        }
        position += 4

        var keys: [[UInt8]] = []
        for _ in 0..<max(0, Int(keyCount)) {
            guard let keySize = bytes.int32(at: position) else {
                throw HitomiError.malformed("ノード: キー長が切れています")
            }
            position += 4
            // Kotlin rejects 0 and anything over the index's 32-byte cap.
            guard keySize > 0, keySize <= 32 else {
                throw HitomiError.malformed("ノード: キー長 \(keySize)")
            }
            let end = position + Int(keySize)
            guard end <= bytes.count else {
                throw HitomiError.malformed("ノード: キー本体が切れています")
            }
            keys.append(Array(bytes[position..<end]))
            position = end
        }

        guard let dataCount = bytes.int32(at: position) else {
            throw HitomiError.malformed("ノード: データ件数が切れています")
        }
        position += 4

        var datas: [(offset: Int64, length: Int32)] = []
        for _ in 0..<max(0, Int(dataCount)) {
            guard let offset = bytes.int64(at: position) else {
                throw HitomiError.malformed("ノード: オフセットが切れています")
            }
            position += 8
            guard let length = bytes.int32(at: position) else {
                throw HitomiError.malformed("ノード: 長さが切れています")
            }
            position += 4
            datas.append((offset: offset, length: length))
        }

        var subNodes: [Int64] = []
        subNodes.reserveCapacity(HitomiEndpoint.bTreeOrder + 1)
        for _ in 0..<(HitomiEndpoint.bTreeOrder + 1) {
            guard let address = bytes.int64(at: position) else {
                throw HitomiError.malformed("ノード: 子ノードアドレスが切れています")
            }
            position += 8
            subNodes.append(address)
        }

        return BTreeNode(keys: keys, datas: datas, subNodeAddresses: subNodes)
    }

    /// Byte-wise compare over the shorter of the two, the way hitomi's own
    /// index lookup reads it (Kotlin: `compareArrayBuffers`).
    ///
    /// The loop stops at `min(a.count, b.count)`, so a key that is a prefix of
    /// a node key compares **equal** -- `0`, not `-1`. `bSearch` treats `<= 0`
    /// as "the first key at or after this one", which is that same rule.
    static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let top = min(a.count, b.count)
        var index = 0
        while index < top {
            if a[index] < b[index] { return -1 }
            if a[index] > b[index] { return 1 }
            index += 1
        }
        return 0
    }

    func bSearch(field: String, key: [UInt8], node: BTreeNode) async throws -> (offset: Int64, length: Int32)? {
        if node.keys.isEmpty { return nil }

        var location = node.keys.count
        var found = false

        for (index, candidate) in node.keys.enumerated() {
            let result = Self.compare(key, candidate)
            if result <= 0 {
                location = index
                found = result == 0
                break
            }
        }

        if found, location < node.datas.count {
            return node.datas[location]
        }

        if node.isLeaf { return nil }
        guard location < node.subNodeAddresses.count else { return nil }

        let address = node.subNodeAddresses[location]
        guard address != 0 else { return nil }
        let next = try await self.node(field: field, address: address)
        return try await bSearch(field: field, key: key, node: next)
    }

    /// The id list a b-tree entry points at: int32 count then that many ids.
    func galleryIDsFromData(offset: Int64, length: Int32) async throws -> [Int] {
        guard length > 0, length < 100_000_000 else {
            throw HitomiError.malformed("索引長 \(length) が不正です")
        }

        let version = try await indexVersion(HitomiEndpoint.galleriesIndexDirectory)
        let url = try hitomiURL("https://\(HitomiEndpoint.domain)/\(HitomiEndpoint.galleriesIndexDirectory)/galleries.\(version).data")

        let start = Int(offset)
        guard start >= 0 else { throw HitomiError.malformed("負の索引オフセット \(offset)") }
        let end = start + Int(length)
        let (data, _) = try await binary(url, range: start..<end)

        let bytes = data.bytes
        guard let count = bytes.int32(at: 0) else { throw HitomiError.malformed("索引が切れています") }
        guard count > 0, count < 10_000_000 else {
            throw HitomiError.malformed("索引の件数 \(count) が不正です")
        }
        guard 4 + Int(count) * 4 <= bytes.count else {
            throw HitomiError.malformed("索引の件数 \(count) に対してデータが \(bytes.count) バイトしかありません")
        }

        var ids: [Int] = []
        ids.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            if let value = bytes.int32(at: 4 + index * 4) { ids.append(Int(value)) }
        }
        return ids
    }

    /// The IDs a single search term matches, whether it names a tag or is text.
    ///
    /// A namespaced term goes to its own nozomi file; anything else is hashed
    /// into the b-tree. hitomi does not serve a nozomi file for a tag no
    /// gallery carries, and that 404 means "no results", not "failed".
    func galleryIDs(forQuery query: String, sort: SortMode) async throws -> [Int] {
        let sanitized = query.replacingOccurrences(of: "_", with: " ")

        if let args = SearchArgs.fromQuery(sanitized) {
            do {
                return try await galleryIDsFromNozomi(args, sort)
            } catch HitomiError.badStatus(let code) where code == 404 {
                return []
            }
        }

        let key = Self.hashTerm(sanitized)
        let root = try await node(field: "galleries", address: 0)
        guard let data = try await bSearch(field: "galleries", key: key, node: root) else { return [] }
        return try await galleryIDsFromData(offset: data.offset, length: data.length)
    }

    // MARK: - Suggestions

    /// `' ' -> '_'`, `'/' -> "slash"`, `'.' -> "dot"`, everything else itself;
    /// Kotlin: `encodeSearchQueryForUrl`.
    private static func encodeQueryForURL(_ character: Character) -> String {
        switch character {
        case " ": return "_"
        case "/": return "slash"
        case ".": return "dot"
        default: return String(character)
        }
    }

    static func sanitizeTagName(_ input: String) -> String {
        input.replacingOccurrences(of: "[/#]", with: "", options: .regularExpression)
    }

    /// Tag completions from hitomi's own suggestion index: one path component
    /// per character of the term, under the namespace (or `global`).
    func suggestions(forQuery query: String) async throws -> [Suggestion] {
        var field = "global"
        var term = query.replacingOccurrences(of: "_", with: " ")

        if let separator = term.firstIndex(of: ":") {
            field = String(term[term.startIndex..<separator])
            term = String(term[term.index(after: separator)...])
        }

        let cacheKey = "\(field)|\(term)"
        if let cached = suggestionCache[cacheKey] { return cached }

        var address = "https://\(HitomiEndpoint.tagIndexDomain)/\(HitomiPath.segment(field))"
        let chars = term.map { Self.encodeQueryForURL($0) }
        if !chars.isEmpty {
            address += "/" + chars.map { HitomiPath.segment($0) }.joined(separator: "/")
        }
        address += ".json"

        let text: String
        do {
            text = try await getText(try hitomiURL(address))
        } catch HitomiError.badStatus(let code) where code == 404 {
            // The tag index only knows hitomi's own (English) tag names, so a
            // Japanese term is a 404 -- and that is "no suggestions", not an
            // error worth showing.
            suggestionCache[cacheKey] = []
            return []
        }

        let out = Self.decodeSuggestions(text)
        suggestionCache[cacheKey] = out
        return out
    }

    /// The payload is an array of `[tag, count, namespace]` arrays. Decoded
    /// with JSONSerialization rather than Codable so one odd entry cannot cost
    /// the whole list.
    static func decodeSuggestions(_ text: String) -> [Suggestion] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let rows = object as? [Any] else { return [] }

        var out: [Suggestion] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            guard let cells = row as? [Any], cells.count >= 3 else { continue }
            guard let rawTag = cells[0] as? String else { continue }
            let name = sanitizeTagName(rawTag)
            guard !name.isEmpty else { continue }

            let count: Int
            if let value = cells[1] as? Int {
                count = value
            } else if let value = cells[1] as? NSNumber {
                count = value.intValue
            } else if let value = cells[1] as? String {
                count = Int(value) ?? 0
            } else {
                count = 0
            }

            let namespace: String
            if let value = cells[2] as? String {
                namespace = value
            } else if let value = cells[2] as? NSNumber {
                namespace = value.stringValue
            } else {
                namespace = ""
            }

            out.append(Suggestion(tag: name, count: count, namespace: namespace))
        }
        return out
    }
}
