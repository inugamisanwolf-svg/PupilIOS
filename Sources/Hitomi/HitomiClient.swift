import Foundation
import CryptoKit

/**
 The hitomi.la protocol, ported from Pupil's `HitomiClient`.

 Everything the app needs from hitomi goes through here: the gallery metadata
 endpoint, the nozomi index files, the b-tree tag index, the tag suggestion
 endpoint, and the routing that turns an image hash into the one host that
 carries it.
 */
actor HitomiClient {
    static let shared = HitomiClient()

    private let cachedSession: URLSession
    private let uncachedSession: URLSession
    private let gg = GgState()

    var indexVersions: [String: (value: String, at: Date)] = [:]
    var suggestionCache: [String: [Suggestion]] = [:]

    static let indexVersionTTL: TimeInterval = 600

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

    private func rawFetch(_ url: URL, range: Range<Int>?, revalidate: Bool, uncached: Bool) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(HitomiEndpoint.referer, forHTTPHeaderField: "Referer")
        request.setValue(HitomiEndpoint.userAgent, forHTTPHeaderField: "User-Agent")
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        if revalidate {
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }

        let session = (range == nil && !uncached) ? cachedSession : uncachedSession
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw HitomiError.malformed("no http response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw HitomiError.badStatus(http.statusCode)
        }
        return (data, http)
    }

    /// hitomi's edge cuts the body mid-stream often enough that a read is worth
    /// repeating; a status code is the server's answer, so it goes straight out.
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
        throw lastError ?? HitomiError.malformed("read failed")
    }

    func getText(_ url: URL, revalidate: Bool = false) async throws -> String {
        let (data, _) = try await fetch(url, revalidate: revalidate)
        return String(decoding: data, as: UTF8.self)
    }

    func binary(_ url: URL, range: Range<Int>? = nil, revalidate: Bool = false) async throws -> (Data, HTTPURLResponse) {
        try await fetch(url, range: range, revalidate: revalidate)
    }

    func imageData(_ url: URL) async throws -> Data {
        let (data, _) = try await fetch(url, uncached: true)
        return data
    }

    // MARK: - gg.js

    private func ensureGg() async throws {
        if gg.isFresh { return }
        let js = try await getText(try hitomiURL("https://\(HitomiEndpoint.domain)/gg.js"))
        gg.load(js)
    }

    private func subdomain(of url: URL, base: String?, dir: String?) async throws -> String {
        try await ensureGg()

        var retval = ""
        let hasBase = !(base ?? "").isEmpty

        if !hasBase {
            if dir == "webp" { retval = "w" }
            else if dir == "avif" { retval = "a" }
        }

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

        let parts = image.name.components(separatedBy: ".")
        let resolvedExt = ext ?? dir ?? (parts.count > 1 ? (parts.last ?? image.name) : image.name)

        var path = "https://a.\(HitomiEndpoint.imageHost)/"
        if dir != "webp" && dir != "avif" {
            path += (dir ?? "") + "/"
        }
        path += gg.fullPath(image.hash) + "." + resolvedExt
        return try hitomiURL(path)
    }

    func urlFromUrlFromHash(_ galleryID: Int, image: GalleryFiles, dir: String? = nil, ext: String? = nil, base: String? = nil) async throws -> URL {
        if base == "tn" {
            try await ensureGg()
            let raw = "https://a.\(HitomiEndpoint.imageHost)/\(dir ?? "")/\(gg.realFullPath(image.hash)).\(ext ?? "")"
            return try await urlFromUrl(try hitomiURL(raw), base: base)
        }
        return try await urlFromUrl(try await urlFromHash(galleryID, image: image, dir: dir, ext: ext), base: base, dir: dir)
    }

    /// The thumbnail a gallery card shows, and the ones the reader's page
    /// overview shows.
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
        guard let data = json.data(using: .utf8) else { throw HitomiError.malformed("gallery \(galleryID): not utf8") }
        do {
            return try JSONDecoder().decode(GalleryInfo.self, from: data)
        } catch {
            throw HitomiError.malformed("gallery \(galleryID): \(error.localizedDescription)")
        }
    }

    func galleryBlock(_ galleryID: Int) async throws -> GalleryBlock {
        let info = try await galleryInfo(galleryID)

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
            thumbnailURL: thumbnail
        )
    }

    func gallery(_ galleryID: Int) async throws -> Gallery {
        let info = try await galleryInfo(galleryID)

        var cover: URL?
        if let first = info.fileList.first {
            cover = try? await thumbnailURL(galleryID, image: first, dir: "webpbigtn")
        }

        var thumbnails: [URL] = []
        for file in info.fileList {
            if let url = try? await thumbnailURL(galleryID, image: file, dir: "webpsmalltn") {
                thumbnails.append(url)
            }
        }

        let languages: [(name: String, galleryID: String)] = (info.languages ?? []).compactMap { entry in
            guard let name = entry.name, let id = entry.galleryid else { return nil }
            return (name, id)
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
}
