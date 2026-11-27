import Foundation

/// The per-image-host routing table hitomi publishes as `gg.js`.
///
/// Not thread safe on its own; `HitomiClient` owns the single instance and only
/// touches it from inside the actor.
final class GgState {
    private(set) var mDefault = 0
    private(set) var caseMap: [Int: Int] = [:]
    private(set) var b = ""
    private var fetchedAt: Date?

    var isFresh: Bool {
        guard let fetchedAt else { return false }
        return Date().timeIntervalSince(fetchedAt) < 60
    }

    func load(_ js: String) {
        if let value = RE.first("var o = (\\d)", in: js), let parsed = Int(value) {
            mDefault = parsed
        }

        let branchValue = RE.first("o = (\\d); break;", in: js).flatMap { Int($0) } ?? mDefault

        var map: [Int: Int] = [:]
        for caseText in RE.all("case (\\d+):", in: js) {
            if let key = Int(caseText) { map[key] = branchValue }
        }
        caseMap = map

        if let bValue = RE.first("b: '(.+)'", in: js) {
            b = bValue
        }

        fetchedAt = Date()
    }

    func m(_ g: Int) -> Int {
        caseMap[g] ?? mDefault
    }

    /// `s` from gg.js: the last three hex digits, last digit first, read as one hex number.
    func s(_ hash: String) -> String {
        let tail = Array(hash.suffix(3))
        guard tail.count == 3 else { return "0" }
        let hex = String([tail[2], tail[0], tail[1]])
        return String(Int(hex, radix: 16) ?? 0)
    }

    func fullPath(_ hash: String) -> String {
        "\(b)\(s(hash))/\(hash)"
    }

    /// The path hitomi's own `real_full_path_from_hash` builds: `xx/x/hash`.
    func realFullPath(_ hash: String) -> String {
        let tail = Array(hash.suffix(3))
        guard tail.count == 3 else { return hash }
        let group1 = String([tail[0], tail[1]])
        let group2 = String([tail[2]])
        return "\(group2)/\(group1)/\(hash)"
    }
}
