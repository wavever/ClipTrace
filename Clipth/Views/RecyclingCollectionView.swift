import SwiftUI
import AppKit

/// One logical collection section. Headers remain SwiftUI so the production
/// pinned control keeps its paper styling, while AppKit owns item lifetime and
/// scroll geometry.
struct RecyclingCollectionSection<Item: Identifiable> {
    let id: AnyHashable
    let items: [Item]
    let headerHeight: CGFloat
    let header: AnyView?

    init(
        id: some Hashable,
        items: [Item],
        headerHeight: CGFloat = 0,
        header: AnyView? = nil
    ) {
        self.id = AnyHashable(id)
        self.items = items
        self.headerHeight = headerHeight
        self.header = header
    }
}

/// AppKit's collection view is the native macOS equivalent of a recycling
/// list: only visible items own views, and offscreen items are returned through
/// `makeItem(withIdentifier:for:)`. Each recycled shell hosts the existing
/// SwiftUI card, preserving the product's visual and interaction code without
/// leaving hundreds of card view graphs alive during a scroll.
struct RecyclingCollectionView<Item: Identifiable, Cell: View>: NSViewRepresentable
where Item.ID: Hashable {
    let sections: [RecyclingCollectionSection<Item>]
    let fixedColumnCount: Int?
    let minimumItemWidth: CGFloat
    let maximumItemWidth: CGFloat
    let itemHeight: CGFloat
    let interitemSpacing: CGFloat
    let lineSpacing: CGFloat
    let contentInsets: NSEdgeInsets
    let focusedID: Item.ID?
    let visibleStateID: AnyHashable
    let canPrefetch: Bool
    let prefetchThreshold: Int
    /// Returns whether the owner accepted this page request. A rejected
    /// request must remain retryable: SwiftUI can still be applying the
    /// previous page when AppKit starts displaying cells from the new one.
    let onPrefetch: () -> Bool
    let onColumnCountChange: (Int) -> Void
    @ViewBuilder let content: (Item) -> Cell

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let collectionView = WidthAwareCollectionView()
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = interitemSpacing
        layout.minimumLineSpacing = lineSpacing
        layout.sectionInset = NSEdgeInsets()
        layout.estimatedItemSize = .zero

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.isSelectable = false
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            RecyclingHostingCollectionItem.self,
            forItemWithIdentifier: RecyclingHostingCollectionItem.reuseIdentifier
        )
        collectionView.register(
            RecyclingHostingSupplementaryView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: RecyclingHostingSupplementaryView.reuseIdentifier
        )

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = collectionView
        scrollView.contentView.postsBoundsChangedNotifications = true

        collectionView.onWidthChange = { [weak coordinator = context.coordinator] in
            coordinator?.invalidateLayoutForWidthChange()
        }
        context.coordinator.collectionView = collectionView
        context.coordinator.observeViewport(of: scrollView.contentView)
        context.coordinator.structure = structureSnapshot
        context.coordinator.visibleStateID = visibleStateID
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let collectionView = scrollView.documentView as? WidthAwareCollectionView else { return }
        let coordinator = context.coordinator
        let previousStructure = coordinator.structure
        let nextStructure = structureSnapshot
        let previousFocusedID = coordinator.parent.focusedID
        let previousVisibleStateID = coordinator.visibleStateID
        coordinator.parent = self

        if previousStructure != nextStructure {
            coordinator.structure = nextStructure
            if let inserted = appendedIndexPaths(from: previousStructure, to: nextStructure) {
                // Page growth is append-only (the query is newest-first). Tell
                // AppKit only about the new indexes so it keeps visible cells,
                // momentum and scroll geometry untouched while the next page
                // becomes available below the viewport.
                NSAnimationContext.runAnimationGroup { animationContext in
                    animationContext.duration = 0
                    animationContext.allowsImplicitAnimation = false
                    collectionView.performBatchUpdates {
                        collectionView.insertItems(at: inserted)
                    }
                }
                // A fast scrollbar drag can already be at the end while the
                // append transaction is settling. Re-check on the next event
                // turn instead of relying solely on a future willDisplay.
                DispatchQueue.main.async { [weak coordinator] in
                    coordinator?.prefetchIfNeededForViewport()
                }
            } else {
                let viewportOrigin = scrollView.contentView.bounds.origin
                coordinator.lastPrefetchedItemCount = 0
                collectionView.reloadData()
                collectionView.collectionViewLayout?.invalidateLayout()
                collectionView.layoutSubtreeIfNeeded()
                scrollView.contentView.scroll(to: viewportOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else if previousVisibleStateID != visibleStateID {
            coordinator.reconfigureVisibleItems()
        } else if previousFocusedID != focusedID {
            coordinator.reconfigureItems(withIDs: [previousFocusedID, focusedID].compactMap { $0 })
        }

        coordinator.visibleStateID = visibleStateID
        coordinator.updateLayoutMetrics()
        if previousFocusedID != focusedID, let focusedID {
            coordinator.scrollToItem(withID: focusedID)
        }
    }

    private var structureSnapshot: [[AnyHashable]] {
        sections.map { section in
            [section.id] + section.items.map { AnyHashable($0.id) }
        }
    }

    /// Returns the precise inserted paths when every existing section keeps
    /// the same ordered prefix. Any delete, reorder, filter, or section change
    /// intentionally falls back to a viewport-preserving reload.
    private func appendedIndexPaths(
        from old: [[AnyHashable]],
        to new: [[AnyHashable]]
    ) -> Set<IndexPath>? {
        guard old.count == new.count else { return nil }
        var inserted = Set<IndexPath>()
        for section in old.indices {
            guard old[section].first == new[section].first,
                  old[section].count <= new[section].count,
                  Array(new[section].prefix(old[section].count)) == old[section] else {
                return nil
            }
            let oldItemCount = max(0, old[section].count - 1)
            let newItemCount = max(0, new[section].count - 1)
            for item in oldItemCount..<newItemCount {
                inserted.insert(IndexPath(item: item, section: section))
            }
        }
        return inserted
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        var parent: RecyclingCollectionView
        weak var collectionView: WidthAwareCollectionView?
        var structure: [[AnyHashable]] = []
        var visibleStateID: AnyHashable
        var lastPrefetchedItemCount = 0
        private var lastReportedColumnCount = 0
        private var layoutSignature: [CGFloat] = []
        private var viewportObserver: NSObjectProtocol?
        private var prefetchRetryTask: Task<Void, Never>?

        init(parent: RecyclingCollectionView) {
            self.parent = parent
            visibleStateID = parent.visibleStateID
        }

        deinit {
            if let viewportObserver {
                NotificationCenter.default.removeObserver(viewportObserver)
            }
            prefetchRetryTask?.cancel()
        }

        func observeViewport(of clipView: NSClipView) {
            if let viewportObserver {
                NotificationCenter.default.removeObserver(viewportObserver)
            }
            viewportObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.prefetchIfNeededForViewport()
                }
            }
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            parent.sections.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            guard parent.sections.indices.contains(section) else { return 0 }
            return parent.sections[section].items.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            guard parent.sections.indices.contains(indexPath.section),
                  parent.sections[indexPath.section].items.indices.contains(indexPath.item),
                  let item = collectionView.makeItem(
                    withIdentifier: RecyclingHostingCollectionItem.reuseIdentifier,
                    for: indexPath
                  ) as? RecyclingHostingCollectionItem else {
                return NSCollectionViewItem()
            }
            let model = parent.sections[indexPath.section].items[indexPath.item]
            item.configure(AnyView(parent.content(model).id(model.id)))
            return item
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            guard kind == NSCollectionView.elementKindSectionHeader,
                  parent.sections.indices.contains(indexPath.section),
                  let view = collectionView.makeSupplementaryView(
                    ofKind: kind,
                    withIdentifier: RecyclingHostingSupplementaryView.reuseIdentifier,
                    for: indexPath
                  ) as? RecyclingHostingSupplementaryView else {
                return NSView()
            }
            view.configure(parent.sections[indexPath.section].header ?? AnyView(EmptyView()))
            return view
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            NSSize(width: itemWidthAndColumns().width, height: parent.itemHeight)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            referenceSizeForHeaderInSection section: Int
        ) -> NSSize {
            guard parent.sections.indices.contains(section) else { return .zero }
            let height = parent.sections[section].headerHeight
            return height > 0 ? NSSize(width: collectionView.bounds.width, height: height) : .zero
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            insetForSectionAt section: Int
        ) -> NSEdgeInsets {
            let isFirst = section == 0
            let isLast = section == parent.sections.count - 1
            return NSEdgeInsets(
                top: isFirst ? parent.contentInsets.top : 0,
                left: parent.contentInsets.left,
                bottom: isLast ? parent.contentInsets.bottom : parent.lineSpacing,
                right: parent.contentInsets.right
            )
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            willDisplay item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            guard parent.canPrefetch else { return }
            let total = parent.sections.reduce(0) { $0 + $1.items.count }
            let preceding = parent.sections.prefix(indexPath.section).reduce(0) { $0 + $1.items.count }
            let visibleIndex = preceding + indexPath.item
            guard visibleIndex >= max(0, total - parent.prefetchThreshold) else { return }
            requestPrefetch(total: total)
        }

        /// `willDisplay` is normally sufficient, but it is not guaranteed to
        /// fire again when a scrollbar thumb jumps directly to an already
        /// materialised end cell. Bounds notifications close that gap. This
        /// path intentionally uses only scroll geometry (no visible-item set
        /// allocation) so it remains negligible during high-frequency scroll.
        func prefetchIfNeededForViewport() {
            guard parent.canPrefetch,
                  let collectionView,
                  let clipView = collectionView.enclosingScrollView?.contentView else { return }
            let total = parent.sections.reduce(0) { $0 + $1.items.count }
            let columns = max(1, itemWidthAndColumns().columns)
            let thresholdRows = ceil(CGFloat(parent.prefetchThreshold) / CGFloat(columns))
            let triggerDistance = max(
                parent.itemHeight + parent.lineSpacing,
                thresholdRows * (parent.itemHeight + parent.lineSpacing)
            )
            let remainingDistance = collectionView.bounds.maxY - clipView.bounds.maxY
            guard remainingDistance <= triggerDistance else { return }
            requestPrefetch(total: total)
        }

        private func requestPrefetch(total: Int) {
            guard total > lastPrefetchedItemCount else { return }
            if parent.onPrefetch() {
                lastPrefetchedItemCount = total
                prefetchRetryTask?.cancel()
                prefetchRetryTask = nil
            } else {
                schedulePrefetchRetry()
            }
        }

        private func schedulePrefetchRetry() {
            guard prefetchRetryTask == nil else { return }
            prefetchRetryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 32_000_000)
                guard !Task.isCancelled, let self else { return }
                self.prefetchRetryTask = nil
                self.prefetchIfNeededForViewport()
            }
        }

        func invalidateLayoutForWidthChange() {
            collectionView?.collectionViewLayout?.invalidateLayout()
            updateLayoutMetrics()
        }

        func updateLayoutMetrics() {
            guard let collectionView,
                  let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
            let nextSignature: [CGFloat] = [
                CGFloat(parent.fixedColumnCount ?? 0),
                parent.minimumItemWidth,
                parent.maximumItemWidth,
                parent.itemHeight,
                parent.interitemSpacing,
                parent.lineSpacing,
                parent.contentInsets.top,
                parent.contentInsets.left,
                parent.contentInsets.bottom,
                parent.contentInsets.right
            ]
            let layoutChanged = layoutSignature != nextSignature
            layoutSignature = nextSignature
            layout.minimumInteritemSpacing = parent.interitemSpacing
            layout.minimumLineSpacing = parent.lineSpacing
            layout.sectionInset = NSEdgeInsets()
            let metrics = itemWidthAndColumns()
            layout.itemSize = NSSize(width: metrics.width, height: parent.itemHeight)
            if layoutChanged { layout.invalidateLayout() }
            if metrics.columns != lastReportedColumnCount {
                lastReportedColumnCount = metrics.columns
                DispatchQueue.main.async { [parent] in
                    parent.onColumnCountChange(metrics.columns)
                }
            }
        }

        func reconfigureVisibleItems() {
            guard let collectionView else { return }
            for indexPath in collectionView.indexPathsForVisibleItems() {
                guard parent.sections.indices.contains(indexPath.section),
                      parent.sections[indexPath.section].items.indices.contains(indexPath.item),
                      let item = collectionView.item(at: indexPath) as? RecyclingHostingCollectionItem else {
                    continue
                }
                let model = parent.sections[indexPath.section].items[indexPath.item]
                item.configure(AnyView(parent.content(model).id(model.id)))
            }
        }

        func reconfigureItems(withIDs ids: [Item.ID]) {
            guard let collectionView, !ids.isEmpty else { return }
            let wanted = Set(ids)
            for indexPath in collectionView.indexPathsForVisibleItems() {
                guard parent.sections.indices.contains(indexPath.section),
                      parent.sections[indexPath.section].items.indices.contains(indexPath.item) else {
                    continue
                }
                let model = parent.sections[indexPath.section].items[indexPath.item]
                guard wanted.contains(model.id),
                      let item = collectionView.item(at: indexPath) as? RecyclingHostingCollectionItem else {
                    continue
                }
                item.configure(AnyView(parent.content(model).id(model.id)))
            }
        }

        func scrollToItem(withID id: Item.ID) {
            guard let collectionView else { return }
            for (sectionIndex, section) in parent.sections.enumerated() {
                guard let itemIndex = section.items.firstIndex(where: { $0.id == id }) else { continue }
                collectionView.scrollToItems(
                    at: [IndexPath(item: itemIndex, section: sectionIndex)],
                    scrollPosition: .nearestHorizontalEdge.union(.nearestVerticalEdge)
                )
                return
            }
        }

        private func itemWidthAndColumns() -> (width: CGFloat, columns: Int) {
            guard let collectionView else {
                return (parent.minimumItemWidth, 1)
            }
            let availableWidth = max(
                1,
                collectionView.bounds.width - parent.contentInsets.left - parent.contentInsets.right
            )
            let minimum = max(1, parent.minimumItemWidth)
            let columns = parent.fixedColumnCount.map { max(1, $0) } ?? max(
                    1,
                    Int((availableWidth + parent.interitemSpacing) / (minimum + parent.interitemSpacing))
                )
            let distributed = floor(
                (availableWidth - CGFloat(columns - 1) * parent.interitemSpacing) / CGFloat(columns)
            )
            return (min(max(distributed, minimum), parent.maximumItemWidth), columns)
        }
    }
}

final class WidthAwareCollectionView: NSCollectionView {
    var onWidthChange: (() -> Void)?
    private var previousLayoutWidth: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - previousLayoutWidth) > 0.5
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        previousLayoutWidth = newSize.width
        onWidthChange?()
    }
}

private final class RecyclingHostingCollectionItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ClipthRecyclingHostingItem")
    private var hostingView: NSHostingView<AnyView>?

    override func loadView() {
        view = NSView()
    }

    func configure(_ content: AnyView) {
        if let hostingView {
            hostingView.rootView = content
            return
        }
        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.hostingView = hostingView
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hostingView?.rootView = AnyView(EmptyView())
    }
}

private final class RecyclingHostingSupplementaryView: NSView, NSCollectionViewElement {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ClipthRecyclingHostingHeader")
    private var hostingView: NSHostingView<AnyView>?

    func configure(_ content: AnyView) {
        if let hostingView {
            hostingView.rootView = content
            return
        }
        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        self.hostingView = hostingView
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hostingView?.rootView = AnyView(EmptyView())
    }
}
