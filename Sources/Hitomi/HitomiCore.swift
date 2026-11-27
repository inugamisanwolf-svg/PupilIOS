import Foundation

/// The one host everything public is reached through. hitomi rotates the
/// `ltn.` front end rather than the name, so this is the stable half.
enum HitomiEndpoint {
    static let domain = "ltn.gold-usergeneratedcontent.net"
    static let tagIndexDomain = "tagindex.hitomi.la"
    static let imageHost = "gold-usergeneratedcontent.net"
    static let referer = "https://hitomi.la/"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.81 Safari/537.36"
    static let nozomiExtension = ".nozomi"
    static let maxNodeSize = 464
    static let bTreeOrder = 16
    static let galleryBlockExtension = ".html"
    static let tagIndexDirectory = "tagindex"
    static let galleriesIndexDirectory = "galleriesindex"
}

enum HitomiError: LocalizedError {
    case badStatus(Int)
    case malformed(String)
    case badURL(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            switch code {
            case 404: return "見つかりません (HTTP 404)"
            case 403: return "アクセスが拒否されました (HTTP 403)"
            case 429: return "リクエストが多すぎます (HTTP 429)"
            case 500...599: return "hitomi 側のエラー (HTTP \(code))"
            default: return "HTTP \(code)"
            }
        case .malformed(let what): return what
        case .badURL(let what): return "URL を組み立てられません: \(what)"
        }
    }

    /// The status, when there was one, so a caller can tell "this tag has no
    /// nozomi file" from "the network dropped".
    var statusCode: Int? {
        if case .badStatus(let code) = self { return code }
        return nil
    }
}

func hitomiURL(_ string: String) throws -> URL {
    guard let url = URL(string: string) else { throw HitomiError.badURL(string) }
    return url
}

/// Percent-encodes one path component of a hitomi URL.
///
/// The Kotlin original hands a plain string to ktor, which encodes the space
/// in `female:big breasts` for it; `URL(string:)` returns nil for the same
/// string, so the port has to encode the segment itself. `:` and `-` stay as
/// they are -- hitomi's paths are full of both -- while `/`, `?`, `#` and `%`
/// are escaped so a tag name cannot break out of its component.
enum HitomiPath {
    static func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

enum RE {
    static func captures(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        guard ns.length > 0,
              let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return []
        }
        var out: [String] = []
        for i in 1..<m.numberOfRanges {
            let r = m.range(at: i)
            out.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return out
    }

    static func first(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text).first
    }

    static func all(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        return re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > group else { return nil }
            let r = match.range(at: group)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }
}

extension Array where Element == UInt8 {
    /// Big-endian, so the nozomi files and the index nodes read as they do in
    /// the Kotlin original (`ByteBuffer.order(BIG_ENDIAN)`).
    func int32(at offset: Int) -> Int32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(self[offset + i]) }
        return Int32(bitPattern: v)
    }

    func int64(at offset: Int) -> Int64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(self[offset + i]) }
        return Int64(bitPattern: v)
    }

    func text(from offset: Int, length: Int) -> String {
        guard offset >= 0, length >= 0, offset + length <= count else { return "" }
        return String(decoding: self[offset..<(offset + length)], as: UTF8.self)
    }
}

extension Data {
    var bytes: [UInt8] { [UInt8](self) }
}

/// A JSON scalar read as text, whichever way hitomi spelled it.
///
/// The gallery payload is not consistent about this: `languages[].galleryid`
/// comes back as a number while `id` beside it is a string, and `tags[].female`
/// is `"1"`. Decoding straight into `String?` throws on the whole gallery, which
/// takes the entire detail screen with it, so every one of those fields goes
/// through here.
struct FlexibleString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else if let bool = try? container.decode(Bool.self) {
            value = bool ? "1" : ""
        } else {
            value = nil
        }
    }

    var nonEmpty: String? {
        guard let value = value, !value.isEmpty else { return nil }
        return value
    }
}

/// Reads one key as text, tolerating a missing key, a null, or any scalar type.
func flexString<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> String? {
    guard let wrapped = try? container.decodeIfPresent(FlexibleString.self, forKey: key) else { return nil }
    return wrapped.value
}

func flexInt<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int? {
    guard let text = flexString(container, key) else { return nil }
    if let value = Int(text) { return value }
    if let value = Double(text) { return Int(value) }
    return nil
}
