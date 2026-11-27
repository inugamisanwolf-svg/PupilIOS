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

 ## Routing is one await, not one per image

 `ensureGg()` (a `gg.js` fetch, cached for 60 s) used to be the only await in
 URL construction, but it sat in the middle of the per-image path, so a gallery
 with 2000 pages cost 2000 actor hops and held 2000 URLs. The routing maths is
 now a synchronous core (`syncHashPath` / `syncURLString` / `syncImageURL`) that
 assumes `gg` is loaded, and the public API wraps it with a single `ensureGg()`.
 Batches (`pageURLs`) therefore cost one hop in total.
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

    /// The whole-index listings, memoised by the nozomi file they came from.
    ///
    /// One entry is ~1.25M ids -- ~10 MB as `[Int]` (measured: the
    /// `index-all.nozomi` file is 4,990,152 bytes). A query built out of NOT or
    /// OR asks for it more than once, and ranking asks again, so it is held for
    /// the same ten minutes the index version is; two entries at most, oldest
    /// evicted, because a cache that grows per language is its own jetsam.
    var indexListingCache: [String: (ids: [Int], at: Date)] = [:]

    /// One read in flight per listing, shared by every caller waiting on it.
    /// Two concurrent downloads of the same 10 MB file is the case that gets
    /// the app killed, and a tag search that negates something does exactly
    /// that on every keystroke.
    var indexListingInFlight: [String: Task<[Int], Error>] = [:]

    /// Kotlin: `INDEX_VERSION_TTL_MS = 10 * 60 * 1000`.
    static let indexVersionTTL: TimeInterval = 600

    /// How many `all` listings are kept (see `indexListingCache`).
    static let indexListingCacheLimit = 2

    /// How many gallery info requests a grid may have in flight at once.
    static let parallelBlockLimit = 6

    /// How many page thumbnails a detail screen resolves up front. The strip
    /// shows 30; the rest of the pages are resolved on demand by the reader.
    static let thumbnailLimit = 60

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

    // MARK: - Routing, synchronous core
    //
    // Everything below this line assumes `gg` has been loaded and touches no
    // suspension point. Kotlin does the same work with `suspend` on every call
    // because its `Gg.m` refreshes on demand; here the refresh is the caller's
    // single `ensureGg()`.

    /// Kotlin `subdomainFromURL`: two hex digits then one, read back as one
    /// number, and `m(g)` picking the host.
    private func syncSubdomain(of string: String, base: String?, dir: String?) -> String {
        var retval = ""
        let hasBase = !(base ?? "").isEmpty

        if !hasBase {
            if dir == "webp" { retval = "w" }
            else if dir == "avif" { retval = "a" }
        }

        let caps = RE.captures("/[0-9a-f]{61}([0-9a-f]{2})([0-9a-f])", in: string)
        guard caps.count >= 2, let g = Int(caps[1] + caps[0], radix: 16) else { return "" }

        if !hasBase {
            retval += String(1 + gg.m(g))
        } else if let scalar = UnicodeScalar(97 + gg.m(g)) {
            retval = String(Character(scalar)) + (base ?? "")
        }

        return retval
    }

    /// The `//..?.host/` prefix rewritten to the one host that carries this
    /// image. Kotlin: `urlFromUrl`.
    private func syncURLString(_ string: String, base: String?, dir: String?) -> String {
        let sub = syncSubdomain(of: string, base: base, dir: dir)
        return string.replacingOccurrences(
            of: "//..?\\.(?:gold-usergeneratedcontent\\.net|hitomi\\.la)/",
            with: "//\(sub).\(HitomiEndpoint.imageHost)/",
            options: .regularExpression
        )
    }

    /// `https://a.<host>/[dir/]<b><s>/<hash>.<ext>`. Kotlin: `urlFromHash`.
    private func syncHashPath(_ image: GalleryFiles, dir: String?, ext: String?) -> String {
        let resolvedExt = ext ?? dir ?? Self.fileExtension(of: image.name)
        var path = "https://a.\(HitomiEndpoint.imageHost)/"
        if let dir = dir, !dir.isEmpty, dir != "webp", dir != "avif" {
            path += dir + "/"
        }
        path += gg.fullPath(image.hash) + "." + resolvedExt
        return path
    }

    /// Kotlin: `urlFromUrlFromHash`. A `tn` thumbnail is laid out by
    /// `realFullPath` (`xx/x/<hash>`) on the letter-prefixed hosts instead, and
    /// the subdomain is resolved without the `dir` hint, exactly as Kotlin
    /// passes it.
    private func syncImageURL(_ image: GalleryFiles, dir: String?, ext: String?, base: String?) -> URL? {
        if base == "tn" {
            let raw = "https://a.\(HitomiEndpoint.imageHost)/\(dir ?? "")/\(gg.realFullPath(image.hash)).\(ext ?? "")"
            return URL(string: syncURLString(raw, base: base, dir: nil))
        }
        let hashed = syncHashPath(image, dir: dir, ext: ext)
        return URL(string: syncURLString(hashed, base: base, dir: dir))
    }

    // MARK: - Routing, public API

    func urlFromUrl(_ url: URL, base: String? = nil, dir: String? = nil) async throws -> URL {
        try await ensureGg()
        let replaced = syncURLString(url.absoluteString, base: base, dir: dir)
        return try hitomiURL(replaced)
    }

    func urlFromHash(_ galleryID: Int, image: GalleryFiles, dir: String? = nil, ext: String? = nil) async throws -> URL {
        try await ensureGg()
        return try hitomiURL(syncHashPath(image, dir: dir, ext: ext))
    }

    func urlFromUrlFromHash(_ galleryID: Int, image: GalleryFiles, dir: String? = nil, ext: String? = nil, base: String? = nil) async throws -> URL {
        try await ensureGg()
        guard let url = syncImageURL(image, dir: dir, ext: ext, base: base) else {
            throw HitomiError.badURL(syncHashPath(image, dir: dir, ext: ext))
        }
        return url
    }

    /// The thumbnail a gallery card shows.
    func thumbnailURL(_ galleryID: Int, image: GalleryFiles, dir: String = "webpbigtn") async throws -> URL {
        try await ensureGg()
        let raw = "https://a.\(HitomiEndpoint.imageHost)/\(dir)/\(gg.realFullPath(image.hash)).webp"
        return try hitomiURL(syncURLString(raw, base: "tn", dir: nil))
    }

    /// The page itself, in webp.
    func pageURL(_ galleryID: Int, image: GalleryFiles) async throws -> URL {
        try await ensureGg()
        let path = syncHashPath(image, dir: "webp", ext: nil)
        return try hitomiURL(syncURLString(path, base: nil, dir: "webp"))
    }

    /// Up to `limit` page URLs, index-aligned with `files`, `nil` where one could
    /// not be built.
    ///
    /// One `gg.js` check for the whole batch and no suspension point inside the
    /// loop: a reader that materialises 2000 pages pays two actor hops, not
    /// 2000. Non-throwing and length-preserving, so a caller can show a
    /// placeholder for the pages it could not resolve instead of losing the
    /// alignment between slot and page number.
    func pageURLs(_ galleryID: Int, files: [GalleryFiles], limit: Int) async -> [URL?] {
        guard limit > 0, !files.isEmpty else { return [] }
        let slice = Array(files.prefix(limit))
        do {
            try await ensureGg()
        } catch {
            return Array(repeating: nil, count: slice.count)
        }
        return slice.map { image in
            let path = syncHashPath(image, dir: "webp", ext: nil)
            return URL(string: syncURLString(path, base: nil, dir: "webp"))
        }
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

        // One routing table read for the cover and the whole strip. If `gg.js`
        // cannot be had, the metadata still opens -- a detail screen without
        // pictures beats a detail screen with an error.
        var routed = true
        do {
            try await ensureGg()
        } catch {
            routed = false
        }

        var cover: URL?
        if routed, let first = info.fileList.first {
            let raw = "https://a.\(HitomiEndpoint.imageHost)/webpbigtn/\(gg.realFullPath(first.hash)).webp"
            cover = URL(string: syncURLString(raw, base: "tn", dir: nil))
        }

        // A gallery can have thousands of pages and the strip shows 30; building
        // every thumbnail meant thousands of awaits and thousands of retained
        // URLs for pictures nobody was going to see. Slots stay aligned with the
        // page number, so `nil` in the middle never shifts the ones after it.
        let limit = min(HitomiClient.thumbnailLimit, info.fileList.count)
        var thumbnails: [URL?] = []
        thumbnails.reserveCapacity(limit)
        if routed {
            for file in info.fileList.prefix(limit) {
                let raw = "https://a.\(HitomiEndpoint.imageHost)/webpsmalltn/\(gg.realFullPath(file.hash)).webp"
                thumbnails.append(URL(string: syncURLString(raw, base: "tn", dir: nil)))
            }
        } else {
            thumbnails = Array(repeating: nil, count: limit)
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
