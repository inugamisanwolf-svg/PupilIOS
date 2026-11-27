import Foundation

/**
 The hitomi.la protocol, ported from Pupil's `HitomiClient`.

 Everything the app needs from hitomi goes through here: the gallery metadata
 endpoint, the nozomi index files, the b-tree tag index, the tag suggestion
 endpoint, and the routing that turns an image hash into the one host that
 carries it.

 The port deliberately keeps the Kotlin structure -- same two sessions, same
 retry, same range arithmetic -- so a divergence between the two is a bug here
 rather than a difference in intent. `_probe/verify.py` re-derives every URL
 this file builds and asks the live hosts for them.
 */
actor HitomiClient {
    static let shared = HitomiClient()

    private let cachedSession: URLSession
    private let uncachedSession: URLSession
    /// Internal, not private: `Index.swift` drives the same table from an
    /// extension, and `private` is file scope in Swift.
    let gg = GgState()

    /// Bumped for a refresh, read while paging. Internal for the same reason.
    var indexVersions: [String: (value: String, at: Date)] = [:]
    var suggestionCache: [String: [Suggestion]] = [:]

    /// Kotlin: `INDEX_VERSION_TTL_MS = 10 * 60 * 1000`.
    static let indexVersionTTL: TimeInterval = 600

    /// How many gallery info requests a grid may have in flight at once.
    static let parallelBlockLimit = 6

    private init() {
        let cached = URLSessionConfiguration.default
        cached.timeoutIntervalForRequest = 30
        cached.timeoutIntervalForResource = 180
        cached.httpMaximumConnectionsPerHost = 8
        cached.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
        cached.requestCachePolicy = .useProtocolCachePolicy
        cachedSession = URLSession(configuration: cached)

        let uncached = URLSessionConfiguration.default
        uncached.timeoutIntervalForRequest = 30
        uncached.timeoutIntervalForResource = 180
        uncached.httpMaximumConnectionsPerHost = 8
        uncached.urlCache = nil
        uncached.requestCachePolicy = .reloadIgnoringLocalCacheData
        uncachedSession = URLSession(configuration: uncached)
    }

    // MARK: - Transport

    /// `range` is half-open, the way Swift spells it: `0..<464` is 464 bytes.
    /// The `Range` header is inclusive at both ends, so the last byte asked for
    /// is `upperBound - 1` -- asking for `upperBound` costs one extra byte and
    /// hands the caller a buffer that is not a whole number of records.
    private func rawFetch(_ url: URL, range: Range<Int>?, revalidate: Bool, uncached: Bool) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(HitomiEndpoint.referer, forHTTPHeaderField: "Referer")
        request.setValue(HitomiEndpoint.userAgent, forHTTPHeaderField: "User-Agent")
        if let range = range {
            let first = max(0, range.lowerBound)
            let last = max(first, range.upperBound - 1)
            request.setValue("bytes=\(first)-\(last)", forHTTPHeaderField: "Range")
        }
        if revalidate {
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }

        let session = (range == nil && !uncached) ? cachedSession : uncachedSession
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw HitomiError.malformed("HTTP 応答ではありません")
        }
        guard (200...299).contains(http.statusCode) else {
            throw HitomiError.badStatus(http.statusCode)
        }
        return (data, http)
    }

    /// hitomi's edge cuts the body mid-stream often enough that a read is worth
    /// repeating; a status code is the server's answer, so it goes straight out
    /// (Kotlin: `retryingCutReads`).
    private func fetch(_ url: URL, range: Range<Int>? = nil, revalidate: Bool = false, uncached: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await rawFetch(url, range: range, revalidate: revalidate, uncached: uncached)
            } catch let error as HitomiError {
                throw error
            } catch {
                lastError = error
                if attempt < 2 {
                    let delay = UInt64(200 << attempt) * 1_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        throw lastError ?? HitomiError.malformed("読み込みに失敗しました")
    }

    func getText(_ url: URL, revalidate: Bool = false) async throws -> String {
        let (data, _) = try await fetch(url, revalidate: revalidate)
        return String(decoding: data, as: UTF8.self)
    }

    func binary(_ url: URL, range: Range<Int>? = nil, revalidate: Bool = false) async throws -> (Data, HTTPURLResponse) {
        try await fetch(url, range: range, revalidate: revalidate)
    }

    /// The bytes of one image. Uncached and still Referer-tagged: the image
    /// hosts answer 403 without it.
    func imageData(_ url: URL) async throws -> Data {
        let (data, _) = try await fetch(url, uncached: true)
        return data
    }

    // MARK: - gg.js

    private func ensureGg() async throws {
        if gg.isFresh { return }
        let js = try await getText(try hitomiURL("https://\(HitomiEndpoint.domain)/gg.js"))
        try gg.load(js)
    }

    private func subdomain(of url: URL, base: String?, dir: String?) async throws -> String {
        try await ensureGg()

        var retval = ""
        let hasBase = !(base ?? "").isEmpty

        if !hasBase {
            if dir == "webp" { retval = "w" }
            else if dir == "avif" { retval = "a" }
        }

        // Two hex digits then one, read back as one number -- the Kotlin
        // `(..)(.)` groups, in the same order.
        let caps = RE.captures("/[0-9a-f]{61}([0-9a-f]{2})([0-9a-f])", in: url.absoluteString)
        guard caps.count >= 2, let g = Int(caps[1] + caps[0], radix: 16) else { return "" }

        if !hasBase {
            retval += String(1 + gg.m(g))
        } else if let scalar = UnicodeScalar(97 + gg.m(g)) {
            retval = String(Character(scalar)) + (base ?? "")
        }

        return retval
    }

    func urlFromUrl(_ url: URL, base: String? = nil, dir: String? = nil) async throws -> URL {
        let sub = try await subdomain(of: url, base: base, dir: dir)
        let replaced = url.absoluteString.replacingOccurrences(
            of: "//..?\\.(?:gold-usergeneratedcontent\\.net|hitomi\\.la)/",
            with: "//\(sub).\(HitomiEndpoint.imageHost)/",
            options: .regularExpression
        )
        return try hitomiURL(replaced)
    }

    func urlFromHash(_ galleryID: Int, image: GalleryFiles, dir: String? = nil, ext: String? = nil) async throws -> URL {
        try await ensureGg()

        let resolvedExt = ext ?? dir ?? Self.fileExtension(of: image.name)

        var path = "https://a.\(HitomiEndpoint.imageHost)/"
        if let dir = dir, !dir.isEmpty, dir != "webp", dir != "avif" {
            path += dir + "/"
        }
        path += gg.fullPath(image.hash) + "." + resolvedExt
        return try hitomiURL(path)
    }

    func urlFromUrlFromHash(_ galleryID: Int, image: GalleryFiles, dir: String? = nil, ext: String? = nil, base: String? = nil) async throws -> URL {
        if base == "tn" {
            try await ensureGg()
            // Kotlin passes only `base` on to urlFromUrl here -- no `dir` -- and
            // the subdomain does not depend on it for the tn hosts, so the port
            // does the same.
            let raw = "https://a.\(HitomiEndpoint.imageHost)/\(dir ?? "")/\(gg.realFullPath(image.hash)).\(ext ?? "")"
            return try await urlFromUrl(try hitomiURL(raw), base: base)
        }
        let hashed = try await urlFromHash(galleryID, image: image, dir: dir, ext: ext)
        return try await urlFromUrl(hashed, base: base, dir: dir)
    }

    /// The thumbnail a gallery card shows.
    func thumbnailURL(_ galleryID: Int, image: GalleryFiles, dir: String = "webpbigtn") async throws -> URL {
        try await urlFromUrlFromHash(galleryID, image: image, dir: dir, ext: "webp", base: "tn")
    }

    /// The page itself, in webp.
    func pageURL(_ galleryID: Int, image: GalleryFiles) async throws -> URL {
        try await urlFromUrlFromHash(galleryID, image: image, dir: "webp")
    }

    // MARK: - Galleries

    func galleryInfo(_ galleryID: Int) async throws -> GalleryInfo {
        let text = try await getText(try hitomiURL("https://\(HitomiEndpoint.domain)/galleries/\(galleryID).js"))
        let json = text.replacingOccurrences(of: "var galleryinfo = ", with: "")
        guard let data = json.data(using: .utf8) else {
            throw HitomiError.malformed("ギャラリー \(galleryID): UTF-8 として読めません")
        }
        do {
            return try JSONDecoder().decode(GalleryInfo.self, from: data)
        } catch {
            throw HitomiError.malformed("ギャラリー \(galleryID): \(error.localizedDescription)")
        }
    }

    func galleryBlock(_ galleryID: Int) async throws -> GalleryBlock {
        let info = try await galleryInfo(galleryID)
        return try await block(from: info, galleryID: galleryID)
    }

    /// The same block, built from an info payload a caller already holds --
    /// `gallery(_:)` needs both and neither should fetch twice.
    private func block(from info: GalleryInfo, galleryID: Int) async throws -> GalleryBlock {
        var thumbnail: URL?
        if let first = info.fileList.first {
            thumbnail = try? await thumbnailURL(galleryID, image: first, dir: "webpbigtn")
        }

        return GalleryBlock(
            id: galleryID,
            title: info.title,
            japaneseTitle: info.japanese_title,
            artists: (info.artists ?? []).compactMap { $0.artist },
            series: (info.parodys ?? []).compactMap { $0.parody },
            groups: (info.groups ?? []).compactMap { $0.group },
            type: info.type ?? "",
            language: info.language ?? "",
            relatedTags: info.tagNames,
            thumbnailURL: thumbnail,
            pageCount: info.pageCount
        )
    }

    func gallery(_ galleryID: Int) async throws -> Gallery {
        let info = try await galleryInfo(galleryID)

        var cover: URL?
        if let first = info.fileList.first {
            cover = try? await thumbnailURL(galleryID, image: first, dir: "webpbigtn")
        }

        var thumbnails: [URL] = []
        thumbnails.reserveCapacity(info.fileList.count)
        for file in info.fileList {
            if let url = try? await thumbnailURL(galleryID, image: file, dir: "webpsmalltn") {
                thumbnails.append(url)
            }
        }

        let languages: [(name: String, galleryID: String)] = (info.languages ?? []).compactMap { entry -> (name: String, galleryID: String)? in
            guard let name = entry.name, let id = entry.galleryid else { return nil }
            return (name: name, galleryID: id)
        }

        return Gallery(
            id: galleryID,
            related: info.related ?? [],
            languages: languages,
            coverURL: cover,
            title: info.title,
            japaneseTitle: info.japanese_title,
            artists: (info.artists ?? []).compactMap { $0.artist },
            groups: (info.groups ?? []).compactMap { $0.group },
            type: info.type ?? "",
            language: info.language ?? "",
            series: (info.parodys ?? []).compactMap { $0.parody },
            characters: (info.characters ?? []).compactMap { $0.character },
            tags: info.tagNames,
            thumbnails: thumbnails,
            coverAspectRatio: info.fileList.first?.aspectRatio ?? 0.7,
            pageCount: info.pageCount,
            info: info
        )
    }

    // MARK: - Parallel blocks (favourites / history / related)

    /// A grid of blocks for a list of IDs, in the order given.
    ///
    /// Favourites and history are stored as bare IDs, so the cards need their
    /// info fetched; a few at a time is enough to keep a 3-column grid filling
    /// without asking hitomi for forty galleries at once. An ID that fails is
    /// dropped rather than failing the whole grid -- one deleted gallery should
    /// not blank out a favourites screen.
    ///
    /// **API contract, relied on by `Sources/UI`:** non-throwing, order
    /// preserving, failures dropped. A caller must never need `try?` around
    /// this, and must never have to re-sort the result; changing it to throw or
    /// to filter silently would break `GalleryListModel` and the related grid.
    func galleryBlocks(_ ids: [Int]) async -> [GalleryBlock] {
        guard !ids.isEmpty else { return [] }

        var ordered: [Int: GalleryBlock] = [:]
        ordered.reserveCapacity(ids.count)

        await withTaskGroup(of: (Int, GalleryBlock?).self) { group in
            var next = 0
            let limit = min(HitomiClient.parallelBlockLimit, ids.count)

            while next < limit {
                let id = ids[next]
                next += 1
                group.addTask { (id, try? await HitomiClient.shared.galleryBlock(id)) }
            }

            while true {
                guard let finished = await group.next() else { break }
                let (id, block) = finished
                if let block = block { ordered[id] = block }
                if next < ids.count {
                    let id = ids[next]
                    next += 1
                    group.addTask { (id, try? await HitomiClient.shared.galleryBlock(id)) }
                }
            }
        }

        return ids.compactMap { ordered[$0] }
    }

    /// The related grid on a detail screen: the first `limit` of the gallery's
    /// related IDs that still resolve (`related` can name galleries hitomi has
    /// since removed).
    ///
    /// Same contract as `galleryBlocks(_:)`: non-throwing, order preserving,
    /// failures dropped.
    func relatedBlocks(_ ids: [Int], limit: Int = 20) async -> [GalleryBlock] {
        guard limit > 0, !ids.isEmpty else { return [] }
        let slice = Array(ids.prefix(limit))
        return await galleryBlocks(slice)
    }

    // MARK: - Helpers

    /// `image.name`'s extension the way Kotlin takes it (`takeLastWhile
    /// { it != '.' }`): everything after the last dot, or the whole name.
    private static func fileExtension(of name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[name.index(after: dot)...])
    }
}
