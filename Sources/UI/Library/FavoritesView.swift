import SwiftUI

/// お気に入り。`Library.favorites` の ID 並びをそのままグリッド化する。
struct FavoritesView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var library: Library
    @StateObject private var model = GalleryListModel()

    private var theme: AstryxTheme { AstryxTheme.shared }

    var body: some View {
        NavigationStack {
            GalleryGrid(
                model: model,
                emptyMessage: "お気に入りはまだありません。\nカードを長押しするか、詳細画面から追加できます。"
            )
            .navigationTitle("お気に入り")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Int.self) { id in
                GalleryDetailView(galleryID: id)
            }
        }
        .task(id: library.favorites) {
            await model.configureAndStart(
                source: .ids(library.favorites),
                perPage: settings.perPage
            )
        }
    }
}
