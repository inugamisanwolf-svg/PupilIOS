import Foundation

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
        case .badStatus(let code): return "HTTP \(code)"
        case .malformed(let what): return what
        case .badURL(let what): return "bad url: \(what)"
        }
    }
}

func hitomiURL(_ string: String) throws -> URL {
    guard let url = URL(string: string) else { throw HitomiError.badURL(string) }
    return url
}

enum RE {
    static func captures(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else { return [] }
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
        return re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > group else { return nil }
            let r = match.range(at: group)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }
}

extension Array where Element == UInt8 {
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
