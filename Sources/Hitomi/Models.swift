import Foundation

// MARK: - Payload pieces
//
// The gallery payload is `var galleryinfo = {...}` served as JavaScript, and
// the shapes below follow what is actually in it (checked against the live
// endpoint, see _probe/RESULTS.md): a key can be missing entirely, a "string"
// can come back as a number, and `female` is the string "1" rather than a bool.
// Everything optional in the Kotlin model is optional here too, and the scalar
// reads go through FlexibleString so one odd gallery cannot fail the whole
// decode.

struct HitomiArtist: Codable, Hashable {
    let artist: String?
    let url: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artist = flexString(c, .artist)
        url = flexString(c, .url)
    }

    enum CodingKeys: String, CodingKey { case artist, url }
}

struct HitomiGroup: Codable, Hashable {
    let group: String?
    let url: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        group = flexString(c, .group)
        url = flexString(c, .url)
    }

    enum CodingKeys: String, CodingKey { case group, url }
}

struct HitomiParody: Codable, Hashable {
    let parody: String?
    let url: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        parody = flexString(c, .parody)
        url = flexString(c, .url)
    }

    enum CodingKeys: String, CodingKey { case parody, url }
}

struct HitomiCharacter: Codable, Hashable {
    let character: String?
    let url: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        character = flexString(c, .character)
        url = flexString(c, .url)
    }

    enum CodingKeys: String, CodingKey { case character, url }
}

struct HitomiTag: Codable, Hashable {
    let tag: String?
    let url: String?
    let female: String?
    let male: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = flexString(c, .tag)
        url = flexString(c, .url)
        female = flexString(c, .female)
        male = flexString(c, .male)
    }

    enum CodingKeys: String, CodingKey { case tag, url, female, male }
}

/// One entry of `languages`. `galleryid` is a JSON **number** in the live
/// payload (`{"galleryid": 3901548, "name": "english", ...}`) even though the
/// Kotlin model declares it `String`; it is read flexibly and kept as text so
/// the announced `[(name, galleryID)]` tuple stays a pair of strings.
struct HitomiLanguageEntry: Codable, Hashable {
    let galleryid: String?
    let url: String?
    let language_localname: String?
    let name: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        galleryid = flexString(c, .galleryid)
        url = flexString(c, .url)
        language_localname = flexString(c, .language_localname)
        name = flexString(c, .name)
    }

    enum CodingKeys: String, CodingKey {
        case galleryid, url, language_localname, name
    }
}

struct GalleryFiles: Codable, Hashable {
    let hash: String
    let name: String
    let width: Int
    let height: Int
    let haswebp: Int?
    let hasavif: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = flexString(c, .hash) ?? ""
        name = flexString(c, .name) ?? ""
        width = flexInt(c, .width) ?? 0
        height = flexInt(c, .height) ?? 0
        haswebp = flexInt(c, .haswebp)
        hasavif = flexInt(c, .hasavif)
    }

    enum CodingKeys: String, CodingKey {
        case hash, name, width, height, haswebp, hasavif
    }

    /// Width over height, guarded: a page with no height recorded would
    /// otherwise give a NaN to the layout.
    var aspectRatio: CGFloat {
        guard height > 0, width > 0 else { return 0.7 }
        return CGFloat(width) / CGFloat(height)
    }
}

struct GalleryInfo: Codable {
    let id: String?
    let title: String
    let japanese_title: String?
    let language: String?
    let type: String?
    let date: String?
    let artists: [HitomiArtist]?
    let groups: [HitomiGroup]?
    let parodys: [HitomiParody]?
    let tags: [HitomiTag]?
    let related: [Int]?
    let languages: [HitomiLanguageEntry]?
    let characters: [HitomiCharacter]?
    let scene_indexes: [Int]?
    let files: [GalleryFiles]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = flexString(c, .id)
        // A title is what a card shows, so it is never nil -- but it is read
        // leniently anyway, because a live payload is not worth a dead screen.
        title = (try? c.decode(String.self, forKey: .title)) ?? flexString(c, .title) ?? ""
        japanese_title = flexString(c, .japanese_title)
        language = flexString(c, .language)
        type = flexString(c, .type)
        date = flexString(c, .date)
        artists = try? c.decodeIfPresent([HitomiArtist].self, forKey: .artists)
        groups = try? c.decodeIfPresent([HitomiGroup].self, forKey: .groups)
        parodys = try? c.decodeIfPresent([HitomiParody].self, forKey: .parodys)
        tags = try? c.decodeIfPresent([HitomiTag].self, forKey: .tags)
        related = try? c.decodeIfPresent([Int].self, forKey: .related)
        languages = try? c.decodeIfPresent([HitomiLanguageEntry].self, forKey: .languages)
        characters = try? c.decodeIfPresent([HitomiCharacter].self, forKey: .characters)
        scene_indexes = try? c.decodeIfPresent([Int].self, forKey: .scene_indexes)
        files = try? c.decodeIfPresent([GalleryFiles].self, forKey: .files)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, japanese_title, language, type, date, artists, groups, parodys, tags,
             related, languages, characters, scene_indexes, files
    }

    var galleryID: Int? {
        guard let id = id else { return nil }
        return Int(id)
    }

    var fileList: [GalleryFiles] { files ?? [] }
    var pageCount: Int { fileList.count }

    func displayTitle(japaneseTitles: Bool) -> String {
        if japaneseTitles, let jp = japanese_title, !jp.isEmpty { return jp }
        return title
    }

    /// The tag names as hitomi's own search takes them: namespaced where the
    /// payload flagged the tag as a female or male one.
    ///
    /// Kotlin builds the prefix by concatenation, so a tag that is somehow
    /// flagged both ways comes out as `female:male:name`; a name that already
    /// carries a namespace is left alone instead, which is the only case where
    /// this is deliberately not the letter of the original.
    var tagNames: [String] {
        (tags ?? []).compactMap { tag -> String? in
            guard let name = tag.tag, !name.isEmpty else { return nil }
            if name.contains(":") { return name }
            var prefix = ""
            if let female = tag.female, !female.isEmpty { prefix += "female:" }
            if let male = tag.male, !male.isEmpty { prefix += "male:" }
            return prefix + name
        }
    }
}

// MARK: - What the UI binds to

struct GalleryBlock: Identifiable {
    let id: Int
    let title: String
    let japaneseTitle: String?
    let artists: [String]
    let series: [String]
    let groups: [String]
    let type: String
    let language: String
    let relatedTags: [String]
    let thumbnailURL: URL?
    /// Already known from the info request the thumbnail came out of, so a
    /// card can say "24p" without a second fetch.
    let pageCount: Int

    func displayTitle(japaneseTitles: Bool) -> String {
        if japaneseTitles, let jp = japaneseTitle, !jp.isEmpty { return jp }
        return title
    }

    var subtitle: String {
        if !artists.isEmpty { return artists.joined(separator: ", ") }
        if !groups.isEmpty { return groups.joined(separator: ", ") }
        return language
    }
}

struct Gallery {
    let id: Int
    let related: [Int]
    let languages: [(name: String, galleryID: String)]
    let coverURL: URL?
    let title: String
    let japaneseTitle: String?
    let artists: [String]
    let groups: [String]
    let type: String
    let language: String
    let series: [String]
    let characters: [String]
    let tags: [String]
    let thumbnails: [URL]
    let coverAspectRatio: CGFloat
    let pageCount: Int
    let info: GalleryInfo

    func displayTitle(japaneseTitles: Bool) -> String {
        if japaneseTitles, let jp = japaneseTitle, !jp.isEmpty { return jp }
        return title
    }

    /// The other language versions, minus this one, so a language picker does
    /// not offer the gallery already open.
    var otherLanguages: [(name: String, galleryID: String)] {
        languages.filter { entry in
            guard let parsed = Int(entry.galleryID) else { return true }
            return parsed != id
        }
    }
}

struct Suggestion: Identifiable, Hashable {
    let tag: String
    let count: Int
    let namespace: String

    var id: String { "\(namespace)|\(tag)" }

    /// The spelling that goes back into the search box: a namespaced suggestion
    /// has to be quoted as one, or the search reads it as plain text.
    var display: String {
        switch namespace {
        case "female", "male", "artist", "group", "character", "series", "type", "language":
            return "\(namespace):\(tag)"
        default:
            return tag
        }
    }
}
