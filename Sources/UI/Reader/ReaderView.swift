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
    /// 縦スクロールの読了位置書き込み。指が止まって 0.5 秒してから書く
    /// （スクロール中に毎フレーム `Library.setPage` を叩かない）。
    @State private var progressTask: Task<Void, Never>?
    @State private var pendingProgress: Int = -1
    /// スライダーから飛んだとき、縦スクロール側に「ここへ送れ」と伝える。
    @State private var scrollRequest: Int?

    private let verticalSpace = "pupil.reader.vertical"

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
                    mode: settings.readerModeValue,
                    fit: settings.readerFitValue,
                    spread: settings.readerSpreadValue,
                    direction: settings.readerDirectionValue,
                    onClose: { close() },
                    onSelectPage: { page in show(page: page) },
                    onToggleFavorite: { library.toggleFavorite(galleryID) },
                    onToggleReadLater: { library.toggleReadLater(galleryID) },
                    onSelectMode: { mode in settings.readerMode = mode.rawValue },
                    onSelectFit: { fit in settings.readerFit = fit.rawValue },
                    onSelectSpread: { spread in settings.readerSpread = spread.rawValue },
                    onSelectDirection: { direction in settings.readerDirection = direction.rawValue }
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
            prefetch(around: newValue)

            if settings.readerModeValue == .vertical {
                // 縦スクロールは指を止めている間も index が動き続けるので、
                // 落ち着いてから書く。
                scheduleProgressWrite(newValue)
            } else {
                library.setPage(newValue, for: galleryID)
            }
        }
        .onDisappear {
            progressTask?.cancel()
            progressTask = nil
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

    @ViewBuilder
    private var pages: some View {
        if settings.readerModeValue == .vertical {
            verticalPages
        } else {
            pagedPages
        }
    }

    // MARK: - ページ送り（単独 / 見開き）

    /// ページ index と表示スロットの対応。安いので持たずに毎回作る。
    private var spreadLayout: ReaderSpreadLayout {
        ReaderSpreadLayout(
            pageCount: pageURLs.count,
            spread: settings.readerSpreadValue,
            coverSingle: settings.readerCoverSingle,
            direction: settings.readerDirectionValue
        )
    }

    /// `TabView` の selection は **表示スロット**。ページ index との入れ替えは
    /// `ReaderSpreadLayout` に閉じ込めてある（右開きはここで反転する）。
    private var pageSelection: Binding<Int> {
        Binding(
            get: { spreadLayout.visualSlot(forReadingSlot: spreadLayout.slotForPage(currentIndex)) },
            set: { visual in
                let page = spreadLayout.pageForSlot(spreadLayout.readingSlot(forVisualSlot: visual))
                if page != currentIndex {
                    currentIndex = page
                }
            }
        )
    }

    private var pagedPages: some View {
        TabView(selection: pageSelection) {
            ForEach(0..<spreadLayout.slotCount, id: \.self) { visual in
                slotView(visual: visual)
                    .tag(visual)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func slotView(visual: Int) -> some View {
        let layout = spreadLayout
        let pages = layout.visualPages(forReadingSlot: layout.readingSlot(forVisualSlot: visual))

        // 見開き設定なら、1 ページしか無いスロット（表紙・最終ページが奇数）も
        // 見開きの寸法で出す。空き側は背景だけになるので、ページの大きさが
        // スロットごとに変わらない。
        if settings.readerSpreadValue == .double, pageURLs.count > 1 {
            doubleSlot(pages: pages)
        } else {
            singleSlot(page: pages.first ?? 0)
        }
    }

    @ViewBuilder
    private func singleSlot(page: Int) -> some View {
        ZStack {
            theme.background

            if pageURLs.indices.contains(page), let url = pageURLs[page] {
                ZoomablePageView(url: url, fit: settings.readerFitValue) {
                    toggleChrome()
                }
            } else {
                missingPageLabel
            }
        }
    }

    /// 見開き。左右に 1 枚ずつ、`fitScreen` 相当で高さを合わせる。
    ///
    /// ここではズームを持たない軽量ビューを使う。`ZoomablePageView` を 2 枚並べると
    /// pan/zoom が互いのジェスチャを奪い合うため。ダブルタップは
    /// 「見開き ⇄ 単独」に割り当ててある。
    private func doubleSlot(pages: [Int]) -> some View {
        GeometryReader { proxy in
            let box = CGSize(
                width: max(proxy.size.width / 2, 1),
                height: max(proxy.size.height, 1)
            )

            // 1 ページしか無いスロットは、空きを読み終わり側に置く。
            // 右開きなら左が空き（表紙は右）、左開きなら右が空き。
            let halves = spreadHalves(pages: pages, rtl: settings.readerDirectionValue == .rtl)

            HStack(spacing: 0) {
                ForEach(halves.indices, id: \.self) { index in
                    if let page = halves[index] {
                        spreadHalf(page: page, box: box)
                    } else {
                        theme.background
                            .frame(width: box.width, height: box.height)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// 見開きの左右 2 枠。`nil` は空きスロット（背景だけ敷く）。
    private func spreadHalves(pages: [Int], rtl: Bool) -> [Int?] {
        if pages.count > 1 {
            return pages.map { Optional($0) }
        }

        let only = pages.first ?? 0
        return rtl ? [nil, only] : [only, nil]
    }

    @ViewBuilder
    private func spreadHalf(page: Int, box: CGSize) -> some View {
        ZStack {
            theme.background

            if pageURLs.indices.contains(page), let url = pageURLs[page] {
                VerticalPageView(
                    url: url,
                    size: spreadPageSize(page: page, box: box),
                    onTap: { toggleChrome() },
                    onDoubleTap: { toggleSpread(selecting: page) }
                )
            } else {
                missingPageLabel
            }
        }
        .frame(width: box.width, height: box.height)
    }

    private func spreadPageSize(page: Int, box: CGSize) -> CGSize {
        let files = gallery?.info.fileList ?? []

        guard files.indices.contains(page) else { return box }

        let file = files[page]
        let image = CGSize(width: CGFloat(max(file.width, 1)), height: CGFloat(max(file.height, 1)))
        return ReaderFit.fitScreen.pageSize(for: image, in: box)
    }

    private var missingPageLabel: some View {
        Text("このページは読み込めませんでした")
            .font(theme.font(.caption))
            .foregroundColor(theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(theme.space(.lg))
    }

    /// 見開きのページをダブルタップしたら、そのページを保ったまま単独表示へ。
    private func toggleSpread(selecting page: Int) {
        if pageURLs.indices.contains(page), page != currentIndex {
            currentIndex = page
        }

        settings.readerSpread = (settings.readerSpreadValue == .double)
            ? ReaderSpread.single.rawValue
            : ReaderSpread.double.rawValue
    }

    // MARK: - 縦スクロール

    /// ページを縦に連続して並べる（webtoon）。
    ///
    /// `LazyVStack` なので画面外のページは作られない。読了位置は「いちばん
    /// 画面に映っているページ」を各ページの frame から拾って決め、書き込みだけを
    /// 0.5 秒デバウンスする（スクロール中にディスクを叩き続けない）。
    private var verticalPages: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(pageURLs.indices, id: \.self) { index in
                            verticalPage(index: index, viewport: outer.size)
                                .id(index)
                                .background(verticalFrameReader(index: index))
                        }
                    }
                }
                .coordinateSpace(name: verticalSpace)
                .onPreferenceChange(VisiblePageFrames.self) { frames in
                    updateVisiblePage(frames: frames, viewportHeight: outer.size.height)
                }
                .onAppear {
                    // 開いた瞬間は `LazyVStack` の行がまだ揃っていないので、
                    // 1 フレーム待ってから送る。
                    let target = currentIndex
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
                .onChange(of: scrollRequest) { request in
                    guard let target = request else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    scrollRequest = nil
                }
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func verticalPage(index: Int, viewport: CGSize) -> some View {
        let size = verticalPageSize(index: index, viewport: viewport)

        if pageURLs.indices.contains(index), let url = pageURLs[index] {
            VerticalPageView(
                url: url,
                size: size,
                onTap: { toggleChrome() },
                onDoubleTap: { settings.readerFit = settings.readerFitValue.next.rawValue }
            )
        } else {
            ZStack {
                theme.background

                missingPageLabel
            }
            .frame(width: max(size.width, 1), height: max(size.height, 1))
        }
    }

    /// ページの枠は画像の実寸（`GalleryFiles`）から決める。画像を読み込む前でも
    /// 高さが確定するので、スクロール中に行の高さが跳ねない。
    private func verticalPageSize(index: Int, viewport: CGSize) -> CGSize {
        let files = gallery?.info.fileList ?? []

        guard files.indices.contains(index), viewport.width > 1, viewport.height > 1 else {
            let width = max(viewport.width, 1)
            return CGSize(width: width, height: width * 1.4)
        }

        let file = files[index]
        let image = CGSize(width: CGFloat(max(file.width, 1)), height: CGFloat(max(file.height, 1)))
        var size = settings.readerFitValue.pageSize(for: image, in: viewport)

        // 縦スクロールは横に動かせない。`original` や `fitHeight` で画面幅を超える
        // ページは、横が切れて読めなくなるので幅に合わせて縮める。
        if size.width > viewport.width, size.width > 0 {
            let scale = viewport.width / size.width
            size = CGSize(width: viewport.width, height: max(size.height * scale, 1))
        }

        return size
    }

    private func verticalFrameReader(index: Int) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: VisiblePageFrames.self,
                value: [index: proxy.frame(in: .named(verticalSpace))]
            )
        }
    }

    /// いちばん画面に映っているページを読了位置にする。
    private func updateVisiblePage(frames: [Int: CGRect], viewportHeight: CGFloat) {
        guard isReady, settings.readerModeValue == .vertical, viewportHeight > 1, !frames.isEmpty else { return }

        // 横は画面幅いっぱいなので、縦の重なりだけで決めれば足りる。
        let viewport = CGRect(x: 0, y: 0, width: 1_000_000, height: viewportHeight)

        var best = currentIndex
        var bestOverlap: CGFloat = 0

        for (index, frame) in frames {
            let overlap = frame.intersection(viewport).height
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = index
            }
        }

        guard bestOverlap > 0, best != currentIndex, pageURLs.indices.contains(best) else { return }
        currentIndex = best
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        // この3行の順序は契約。まず `phase` を落としてページャごと画面から
        // 外し、そのあと配列を空にする。逆順にすると
        // 「`pageURLs` は空 / `currentIndex` はまだ 37」という瞬間ができ、
        // `TabView(selection:)` が範囲外の index を掴む。
        phase = .loading
        resolvedCount = 0
        pageURLs = []

        do {
            let loaded = try await HitomiClient.shared.gallery(galleryID)

            let files = loaded.info.fileList

            // 全ページ分を 1 ホップで。`pageURL` を 1 枚ずつ await すると、
            // ページ数の多い作品で 2000 回 actor を往復することになる。
            let urls = await HitomiClient.shared.pageURLs(galleryID, files: files, limit: files.count)
            resolvedCount = urls.count

            guard !urls.isEmpty else {
                phase = .failed("このギャラリーにはページがありません")
                return
            }

            // `gg.js` が落ちていると全ページ nil で返る。1 枚ずつ「読めません」と
            // 並べるより、リーダーごと再試行できる画面を出す。
            guard urls.contains(where: { $0 != nil }) else {
                phase = .failed("ページの URL を解決できませんでした")
                return
            }

            gallery = loaded
            pageURLs = urls

            // ここも順序が契約: 配列 → selection → `phase`。
            // `phase = .ready` を先にすると、`TabView` が古い/短い配列と
            // 新しい `currentIndex` の組み合わせで一瞬だけ構築される。
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

        // 縦スクロールは自分で送らないと index と表示位置がずれる。
        if settings.readerModeValue == .vertical {
            scrollRequest = index
        }
    }

    /// 縦スクロールの読了位置。指が止まって 0.5 秒してから 1 回だけ書く。
    private func scheduleProgressWrite(_ index: Int) {
        pendingProgress = index
        progressTask?.cancel()

        progressTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            if pendingProgress == index {
                library.setPage(index, for: galleryID)
            }
        }
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

/// 縦スクロールで、各ページがスクロール座標系のどこに居るかを集める。
/// 読了位置（いちばん画面に映っているページ）を出すためだけに使う。
private struct VisiblePageFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
