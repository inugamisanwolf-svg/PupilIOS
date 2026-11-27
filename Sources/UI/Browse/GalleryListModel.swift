import Foundation
import SwiftUI

/// 一覧が何を並べるか。ブラウズ（nozomi の窓読み）、検索（ID 配列）、ID 直指定
/// （お気に入り / 履歴）の 3 種類。
enum GalleryListSource: Equatable {
    case browse(sort: SortMode, language: String)
    case search(text: String, sort: SortMode)
    case ids([Int])
}

/// ギャラリー一覧のページングと並列取得。
///
/// - ブラウズ: `nozomiWindow` を 60 件ずつ先読みして `perPage` 単位でカード化する。
///   総数は `nozomiWindow` の `total`（Content-Range 由来）。
/// - 検索: `search(...)` が返す ID 配列をローカルでページングする（順位付きの並びを保つ）。
/// - IDs: お気に入り / 履歴の配列をそのままページングする。
///
/// カードは TaskGroup で並列取得するが、`blocks` には必ず ID の順で積む。
/// 取得の世代（`generation`）が変わった結果は捨てるので、`refresh()` や
/// 条件変更と競合しても古いページが混ざらない。
@MainActor
final class GalleryListModel: ObservableObject {

    @Published private(set) var blocks: [GalleryBlock] = []
    @Published private(set) var loading: Bool = false
    @Published private(set) var errorMessage: String?
    /// 読み込み完了したページ数（0 始まりのページ番号 + 1）。
    @Published private(set) var pageCount: Int = 0
    /// 一覧の総件数（ブラウズは nozomi の総数、検索 / IDs は ID 配列の長さ）。
    @Published private(set) var total: Int = 0
    @Published private(set) var hasMore: Bool = true

    /// nozomi から一度に先読みする件数。
    static let windowSize: Int = 60

    private var source: GalleryListSource?
    private var perPage: Int = 24
    private var generation: Int = 0

    /// サーバから取ったが、まだカード化していない ID のキュー。
    private var stagedIDs: [Int] = []
    /// nozomi の読み出し位置（件数）。
    private var remoteOffset: Int = 0
    private var remoteExhausted: Bool = false
    /// 検索 / IDs の全 ID 配列。一度だけ解決する。
    private var plannedIDs: [Int] = []
    private var plannedReady: Bool = false
    private var seenIDs: Set<Int> = []
    /// 取得に失敗したページの ID。次の試行でこの窓から取り直す
    /// （そのまま捨てると、失敗したページの ID が二度と出てこない）。
    private var pendingIDs: [Int] = []

    // MARK: - 状態

    var showsEmptyState: Bool {
        blocks.isEmpty && !loading && errorMessage == nil && !hasMore
    }

    var progressLabel: String {
        if total > 0 { return "\(blocks.count) / \(total) 件" }
        return "\(blocks.count) 件"
    }

    // MARK: - 入口

    func configure(source: GalleryListSource, perPage: Int) {
        self.source = source
        self.perPage = max(perPage, 1)
        reset()
    }

    /// View の `.task(id:)` から呼ぶ想定。同じ条件で既に表示済みなら何もしない
    /// （タブ切り替えで `task` が再実行されてもスクロール位置と一覧を保つ）。
    func configureAndStart(source: GalleryListSource, perPage: Int) async {
        let page = max(perPage, 1)
        if self.source == source && self.perPage == page && !blocks.isEmpty {
            return
        }
        configure(source: source, perPage: page)
        await start()
    }

    func start() async {
        guard !loading else { return }
        guard blocks.isEmpty, errorMessage == nil else { return }
        await loadNextPage()
    }

    /// 引っ張って更新。ブラウズは hitomi 側の index/version を取り直してから先頭から読み直す。
    func refresh() async {
        if let current = source, case .browse = current {
            await HitomiClient.shared.invalidateCaches()
        }
        reset()
        await loadNextPage()
    }

    /// インラインのエラー表示から再試行する。
    func retry() async {
        guard !loading else { return }
        errorMessage = nil
        await loadNextPage()
    }

    /// 無限スクロール。末尾から 6 件以内に入ったカードで次のページを要求する。
    func loadMoreIfNeeded(current: GalleryBlock?) async {
        guard let current = current else { return }
        guard !loading, errorMessage == nil, hasMore, !blocks.isEmpty else { return }
        guard let index = blocks.firstIndex(where: { $0.id == current.id }) else { return }
        let threshold = max(blocks.count - 6, 0)
        if index >= threshold {
            await loadNextPage()
        }
    }

    // MARK: - ページ読み込み

    private func reset() {
        generation += 1
        blocks = []
        stagedIDs = []
        seenIDs = []
        pendingIDs = []
        remoteOffset = 0
        remoteExhausted = false
        plannedIDs = []
        plannedReady = false
        pageCount = 0
        total = 0
        errorMessage = nil
        loading = false
        hasMore = true
    }

    private func loadNextPage() async {
        guard let current = source else { return }
        guard !loading, hasMore else { return }

        let gen = generation
        loading = true
        errorMessage = nil

        do {
            let ids = try await idsForNextPage(source: current)
            guard gen == generation else { return }

            if ids.isEmpty {
                hasMore = false
                loading = false
                return
            }

            let fetched = await GalleryListModel.fetchBlocks(ids: ids)
            guard gen == generation else { return }

            if fetched.isEmpty {
                // ID は取れたのにカードが 1 枚も作れなかった（404 / 429 /
                // タイムアウト / 切断）。ここで id を捨てるとそのページが
                // 永久に欠番になるので、次の試行に回して止める。
                // 空のまま `pageCount` を進めると、末尾のカードが現れないので
                // onAppear も発火せず、無言で止まったままになる。
                pendingIDs = ids
                errorMessage = "ギャラリー情報を取得できませんでした。通信状況を確認して再試行してください。"
                loading = false
                return
            }

            // `ForEach(blocks)` / `LazyVGrid` の id は GalleryBlock.id なので、
            // 同じ ID が 2 枚入ると描画が壊れる（SwiftUI の id 重複）。
            // 供給側で落とせない経路（検索結果の重複など）に備えてここでも弾く。
            let known = Set(blocks.map { $0.id })
            let fresh = fetched.filter { !known.contains($0.id) }
            if !fresh.isEmpty {
                blocks.append(contentsOf: fresh)
            }
            pageCount += 1
            loading = false
        } catch {
            guard gen == generation else { return }
            loading = false
            if Task.isCancelled || GalleryListModel.isCancellation(error) {
                // タブ移動 / 条件変更で `.task` がキャンセルされただけ。
                // エラー面を出すと、戻ってきたときに一覧が「失敗」のまま残る。
                return
            }
            errorMessage = GalleryListModel.describe(error)
        }
    }

    /// キャンセルは失敗ではない（`URLSession` は `URLError(.cancelled)` を投げる）。
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func idsForNextPage(source: GalleryListSource) async throws -> [Int] {
        // 前回カード化に失敗した窓を先に消化する（順序を保ったまま取り直す）。
        if !pendingIDs.isEmpty {
            let retry = pendingIDs
            pendingIDs = []
            return retry
        }

        switch source {
        case .browse(let sort, let language):
            try await fillStaged(sort: sort, language: language, needed: perPage)
            return takeStaged()

        case .search(let text, let sort):
            if !plannedReady {
                let context = Library.shared.searchContext
                let ids = try await HitomiClient.shared.search(text, sort: sort, context: context)
                plannedIDs = ids
                plannedReady = true
                total = ids.count
            }
            return takePlanned()

        case .ids(let ids):
            if !plannedReady {
                plannedIDs = ids
                plannedReady = true
                total = ids.count
            }
            return takePlanned()
        }
    }

    // MARK: - ブラウズ（nozomi の窓読み）

    private func fillStaged(sort: SortMode, language: String, needed: Int) async throws {
        let args = SearchArgs(area: "all", tag: "index", language: language)

        while stagedIDs.count < needed && !remoteExhausted {
            let window = try await HitomiClient.shared.nozomiWindow(
                args,
                sort,
                offset: remoteOffset,
                count: GalleryListModel.windowSize
            )

            if window.ids.isEmpty {
                remoteExhausted = true
                break
            }

            remoteOffset += window.ids.count
            if window.total > 0 {
                total = window.total
            }

            var added = 0
            for id in window.ids where !seenIDs.contains(id) {
                seenIDs.insert(id)
                stagedIDs.append(id)
                added += 1
            }

            // 新しい ID が 1 件も増えない窓は、nozomi 側がずれている
            // （＝これ以上先へ進んでも同じものが返る）。回り続けないよう打ち切る。
            if added == 0 {
                remoteExhausted = true
                break
            }

            if window.ids.count < GalleryListModel.windowSize {
                remoteExhausted = true
            }
        }
    }

    private func takeStaged() -> [Int] {
        let take = min(perPage, stagedIDs.count)
        if take <= 0 {
            hasMore = false
            return []
        }

        let page = Array(stagedIDs.prefix(take))
        stagedIDs.removeFirst(take)
        hasMore = !(remoteExhausted && stagedIDs.isEmpty)
        return page
    }

    // MARK: - 検索 / IDs（ローカルページング）

    private func takePlanned() -> [Int] {
        let from = pageCount * perPage
        if from >= plannedIDs.count {
            hasMore = false
            return []
        }

        let to = min(from + perPage, plannedIDs.count)
        hasMore = to < plannedIDs.count
        return Array(plannedIDs[from..<to])
    }

    // MARK: - カード取得

    /// ページ分の `GalleryBlock` を並列取得し、**ID の順**で返す。
    /// 取得できなかった ID は落とす（一覧に穴を開けない）。
    ///
    /// 実際の並列数は `HitomiClient.galleryBlocks(_:)` 側の同時 6 に抑えられている
    /// （1 枚ごとに gallery.js ＋ サムネ URL 解決が走るため、無制限だと叩きすぎる）。
    nonisolated static func fetchBlocks(ids: [Int]) async -> [GalleryBlock] {
        let unique = GalleryListModel.uniqueIDs(ids)
        if unique.isEmpty { return [] }
        return await HitomiClient.shared.galleryBlocks(unique)
    }

    nonisolated static func uniqueIDs(_ ids: [Int]) -> [Int] {
        var seen: Set<Int> = []
        var out: [Int] = []
        out.reserveCapacity(ids.count)
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            out.append(id)
        }
        return out
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let hitomi = error as? HitomiError {
            switch hitomi {
            case .badStatus(let code): return "サーバーエラー（HTTP \(code)）"
            case .malformed(let what): return "応答を解釈できませんでした（\(what)）"
            case .badURL(let what): return "URL が不正です（\(what)）"
            }
        }
        return error.localizedDescription
    }
}
