import SwiftUI

/// The app's five tabs.
///
/// Each tab brings its own `NavigationStack`: Browse, Search, Favorites and
/// History do it inside their own screens, and Settings does it inside
/// `SettingsView`, so nothing here wraps a stack around a screen that already has
/// one (that would leave two navigation bars stacked on top of each other).
///
/// The theme lives one layer below everything: the wallpaper is the backmost view,
/// and the `TabView` is keyed on `ThemeStore.revision` so that a theme change
/// rebuilds every screen. `AstryxTheme.shared` is built from
/// `ThemeStore.shared.palette`, so a rebuild is what makes already-drawn screens
/// pick up the new colours.
struct RootView: View {
    enum Tab: Hashable {
        case browse
        case search
        case favorites
        case history
        case settings
    }

    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var editSession = ThemeEditSession.shared

    /// 実際に `TabView` へ与えている revision。編集中は据え置く
    /// （`ThemeEditSession` の説明を参照）。
    @State private var appliedRevision: Int = 0

    @State private var selection: Tab = .browse

    var body: some View {
        ZStack {
            WallpaperView(palette: themeStore.palette)
                .ignoresSafeArea()

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
            // テーマ変更で全画面の色を作り直す。`selection` はこの外側の
            // `@State` なので、作り直してもタブは動かない。
            .id(appliedRevision)
        }
        .tint(AstryxTheme.shared.accent)
        .onChange(of: themeStore.revision) { newValue in
            // 編集中は反映を待つ（1 タップごとに作り直すと編集画面が閉じる）。
            if !editSession.isEditing {
                appliedRevision = newValue
            }
        }
        .onChange(of: editSession.isEditing) { isEditing in
            if !isEditing {
                appliedRevision = themeStore.revision
            }
        }
    }
}
