import SwiftUI

/// The app's five tabs.
///
/// Each tab brings its own `NavigationStack`: Browse, Search, Favorites and
/// History do it inside their own screens, and Settings does it inside
/// `SettingsView`, so nothing here wraps a stack around a screen that already has
/// one (that would leave two navigation bars stacked on top of each other).
struct RootView: View {
    enum Tab: Hashable {
        case browse
        case search
        case favorites
        case history
        case settings
    }

    @State private var selection: Tab = .browse

    var body: some View {
        TabView(selection: $selection) {
            BrowseView()
                .tabItem { Label("ブラウズ", systemImage: "square.grid.2x2") }
                .tag(Tab.browse)

            SearchView()
                .tabItem { Label("検索", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            FavoritesView()
                .tabItem { Label("お気に入り", systemImage: "star") }
                .tag(Tab.favorites)

            HistoryView()
                .tabItem { Label("履歴", systemImage: "clock") }
                .tag(Tab.history)

            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(AstryxTheme.shared.accent)
    }
}
