import Foundation

struct HitomiArtist: Codable, Hashable {
    let artist: String?
    let url: String?
}

struct HitomiGroup: Codable, Hashable {
    let group: String?
    let url: String?
}

struct HitomiParody: Codable, Hashable {
    let parody: String?
    let url: String?
}

struct HitomiCharacter: Codable, Hashable {
    let character: String?
    let url: String?
}

struct HitomiTag: Codable, Hashable {
    let tag: String?
    let url: String?
    let female: String?
    let male: String?
}

struct HitomiLanguageEntry: Codable, Hashable {
    let galleryid: String?
    let url: String?
    let language_localname: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case galleryid, url, language_localname, name
    }
}

struct GalleryFiles: Codable, Hashable {
    let width: Int
    let hash: String
    let haswebp: Int?
    let name: String
    let height: Int
    let hasavif: Int?

    var aspectRatio: CGFloat {
        guard height > 0 else { return 0.7 }
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

    enum CodingKeys: String, CodingKey {
        case id, title, japanese_title, language, type, date, artists, groups, parodys, tags, related, languages, characters, scene_indexes, files
    }

    var galleryID: Int? { Int(id ?? "") }
    var fileList: [GalleryFiles] { files ?? [] }
    var pageCount: Int { fileList.count }

    func displayTitle(japaneseTitles: Bool) -> String {
        if japaneseTitles, let jp = japanese_title, !jp.isEmpty { return jp }
        return title
    }

    var tagNames: [String] {
        (tags ?? []).compactMap { tag -> String? in
            guard let name = tag.tag, !name.isEmpty else { return nil }
            let female = tag.female?.isEmpty == false
            let male = tag.male?.isEmpty == false
            if female {
                return name.hasPrefix("female:") ? name : "female:" + name
            } else if male {
                return name.hasPrefix("male:") ? name : "male:" + name
            }
            return name
        }
    }
}

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
}

struct Suggestion: Identifiable, Hashable {
    let tag: String
    let count: Int
    let namespace: String

    var id: String { "\(namespace)|\(tag)" }

    var display: String {
        switch namespace {
        case "female", "male": return "\(namespace):\(tag)"
        default: return tag
        }
    }
}
