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

    var isNozomiSorted: Bool { self == .dateAdded || self == .random }
}

struct SearchArgs {
    var area: String?
    var tag: String
    var language: String

    static func fromQuery(_ query: String) -> SearchArgs? {
        guard query.contains(":") else { return nil }

        let parts = query.components(separatedBy: ":")
        guard let left = parts.first else { return nil }
        let right = parts.dropFirst().joined(separator: ":")

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
}

private struct RawSuggestion: Decodable {
    let tag: String
    let count: Int
    let namespace: String

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        tag = (try? container.decode(String.self)) ?? ""
        count = (try? container.decode(Int.self)) ?? 0
        namespace = (try? container.decode(String.self)) ?? ""
    }
}

extension HitomiClient {

    // MARK: - Index versions

    func indexVersion(_ name: String, revalidate: Bool = false) async throws -> String {
        if !revalidate,
           let cached = indexVersions[name],
           Date().timeIntervalSince(cached.at) < HitomiClient.indexVersionTTL {
            return cached.value
        }

        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let text = try await getText(try hitomiURL("https://\(HitomiEndpoint.domain)/\(name)/version?_=\(stamp)"), revalidate: true)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw HitomiError.malformed("empty version for \(name)") }
        indexVersions[name] = (value, Date())
        return value
    }

    /// Drops what a refresh has to look at again; both caches outlive a single query.
    func invalidateCaches() {
        indexVersions.removeAll()
        suggestionCache.removeAll()
    }

    // MARK: - Nozomi

    func nozomiAddress(_ args: SearchArgs, _ sort: SortMode) -> String {
        let base = "https://\(HitomiEndpoint.domain)/n"
        let ext = HitomiEndpoint.nozomiExtension

        if !sort.isNozomiSorted {
            if args.area == "all" {
                return "\(base)/\(sort.orderBy)/\(sort.orderByKey)-\(args.language)\(ext)"
            }
            return "\(base)/\(args.area ?? "")/\(sort.orderBy)/\(sort.orderByKey)/\(args.tag)-\(args.language)\(ext)"
        }

        if args.area == "all" {
            return "\(base)/\(args.tag)-\(args.language)\(ext)"
        }
        return "\(base)/\(args.area ?? "")/\(args.tag)-\(args.language)\(ext)"
    }

    /// The whole nozomi file as gallery IDs.
    func galleryIDsFromNozomi(_ args: SearchArgs, _ sort: SortMode) async throws -> [Int] {
        let url = try hitomiURL(nozomiAddress(args, sort))
        let (data, _) = try await binary(url)
        return Self.decodeIDs(data)
    }

    /// One window of a nozomi file, with the file's total from `Content-Range`
    /// so a list can page through it without ever holding all of it.
    func nozomiWindow(_ args: SearchArgs, _ sort: SortMode, offset: Int, count: Int) async throws -> (ids: [Int], total: Int) {
        guard count > 0, offset >= 0 else { return ([], 0) }

        let url = try hitomiURL(nozomiAddress(args, sort))
        let start = offset * 4
        let end = (offset + count) * 4
        let (data, response) = try await binary(url, range: start..<end)

        let total = Self.totalFromContentRange(response.value(forHTTPHeaderField: "Content-Range")) ?? (offset + count)
        return (Self.decodeIDs(data), total)
    }

    private static func totalFromContentRange(_ header: String?) -> Int? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        let totalText = header[header.index(after: slash)...]
        guard let total = Int(totalText.trimmingCharacters(in: .whitespaces)) else { return nil }
        return total / 4
    }

    private static func decodeIDs(_ data: Data) -> [Int] {
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
        let isGalleryField = field == "galleries" || field == "languages" || field == "nozomiurl"
        let version = try await indexVersion(isGalleryField ? HitomiEndpoint.galleriesIndexDirectory : HitomiEndpoint.tagIndexDirectory)

        let url = try hitomiURL(nodeAddress(field: field, version: version))
        let start = Int(address)
        let end = start + HitomiEndpoint.maxNodeSize
        let (data, _) = try await binary(url, range: start..<end)
        return try Self.decodeNode(data)
    }

    static func decodeNode(_ data: Data) throws -> BTreeNode {
        let bytes = data.bytes
        var position = 0

        guard let keyCount = bytes.int32(at: position) else { throw HitomiError.malformed("node: truncated header") }
        position += 4

        var keys: [[UInt8]] = []
        for _ in 0..<max(0, Int(keyCount)) {
            guard let keySize = bytes.int32(at: position) else { throw HitomiError.malformed("node: truncated key size") }
            position += 4
            guard keySize > 0, keySize <= 32 else { throw HitomiError.malformed("node: key size \(keySize)") }
            keys.append(Array(bytes[position..<(position + Int(keySize))]))
            position += Int(keySize)
        }

        guard let dataCount = bytes.int32(at: position) else { throw HitomiError.malformed("node: truncated data count") }
        position += 4

        var datas: [(offset: Int64, length: Int32)] = []
        for _ in 0..<max(0, Int(dataCount)) {
            guard let offset = bytes.int64(at: position) else { throw HitomiError.malformed("node: truncated offset") }
            position += 8
            guard let length = bytes.int32(at: position) else { throw HitomiError.malformed("node: truncated length") }
            position += 4
            datas.append((offset, length))
        }

        var subNodes: [Int64] = []
        for _ in 0..<(HitomiEndpoint.bTreeOrder + 1) {
            guard let address = bytes.int64(at: position) else { throw HitomiError.malformed("node: truncated subnode") }
            position += 8
            subNodes.append(address)
        }

        return BTreeNode(keys: keys, datas: datas, subNodeAddresses: subNodes)
    }

    /// Byte-wise compare over the shorter length, the way hitomi's own index
    /// lookup reads it.
    private static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
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

        let isLeaf = node.subNodeAddresses.allSatisfy { $0 == 0 }
        if isLeaf { return nil }
        guard location < node.subNodeAddresses.count else { return nil }

        let next = try await self.node(field: field, address: node.subNodeAddresses[location])
        return try await bSearch(field: field, key: key, node: next)
    }

    func galleryIDsFromData(offset: Int64, length: Int32) async throws -> [Int] {
        guard length > 0, length < 100_000_000 else { throw HitomiError.malformed("index length \(length)") }

        let version = try await indexVersion(HitomiEndpoint.galleriesIndexDirectory)
        let url = try hitomiURL("https://\(HitomiEndpoint.domain)/\(HitomiEndpoint.galleriesIndexDirectory)/galleries.\(version).data")

        let start = Int(offset)
        let end = start + Int(length)
        let (data, _) = try await binary(url, range: start..<end)

        let bytes = data.bytes
        guard let count = bytes.int32(at: 0) else { throw HitomiError.malformed("index: truncated") }
        guard count > 0, count < 10_000_000 else { throw HitomiError.malformed("index count \(count)") }

        var ids: [Int] = []
        ids.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            if let value = bytes.int32(at: 4 + index * 4) { ids.append(Int(value)) }
        }
        return ids
    }

    /// The IDs a single search term matches, whether it names a tag or is text.
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

    /// Tag completions from hitomi's own suggestion index -- the JSON endpoint
    /// the site's search box asks.
    func suggestions(forQuery query: String) async throws -> [Suggestion] {
        var field = "global"
        var term = query.replacingOccurrences(of: "_", with: " ")

        if let separator = term.firstIndex(of: ":") {
            field = String(term[term.startIndex..<separator])
            term = String(term[term.index(after: separator)...])
        }

        let cacheKey = "\(field)|\(term)"
        if let cached = suggestionCache[cacheKey] { return cached }

        let chars = term.map { Self.encodeQueryForURL($0) }
        var address = "https://\(HitomiEndpoint.tagIndexDomain)/\(field)"
        if !chars.isEmpty {
            address += "/" + chars.joined(separator: "/")
        }
        address += ".json"

        let text = try await getText(try hitomiURL(address))
        guard let data = text.data(using: .utf8) else { return [] }

        let decoded = (try? JSONDecoder().decode([RawSuggestion].self, from: data)) ?? []
        let out = decoded.compactMap { raw -> Suggestion? in
            let name = Self.sanitizeTagName(raw.tag)
            guard !name.isEmpty else { return nil }
            return Suggestion(tag: name, count: raw.count, namespace: raw.namespace)
        }

        suggestionCache[cacheKey] = out
        return out
    }
}
