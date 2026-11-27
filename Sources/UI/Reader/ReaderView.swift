import SwiftUI

/// The reader: one gallery, full screen, pages turned by a swipe.
///
/// Every page's URL is resolved up front, because hitomi's image hosts are
/// derived from `gg.js` and a page that is only resolved when it arrives stutters
/// on a swipe. Resolution is cheap (one string transform each) and happens in
/// order, so the pages stay aligned with the gallery's own numbering even when a
/// single page fails: a failure leaves a gap rather than shifting every page after
/// it.
struct ReaderView: View {
    let galleryID: Int
    /// 0 始まりのページ index。呼び出し元が `Library.page(for:)` をそのまま渡す。
    let startPage: Int

    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var library = Library.shared

    @Environment(\.dismiss) private var dismiss

    @State private var gallery: Gallery?
    @State private var pageURLs: [URL?] = []
    @State private var phase: Phase = .loading
    @State private var currentIndex: Int = 0
    @State private var resolvedCount: Int = 0
    @State private var chromeVisible: Bool = true
    @State private var chromeToken: Int = 0
    @State private var prefetchTask: Task<Void, Never>?

    init(galleryID: Int, startPage: Int) {
        self.galleryID = galleryID
        self.startPage = startPage
    }

    private enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private var theme: AstryxTheme { AstryxTheme.shared }

    private var isReady: Bool { phase == .ready }

    private var titleText: String {
        gallery?.displayTitle(japaneseTitles: settings.japaneseTitles) ?? "Pupil"
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            content

            if isReady, chromeVisible {
                ReaderOverlay(
                    title: titleText,
                    currentPage: currentIndex + 1,
                    pageCount: pageURLs.count,
                    isFavorite: library.isFavorite(galleryID),
                    isInReadLater: library.isInReadLater(galleryID),
                    onClose: { close() },
                    onSelectPage: { page in show(page: page) },
                    onToggleFavorite: { library.toggleFavorite(galleryID) },
                    onToggleReadLater: { library.toggleReadLater(galleryID) }
                )
                .transition(.opacity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .animation(.easeInOut(duration: 0.18), value: chromeVisible)
        .task { await load() }
        .task(id: chromeToken) { await hideChromeLater() }
        .onChange(of: currentIndex) { newValue in
            guard isReady else { return }
            library.setPage(newValue, for: galleryID)
            prefetch(around: newValue)
        }
        .onDisappear {
            saveProgress()
            prefetchTask?.cancel()
            prefetchTask = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            loadingView
        case .failed(let message):
            failedView(message)
        case .ready:
            pages
        }
    }

    private var loadingView: some View {
        VStack(spacing: theme.space(.sm)) {
            ProgressView()
                .tint(theme.accent)

            Text("ページを準備しています…")
                .font(theme.font(.caption))
                .foregroundColor(theme.textSecondary)

            if resolvedCount > 0 {
                Text("\(resolvedCount) ページを解決")
                    .font(theme.font(.caption))
                    .foregroundColor(theme.textSecondary)
                    .monospacedDigit()
            }
        }
        .padding(theme.space(.lg))
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: theme.space(.md)) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(theme.danger)

            Text(message)
                .font(theme.font(.body))
                .foregroundColor(theme.textPrimary)
                .multilineTextAlignment(.center)

            Button {
                Task { await load() }
            } label: {
                Text("再試行")
                    .font(theme.font(.label))
                    .padding(.horizontal, theme.space(.lg))
                    .padding(.vertical, theme.space(.sm))
            }
            .foregroundColor(theme.onAccent)
            .background(theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))

            Button {
                close()
            } label: {
                Text("閉じる")
                    .font(theme.font(.label))
            }
            .foregroundColor(theme.textSecondary)
        }
        .padding(theme.space(.lg))
    }

    private var pages: some View {
        TabView(selection: $currentIndex) {
            ForEach(pageURLs.indices, id: \.self) { index in
                ZStack {
                    theme.background

                    if let url = pageURLs[index] {
                        ZoomablePageView(url: url) {
                            toggleChrome()
                        }
                    } else {
                        Text("このページは読み込めませんでした")
                            .font(theme.font(.caption))
                            .foregroundColor(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(theme.space(.lg))
                    }
                }
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        phase = .loading
        resolvedCount = 0
        pageURLs = []

        do {
            let loaded = try await HitomiClient.shared.gallery(galleryID)

            var urls: [URL?] = []
            urls.reserveCapacity(loaded.info.fileList.count)

            for file in loaded.info.fileList {
                urls.append(try? await HitomiClient.shared.pageURL(galleryID, image: file))
                resolvedCount = urls.count
            }

            guard !urls.isEmpty else {
                phase = .failed("このギャラリーにはページがありません")
                return
            }

            gallery = loaded
            pageURLs = urls

            let index = min(max(startPage, 0), urls.count - 1)
            currentIndex = index

            phase = .ready

            library.recordVisit(galleryID)
            library.setPage(index, for: galleryID)
            prefetch(around: index)
        } catch {
            phase = .failed("ギャラリーを読み込めませんでした")
        }
    }

    /// The pages either side of the one on screen, so a turn lands on an image the
    /// cache already holds.
    private func prefetch(around index: Int) {
        guard isReady, !pageURLs.isEmpty else { return }

        var urls: [URL] = []
        for offset in [-2, -1, 1, 2] {
            let target = index + offset
            guard pageURLs.indices.contains(target), let url = pageURLs[target] else { continue }
            urls.append(url)
        }

        guard !urls.isEmpty else { return }

        prefetchTask?.cancel()
        prefetchTask = Task { @MainActor in
            await ImageCache.shared.prefetch(urls)
        }
    }

    // MARK: - Chrome

    private func toggleChrome() {
        if chromeVisible {
            chromeVisible = false
        } else {
            chromeVisible = true
            chromeToken &+= 1
        }
    }

    /// バーは見せるためだけに出ているので、使われなければ自分で引っ込む。
    @MainActor
    private func hideChromeLater() async {
        guard chromeVisible else { return }

        try? await Task.sleep(nanoseconds: 5_000_000_000)
        if Task.isCancelled { return }

        chromeVisible = false
    }

    // MARK: - Actions

    /// `page` は 1 始まり（オーバーレイのスライダーが扱う番号）。
    private func show(page: Int) {
        guard !pageURLs.isEmpty else { return }

        let index = min(max(page - 1, 0), pageURLs.count - 1)
        guard index != currentIndex else { return }

        // 保存と先読みは `onChange(of: currentIndex)` がまとめて行う。
        currentIndex = index
    }

    private func saveProgress() {
        guard isReady else { return }
        library.setPage(currentIndex, for: galleryID)
    }

    private func close() {
        saveProgress()
        dismiss()
    }
}
