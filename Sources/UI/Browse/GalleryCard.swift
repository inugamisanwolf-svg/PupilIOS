import SwiftUI

/// 一覧の 1 枚。サムネイル + タイトル 2 行 + サブタイトル + ページ数バッジ。
///
/// 長押し（contextMenu）でお気に入り / 後で読むを切り替える。
struct GalleryCard: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var library: Library

    let block: GalleryBlock

    init(block: GalleryBlock) {
        self.block = block
    }

    private var theme: AstryxTheme { AstryxTheme.shared }

    /// ページ数バッジの文字列。`GalleryBlock.pageCount` を使う。
    private var pageBadgeText: String {
        block.pageCount > 0 ? "\(block.pageCount)p" : ""
    }

    private var cornerRadius: CGFloat { theme.radiusSmall }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.xs)) {
            thumbnail
            title
            if !block.subtitle.isEmpty {
                Text(block.subtitle)
                    .font(theme.font(.caption))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                library.toggleFavorite(block.id)
            } label: {
                Label(
                    library.isFavorite(block.id) ? "お気に入りから削除" : "お気に入りに追加",
                    systemImage: library.isFavorite(block.id) ? "heart.slash" : "heart"
                )
            }

            Button {
                library.toggleReadLater(block.id)
            } label: {
                Label(
                    library.isInReadLater(block.id) ? "後で読むから削除" : "後で読むに追加",
                    systemImage: library.isInReadLater(block.id) ? "bookmark.slash" : "bookmark"
                )
            }
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .aspectRatio(0.72, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(
                    RemoteImage(url: block.thumbnailURL, contentMode: .fill)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(theme.border, lineWidth: 1)
                )

            if !pageBadgeText.isEmpty {
                AstryxBadge(pageBadgeText, tint: theme.surfaceRaised)
                    .padding(theme.space(.xxs))
            }

            if library.isFavorite(block.id) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11))
                    .foregroundColor(theme.accent)
                    .padding(theme.space(.xxs))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var title: some View {
        Text(block.displayTitle(japaneseTitles: settings.japaneseTitles))
            .font(theme.font(.label))
            .foregroundColor(theme.textPrimary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
