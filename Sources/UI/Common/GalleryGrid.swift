import SwiftUI

/// 一覧グリッド + フッター（読み込み中 / インラインエラー / 空状態 / 終端）。
///
/// カードのタップは `NavigationLink(value: block.id)` なので、置く側の
/// `NavigationStack` に `.navigationDestination(for: Int.self)` が必要。
struct GalleryGrid: View {
    @ObservedObject var model: GalleryListModel

    /// 0 件のときに出す文言。
    let emptyMessage: String

    init(model: GalleryListModel, emptyMessage: String) {
        self.model = model
        self.emptyMessage = emptyMessage
    }

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
        }
        .background(theme.background)
        .refreshable {
            await model.refresh()
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let message = model.errorMessage {
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
            .padding(theme.space(.md))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
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
