import SwiftUI
import UIKit

/// 縦スクロールモードの 1 ページ。
///
/// ページ送りの `ZoomablePageView` とは別の軽量なビュー。連続スクロールでは
/// ページごとのピンチは要らないので `UIScrollView` を持たず、`Image` を 1 枚
/// 置くだけにしてある（数百ページを縦に並べるので、1 ページあたりの重さが
/// そのままスクロールの滑らかさになる）。
///
/// 大きさは呼び出し側が `ReaderFit` から決めて渡す。画像はページ送りと同じ
/// `ImageCache` を共有するので、先読み済みのページは待たずに出る。
/// シングルタップでクローム、ダブルタップで大きさを送る。
struct VerticalPageView: View {
    let url: URL
    let size: CGSize
    let onTap: () -> Void
    let onDoubleTap: () -> Void

    @State private var image: UIImage?
    @State private var failed: Bool = false

    private var theme: AstryxTheme { AstryxTheme.shared }

    var body: some View {
        ZStack {
            theme.background

            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
            } else if failed {
                VStack(spacing: theme.space(.xs)) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 18))
                        .foregroundColor(theme.textSecondary)

                    Text("このページを読み込めませんでした")
                        .font(theme.font(.caption))
                        .foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(theme.space(.sm))
            } else {
                ProgressView()
                    .tint(theme.accent)
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
        .clipped()
        .contentShape(Rectangle())
        // ダブルタップを先に置く。後ろに置くとシングルタップが先に成立する。
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture { onTap() }
        .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        // メモリに載っていれば待たずに出す（戻りスクロール、先読み済み）。
        if let cached = ImageCache.shared.cachedImage(for: url) {
            image = cached
            failed = false
            return
        }

        image = nil
        failed = false

        let loaded = await ImageCache.shared.image(for: url)
        if Task.isCancelled { return }

        image = loaded
        failed = (loaded == nil)
    }
}
