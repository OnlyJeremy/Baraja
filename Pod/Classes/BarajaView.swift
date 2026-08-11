//
//  BarajaView.swift
//  Baraja
//
//  垂直卡片牌组容器：逐卡动态高度 + 只物化可视窗口的卡视图。
//  偏移表（cardHeights/offsets）保存全量高度，离屏卡无视图也能精确吸附；一屏一卡吸附、
//  双向回看、上滑划出（pass）、临近末尾预加载、限额门控、删卡皆具备。
//

import UIKit
import SnapKit

// MARK: - 有序变更队列

/// 卡片增删/前进等有序操作的串行执行器。
/// 动画进行时把后续操作排队，避免并发改写 cursor 游标与偏移表导致状态错乱。
final class BarajaOpQueue {

    private var queue: [() -> Void] = []
    /// 是否有操作正在跑（滚动代理据此让行，避免与删卡争用状态）。
    private(set) var busy = false

    var isEmpty: Bool { queue.isEmpty }

    /// 排入一个操作；空闲则马上跑。
    func enqueue(_ op: @escaping () -> Void) {
        queue.append(op)
        drain()
    }

    /// 标记当前操作结束，接着跑下一个。
    func complete() {
        busy = false
        drain()
    }

    /// 丢弃全部待执行（reload 时用）。
    func clear() {
        queue.removeAll()
        busy = false
    }

    private func drain() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let op = queue.removeFirst()
        DispatchQueue.main.async { op() }
    }
}

/// 卡片手势去向。
public enum BarajaSwipe {
    case discard   // 上滑划出 = 略过（pass）
    case recall    // 下滑回看（不产生业务动作）
}

// MARK: - 数据源

public protocol BarajaSource: AnyObject {
    func cardCount(in board: BarajaView) -> Int
    func baraja(_ board: BarajaView, viewForCardAt index: Int) -> UIView
    /// 第 index 张卡按 `width` 宽折叠到 `maxHeight` 高后的实测高度。
    func baraja(_ board: BarajaView, heightForCardAt index: Int, maxHeight: CGFloat, width: CGFloat) -> CGFloat
}

// MARK: - 观察者

public protocol BarajaObserver: AnyObject {
    /// 吸附目标确定、顶卡切换时调用。
    func baraja(_ board: BarajaView, movedToTop index: Int)
    /// 顶卡完全停稳后调用（驱动解读仪式等）。
    func baraja(_ board: BarajaView, restedOn index: Int)
    /// 卡片划出屏幕（带手势方向）；pass 上报走这里，**纯 index**，去重由业务层自取。
    func baraja(_ board: BarajaView, sweptAway index: Int, via swipe: BarajaSwipe)
    /// 是否允许朝目标方向滑动（限额门控）。
    func baraja(_ board: BarajaView, permitSwipe swipe: BarajaSwipe, toward index: Int) -> Bool
    /// 临近末尾（倒数第 3 张）触发预加载。
    func barajaWantsMore(_ board: BarajaView)
    /// 拖拽进度变化（震动反馈等）。
    func baraja(_ board: BarajaView, draggedBy progress: CGFloat, swipe: BarajaSwipe)
    /// 卡片被**删除**（非滑出），携原始 index；删除绝不触发 sweptAway。
    func baraja(_ board: BarajaView, removedCardAt index: Int)
    /// 卡片视图被**回收**（滑出窗口、暂不在内存）；业务据此释放引用。
    func baraja(_ board: BarajaView, releasedCardAt index: Int)
    /// 卡片物化进窗口、已定帧上屏（本帧同步）；宿主据此同步定格已解读卡，避免滑回时闪一帧空白。
    func baraja(_ board: BarajaView, aboutToShowCardAt index: Int)
    /// 卡高整表重测完成（首帧/旋转/分屏）；宿主据此把在场活卡按最新折叠档重新同步。
    func barajaDidResize(_ board: BarajaView)
    /// 卡片全部用完（刷新拉空 / 删到空）。
    func barajaRanOut(_ board: BarajaView)
    /// 每帧滚动回调（宿主用于阴影渐隐等）。
    func barajaDidScroll(_ board: BarajaView)
}

// 默认空实现，让观察者各方法可选。
public extension BarajaObserver {
    func baraja(_ board: BarajaView, movedToTop index: Int) {}
    func baraja(_ board: BarajaView, restedOn index: Int) {}
    func baraja(_ board: BarajaView, sweptAway index: Int, via swipe: BarajaSwipe) {}
    func baraja(_ board: BarajaView, permitSwipe swipe: BarajaSwipe, toward index: Int) -> Bool { true }
    func barajaWantsMore(_ board: BarajaView) {}
    func baraja(_ board: BarajaView, draggedBy progress: CGFloat, swipe: BarajaSwipe) {}
    func baraja(_ board: BarajaView, removedCardAt index: Int) {}
    func baraja(_ board: BarajaView, releasedCardAt index: Int) {}
    func baraja(_ board: BarajaView, aboutToShowCardAt index: Int) {}
    func barajaDidResize(_ board: BarajaView) {}
    func barajaRanOut(_ board: BarajaView) {}
    func barajaDidScroll(_ board: BarajaView) {}
}

// MARK: - 容器

/// 自定义垂直卡片牌组。
///
/// **动态高度 + 窗口物化**：每张卡按折叠后的高度排布（cardHeights/offsets 全量偏移表），
/// 但**只让可视窗口附近的卡上屏**（activeViews），滑出即回收、滚回按数据重建 —— 内存
/// O(窗口)，不随预加载增长。高度由数据源**数据驱动**测得并缓存进偏移表，离屏卡无视图
/// 也能精确吸附。一屏一卡吸附、双向回看、滑出去重（pass 幂等）、预加载、限额门控、删除俱全。
public final class BarajaView: UIView {

    public weak var observer: BarajaObserver?
    public weak var source: BarajaSource?

    /// 卡片左右内缩（外部设置）。
    public var sideInset: CGFloat = 0
    /// 卡间距（外部设置）。
    public var cardSpacing: CGFloat = 0

    private var cardTotal = 0
    private var cursor = 0

    /// 下一张露出自身高度的比例（微妙的偷看）。宿主可设 0 关闭偷看。
    public var peekFraction: CGFloat = 0.06

    /// 越过当前卡 5% 即吸附到相邻卡。
    private let snapRatio: CGFloat = 0.05

    /// 卡高上限：留 peek 给下一张。
    private var maxCardHeight: CGFloat { bounds.height * (1 - peekFraction) }
    /// 卡内容宽（去掉左右内缩）。
    private var contentWidth: CGFloat { bounds.width - 2 * sideInset }

    /// 逐卡高度与累加 y 起点。
    private var cardHeights: [CGFloat] = []
    private var offsets: [CGFloat] = []

    /// 已回调过滑出的卡索引（防刷屏：滚动中同一张别每帧重复上报）。
    /// **纯 index**，权威去重在业务层；删卡后清空。
    private var reportedSwipes: Set<Int> = []

    /// 有序变更队列（删卡/前进入队；reload 不入队，直接 clear 后重建）。
    private let opQueue = BarajaOpQueue()

    /// 重载代际：每次 reload 自增；过期动画 completion 检测到代际不符即跳过。
    private var revision = 0

    /// 上次预加载时的数据量，防止重复触发。
    private var lastLoadedCount = 0

    /// 上次完成布局的尺寸，避免每次 layoutSubviews 都重测。
    private var lastBounds: CGSize = .zero

    private lazy var scroller: UIScrollView = {
        let sv = UIScrollView()
        sv.delegate = self
        sv.isPagingEnabled = false
        sv.showsVerticalScrollIndicator = false
        sv.bounces = false
        sv.alwaysBounceVertical = false
        sv.decelerationRate = .fast
        sv.backgroundColor = .clear
        sv.contentInsetAdjustmentBehavior = .never
        return sv
    }()

    private let cardHost = UIView()
    /// **窗口物化**：只持有可视窗口附近已上屏的卡（index→view），其余回收。
    /// cardHeights/offsets 仍是全量偏移表，滚回时按数据重建即可。
    private var activeViews: [Int: UIView] = [:]

    /// 可视区上下额外保留的缓冲（各约一屏），确保上一张/下一张提前物化、滚动不见白。
    private var bufferPad: CGFloat { bounds.height }

    // MARK: 只读透出（供宿主做阴影渐隐）

    /// 暴露内部滚动视图供 fadeShadows 计算相对偏移。
    public var scrollHost: UIScrollView { scroller }

    /// 当前已上屏的卡视图集合。
    public func visibleCards() -> [UIView] { Array(activeViews.values) }

    // MARK: 初始化

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .clear
        addSubview(scroller)
        scroller.addSubview(cardHost)
        scroller.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard cardTotal > 0, bounds.height > 0, bounds.width > 0 else { return }
        // 卡高只是「内容 × 内容宽」的纯函数：仅在卡数或内容宽变化（首帧/旋转/分屏）时才重测重折；
        // 导航转场里视口高会瞬时抖动，若跟着重测会让跨挡卡忽折忽展造成跳变，故高度变化只做轻量重排。
        let needsMeasure = cardHeights.count != cardTotal || bounds.width != lastBounds.width
        let sizeChanged = bounds.size != lastBounds
        if needsMeasure { measureAll() }
        if needsMeasure || sizeChanged {
            updateContentSize()
            scroller.contentOffset.y = offsetOf(cursor)
            syncVisible()
            positionCards()
            // 真重测后（如旋转）折叠档可能变了，通知宿主把活卡按新档重新同步，避免内容与帧错位。
            if needsMeasure { observer?.barajaDidResize(self) }
        }
        lastBounds = bounds.size
    }

    // MARK: 对外方法

    /// 整表重置到第一张（首批加载 / 空态重试 / 切数据）。
    public func reloadFromStart() {
        guard let source = source else { return }
        revision += 1
        opQueue.clear()
        cardTotal = source.cardCount(in: self)
        cursor = 0
        lastLoadedCount = 0
        clearSwipeState()
        rebuild()
        notifyAfterRebuild()
    }

    /// 保位重载（原地数据变化：重建全部卡视图但**保留当前位置**）。
    public func reloadInPlace() {
        guard let source = source else { return }
        revision += 1
        opQueue.clear()
        cardTotal = source.cardCount(in: self)
        cursor = max(0, min(cursor, cardTotal - 1))
        lastLoadedCount = min(lastLoadedCount, cardTotal)
        clearSwipeState()
        rebuild()
        scroller.contentOffset.y = offsetOf(cursor)
        notifyAfterRebuild()
    }

    /// 追加分页数据（只量新卡高度、延长偏移表；视图按窗口懒物化）。
    public func appendCards() {
        guard let source = source else { return }
        let oldCount = cardTotal
        cardTotal = source.cardCount(in: self)
        guard cardTotal > oldCount else { return }
        // 追加前已划到底/空态：追加后首张新卡即新顶卡，需吸附并驱动仪式。
        let wasExhausted = cursor >= oldCount
        if cardHeights.count == oldCount, maxCardHeight > 0, contentWidth > 0 {
            for index in oldCount..<cardTotal {
                cardHeights.append(source.baraja(self, heightForCardAt: index, maxHeight: maxCardHeight, width: contentWidth))
            }
            recomputeOffsets()
        } else {
            measureAll()
        }
        updateContentSize()
        if wasExhausted {
            cursor = min(cursor, cardTotal - 1)
            scroller.contentOffset.y = offsetOf(cursor)
        }
        syncVisible()
        positionCards()
        if wasExhausted {
            observer?.baraja(self, restedOn: cursor)
        }
    }

    public func currentIndex() -> Int { cursor }

    /// 程序化前进到下一张（用于 like / Say hi）。
    public func stepForward() {
        opQueue.enqueue { [weak self] in
            self?.runStep()
        }
    }

    private func runStep() {
        let last = cardTotal - 1
        guard cardTotal > 0, cursor <= last else {
            opQueue.complete()
            return
        }
        let dest = cursor + 1
        let destOffset = restOffset(for: dest)
        let rev = revision
        UIView.animate(withDuration: 0.3, animations: { [weak self] in
            self?.scroller.contentOffset.y = destOffset
        }, completion: { [weak self] _ in
            guard let self else { return }
            defer { self.opQueue.complete() }
            guard rev == self.revision else { return }   // 期间发生 reload/删卡 → 丢弃
            let prev = self.cursor
            self.cursor = dest
            self.syncVisible()
            if prev != dest {
                self.observer?.baraja(self, movedToTop: dest)
            }
            // UIView.animate 不触发 didEndDecelerating，需手动驱动用尽 / 新顶卡仪式。
            if self.cursor >= self.cardTotal {
                self.observer?.barajaRanOut(self)
            } else {
                self.observer?.baraja(self, restedOn: dest)
                self.preloadIfNear(index: dest)
            }
        })
    }

    /// 落位偏移：已划过最后一张（index >= cardTotal）时停在「末张完全移出顶部」处（用尽）；否则停在该卡顶部。
    private func restOffset(for index: Int) -> CGFloat {
        guard index < cardTotal else {
            let last = cardTotal - 1
            return offsetOf(last) + heightOf(last)
        }
        return offsetOf(index)
    }

    /// 删除当前顶卡：**无动画**，下一张直接顶到当前位置。
    /// 契约同 remove(at:)：调用方先删数据源对应卡。
    public func removeTop() {
        opQueue.enqueue { [weak self] in
            guard let self else { return }
            self.runRemove(indices: [self.cursor])
            self.opQueue.complete()
        }
    }

    /// 按索引批量删除（拉黑 / 已建会话等）。
    /// 契约：调用方须**先**把这些卡从自己的数据源移除（同一组索引），再调本方法。
    public func remove(at indices: [Int]) {
        opQueue.enqueue { [weak self] in
            guard let self else { return }
            self.runRemove(indices: indices)
            self.opQueue.complete()
        }
    }

    public func clearSwipeState() {
        reportedSwipes.removeAll()
    }

    // MARK: 布局度量

    private func offsetOf(_ index: Int) -> CGFloat {
        guard index >= 0, index < offsets.count else { return 0 }
        return offsets[index]
    }

    private func heightOf(_ index: Int) -> CGFloat {
        guard index >= 0, index < cardHeights.count else { return 0 }
        return cardHeights[index]
    }

    /// 重建逐卡高度表（cardHeights）与累加起点（offsets）。
    private func measureAll() {
        guard let source = source, maxCardHeight > 0, contentWidth > 0 else { return }
        cardHeights = (0..<cardTotal).map {
            source.baraja(self, heightForCardAt: $0, maxHeight: maxCardHeight, width: contentWidth)
        }
        recomputeOffsets()
    }

    /// 由现有 cardHeights 累加重算 offsets（删卡后用，不重新量高）。
    private func recomputeOffsets() {
        offsets = []
        var y: CGFloat = 0
        for h in cardHeights {
            offsets.append(y)
            y += h + cardSpacing
        }
    }

    // MARK: 私有

    /// 重建偏移表（数据驱动量高）并按窗口物化可视卡（**不发回调**）。
    private func rebuild() {
        releaseAll()
        cardHeights = []
        offsets = []
        guard source != nil, cardTotal > 0 else {
            updateContentSize()
            cardHost.frame = .zero
            return
        }
        measureAll()            // 量全高；bounds 未就绪则留空，交给 layoutSubviews
        updateContentSize()
        cardHost.frame = CGRect(x: 0, y: 0, width: bounds.width,
                                height: (offsets.last ?? 0) + (cardHeights.last ?? 0))
        syncVisible()           // 只物化可视窗口附近的卡
    }

    /// 回收全部已上屏卡，逐个通知业务释放引用。
    private func releaseAll() {
        let indices = Array(activeViews.keys)
        activeViews.values.forEach { $0.removeFromSuperview() }
        activeViews.removeAll()
        indices.forEach { observer?.baraja(self, releasedCardAt: $0) }
    }

    /// 重建后异步通知：有卡 → 顶卡展示；无卡 → 空态。下一 runloop 等布局稳定。
    private func notifyAfterRebuild() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.cardTotal > 0 {
                self.observer?.baraja(self, restedOn: self.cursor)
            } else {
                self.observer?.barajaRanOut(self)
            }
        }
    }

    private func positionCards() {
        guard cardHeights.count == cardTotal else { return }
        for (index, card) in activeViews {
            card.frame = CGRect(x: sideInset, y: offsetOf(index),
                                width: contentWidth, height: heightOf(index))
        }
        let stackHeight = (offsets.last ?? 0) + (cardHeights.last ?? 0)
        cardHost.frame = CGRect(x: 0, y: 0, width: bounds.width, height: stackHeight)
    }

    // MARK: 窗口物化

    /// 当前应物化的卡索引区间 = 与「可视矩形 ± bufferPad」相交的卡。
    private func visibleRange() -> ClosedRange<Int>? {
        guard cardTotal > 0, cardHeights.count == cardTotal, bounds.height > 0 else { return nil }
        let topY = scroller.contentOffset.y - bufferPad
        let bottomY = scroller.contentOffset.y + bounds.height + bufferPad
        var first = -1, last = -1
        for index in 0..<cardTotal {
            let cardTopY = offsets[index]
            let cardBottomY = offsets[index] + cardHeights[index]
            if cardBottomY >= topY && cardTopY <= bottomY {
                if first < 0 { first = index }
                last = index
            } else if first >= 0 {
                break   // offsets 单调增，过区间即停
            }
        }
        if first < 0 {   // 还没量好/越界：退化到当前卡 ±1
            return max(0, cursor - 1)...min(cardTotal - 1, cursor + 1)
        }
        return first...last
    }

    /// 物化进窗口的卡、回收出窗口的卡（diff，只在变化时增删）。
    private func syncVisible() {
        guard let range = visibleRange(), let source = source else { return }
        for (index, card) in activeViews where !range.contains(index) {
            card.removeFromSuperview()
            activeViews[index] = nil
            observer?.baraja(self, releasedCardAt: index)
        }
        for index in range where activeViews[index] == nil {
            let card = source.baraja(self, viewForCardAt: index)
            card.frame = CGRect(x: sideInset, y: offsetOf(index),
                                width: contentWidth, height: heightOf(index))
            cardHost.addSubview(card)
            activeViews[index] = card
            // 定帧后同步通知宿主：已解读卡在入画同一帧即定格揭示，去掉「无→有」的一帧空白。
            card.layoutIfNeeded()
            observer?.baraja(self, aboutToShowCardAt: index)
        }
    }

    private func updateContentSize() {
        let stackHeight = (offsets.last ?? 0) + (cardHeights.last ?? 0)
        scroller.contentSize = CGSize(width: bounds.width, height: stackHeight)
        // 预留一屏底部内距：让矮的最后一张能吸附到顶，并给「末张上滑划出」留出滚动空间。
        scroller.contentInset.bottom = max(0, bounds.height)
    }

    /// 检测向上完全滑出屏幕的卡（= pass），按 index 防刷屏回调一次。
    private func checkSweptCards() {
        guard cursor > 0 else { return }
        let offsetY = scroller.contentOffset.y
        for index in 0..<cursor {
            guard !reportedSwipes.contains(index) else { continue }
            if offsetY > offsetOf(index) + heightOf(index) {
                reportSwipe(at: index, swipe: .discard)
            }
        }
    }

    private func reportSwipe(at index: Int, swipe: BarajaSwipe) {
        guard index >= 0, index < cardTotal else { return }
        reportedSwipes.insert(index)
        observer?.baraja(self, sweptAway: index, via: swipe)
    }

    /// 删除若干卡（全量索引，降序处理）：删 cardHeights 项、重算 offsets、补偿 contentOffset，
    /// 回收全部上屏卡后按窗口重建，并发删除/展示/空态/预加载回调。
    private func runRemove(indices localIndices: [Int]) {
        let valid = localIndices.filter { $0 >= 0 && $0 < cardTotal }.sorted()
        guard !valid.isEmpty else { return }
        revision += 1   // 失效进行中的动画 completion

        let removedBeforeTop = valid.filter { $0 < cursor }.count
        var removedHeightAboveTop: CGFloat = 0
        for i in valid where i < cursor {
            removedHeightAboveTop += heightOf(i) + cardSpacing
        }
        let removingTop = valid.contains(cursor)

        releaseAll()

        for i in valid.sorted(by: >) where i < cardHeights.count {
            cardHeights.remove(at: i)
        }
        cardTotal = max(0, cardTotal - valid.count)
        cursor = max(0, min(cursor - removedBeforeTop, cardTotal - 1))
        reportedSwipes.removeAll()

        recomputeOffsets()
        updateContentSize()

        if cardTotal > 0 {
            if removingTop {
                scroller.contentOffset.y = offsetOf(cursor)
            } else if removedHeightAboveTop > 0 {
                scroller.contentOffset.y = max(0, scroller.contentOffset.y - removedHeightAboveTop)
            }
        }

        valid.forEach { observer?.baraja(self, removedCardAt: $0) }

        if cardTotal == 0 {
            cardHost.frame = .zero
            observer?.barajaRanOut(self)
            return
        }
        syncVisible()
        if removingTop || removedBeforeTop > 0 {
            observer?.baraja(self, restedOn: cursor)
        }
        lastLoadedCount = min(lastLoadedCount, cardTotal)
        preloadIfNear(index: cursor)
    }

    private func preloadIfNear(index: Int) {
        if index >= cardTotal - 3, cardTotal > lastLoadedCount {
            lastLoadedCount = cardTotal
            observer?.barajaWantsMore(self)
        }
    }
}

// MARK: - UIScrollViewDelegate

extension BarajaView: UIScrollViewDelegate {

    public func scrollViewWillEndDragging(_ scrollView: UIScrollView,
                                          withVelocity velocity: CGPoint,
                                          targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard !opQueue.busy else { return }   // 删卡/前进进行中，让行
        let h = heightOf(cursor)
        guard h > 0 else { return }
        let delta = scrollView.contentOffset.y - offsetOf(cursor)

        var dest: Int
        if delta > 0 {
            dest = (delta / h) >= snapRatio ? cursor + 1 : cursor
        } else {
            dest = (abs(delta) / h) >= snapRatio ? cursor - 1 : cursor
        }
        // 允许到 cardTotal = 末张向上划出（用尽）；其余夹在有效区间。
        dest = max(0, min(dest, cardTotal))

        let swipe: BarajaSwipe = dest > cursor ? .discard : .recall

        if dest != cursor,
           let observer = observer,
           !observer.baraja(self, permitSwipe: swipe, toward: dest) {
            targetContentOffset.pointee.y = offsetOf(cursor)
            return
        }

        let prev = cursor
        cursor = dest
        targetContentOffset.pointee.y = restOffset(for: dest)

        if prev != dest {
            observer?.baraja(self, movedToTop: dest)
        }
        if swipe == .discard {
            preloadIfNear(index: dest)
        }
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        observer?.barajaDidScroll(self)
        guard !opQueue.busy else { return }   // 删卡期间不检测滑出/不发拖拽进度
        syncVisible()
        checkSweptCards()
        let h = heightOf(cursor)
        guard h > 0 else { return }
        let delta = scrollView.contentOffset.y - offsetOf(cursor)
        let progress = abs(delta) / h
        if progress > 0.01 {
            let swipe: BarajaSwipe = delta > 0 ? .discard : .recall
            observer?.baraja(self, draggedBy: progress, swipe: swipe)
        }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        emitSettle()
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { emitSettle() }
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        emitSettle()
    }

    /// 落定后回调：已划过最后一张 → 用尽；否则驱动顶卡展示。
    private func emitSettle() {
        if cursor >= cardTotal {
            observer?.barajaRanOut(self)
        } else {
            observer?.baraja(self, restedOn: cursor)
        }
    }
}
