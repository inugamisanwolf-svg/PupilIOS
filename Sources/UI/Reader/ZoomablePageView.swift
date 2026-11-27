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
/// recognisers meet on the same touch. At 1x this page has nothing to pan, and
/// if its pan began the page turn would stop working: `PanGate` refuses the pan
/// while the page is at its minimum zoom and lets the drag travel up to the
/// pager. Zoomed in, the pan is allowed and the page moves under the finger
/// instead of turning. The pinch recogniser is deliberately left alone, so
/// zooming never depends on that decision.
struct ZoomablePageView: UIViewRepresentable {
    let url: URL
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
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

    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let messageLabel = UILabel()
    private let panGate = PanGate()

    private let doubleTapZoom: CGFloat = 2.5
    private let maximumZoom: CGFloat = 4

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

        panGate.scrollView = self
        panGestureRecognizer.delegate = panGate

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
    }

    // MARK: - State

    func beginLoading() {
        imageView.image = nil
        messageLabel.isHidden = true
        setZoomScale(minimumZoomScale, animated: false)
        contentOffset = .zero
        contentInset = .zero
        contentSize = .zero
        spinner.startAnimating()
        setNeedsLayout()
    }

    func endLoading(image: UIImage?) {
        spinner.stopAnimating()

        guard let image = image, image.size.width > 0, image.size.height > 0 else {
            messageLabel.text = "このページを読み込めませんでした"
            messageLabel.isHidden = false
            setNeedsLayout()
            return
        }

        messageLabel.isHidden = true
        imageView.image = image
        setZoomScale(minimumZoomScale, animated: false)
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// 取得済みのページを、スピナーを出さずにそのまま置く。
    func show(image: UIImage) {
        spinner.stopAnimating()
        messageLabel.isHidden = true
        imageView.image = image
        setZoomScale(minimumZoomScale, animated: false)
        setNeedsLayout()
        layoutIfNeeded()
    }

    func resetToPlaceholder() {
        imageView.image = nil
        messageLabel.isHidden = true
        spinner.stopAnimating()
        setZoomScale(minimumZoomScale, animated: false)
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
        // it here would fight the zoom.
        guard zoomScale <= minimumZoomScale + 0.001 else { return }

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

        let target = min(doubleTapZoom, maximumZoom)
        let point = gesture.location(in: self)
        let width = bounds.width / target
        let height = bounds.height / target
        let rect = CGRect(
            x: point.x - width / 2,
            y: point.y - height / 2,
            width: max(width, 1),
            height: max(height, 1)
        )

        zoom(to: rect, animated: true)
    }
}

/// Decides whether the page's own pan may start.
///
/// A separate object rather than the scroll view itself: the scroll view already
/// carries `UIScrollViewDelegate` duties here, and keeping the gate apart leaves
/// nothing to reinterpret on the view's own gesture handling.
final class PanGate: NSObject, UIGestureRecognizerDelegate {
    weak var scrollView: UIScrollView?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let scrollView = scrollView else { return true }

        if gestureRecognizer === scrollView.panGestureRecognizer,
           scrollView.zoomScale <= scrollView.minimumZoomScale + 0.001 {
            return false
        }

        return true
    }
}
