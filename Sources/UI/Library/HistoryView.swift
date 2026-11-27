import SwiftUI

/// 履歴。`Library.history`（新しい順、最大 500 件）をグリッド化し、全消去できる。
struct HistoryView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var library: Library
    @StateObject private var model = GalleryListModel()

    @State private var showClearConfirm: Bool = false

    private var theme: AstryxTheme { AstryxTheme.shared }

    var body: some View {
        NavigationStack {
            GalleryGrid(
                model: model,
                emptyMessage: "履歴はまだありません。\nギャラリーを開くとここに残ります。"
            )
            .navigationTitle("履歴")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Int.self) { id in
                GalleryDetailView(galleryID: id)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showClearConfirm = true
                    } label: {
                        Label("履歴を消去", systemImage: "trash")
                    }
                    .disabled(library.history.isEmpty)
                }
            }
            .confirmationDialog(
                "履歴をすべて消去しますか？",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("消去", role: .destructive) {
                    library.clearHistory()
                }
                Button("キャンセル", role: .cancel) { }
            }
        }
        .task(id: library.history) {
            await model.configureAndStart(
                source: .ids(library.history),
                perPage: settings.perPage
            )
        }
    }
}
