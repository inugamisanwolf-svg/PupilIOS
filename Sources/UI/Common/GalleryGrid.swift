import SwiftUI

/// 一覧グリッド + フッター（読み込み中 / インラインエラー / 空状態 / 終端）。
///
/// カードのタップは `NavigationLink(value: block.id)` なので、置く側の
/// `NavigationStack` に `.navigationDestination(for: Int.self)` が必要。
///
/// 無限スクロールは **スクロール位置**で判定する（セルの `onAppear` だけに頼らない）。
/// 理由: `LazyVGrid` は環境によっては画面外のセルもまとめて生成するため、
/// 末尾セルの `onAppear` は「初回レンダーの 1 回」しか来ないことがある。その瞬間
/// 読み込み中だと要求が捨てられ、以降しきい値に誰も到達せず 24 件で止まる（実機症状）。
/// ここでは内容の下端 Y とビューポート高さを測り、下端が画面の 1.5 面分まで
/// 近づいたら次ページを要求する。ページが増えると下端は遠ざかるので暴走しない。
struct GalleryGrid: View {
    @ObservedObject var model: GalleryListModel

    /// 0 件のときに出す文言。
    let emptyMessage: String

    init(model: GalleryListModel, emptyMessage: String) {
        self.model = model
        self.emptyMessage = emptyMessage
    }

    /// スクロール座標系の名前。
    private static let scrollSpace: String = "gallery-grid-scroll"

    @State private var viewportHeight: CGFloat = 0
    @State private var contentBottom: CGFloat = .greatestFiniteMagnitude

    private var theme: AstryxTheme { AstryxTheme.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.sm)) {
                if model.total > 0 {
                    Text(model.progressLabel)
                        .font(theme.font(.caption))
                        .foregroundColor(theme.textSecondary)
                        .padding(.horizontal, theme.space(.sm))
                }

                LazyVGrid(columns: GridColumns.standard, spacing: theme.space(.sm)) {
                    ForEach(model.blocks) { block in
                        NavigationLink(value: block.id) {
                            GalleryCard(block: block)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            // 補助経路（位置判定が主）。読み込み中ならモデルが
                            // `wantsMore` に覚えて、完了時に 1 ページ再生する。
                            Task {
                                await model.loadMoreIfNeeded(current: block)
                            }
                        }
                    }
                }
                .padding(.horizontal, theme.space(.sm))

                footer
            }
            .padding(.vertical, theme.space(.sm))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: GalleryContentBottomKey.self,
                        value: proxy.frame(in: .named(GalleryGrid.scrollSpace)).maxY
                    )
                }
            )
        }
        .coordinateSpace(name: GalleryGrid.scrollSpace)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: GalleryViewportHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(GalleryContentBottomKey.self) { value in
            contentBottom = value
            requestMoreIfNearBottom()
        }
        .onPreferenceChange(GalleryViewportHeightKey.self) { value in
            viewportHeight = value
            requestMoreIfNearBottom()
        }
        .background(theme.screenBackground)
        .refreshable {
            await model.refresh()
        }
    }

    /// 下端が画面の 1.5 面分以内に入ったら次を要求する。
    /// ページが増えると `contentBottom` が大きくなり条件から外れるので、
    /// 追加読み込みが連鎖して暴走することはない。
    private func requestMoreIfNearBottom() {
        guard model.hasMore, model.errorMessage == nil else { return }
        guard viewportHeight > 1, contentBottom.isFinite else { return }
        guard contentBottom < viewportHeight * 1.5 else { return }
        Task {
            await model.loadMoreIfNeededAtBottom()
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let message = model.errorMessage {
            AstryxCard {
                VStack(alignment: .leading, spacing: theme.space(.sm)) {
                    Text(message)
                        .font(theme.font(.caption))
                        .foregroundColor(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("再試行") {
                        Task { await model.retry() }
                    }
                    .buttonStyle(.astryx)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, theme.space(.sm))
        } else if model.loading {
            HStack(spacing: theme.space(.sm)) {
                ProgressView()
                Text("読み込み中…")
                    .font(theme.font(.caption))
                    .foregroundColor(theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(theme.space(.md))
        } else if model.showsEmptyState {
            VStack(spacing: theme.space(.sm)) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 28))
                    .foregroundColor(theme.textSecondary)
                Text(emptyMessage)
                    .font(theme.font(.body))
                    .foregroundColor(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(theme.space(.xl))
        } else if !model.hasMore && !model.blocks.isEmpty {
            Text("すべて表示しました")
                .font(theme.font(.caption))
                .foregroundColor(theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(theme.space(.md))
        }
    }
}

/// グリッド内容の下端 Y（スクロール座標系）。
private struct GalleryContentBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// ビューポートの高さ。
private struct GalleryViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
