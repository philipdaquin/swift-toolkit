//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared
import UIKit

enum PageLocation: Equatable {
    case start
    case end
    case locator(Locator)

    init(_ locator: Locator?) {
        self = locator.map { .locator($0) }
            ?? .start
    }

    var isStart: Bool {
        switch self {
        case .start:
            return true
        case let .locator(locator) where locator.locations.progression ?? 0 == 0:
            return true
        default:
            return false
        }
    }
}

protocol PageView {
    /// Moves the page to the given internal location.
    func go(to location: PageLocation) async

    /// Scroll view showing the page content, driven by the pagination view in
    /// continuous mode.
    var pageScrollView: UIScrollView? { get }

    /// Height of the page content, when it may be shorter than the viewport.
    func measureContentHeight() async -> CGFloat?
}

extension PageView {
    var pageScrollView: UIScrollView? { nil }
    func measureContentHeight() async -> CGFloat? { nil }
}

protocol PaginationViewDelegate: AnyObject {
    /// Creates the page view for the page at given index.
    func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (UIView & PageView)?

    /// Called when the page views were updated.
    func paginationViewDidUpdateViews(_ paginationView: PaginationView)

    /// Returns the number of positions (as in `Publication.positionList`) in the page view at given index.
    func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int
}

final class PaginationView: UIView, Loggable {
    weak var delegate: PaginationViewDelegate?

    /// Total number of page views to be paginated.
    private(set) var pageCount: Int = 0

    /// Index of the page currently being displayed.
    private(set) var currentIndex: Int = 0

    /// Direction for the reading progression.
    private(set) var readingProgression: ReadingProgression = .ltr

    /// Pre-loaded page views, indexed by their position.
    private(set) var loadedViews: [Int: UIView & PageView] = [:]

    /// Number of positions (as in `Publication.positionList`) to preload before and after the
    /// current page.
    private let preloadPreviousPositionCount: Int
    private let preloadNextPositionCount: Int

    /// Queue of page index to be loaded next.
    private var loadingIndexQueue: [(index: Int, location: PageLocation?)] = []

    /// Returns whether the page views are loaded.
    var isEmpty: Bool {
        loadedViews.isEmpty
    }

    /// Return the currently presented page view from the Views array.
    var currentView: (UIView & PageView)? {
        loadedViews[currentIndex]
    }

    /// Loaded page views in reading order.
    private var orderedViews: [UIView & PageView] {
        var orderedViews = loadedViews
            .sorted { $0.key < $1.key }
            .map(\.value)

        if readingProgression == .rtl {
            orderedViews.reverse()
        }

        return orderedViews
    }

    private let scrollView = UIScrollView()

    /// Allows the scroll view to scroll.
    var isScrollEnabled: Bool {
        didSet { scrollView.isScrollEnabled = isScrollEnabled }
    }

    // MARK: Continuous scroll state

    /// When true, the pages form one vertical scroll: `scrollView` spans the
    /// whole publication, and each page view stays pinned to the screen while
    /// its own content offset moves underneath. Each web view therefore stays
    /// viewport-sized and scrolls normally from the point of view of its
    /// scripts. See https://oleb.net/blog/2014/05/scrollviews-inside-scrollviews/
    var isContinuous = false {
        didSet {
            guard isContinuous != oldValue else { return }
            scrollView.isPagingEnabled = !isContinuous
            scrollView.bounces = isContinuous
            scrollView.alwaysBounceVertical = isContinuous
            scrollView.showsVerticalScrollIndicator = false
            if !isContinuous {
                scrollView.contentInset = .zero
                scrollView.contentOffset = .zero
            }
            resetContinuousState()
            setNeedsLayout()
        }
    }

    /// Space around the whole publication in continuous mode.
    var continuousContentInset: (() -> UIEdgeInsets)?

    /// Space between two pages in continuous mode.
    private let continuousPageGap: CGFloat = 48
    /// Estimated height of a position until a page has been measured.
    private let estimatedPositionHeight: CGFloat = 640

    private var measuredHeights: [Int: CGFloat] = [:]
    private var pageOrigins: [CGFloat] = []
    private var pageObservations: [Int: [NSKeyValueObservation]] = [:]
    private var isApplyingContinuousLayout = false

    init(
        frame: CGRect,
        preloadPreviousPositionCount: Int,
        preloadNextPositionCount: Int,
        isScrollEnabled: Bool
    ) {
        self.preloadPreviousPositionCount = preloadPreviousPositionCount
        self.preloadNextPositionCount = preloadNextPositionCount
        self.isScrollEnabled = isScrollEnabled

        super.init(frame: frame)

        scrollView.delegate = self
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        scrollView.isPagingEnabled = true
        scrollView.bounces = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isScrollEnabled = isScrollEnabled
        addSubview(scrollView)

        // Adds an empty view before the scroll view to have a consistent behavior on all iOS
        // versions, regarding to the content inset adjustements. Even if
        // `automaticallyAdjustsScrollViewInsets` is not set to false on the navigator's parent
        // view controller, the scroll view insets won't be adjusted if the scroll view is not the
        // first child in the subviews hierarchy.
        insertSubview(UIView(frame: .zero), at: 0)
        // Prevents the content from jumping down when the status bar is toggled
        scrollView.contentInsetAdjustmentBehavior = .never
    }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func layoutSubviews() {
        if isContinuous {
            layoutContinuousPages()
            return
        }

        guard !loadedViews.isEmpty else {
            scrollView.contentSize = bounds.size
            return
        }

        let size = scrollView.bounds.size
        scrollView.contentSize = CGSize(width: size.width * CGFloat(pageCount), height: size.height)

        for (index, view) in loadedViews {
            view.frame = CGRect(origin: CGPoint(x: xOffsetForIndex(index), y: 0), size: size)
        }

        scrollView.contentOffset.x = xOffsetForIndex(currentIndex)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)

        if newSuperview == nil {
            // Remove all spread views to break retain cycles
            for (_, view) in loadedViews {
                view.removeFromSuperview()
            }
            loadedViews.removeAll()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if window == nil {
            loadPagesTask.cancel()
        } else {
            loadPages()
        }
    }

    /// Returns the x offset to the page view with given index in the scroll view.
    private func xOffsetForIndex(_ index: Int) -> CGFloat {
        (readingProgression == .rtl)
            ? scrollView.contentSize.width - (CGFloat(index + 1) * scrollView.bounds.width)
            : scrollView.bounds.width * CGFloat(index)
    }

    /// Reloads the pagination with the given total number of pages and current index.
    ///
    /// - Parameters:
    ///   - index: Index of the page to be displayed after reloading the pagination.
    ///   - location: Location to be displayed in the page.
    ///   - pageCount: Total number of pages in the pagination view.
    ///   - readingProgression: Direction of reading progression.
    func reloadAtIndex(_ index: Int, location: PageLocation, pageCount: Int, readingProgression: ReadingProgression) {
        precondition(pageCount >= 1)
        precondition(0 ..< pageCount ~= index)

        self.pageCount = pageCount
        self.readingProgression = readingProgression

        for (_, view) in loadedViews {
            view.removeFromSuperview()
        }
        loadedViews.removeAll()
        loadingIndexQueue.removeAll()

        resetContinuousState()
        setCurrentIndex(index, location: location)
        scrollContinuous(toPage: index)
    }

    /// Updates the current and pre-loaded views.
    private func setCurrentIndex(_ index: Int, location: PageLocation? = nil) {
        guard isEmpty || index != currentIndex else {
            return
        }

        // If no explicit location is given, we'll load either the beginning or the end of the
        // resource depending on the last index. This allows to navigate backward across resources,
        // starting from the end of each previous resource.
        let movingBackward = (currentIndex - 1 == index)
        // In continuous mode a page without an explicit location is placed by
        // the shared scroll position, not moved to its start or end.
        let location = location ?? (isContinuous ? nil : (movingBackward ? .end : .start))

        currentIndex = index

        // To make sure that the views the most likely to be visible are loaded first, we first load
        // the current one, then the next ones and to finish the previous ones.
        scheduleLoadPage(at: index, location: location)
        let lastIndex = scheduleLoadPages(from: index, upToPositionCount: preloadNextPositionCount, direction: .forward, location: isContinuous ? nil : .start)
        let firstIndex = scheduleLoadPages(from: index, upToPositionCount: preloadPreviousPositionCount, direction: .backward, location: isContinuous ? nil : .end)

        for (i, view) in loadedViews {
            // Flushes the views that are not needed anymore.
            guard firstIndex ... lastIndex ~= i else {
                view.removeFromSuperview()
                loadedViews.removeValue(forKey: i)
                pageObservations.removeValue(forKey: i)
                continue
            }
        }

        loadPages()
    }

    private func loadPages() {
        loadPagesTask.replace { @MainActor in
            await loadNextPage()
            delegate?.paginationViewDidUpdateViews(self)
        }
    }

    private var loadPagesTask: Task<Void, Never>?

    private func loadNextPage() async {
        guard let (index, location) = loadingIndexQueue.popFirst() else {
            return
        }

        if
            loadedViews[index] == nil,
            let view = delegate?.paginationView(self, pageViewAtIndex: index)
        {
            loadedViews[index] = view
            scrollView.addSubview(view)
            prepareForContinuousScroll(view, at: index)
            setNeedsLayout()
        }

        guard let view = loadedViews[index] else {
            return
        }

        if let location {
            await view.go(to: location)
        }
        await loadNextPage()
    }

    /// Queue views to be loaded until reaching the given number of pre-loaded positions.
    ///
    /// - Parameters:
    ///   - positionCount: Number of positions to pre-load before stopping.
    ///   - sourceIndex: Starting page index from which to pre-load the views.
    ///   - direction: The direction in which to load the views from the sourceIndex.
    /// - Returns: The last page index to be loaded after reaching the requested number of positions.
    private func scheduleLoadPages(from sourceIndex: Int, upToPositionCount positionCount: Int, direction: PageIndexDirection, location: PageLocation?) -> Int {
        let index = sourceIndex + direction.rawValue
        guard
            positionCount > 0,
            scheduleLoadPage(at: index, location: location),
            let indexPositionCount = delegate?.paginationView(self, positionCountAtIndex: index)
        else {
            return sourceIndex
        }

        return scheduleLoadPages(
            from: index,
            upToPositionCount: positionCount - indexPositionCount,
            direction: direction,
            location: location
        )
    }

    /// Queue a page to be loaded at the given index, if it's not already loaded.
    ///
    /// - Returns: Whether page is or will be loaded.
    @discardableResult
    private func scheduleLoadPage(at index: Int, location: PageLocation?) -> Bool {
        guard 0 ..< pageCount ~= index else {
            return false
        }

        loadingIndexQueue.removeAll { $0.index == index }
        loadingIndexQueue.append((index: index, location: location))
        return true
    }

    private enum PageIndexDirection: Int {
        case forward = 1
        case backward = -1
    }

    // MARK: - Navigation

    /// Go to the page view with given index.
    ///
    /// - Parameters:
    ///   - index: The index to move to.
    ///   - location: The location to move the future current page view to.
    /// - Returns: Whether the move is possible.
    func goToIndex(_ index: Int, location: PageLocation, options: NavigatorGoOptions) async -> Bool {
        guard 0 ..< pageCount ~= index else {
            return false
        }

        if currentIndex == index {
            await scrollToView(at: index, location: location)
        } else {
            await fadeToView(at: index, location: location, animated: options.animated)
        }
        return true
    }

    private func fadeToView(at index: Int, location: PageLocation, animated: Bool) async {
        func fade(to alpha: CGFloat) async {
            if animated {
                await withCheckedContinuation { continuation in
                    UIView.animate(withDuration: 0.15, animations: {
                        self.alpha = alpha
                    }) { _ in
                        continuation.resume()
                    }
                }
            } else {
                self.alpha = alpha
            }
        }

        await fade(to: 0)
        await scrollToView(at: index, location: location)
        await fade(to: 1)
    }

    private func scrollToView(at index: Int, location: PageLocation) async {
        guard currentIndex != index else {
            if let view = currentView {
                await view.go(to: location)
            }
            return
        }

        scrollView.isScrollEnabled = isScrollEnabled
        setCurrentIndex(index, location: location)

        if isContinuous {
            scrollContinuous(toPage: index)
            return
        }

        scrollView.scrollRectToVisible(CGRect(
            origin: CGPoint(
                x: xOffsetForIndex(index),
                y: scrollView.contentOffset.y
            ),
            size: scrollView.frame.size
        ), animated: false)
    }
}

extension PaginationView: UIScrollViewDelegate {
    /// We disable the scroll once the user releases the drag to prevent scrolling through more than 1 resource at a
    /// time. Otherwise, because the pagination view's scroll view would have the focus during the scroll gesture, the
    /// scrollable content of the resources would be skipped.
    /// Note: using this approach might provide a better experience:
    /// https://oleb.net/blog/2014/05/scrollviews-inside-scrollviews/

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isContinuous, !isApplyingContinuousLayout else { return }
        layoutContinuousPages()
        updateContinuousCurrentIndex()
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard !isContinuous else { return }
        scrollView.isScrollEnabled = false
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollView.isScrollEnabled = isScrollEnabled
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !isContinuous else { return }
        if !decelerate {
            scrollView.isScrollEnabled = isScrollEnabled
        }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard !isContinuous else { return }
        scrollView.isScrollEnabled = isScrollEnabled

        let currentOffset = (readingProgression == .rtl)
            ? scrollView.contentSize.width - (scrollView.contentOffset.x + scrollView.frame.width)
            : scrollView.contentOffset.x

        let newIndex = Int(round(currentOffset / scrollView.frame.width))
        setCurrentIndex(newIndex)
    }
}

// MARK: - Continuous scroll

private extension PaginationView {
    func resetContinuousState() {
        measuredHeights.removeAll()
        pageOrigins.removeAll()
        pageObservations.removeAll()
    }

    func pageHeight(at index: Int) -> CGFloat {
        if let height = measuredHeights[index] {
            return height
        }
        let positions = delegate?.paginationView(self, positionCountAtIndex: index) ?? 1
        return CGFloat(max(positions, 1)) * estimatedPositionHeight
    }

    func rebuildPageOrigins() {
        var y: CGFloat = 0
        pageOrigins = (0 ..< pageCount).map { index in
            defer { y += pageHeight(at: index) + continuousPageGap }
            return y
        }
    }

    func originOfPage(_ index: Int) -> CGFloat {
        if pageOrigins.count != pageCount {
            rebuildPageOrigins()
        }
        return pageOrigins.indices.contains(index) ? pageOrigins[index] : 0
    }

    var continuousContentHeight: CGFloat {
        guard pageCount > 0 else { return 0 }
        return originOfPage(pageCount - 1) + pageHeight(at: pageCount - 1)
    }

    /// Pins each loaded page to the screen and moves its content underneath.
    func layoutContinuousPages() {
        guard !isApplyingContinuousLayout, bounds.height > 0 else { return }
        isApplyingContinuousLayout = true
        defer { isApplyingContinuousLayout = false }

        let inset = continuousContentInset?() ?? .zero
        if scrollView.contentInset != inset {
            scrollView.contentInset = inset
        }
        scrollView.contentSize = CGSize(width: bounds.width, height: continuousContentHeight)

        let viewportHeight = scrollView.bounds.height
        let visibleTop = scrollView.contentOffset.y
        for (index, view) in loadedViews {
            let origin = originOfPage(index)
            let height = pageHeight(at: index)
            let slotHeight = min(viewportHeight, height)
            let y = min(max(visibleTop, origin), origin + height - slotHeight)
            view.frame = CGRect(x: 0, y: y, width: bounds.width, height: slotHeight)

            if let pageScroll = view.pageScrollView {
                let offset = y - origin
                if abs(pageScroll.contentOffset.y - offset) > 0.5 {
                    pageScroll.contentOffset = CGPoint(x: 0, y: offset)
                }
            }
        }
    }

    /// The current page is the one holding the middle of the screen.
    func updateContinuousCurrentIndex() {
        guard pageCount > 0 else { return }
        let middle = scrollView.contentOffset.y + scrollView.bounds.height / 2
        var index = 0
        for candidate in 0 ..< pageCount where originOfPage(candidate) <= middle {
            index = candidate
        }
        if index != currentIndex {
            setCurrentIndex(index)
        }
    }

    func scrollContinuous(toPage index: Int) {
        guard isContinuous else { return }
        setNeedsLayout()
        isApplyingContinuousLayout = true
        scrollView.contentSize = CGSize(width: bounds.width, height: continuousContentHeight)
        scrollView.contentOffset = CGPoint(x: 0, y: originOfPage(index))
        isApplyingContinuousLayout = false
        layoutContinuousPages()
    }

    func prepareForContinuousScroll(_ view: UIView & PageView, at index: Int) {
        guard isContinuous, let pageScroll = view.pageScrollView else { return }
        pageScroll.isScrollEnabled = false

        let size = pageScroll.observe(\.contentSize, options: [.new]) { [weak self, weak view] _, _ in
            MainActor.assumeIsolated {
                guard let self, let view else { return }
                self.updateMeasuredHeight(of: view, at: index)
            }
        }
        // The page moved itself: a script scroll, such as restoring a location
        // or following the spoken text. The shared position has to follow it.
        let offset = pageScroll.observe(\.contentOffset, options: [.new]) { [weak self, weak pageScroll] _, _ in
            MainActor.assumeIsolated {
                guard let self, let pageScroll else { return }
                self.pageDidMoveItself(pageScroll, at: index)
            }
        }
        pageObservations[index] = [size, offset]
    }

    func pageDidMoveItself(_ pageScroll: UIScrollView, at index: Int) {
        guard
            isContinuous,
            !isApplyingContinuousLayout,
            !scrollView.isTracking,
            !scrollView.isDecelerating,
            index == currentIndex
        else {
            return
        }
        let target = originOfPage(index) + pageScroll.contentOffset.y
        guard abs(target - scrollView.contentOffset.y) > 0.5 else { return }
        isApplyingContinuousLayout = true
        scrollView.contentOffset = CGPoint(x: 0, y: target)
        isApplyingContinuousLayout = false
        layoutContinuousPages()
    }

    func updateMeasuredHeight(of view: UIView & PageView, at index: Int) {
        guard let pageScroll = view.pageScrollView else { return }
        let contentHeight = pageScroll.contentSize.height
        guard contentHeight > 1 else { return }

        if contentHeight > view.bounds.height + 1 {
            applyMeasuredHeight(contentHeight, at: index)
            return
        }

        // A web view never reports a content smaller than its own frame, so a
        // page that fits on screen has to be measured from its document.
        Task { @MainActor [weak self, weak view] in
            guard let view, let height = await view.measureContentHeight(), height > 1 else { return }
            self?.applyMeasuredHeight(height, at: index)
        }
    }

    func applyMeasuredHeight(_ height: CGFloat, at index: Int) {
        let oldHeight = pageHeight(at: index)
        let wasMeasured = measuredHeights[index] != nil
        guard !wasMeasured || abs(height - oldHeight) >= 1 else { return }

        let wasAbove = originOfPage(index) + oldHeight <= scrollView.contentOffset.y
        measuredHeights[index] = height
        rebuildPageOrigins()

        isApplyingContinuousLayout = true
        scrollView.contentSize = CGSize(width: bounds.width, height: continuousContentHeight)
        if wasAbove {
            // Keeps the text on screen still when a page above it resizes.
            scrollView.contentOffset.y += height - oldHeight
        }
        isApplyingContinuousLayout = false
        layoutContinuousPages()
    }
}
