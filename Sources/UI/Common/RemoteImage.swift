import SwiftUI
import UIKit
import CryptoKit

/// 画像の二段キャッシュ（メモリ `NSCache` + `Caches/PupilImageCache/` ディスク）。
///
/// hitomi の画像は `Referer` / ブラウザ UA が無いと **403** になるため、取得は必ず
/// `HitomiClient.imageData(_:)`（Referer/UA 付与済み・リトライ付き）を通す。
/// `AsyncImage` は Referer を付けられないので使わない。
///
/// キャッシュキーは URL 文字列の SHA256（16進 64 文字）。ディスク上のファイル名も同じ。
final class ImageCache {
    static let shared = ImageCache()

    /// メモリ上限。サムネイル 1 枚が概ね 30〜80KB なので 96MB で 1200 枚前後。
    private let memory: NSCache<NSString, UIImage> = ImageCache.makeMemory()
    private let lock = NSLock()
    /// 同一 URL の同時取得を 1 本に畳む（グリッドで同じ表紙が並ぶ場合の無駄打ち防止）。
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let directory: URL
    private let fileManager = FileManager.default

    private static func makeMemory() -> NSCache<NSString, UIImage> {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 96 * 1024 * 1024
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

    /// URL 文字列の SHA256（小文字 16 進）。メモリキーとファイル名の両方に使う。
    static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { byte in String(format: "%02x", byte) }.joined()
    }

    // MARK: - Public

    /// キャッシュ（メモリ → ディスク → ネットワーク）から 1 枚取り出す。
    /// 取得に失敗した場合は `nil`（呼び出し側でプレースホルダを出す）。
    ///
    /// `lock()` / `unlock()` は async 文脈では呼ばない（協調スレッドプールを
    /// 塞ぐため Swift 6 ではエラー）。ロックの取得は下の同期ヘルパに閉じ込めてある。
    func image(for url: URL) async -> UIImage? {
        let key = ImageCache.key(for: url)

        if let hit = memory.object(forKey: key as NSString) { return hit }

        if let running = existingTask(key: key) {
            return await running.value
        }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let cache = self else { return nil }
            let loaded = await cache.load(url: url, key: key)
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

    /// 先読み。結果は捨てるが、メモリ/ディスクに載るので後続の `image(for:)` が速い。
    func prefetch(_ urls: [URL]) async {
        for url in urls {
            _ = await image(for: url)
            if Task.isCancelled { return }
        }
    }

    /// メモリに載っている分だけを同期で返す（スクロール中のプレースホルダ抑制用）。
    func cachedImage(for url: URL) -> UIImage? {
        memory.object(forKey: ImageCache.key(for: url) as NSString)
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

    private func load(url: URL, key: String) async -> UIImage? {
        if let data = diskData(key: key), let image = UIImage(data: data) {
            memory.setObject(image, forKey: key as NSString, cost: data.count)
            return image
        }

        do {
            let data = try await HitomiClient.shared.imageData(url)
            guard let image = UIImage(data: data) else { return nil }
            memory.setObject(image, forKey: key as NSString, cost: data.count)
            write(data: data, key: key)
            return image
        } catch {
            return nil
        }
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

    private func diskData(key: String) -> Data? {
        try? Data(contentsOf: fileURL(key: key))
    }

    private func write(data: Data, key: String) {
        try? data.write(to: fileURL(key: key), options: .atomic)
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
        image = loaded
        failed = (loaded == nil)
    }
}
