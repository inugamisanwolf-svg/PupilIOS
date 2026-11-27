import Foundation

/// The per-image-host routing table hitomi publishes as `gg.js`.
///
/// Not thread safe on its own; `HitomiClient` owns the single instance and only
/// touches it from inside the actor. `load` throws rather than leaving a
/// half-parsed table behind: routing an image with `mDefault = 0` and an empty
/// path prefix would build a host that never answers, and that looks exactly
/// like a dead network.
final class GgState {
    private(set) var mDefault = 0
    private(set) var caseMap: [Int: Int] = [:]
    private(set) var b = ""
    private var fetchedAt: Date?

    /// Kotlin keeps the table for 60 s (`lastRetrieval + 60000`).
    var isFresh: Bool {
        guard let fetchedAt = fetchedAt else { return false }
        return Date().timeIntervalSince(fetchedAt) < 60
    }

    func load(_ js: String) throws {
        guard let defaultText = RE.first("var o = (\\d)", in: js),
              let parsed = Int(defaultText) else {
            throw HitomiError.malformed("gg.js: 既定ブランチが見つかりません")
        }

        let branchValue = RE.first("o = (\\d); break;", in: js).flatMap { Int($0) } ?? parsed

        var map: [Int: Int] = [:]
        for caseText in RE.all("case (\\d+):", in: js) {
            if let key = Int(caseText) { map[key] = branchValue }
        }

        guard let bValue = RE.first("b: '(.+)'", in: js), !bValue.isEmpty else {
            throw HitomiError.malformed("gg.js: パス接頭辞が見つかりません")
        }

        mDefault = parsed
        caseMap = map
        b = bValue
        fetchedAt = Date()
    }

    func m(_ g: Int) -> Int {
        caseMap[g] ?? mDefault
    }

    /// `s` from gg.js: the last three hex digits, last one first, read as one
    /// hex number and printed in base 10 (`parseInt(m[2]+m[1], 16)`).
    func s(_ hash: String) -> String {
        let tail = Array(hash.suffix(3))
        guard tail.count == 3 else { return "0" }
        let hex = String(tail[2]) + String(tail[0]) + String(tail[1])
        return String(Int(hex, radix: 16) ?? 0)
    }

    /// `b` plus `s`: the directory an image actually sits in.
    func fullPath(_ hash: String) -> String {
        "\(b)\(s(hash))/\(hash)"
    }

    /// The path hitomi's own `real_full_path_from_hash` builds: `xx/x/hash`,
    /// which is what the `tn` thumbnail hosts are laid out as.
    func realFullPath(_ hash: String) -> String {
        let tail = Array(hash.suffix(3))
        guard tail.count == 3 else { return hash }
        let group1 = String(tail[0]) + String(tail[1])
        let group2 = String(tail[2])
        return "\(group2)/\(group1)/\(hash)"
    }
}
