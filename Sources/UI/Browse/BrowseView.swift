import SwiftUI

/// ブラウズ。`SortMode` メニュー + 言語メニュー + 3 列グリッド + 無限スクロール +
/// 引っ張って更新（hitomi の index バージョンを取り直して先頭から）。
struct BrowseView: View {
    @EnvironmentObject private var settings: Settings
    @StateObject private var model = GalleryListModel()

    /// `Settings.browseSort` / `browseLanguage` の作業コピー。
    @State private var sortRaw: String = SortMode.popularWeek.rawValue
    @State private var language: String = "all"
    @State private var didSyncSettings: Bool = false

    private var theme: AstryxTheme { AstryxTheme.shared }

    private var sortMode: SortMode {
        SortMode(rawValue: sortRaw) ?? .dateAdded
    }

    private var reloadKey: String {
        "\(sortRaw)|\(language)|\(settings.perPage)"
    }

    var body: some View {
        NavigationStack {
            GalleryGrid(model: model, emptyMessage: "ギャラリーが見つかりませんでした")
                .navigationTitle("ブラウズ")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    toolbarContent
                }
                .navigationDestination(for: Int.self) { id in
                    GalleryDetailView(galleryID: id)
                }
        }
        .task(id: reloadKey) {
            await syncSettingsAndLoad()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("更新", systemImage: "arrow.clockwise")
            }
            .disabled(model.loading)
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Picker("並び順", selection: $sortRaw) {
                    ForEach(SortMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
            } label: {
                Label("並び順", systemImage: "arrow.up.arrow.down")
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Picker("言語", selection: $language) {
                    ForEach(Array(Settings.languages.enumerated()), id: \.offset) { pair in
                        Text(pair.element.label).tag(pair.element.id)
                    }
                }
            } label: {
                Label("言語", systemImage: "globe")
            }
        }
    }

    /// 初回だけ `Settings` から読み、以降は変更を `Settings` に書き戻す。
    /// `reloadKey` が変わると `.task` が再実行される（前のタスクはキャンセル）。
    private func syncSettingsAndLoad() async {
        if !didSyncSettings {
            didSyncSettings = true
            let storedSort = settings.browseSort
            let storedLanguage = settings.browseLanguage

            if sortRaw != storedSort {
                sortRaw = storedSort
                return
            }
            if language != storedLanguage {
                language = storedLanguage
                return
            }
        } else {
            settings.browseSort = sortRaw
            settings.browseLanguage = language
        }

        await model.configureAndStart(
            source: .browse(sort: sortMode, language: language),
            perPage: settings.perPage
        )
    }
}
