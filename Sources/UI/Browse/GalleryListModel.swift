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
    /// ロード中に来た「もっと読みたい」要求。完了時に 1 ページだけ再生する
    /// （セルの `onAppear` は高々 1 回しか来ないので、捨てると永久に止まる）。
    private var wantsMore: Bool = false

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
    ///
    /// **ロード中の要求を捨てない**: 初回ロードの直後は画面内の末尾セルが一斉に
    /// `onAppear` する。その瞬間 `loading == true` なので素通しで捨てると、
    /// そのセルは LazyVGrid に生かされたまま二度と `onAppear` せず、末尾しきい値に
    /// 誰も到達しないまま 24 件で止まる（実機で出た症状）。要求は `wantsMore` に
    /// 覚えておき、走っているロードの完了時に 1 回だけ再生する。
    func loadMoreIfNeeded(current: GalleryBlock?) async {
        guard let current = current else { return }
        guard !blocks.isEmpty, hasMore, errorMessage == nil else { return }
        guard let index = blocks.firstIndex(where: { $0.id == current.id }) else { return }
        let threshold = max(blocks.count - 6, 0)
        guard index >= threshold else { return }
        await requestMore()
    }

    /// グリッド末尾（＝画面下端が近づいた）から呼ぶ（`GalleryGrid`）。
    /// セル側のしきい値（末尾 6 件）が取りこぼされた場合の保険。
    func loadMoreIfNeededAtBottom() async {
        guard hasMore, errorMessage == nil else { return }
        // 1 枚も描画できていないうちは「下端」に意味がない（初回ロード中）。
        // ここで要求すると起動直後に 2 ページ目まで自動で取りに行ってしまう。
        guard !blocks.isEmpty else { return }
        await requestMore()
    }

    /// 1 ページぶんの要求。走っているロードがあれば「終わったらもう 1 ページ」と覚える。
    private func requestMore() async {
        if loading {
            wantsMore = true
            return
        }
        await loadPagesWhileWanted()
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
        wantsMore = false
    }

    private func loadNextPage() async {
        guard hasMore else { return }
        if loading {
            wantsMore = true
            return
        }
        await loadPagesWhileWanted()
    }

    /// 取りこぼした要求を 1 ページずつ消化する。1 回の呼び出しで最大 4 ページ。
    private func loadPagesWhileWanted() async {
        guard let current = source else { return }

        var rounds = 0
        while rounds < 4 {
            wantsMore = false
            let progressed = await loadPageOnce(source: current)
            rounds += 1

            if !progressed { break }        // 失敗 / 0 件。エラー面か空状態が出る
            if !wantsMore { break }         // 追加要求なし
            if !hasMore { break }           // 末尾に到達
        }
        wantsMore = false
    }

    /// 1 ページだけ読む。進んだら true（＝もう 1 ページ読む価値がある）。
    ///
    /// 429（レート制限）とカード全滅（gallery.js が 429/切断で落ちた場合が典型）は、
    /// 1 秒待って **1 回だけ**静かに取り直す。長距離スクロールでの体感を守りつつ、
    /// エラー面を出さずに済むケースを増やす。
    @discardableResult
    private func loadPageOnce(source current: GalleryListSource) async -> Bool {
        let gen = generation
        var retried = false

        while true {
            let beforeCount = blocks.count
            let beforePage = pageCount

            loading = true
            errorMessage = nil

            do {
                let ids = try await idsForNextPage(source: current)
                guard gen == generation else { return false }

                if ids.isEmpty {
                    hasMore = false
                    loading = false
                    return false
                }

                let fetched = await GalleryListModel.fetchBlocks(ids: ids)
                guard gen == generation else { return false }

                if fetched.isEmpty {
                    // ID は取れたのにカードが 1 枚も作れなかった（404 / 429 /
                    // タイムアウト / 切断）。ここで id を捨てるとそのページが
                    // 永久に欠番になるので、`pendingIDs` に戻して次の試行へ。
                    pendingIDs = ids

                    if !retried {
                        retried = true
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if Task.isCancelled || gen != generation {
                            loading = false
                            return false
                        }
                        continue
                    }

                    loading = false
                    errorMessage = "ギャラリー情報を取得できませんでした。通信状況を確認して再試行してください。"
                    return false
                }

                // `ForEach(blocks)` / `LazyVGrid` の id は GalleryBlock.id なので、
                // 同じ ID が 2 枚入ると描画が壊れる（SwiftUI の id 重複）。
                let known = Set(blocks.map { $0.id })
                let fresh = fetched.filter { !known.contains($0.id) }
                if !fresh.isEmpty {
                    blocks.append(contentsOf: fresh)
                }
                pageCount += 1
                loading = false

                // 重複だけで 1 件も増えなくても、ページは 1 つ進んだ（＝続きはある）。
                return blocks.count > beforeCount || pageCount > beforePage
            } catch {
                guard gen == generation else { return false }

                if Task.isCancelled || GalleryListModel.isCancellation(error) {
                    // タブ移動 / 条件変更で `.task` がキャンセルされただけ。
                    loading = false
                    return false
                }

                if !retried && GalleryListModel.isRateLimited(error) {
                    retried = true
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled || gen != generation {
                        loading = false
                        return false
                    }
                    continue
                }

                loading = false
                errorMessage = GalleryListModel.describe(error)
                return false
            }
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

        // 人気順の nozomi は同じ ID の重複や削除済み作品の ID を多く含むため、
        // 1 窓（60 件）が全部「既出」になることがある。そこで即打ち切ると
        // 「まだ続きがあるのに終了」になる（実機症状: 既定の人気順だけ数ページで
        // 止まり、追加日順だと長く続く）。連続で空窓が続いたときだけ打ち切る。
        var emptyWindows = 0

        while stagedIDs.count < needed && !remoteExhausted {
            let requestedOffset = remoteOffset
            let requestedCount = GalleryListModel.windowSize

            let window = try await HitomiClient.shared.nozomiWindow(
                args,
                sort,
                offset: requestedOffset,
                count: requestedCount
            )

            if window.ids.isEmpty {
                remoteExhausted = true
                break
            }

            remoteOffset += window.ids.count

            // `Content-Range` が無いときの `nozomiWindow` の total は
            // 「要求した offset + 件数」になる（＝末尾に見える）。この値で
            // 打ち切ると 1 ページで終わってしまうので、その場合は総数判定をしない。
            let totalLooksLikeFallback = window.total == requestedOffset + requestedCount
            if window.total > 0 {
                total = window.total
            }

            var added = 0
            for id in window.ids where !seenIDs.contains(id) {
                seenIDs.insert(id)
                stagedIDs.append(id)
                added += 1
            }

            // 要求より短い窓が返った＝ nozomi ファイルの末尾。
            let reachedEndOfFile = window.ids.count < requestedCount

            if added == 0 {
                emptyWindows += 1
                if reachedEndOfFile || emptyWindows >= 3 {
                    remoteExhausted = true
                    break
                }
                // `remoteOffset` は進んでいるので、次の窓を読みに行く。
                continue
            }
            emptyWindows = 0

            if reachedEndOfFile {
                remoteExhausted = true
            }

            // 総数に到達（Content-Range 由来の確かな total のときだけ）。
            if !totalLooksLikeFallback && total > 0 && remoteOffset >= total {
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

    /// 画面に出す文言。**英語や Cocoa の生メッセージは絶対に返さない**
    /// （実機で "RAW データをデコードできません" がそのまま出た）。詳細は NSLog に落とす。
    nonisolated static func describe(_ error: Error) -> String {
        NSLog("[Pupil] gallery list error: %@", String(describing: error))

        let nsError = error as NSError

        if let hitomi = error as? HitomiError {
            switch hitomi {
            case .badStatus(let code):
                switch code {
                case 403:
                    return "アクセスが拒否されました（HTTP 403）。しばらく待って再試行してください"
                case 404:
                    return "作品が見つかりません"
                case 429:
                    return "リクエストが多すぎます。少し待って再試行してください"
                case 500...599:
                    return "サーバーが混み合っています（HTTP \(code)）。少し待って再試行してください"
                default:
                    return "サーバーエラー（HTTP \(code)）"
                }
            case .malformed:
                return "作品データを読み込めませんでした（一時的な可能性があります）。再試行してください"
            case .badURL:
                return "作品情報を読み込めませんでした。通信状況を確認して再試行してください"
            }
        }

        if error is DecodingError {
            return "作品データを読み込めませんでした（一時的な可能性があります）。再試行してください"
        }

        // NSCocoaErrorDomain 4864 = NSFileReadCorruptFileError（壊れた RAW データ）
        if nsError.domain == NSCocoaErrorDomain && nsError.code == 4864 {
            return "作品データを読み込めませんでした（一時的な可能性があります）。再試行してください"
        }

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost:
                return "通信できませんでした。ネットワークを確認して再試行してください"
            default:
                break
            }
        }

        // ここから下は日本語の定型文のみ（`localizedDescription` は使わない）。
        return "作品情報を読み込めませんでした。通信状況を確認して再試行してください"
    }

    /// 429（レート制限）。長距離スクロールで実際に踏む。
    nonisolated static func isRateLimited(_ error: Error) -> Bool {
        if let hitomi = error as? HitomiError, case .badStatus(let code) = hitomi, code == 429 {
            return true
        }
        return false
    }
}
