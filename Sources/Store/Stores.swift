import Foundation
import SwiftUI

/// What the settings screen writes and the rest of the app reads.
///
/// `ObservableObject` rather than `@Observable`: the deployment target is iOS 16
/// and the macro needs 17.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var japaneseTitles: Bool = false { didSet { persist() } }
    @Published var tagTranslation: String = "" { didSet { persist() } }
    @Published var perPage: Int = 24 { didSet { persist() } }
    @Published var theme: String = "system" { didSet { persist() } }
    @Published var browseLanguage: String = "all" { didSet { persist() } }
    @Published var browseSort: String = SortMode.popularWeek.rawValue { didSet { persist() } }

    private init() {
        // Read before the observers exist: assigning in init would otherwise
        // write every key straight back.
        japaneseTitles = defaults.bool(forKey: "japaneseTitles")
        tagTranslation = defaults.string(forKey: "tagTranslation") ?? ""
        perPage = defaults.object(forKey: "perPage") as? Int ?? 24
        theme = defaults.string(forKey: "theme") ?? "system"
        browseLanguage = defaults.string(forKey: "browseLanguage") ?? "all"
        browseSort = defaults.string(forKey: "browseSort") ?? SortMode.popularWeek.rawValue
    }

    private func persist() {
        defaults.set(japaneseTitles, forKey: "japaneseTitles")
        defaults.set(tagTranslation, forKey: "tagTranslation")
        defaults.set(perPage, forKey: "perPage")
        defaults.set(theme, forKey: "theme")
        defaults.set(browseLanguage, forKey: "browseLanguage")
        defaults.set(browseSort, forKey: "browseSort")
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    var sortMode: SortMode { SortMode(rawValue: browseSort) ?? .dateAdded }

    /// The languages hitomi serves nozomi listings for.
    static let languages: [(id: String, label: String)] = [
        ("all", "すべて"),
        ("japanese", "日本語"),
        ("english", "English"),
        ("chinese", "中文"),
        ("korean", "한국어"),
    ]
}

/// Everything the reader owns rather than fetches: favourites, history, the read
/// later list, favourite tags, past searches and page positions.
///
/// One JSON file per list under Application Support/Pupil, written on change.
/// No ID list is long enough to be worth a database, and a half-written file
/// only costs that one list.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var favorites: [Int] = []
    @Published private(set) var history: [Int] = []
    @Published private(set) var readLater: [Int] = []
    @Published private(set) var favoriteTags: [String] = []
    @Published private(set) var searchHistory: [String] = []
    @Published private(set) var progress: [String: Int] = [:]

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Pupil", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        favorites = load("favorites", fallback: [])
        history = load("history", fallback: [])
        readLater = load("readLater", fallback: [])
        favoriteTags = load("favoriteTags", fallback: [])
        searchHistory = load("searchHistory", fallback: [])
        progress = load("progress", fallback: [:])
    }

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent("\(name).json")
    }

    private func load<T: Decodable>(_ name: String, fallback: T) -> T {
        guard let data = try? Data(contentsOf: url(name)) else { return fallback }
        return (try? decoder.decode(T.self, from: data)) ?? fallback
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    // MARK: - Favourites

    func isFavorite(_ id: Int) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: Int) {
        if let index = favorites.firstIndex(of: id) {
            favorites.remove(at: index)
        } else {
            favorites.insert(id, at: 0)
        }
        save(favorites, "favorites")
    }

    // MARK: - History

    func recordVisit(_ id: Int) {
        if let index = history.firstIndex(of: id) {
            history.remove(at: index)
        }
        history.insert(id, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        save(history, "history")
    }

    func clearHistory() {
        history.removeAll()
        save(history, "history")
    }

    // MARK: - Read later

    func isInReadLater(_ id: Int) -> Bool { readLater.contains(id) }

    func toggleReadLater(_ id: Int) {
        if let index = readLater.firstIndex(of: id) {
            readLater.remove(at: index)
        } else {
            readLater.insert(id, at: 0)
        }
        save(readLater, "readLater")
    }

    // MARK: - Favourite tags

    func toggleFavoriteTag(_ tag: String) {
        if let index = favoriteTags.firstIndex(of: tag) {
            favoriteTags.remove(at: index)
        } else {
            favoriteTags.append(tag)
        }
        save(favoriteTags, "favoriteTags")
    }

    func isFavoriteTag(_ tag: String) -> Bool { favoriteTags.contains(tag) }

    // MARK: - Search history

    /// Stores a line the user submitted.
    ///
    /// The line is re-spelled through `QueryLanguage` first, so what is kept is
    /// the one canonical form (`female:big_breasts`) that parses back into the
    /// query that produced it -- not whatever case and spacing the keyboard
    /// happened to produce.
    func addSearchHistory(_ text: String) {
        guard let stored = QueryLanguage.canonicalHistoryText(text) else { return }
        remember(stored)
    }

    /// Stores a structured query. A query with no plain spelling (an OR group,
    /// the favourite artists, the read later list) is not history material --
    /// there would be no way to restore it -- so it is simply not stored.
    func addSearchHistory(_ query: SearchQuery) {
        guard let stored = QueryLanguage.text(of: query) else { return }
        remember(stored)
    }

    private func remember(_ line: String) {
        if let index = searchHistory.firstIndex(of: line) {
            searchHistory.remove(at: index)
        }
        searchHistory.insert(line, at: 0)
        if searchHistory.count > 50 { searchHistory.removeLast(searchHistory.count - 50) }
        save(searchHistory, "searchHistory")
    }

    func removeSearchHistory(_ text: String) {
        searchHistory.removeAll { $0 == text }
        save(searchHistory, "searchHistory")
    }

    // MARK: - Read progress

    func page(for galleryID: Int) -> Int? { progress["\(galleryID)"] }

    func setPage(_ page: Int, for galleryID: Int) {
        progress["\(galleryID)"] = page
        save(progress, "progress")
    }

    // MARK: - What a query may consult

    var searchContext: SearchContext {
        SearchContext(favoriteTags: favoriteTags, readLater: readLater)
    }
}
