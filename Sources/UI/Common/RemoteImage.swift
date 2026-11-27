import SwiftUI
import UIKit
import CryptoKit
import ImageIO

/// 画像の二段キャッシュ（メモリ `NSCache` + `Caches/PupilImageCache/` ディスク）。
///
/// hitomi の画像は `Referer` / ブラウザ UA が無いと **403** になるため、取得は必ず
/// `HitomiClient.imageData(_:)`（Referer/UA 付与済み・リトライ付き）を通す。
/// `AsyncImage` は Referer を付けられないので使わない。
///
/// 設計の要点（メモリ = jetsam 対策）:
/// - **メモリコストは「デコード後バイト数」で計上する**。圧縮後の `Data.count` を
///   cost にすると、800x12000 の縦長ページ（デコード後 約 38MB）が数百 KB と
///   計上され、`totalCostLimit` を 100 倍以上すり抜けて jetsam で kill される。
/// - **表示前に ImageIO でダウンサンプリングする**（`image(for:maxPixelSize:)`）。
///   `CGImageSourceCreateThumbnailAtIndex` は圧縮データから直接縮小ビットマップを
///   作るので、フル解像度のビットマップを一度も実メモリに載せない。
///   `UIImage.preparingThumbnail(of:)` はメインスレッド制約があるため使わない。
/// - ディスクには**圧縮データ（原本）を 1 部だけ**置き、解像度違いはメモリ側で分ける。
/// - ディスクは合計 512MB を上限に、最終更新の古い順で削除する。
final class ImageCache {
    static let shared = ImageCache()

    /// メモリ上限。**デコード後バイト**基準なので 128MB は実メモリ 128MB の意味。
    private let memory: NSCache<NSString, UIImage> = ImageCache.makeMemory()
    private let lock = NSLock()
    /// 同一キーの同時取得を 1 本に畳む。
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// ディスク整理のスロットル用（`lock` で保護）。
    private var lastDiskTrim: Date = Date.distantPast
    private let directory: URL
    private let fileManager = FileManager.default

    /// ディスクキャッシュの上限（圧縮データの合計）。
    static let diskLimitBytes: Int = 512 * 1024 * 1024

    /// 画面表示に使う画素上限（長辺）。既定 4096px。
    ///
    /// 現在の iPhone の長辺は約 2622px（3x）なので、これは約 1.5 倍の余裕を見た値。
    /// 800x12000 の縦長ページなら 273x4096 ≈ 4.5MB に収まる（フルなら 38MB）。
    /// 呼び出し側が `image(for:maxPixelSize:)` で明示指定すれば上書きできる。
    static var maxPixelSize: CGFloat = 4096

    private static func makeMemory() -> NSCache<NSString, UIImage> {
        let cache = NSCache<NSString, UIImage>()
        // 縦長ページは 1 枚 5MB 前後になるので、件数上限は控えめにする。
        cache.countLimit = 140
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base.appendingPathComponent("PupilImageCache", isDirectory: true)
        directory = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // MARK: - Keys

    /// URL 文字列の SHA256（小文字 16 進）。ディスクのファイル名に使う。
    static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { byte in String(format: "%02x", byte) }.joined()
    }

    /// メモリキャッシュのキー。**縮小解像度が違えば別エントリ**（混ぜない）。
    static func memoryKey(for url: URL, maxPixelSize: CGFloat?) -> String {
        let base = key(for: url)
        guard let maxPixelSize = maxPixelSize, maxPixelSize > 0 else { return base + "|full" }
        return base + "|" + String(Int(maxPixelSize.rounded()))
    }

    // MARK: - Public

    /// 既定の画素上限（`ImageCache.maxPixelSize`）で取得する。
    ///
    /// 画面表示用の入口。縦長ページでも実メモリを食い潰さないよう、
    /// 内部でダウンサンプリングしてから返す。
    func image(for url: URL) async -> UIImage? {
        await image(for: url, maxPixelSize: ImageCache.maxPixelSize)
    }

    /// 画素上限を指定して取得する。`nil` を渡すと**フル解像度**（保存・共有用）。
    func image(for url: URL, maxPixelSize: CGFloat?) async -> UIImage? {
        let key = ImageCache.memoryKey(for: url, maxPixelSize: maxPixelSize)

        if let hit = memory.object(forKey: key as NSString) { return hit }

        if let running = existingTask(key: key) {
            return await running.value
        }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let cache = self else { return nil }
            let loaded = await cache.load(url: url, maxPixelSize: maxPixelSize, key: key)
            cache.finish(key: key)
            return loaded
        }
        // check と register の間に await が無いので、競合しても最悪 1 枚を
        // 二重取得するだけ（メモリ/ディスクの結果は同じ）。ここでロックを
        // 取りっぱなしにすると Task 本体の finish() と競合するため、あえて
        // 2 段階の同期ヘルパで済ませている。
        register(task, key: key)
        return await task.value
    }

    /// フル解像度で取得する（保存・共有など、画素を落としたくない用途）。
    func fullImage(for url: URL) async -> UIImage? {
        await image(for: url, maxPixelSize: nil)
    }

    /// 先読み。既定の画素上限で温める。
    func prefetch(_ urls: [URL]) async {
        await prefetch(urls, maxPixelSize: ImageCache.maxPixelSize)
    }

    /// 先読み（画素上限指定）。結果は捨てるが、メモリ/ディスクに載る。
    func prefetch(_ urls: [URL], maxPixelSize: CGFloat?) async {
        for url in urls {
            _ = await image(for: url, maxPixelSize: maxPixelSize)
            if Task.isCancelled { return }
        }
    }

    /// メモリに載っている分だけを同期で返す（スクロール中のプレースホルダ抑制用）。
    func cachedImage(for url: URL) -> UIImage? {
        memory.object(forKey: ImageCache.memoryKey(for: url, maxPixelSize: ImageCache.maxPixelSize) as NSString)
    }

    /// 指定解像度でメモリに載っている分だけを同期で返す。
    func cachedImage(for url: URL, maxPixelSize: CGFloat?) -> UIImage? {
        memory.object(forKey: ImageCache.memoryKey(for: url, maxPixelSize: maxPixelSize) as NSString)
    }

    /// メモリとディスクの両方を捨てる。
    func clear() {
        memory.removeAllObjects()
        lock.lock()
        inFlight.removeAll()
        lock.unlock()
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Loading

    private func load(url: URL, maxPixelSize: CGFloat?, key: String) async -> UIImage? {
        // ディスクには圧縮データ（原本）を 1 部だけ持つ。
        let data: Data
        if let cached = diskData(url: url) {
            data = cached
        } else {
            do {
                let fetched = try await HitomiClient.shared.imageData(url)
                write(data: fetched, url: url)
                data = fetched
            } catch {
                return nil
            }
        }

        guard let image = ImageCache.decode(data: data, maxPixelSize: maxPixelSize) else { return nil }
        memory.setObject(image, forKey: key as NSString, cost: ImageCache.cost(of: image))
        return image
    }

    /// 圧縮データから `UIImage` を作る。`maxPixelSize` 指定時は ImageIO で縮小する
    /// （フル解像度のビットマップを経由しないので、縦長ページでもメモリが跳ねない）。
    private static func decode(data: Data, maxPixelSize: CGFloat?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }

        if let maxPixelSize = maxPixelSize, maxPixelSize > 0 {
            let side = Int(maxPixelSize.rounded())
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: cgImage)
            }
            // 縮小に失敗したらフル解像度で返す（表示はしたいので）。
        }

        // 縮小しない経路（`fullImage` / 保存・共有用）。EXIF 回転を保つため
        // `CGImageSourceCreateImageAtIndex` ではなく `UIImage(data:)` を使う
        // （デコードは描画時まで遅延する = 取り回しでメモリを張らない）。
        return UIImage(data: data)
    }

    /// デコード後の実バイト数。`CGImage` があれば行バイト×高さが最も正確。
    static func cost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            let bytes = cgImage.bytesPerRow * cgImage.height
            if bytes > 0 { return bytes }
        }
        let scale = max(image.scale, 1)
        let width = image.size.width * scale
        let height = image.size.height * scale
        let bytes = Int(width * height * 4)
        return max(bytes, 1)
    }

    private func finish(key: String) {
        lock.lock()
        defer { lock.unlock() }
        inFlight.removeValue(forKey: key)
    }

    // MARK: - In-flight map（同期メソッドの中だけでロックする）

    private func existingTask(key: String) -> Task<UIImage?, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return inFlight[key]
    }

    private func register(_ task: Task<UIImage?, Never>, key: String) {
        lock.lock()
        defer { lock.unlock() }
        inFlight[key] = task
    }

    // MARK: - Disk

    private func fileURL(key: String) -> URL {
        directory.appendingPathComponent(key, isDirectory: false).appendingPathExtension("img")
    }

    private func diskData(url: URL) -> Data? {
        try? Data(contentsOf: fileURL(key: ImageCache.key(for: url)))
    }

    private func write(data: Data, url: URL) {
        try? data.write(to: fileURL(key: ImageCache.key(for: url)), options: .atomic)

        // 上限超過の整理は 60 秒に 1 回まで（毎回ディレクトリを舐めない）。
        if shouldTrimDisk() {
            trimDiskCache()
        }
    }

    private func shouldTrimDisk() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(lastDiskTrim) < 60 { return false }
        lastDiskTrim = now
        return true
    }

    /// 合計が `diskLimitBytes` を超えていたら、最終更新の古い順に消す。
    private func trimDiskCache() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, date: Date, size: Int)] = []
        entries.reserveCapacity(urls.count)
        var total = 0

        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = values?.fileSize ?? 0
            let date = values?.contentModificationDate ?? Date.distantPast
            total += size
            entries.append((url, date, size))
        }

        if total <= ImageCache.diskLimitBytes { return }

        entries.sort { $0.date < $1.date }
        var remaining = total
        for entry in entries {
            if remaining <= ImageCache.diskLimitBytes { break }
            try? fileManager.removeItem(at: entry.url)
            remaining -= entry.size
        }
    }
}

/// Referer 付きで取得する画像ビュー。読み込み中は Astryx の surface 色の矩形、
/// 失敗時はプレースホルダのアイコンを出す。
struct RemoteImage: View {
    let url: URL?
    let contentMode: ContentMode

    @State private var image: UIImage?
    @State private var failed: Bool = false

    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
    }

    private var theme: AstryxTheme { AstryxTheme.shared }

    var body: some View {
        ZStack {
            theme.surface

            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 20))
                    .foregroundColor(theme.textSecondary)
            } else {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .clipped()
        .task(id: url) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        guard let url = url else {
            image = nil
            failed = true
            return
        }

        // 既にメモリに載っているなら待たずに差し替える（スクロールのちらつき防止）。
        if let cached = ImageCache.shared.cachedImage(for: url) {
            image = cached
            failed = false
            return
        }

        let loaded = await ImageCache.shared.image(for: url)
        // `.task(id: url)` は URL が変わるとキャンセルされる。キャンセル後に
        // 書き戻すと、別ギャラリーの表紙が一瞬出る（セル再利用の取り違え）。
        if Task.isCancelled { return }
        image = loaded
        failed = (loaded == nil)
    }
}
