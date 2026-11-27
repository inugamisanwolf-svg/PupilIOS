import SwiftUI
import UIKit

/// One reader page.
///
/// The page is a `UIScrollView` holding the image, so pinch, pan and the pinch
/// anchor are the system's own behaviour instead of a re-implementation: 1x to
/// 4x, a double tap toggling between 1x and 2.5x, and a single tap reported to
/// the reader so it can show or hide its bars.
///
/// The reader is a paging `TabView`, which is a scroll view too, so two pan
/// recognisers meet on the same touch. At 1x this page has nothing to pan, and if
/// its pan claimed the drag the page turn would stop working: at fit scale the
/// page's pan is narrowed to two fingers, so a one-finger drag travels up to the
/// pager, and zoomed in one finger pans the page instead of turning it.
///
/// The pan is never disabled and its delegate is never reassigned. Reassigning
/// the delegate throws ("UIScrollView's built-in pan gesture recognizer must have
/// its scroll view as its delegate"), and leaving the recogniser enabled at all
/// times keeps the zoom engine untouched: zooming is driven by
/// `pinchGestureRecognizer`, which nothing here modifies, so "can this page
/// zoom" never depends on the page-turn decision.
struct ZoomablePageView: UIViewRepresentable {
    let url: URL
    /// 最初に見せる大きさ。`minimumZoomScale`（＝画面に合わせた状態）は動かさない
    /// ので、fitWidth などで開いてもピンチで 1.0 まで戻せばページ送りが効く。
    let fit: ReaderFit
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.imageFit = fit
        view.tapHandler = { [weak coordinator = context.coordinator] in
            coordinator?.tap()
        }
        context.coordinator.onTap = onTap
        context.coordinator.attach(view: view, url: url)
        return view
    }

    func updateUIView(_ uiView: ZoomScrollView, context: Context) {
        uiView.tapHandler = { [weak coordinator = context.coordinator] in
            coordinator?.tap()
        }
        context.coordinator.onTap = onTap

        if uiView.imageFit != fit {
            uiView.imageFit = fit
            uiView.applyCurrentFit()
        }

        context.coordinator.attach(view: uiView, url: url)
    }

    static func dismantleUIView(_ uiView: ZoomScrollView, coordinator: Coordinator) {
        coordinator.detach()
        uiView.resetToPlaceholder()
    }

    /// Owns the image request for one page.
    ///
    /// The image comes from the app-wide cache the grids and the detail screen
    /// use, so a page the reader prefetched is already awaiting nothing by the
    /// time it is shown.
    final class Coordinator {
        var onTap: () -> Void = {}

        private weak var view: ZoomScrollView?
        private var key: String?
        private var task: Task<Void, Never>?

        func tap() {
            onTap()
        }

        func attach(view: ZoomScrollView, url: URL) {
            self.view = view

            let newKey = url.absoluteString
            guard key != newKey else { return }
            key = newKey

            task?.cancel()

            // メモリに載っているページ（戻りスワイプ、先読み済みの隣）は待たずに出す。
            // ここで一度スピナーを出してから差し替えると、ページ送りのたびに点滅する。
            if let cached = ImageCache.shared.cachedImage(for: url) {
                view.show(image: cached)
                return
            }

            view.beginLoading()

            task = Task { @MainActor in
                let image = await ImageCache.shared.image(for: url)
                if Task.isCancelled { return }
                view.endLoading(image: image)
            }
        }

        func detach() {
            task?.cancel()
            task = nil
            view = nil
            key = nil
        }
    }
}

/// The scroll view a page lives in.
///
/// The image view is fitted to the page's own aspect ratio rather than stretched
/// over the screen, so zooming in lands on the artwork instead of on letterbox
/// bars, and the scroll view keeps whatever it is showing centred.
final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var tapHandler: (() -> Void)?

    /// 最初に見せる大きさ。画像が届いた時点で倍率として適用する。
    var imageFit: ReaderFit = .fitScreen

    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let messageLabel = UILabel()

    private let doubleTapZoom: CGFloat = 2.5
    /// 通常の上限。`original` のようにこれを超える倍率が要る場合は、画像が届いた
    /// 時点で `applyInitialZoom` が上限だけ引き上げる（下限は 1 のまま）。
    private let maximumZoom: CGFloat = 4

    /// True while a pinch is running or a zoomed page is settling.
    ///
    /// Deliberately *not* named `isZooming`: `UIScrollView` already has a
    /// read-only `isZooming` (true only until the pinch ends, so it is false
    /// during the deceleration that follows). Keeping our own flag under a
    /// different name means the two can never be confused.
    private var isUserZooming = false

    /// 画像が届いたとき bounds がまだ 0 で、fit の倍率を適用できなかった。
    /// 次のレイアウトで 1 回だけやり直す。
    private var pendingFitApplication = false

    /// True when the page is showing at its fitted size, so nothing is off screen
    /// to pan to.
    private var isAtFitScale: Bool { zoomScale <= minimumZoomScale + 0.001 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    // MARK: - Setup

    private func setUp() {
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bounces = false
        bouncesZoom = true
        decelerationRate = .fast
        minimumZoomScale = 1
        maximumZoomScale = maximumZoom
        zoomScale = 1
        contentInsetAdjustmentBehavior = .never
        isMultipleTouchEnabled = true
        delegate = self

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)

        spinner.hidesWhenStopped = true
        spinner.color = .secondaryLabel
        addSubview(spinner)

        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        messageLabel.textColor = .secondaryLabel
        messageLabel.isHidden = true
        addSubview(messageLabel)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        updatePanAvailability()
    }

    /// Keeps a one-finger drag out of the page while there is nothing to pan to.
    ///
    /// At fit scale the page has nothing off screen, and a scroll view that keeps
    /// its one-finger pan would swallow the horizontal drag the reader turns pages
    /// with. Narrowing the pan to two fingers is the cheapest way to hand that drag
    /// up to the pager: the recogniser stays enabled, so nothing about the zoom
    /// engine changes (a different delegate throws, and overriding
    /// `gestureRecognizerShouldBegin` is unreachable because the scroll view's
    /// conformance to `UIGestureRecognizerDelegate` is private).
    ///
    /// Two fingers still pan at fit scale, but `contentSize` equals the fitted
    /// image, so there is nothing for them to move.
    ///
    /// This is the documented knob for exactly this job: UIKit exposes a scroll
    /// view's `panGestureRecognizer` so a client "can more precisely control which
    /// pan gestures are recognized by the scroll view", and
    /// `UIPanGestureRecognizer.minimumNumberOfTouches` is a plain settable `Int`
    /// (default `1`) with no scroll-view-specific restriction. Only the *delegate*
    /// is off limits -- UIKit kills the process for that. `maximumNumberOfTouches`
    /// is deliberately left alone: it defaults to `NSUIntegerMax`, so a minimum of
    /// two is already inside the allowed window.
    private func updatePanAvailability() {
        let touches = (isUserZooming || !isAtFitScale) ? 1 : 2

        if panGestureRecognizer.minimumNumberOfTouches != touches {
            panGestureRecognizer.minimumNumberOfTouches = touches
        }

        // 無効化はしない。過去に無効化していた状態が残っていても必ず戻す。
        if !panGestureRecognizer.isEnabled {
            panGestureRecognizer.isEnabled = true
        }
    }

    /// A pinch that gets interrupted (a call arrives, the app is backgrounded, the
    /// page is recycled mid-gesture) can end without `scrollViewDidEndZooming`, and
    /// a stranded `isUserZooming` would keep the pan on one finger at fit scale --
    /// the page would then swallow the swipe the pager needs and the reader would
    /// look frozen, with no crash to show for it. A view arriving in a window has
    /// no gesture in flight, so that is where the flag is cleared.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        isUserZooming = false
        updatePanAvailability()
    }

    // MARK: - State

    func beginLoading() {
        imageView.image = nil
        messageLabel.isHidden = true
        // ここから先は「別のページ」なので、ピンチ状態は引き継がない。
        // プログラムからの `setZoomScale` が `willBeginZooming` だけ呼んで
        // `didEndZooming` を呼ばない経路があっても、フラグは必ず戻す。
        isUserZooming = false
        pendingFitApplication = false
        setZoomScale(minimumZoomScale, animated: false)
        contentOffset = .zero
        contentInset = .zero
        contentSize = .zero
        spinner.startAnimating()
        updatePanAvailability()
        setNeedsLayout()
    }

    func endLoading(image: UIImage?) {
        spinner.stopAnimating()
        isUserZooming = false

        guard let image = image, image.size.width > 0, image.size.height > 0 else {
            messageLabel.text = "このページを読み込めませんでした"
            messageLabel.isHidden = false
            setNeedsLayout()
            return
        }

        messageLabel.isHidden = true
        imageView.image = image
        setZoomScale(minimumZoomScale, animated: false)
        updatePanAvailability()
        setNeedsLayout()
        layoutIfNeeded()
        applyInitialZoom()
    }

    /// 取得済みのページを、スピナーを出さずにそのまま置く。
    func show(image: UIImage) {
        spinner.stopAnimating()
        messageLabel.isHidden = true
        isUserZooming = false
        imageView.image = image
        setZoomScale(minimumZoomScale, animated: false)
        updatePanAvailability()
        setNeedsLayout()
        layoutIfNeeded()
        applyInitialZoom()
    }

    /// 設定の「大きさ」が変わったときに、今の画像へ適用し直す。
    func applyCurrentFit() {
        layoutIfNeeded()
        applyInitialZoom()
    }

    /// 画像と枠が揃った時点で、`imageFit` の倍率へ寄せる。
    ///
    /// ここで上げるのは `zoomScale` だけで、`minimumZoomScale` は 1（画面に
    /// 合わせた状態）のままにしてある。だから fitWidth などで開いても、ピンチで
    /// 1.0 まで戻せばページ送りのスワイプが効く状態に必ず戻れる。
    private func applyInitialZoom() {
        guard let image = imageView.image else { return }

        let box = bounds.size
        guard box.width > 1, box.height > 1 else {
            // まだレイアウトされていない（bounds が 0）。このまま諦めると
            // fitWidth で開いても画面に合わせた倍率のままになるので、
            // 次のレイアウトでやり直す。
            pendingFitApplication = true
            return
        }

        pendingFitApplication = false

        let target = imageFit.initialZoomScale(for: image.size, in: box)

        // 上限は target を下回らないように広げる（原寸が 4 倍を超える画像がある）。
        let ceiling = max(maximumZoom, target)
        if abs(maximumZoomScale - ceiling) > 0.001 {
            maximumZoomScale = ceiling
        }

        let clamped = min(max(target, minimumZoomScale), maximumZoomScale)
        if abs(zoomScale - clamped) > 0.001 {
            setZoomScale(clamped, animated: false)
        }

        updatePanAvailability()
    }

    func resetToPlaceholder() {
        imageView.image = nil
        messageLabel.isHidden = true
        spinner.stopAnimating()
        isUserZooming = false
        setZoomScale(minimumZoomScale, animated: false)
        updatePanAvailability()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }

        // The placeholder is a subview, so it moves with the content: centre it on
        // what the screen is showing rather than on the content's origin.
        let centre = CGPoint(x: contentOffset.x + size.width / 2, y: contentOffset.y + size.height / 2)
        spinner.center = centre
        messageLabel.frame = CGRect(
            x: contentOffset.x + 24,
            y: centre.y + 28,
            width: max(size.width - 48, 1),
            height: 64
        )

        // While zoomed the scroll view drives the image view's geometry; refitting
        // it here would fight the zoom. The same is true while the zoom engine is
        // still animating: a pinch that dips under 1x (bouncesZoom) passes the
        // `zoomScale` test below with the zoom engine mid-transform, and writing
        // `transform = .identity` + `frame` then would tear the page. `isZooming`
        // and `isZoomBouncing` are the scroll view's own read-only flags for that
        // state, so neither can drift the way a hand-rolled flag can.
        guard !isZooming, !isZoomBouncing, zoomScale <= minimumZoomScale + 0.001 else { return }

        let fitted = fittedSize(for: imageView.image?.size ?? .zero, in: size)
        if abs(imageView.bounds.width - fitted.width) > 0.5 || abs(imageView.bounds.height - fitted.height) > 0.5 {
            imageView.transform = .identity
            imageView.frame = CGRect(origin: .zero, size: fitted)
        }

        // 変化した時だけ書く。`layoutSubviews` の中で無条件に contentSize /
        // contentInset を書き換えると、その書き換えがまたレイアウトを要求して
        // ループする。
        if contentSize != fitted {
            contentSize = fitted
        }

        let insets = UIEdgeInsets(
            top: max(0, (size.height - fitted.height) / 2),
            left: max(0, (size.width - fitted.width) / 2),
            bottom: 0,
            right: 0
        )
        if contentInset != insets {
            contentInset = insets
        }

        // 画像が届いた時点でレイアウトが済んでいなかったページの fit を、
        // ここで 1 回だけ適用する（適用後はフラグが落ちるのでループしない）。
        if pendingFitApplication {
            applyInitialZoom()
        }

        updatePanAvailability()
    }

    private func fittedSize(for imageSize: CGSize, in box: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return box }

        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        return CGSize(
            width: max(imageSize.width * scale, 1),
            height: max(imageSize.height * scale, 1)
        )
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let size = bounds.size
        let content = contentSize
        let left = max(0, (size.width - content.width) / 2)
        let top = max(0, (size.height - content.height) / 2)

        if contentInset.left != left || contentInset.top != top {
            contentInset = UIEdgeInsets(top: top, left: left, bottom: 0, right: 0)
        }

        updatePanAvailability()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        isUserZooming = true
        updatePanAvailability()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        isUserZooming = false
        updatePanAvailability()

        // ズームが落ち着いたら refit を1回だけ通す。`layoutSubviews` は
        // ズーム中（`isZooming` / `isZoomBouncing`）に refit を止めるので、
        // ここで一度レイアウトを要求しないと「回転やインセット変更をまたいだ
        // ズーム戻し」のあと画像が古いサイズのまま残りうる。
        // ループしないのは、これがズーム終了時に1回しか来ないから。
        setNeedsLayout()
    }

    // MARK: - Gestures

    @objc private func handleSingleTap() {
        tapHandler?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.001 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }

        // 画像がまだ無い / レイアウト前のページで倍率だけ上げると、
        // `layoutSubviews` の refit も `zoomScale > minimum` の分岐で止まる。
        // その結果「何も無いのに 1 本指 pan がスワイプを飲む」状態になり、
        // ページ送りだけが死ぬ（クラッシュしないので気付きにくい）。倍率は上げない。
        guard imageView.image != nil else { return }

        let box = bounds.size
        guard box.width > 1, box.height > 1 else { return }
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        let target = min(max(doubleTapZoom, minimumZoomScale), maximumZoomScale)
        guard target > minimumZoomScale + 0.001 else { return }

        // `zoom(to:)` は「この矩形が bounds いっぱいに広がる倍率」を計算するので、
        // 矩形の大きさは `bounds / target` でなければ狙った倍率にならない。
        // 位置だけは content 座標（= `imageView` の座標系。fit 倍率では frame の
        // origin が .zero なのでそのまま content 座標になる）で作る。`self` 座標で
        // 作ると `contentInset` のオフセット分だけ狙った場所からずれる。
        let width = box.width / target
        let height = box.height / target
        let point = gesture.location(in: imageView)
        let rect = CGRect(
            x: point.x - width / 2,
            y: point.y - height / 2,
            width: max(width, 1),
            height: max(height, 1)
        )

        zoom(to: rect, animated: true)
    }
}
