//
//  BarajaView.swift
//  Baraja
//
//  纵向卡牌容器：每张卡高度独立测算，仅把可见范围内的卡真正加载成视图。
//  全量高度存在 cardHeights/offsets 两张表里，离屏的卡即使没有视图也能算准吸附点；
//  支持整屏单卡吸附、上下双向翻看、上划移除（pass）、接近底部自动续拉、配额拦截与删卡。
//

import UIKit
import SnapKit

// MARK: - 串行操作队列

/// 把增删、前进这类需要有序执行的操作排成一条队列逐个跑。
/// 有动画在跑时后来的操作先排队，防止同时改动 cursor 和高度表把状态搞乱。
final class BarajaOpQueue {

    private var queue: [() -> Void] = []
    /// 当前是否有操作在执行（滚动回调据此暂避，免得和删卡抢状态）。
    private(set) var busy = false

    var isEmpty: Bool { queue.isEmpty }

    /// 压入一个操作；没在忙就立刻开跑。
    func enqueue(_ op: @escaping () -> Void) {
        queue.append(op)
        drain()
    }

    /// 收尾当前操作，继续跑下一个。
    func complete() {
        busy = false
        drain()
    }

    /// 清空待办队列（reload 场景）。
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

/// 卡片被划走后的两种方向。
public enum BarajaSwipe {
    case discard   // 向上划走 = 跳过（pass）
    case recall    // 向下划回查看（不触发业务逻辑）
}

// MARK: - 数据源

public protocol BarajaSource: AnyObject {
    func cardCount(in board: BarajaView) -> Int
    func baraja(_ board: BarajaView, viewForCardAt index: Int) -> UIView
    /// 返回第 index 张卡在 `width` 宽度下折叠、并限制到 `maxHeight` 后测得的高度。
    func baraja(_ board: BarajaView, heightForCardAt index: Int, maxHeight: CGFloat, width: CGFloat) -> CGFloat
}

// MARK: - 观察者

public protocol BarajaObserver: AnyObject {
    /// 确定吸附目标、顶部卡发生切换时触发。
    func baraja(_ board: BarajaView, movedToTop index: Int)
    /// 顶部卡彻底静止后触发（用来驱动展开仪式等）。
    func baraja(_ board: BarajaView, restedOn index: Int)
    /// 卡片被划出可视区（含方向）；pass 统计在此上报，**只给 index**，是否去重由外部决定。
    func baraja(_ board: BarajaView, sweptAway index: Int, via swipe: BarajaSwipe)
    /// 询问是否放行某个方向的滑动（用于配额拦截）。
    func baraja(_ board: BarajaView, permitSwipe swipe: BarajaSwipe, toward index: Int) -> Bool
    /// 快到底部（还剩 3 张）时请求续拉。
    func barajaWantsMore(_ board: BarajaView)
    /// 拖动进度更新（可用于触感反馈）。
    func baraja(_ board: BarajaView, draggedBy progress: CGFloat, swipe: BarajaSwipe)
    /// 卡片被**主动删除**（并非划走），带上原 index；删除永远不会触发 sweptAway。
    func baraja(_ board: BarajaView, removedCardAt index: Int)
    /// 卡片视图被**回收**（移出可视窗口、暂不驻留内存）；外部据此断开引用。
    func baraja(_ board: BarajaView, releasedCardAt index: Int)
    /// 卡片被加载进窗口且本帧已定位上屏；宿主借此把已展开的卡同步定格，避免划回时闪一帧空白。
    func baraja(_ board: BarajaView, aboutToShowCardAt index: Int)
    /// 全表高度重新测算完毕（首帧/旋转/分屏）；宿主据此把在场的卡按新的折叠档重排。
    func barajaDidResize(_ board: BarajaView)
    /// 卡片彻底见底（刷新为空 / 删到空）。
    func barajaRanOut(_ board: BarajaView)
    /// 每一帧滚动都会回调（宿主可做阴影渐隐之类）。
    func barajaDidScroll(_ board: BarajaView)
}

// 全部方法都给了默认空实现，按需重写即可。
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

/// 自研的纵向卡牌容器。
///
/// **按需高度 + 窗口加载**：每张卡依折叠高度依次摆放（cardHeights/offsets 两张全量表），
/// 但**只有可视窗口附近的卡才真正上屏**（activeViews），划走即回收、划回按数据重建 —— 内存
/// 只和窗口大小相关，不会随续拉膨胀。高度来自数据源的**实测**并缓存进表，离屏卡没有视图
/// 也能算准吸附。整屏单卡吸附、双向翻看、划出去重（pass 幂等）、续拉、配额拦截、删除一应俱全。
public final class BarajaView: UIView {

    public weak var observer: BarajaObserver?
    public weak var source: BarajaSource?

    /// 卡片左右留白（由外部设置）。
    public var sideInset: CGFloat = 0
    /// 卡片之间的间隔（由外部设置）。
    public var cardSpacing: CGFloat = 0

    private var cardTotal = 0
    private var cursor = 0

    /// 下一张预露出的高度占比（一点点探头）。设为 0 即关闭探头。
    public var peekFraction: CGFloat = 0.06

    /// 拖过当前卡高度的 5% 就吸附到相邻卡。
    private let snapRatio: CGFloat = 0.05

    /// 单卡最大高度：预留探头空间给下一张。
    private var maxCardHeight: CGFloat { bounds.height * (1 - peekFraction) }
    /// 卡片内容宽度（扣掉两侧留白）。
    private var contentWidth: CGFloat { bounds.width - 2 * sideInset }

    /// 每张卡的高度，以及据此累加得到的 y 起点。
    private var cardHeights: [CGFloat] = []
    private var offsets: [CGFloat] = []

    /// 已上报过划出的卡索引（避免同一张在滚动中每帧重复上报）。
    /// **仅是 index**，真正去重交给业务层；删卡后清零。
    private var reportedSwipes: Set<Int> = []

    /// 串行操作队列（删卡、前进走入队；reload 不入队，直接清空后重建）。
    private let opQueue = BarajaOpQueue()

    /// 重建版本号：每次 reload 自增；动画回调发现版本对不上就放弃。
    private var revision = 0

    /// 上一次触发续拉时的数据量，用来防止重复触发。
    private var lastLoadedCount = 0

    /// 上一次布局完成时的尺寸，避免每次 layoutSubviews 都重新测量。
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
    /// **窗口内加载**：只保留可视窗口附近已上屏的卡（index→view），其余回收。
    /// cardHeights/offsets 依旧是全量表，划回时按数据重建即可。
    private var activeViews: [Int: UIView] = [:]

    /// 可视区上下各多留约一屏的缓冲，保证相邻卡提前加载，滚动时不露白。
    private var bufferPad: CGFloat { bounds.height }

    // MARK: 只读暴露（供宿主做阴影渐隐）

    /// 把内部滚动视图透出去，方便宿主计算相对偏移做阴影渐隐。
    public var scrollHost: UIScrollView { scroller }

    /// 当前处于上屏状态的卡视图集合。
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
        // 卡高只取决于「内容 + 内容宽度」：只有卡数或宽度变化（首帧/旋转/分屏）才需要重新测量折叠；
        // 导航转场时视口高度会瞬时抖动，跟着重测会让跨档卡反复折叠展开而跳动，所以高度变化只做轻量重排。
        let needsMeasure = cardHeights.count != cardTotal || bounds.width != lastBounds.width
        let sizeChanged = bounds.size != lastBounds
        if needsMeasure { measureAll() }
        if needsMeasure || sizeChanged {
            updateContentSize()
            scroller.contentOffset.y = offsetOf(cursor)
            syncVisible()
            positionCards()
            // 真正重测后（如旋转）折叠档可能变化，通知宿主把在场卡按新档同步，避免内容和帧对不上。
            if needsMeasure { observer?.barajaDidResize(self) }
        }
        lastBounds = bounds.size
    }

    // MARK: 对外接口

    /// 全量重置回第一张（首批加载 / 空态重试 / 切换数据源）。
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

    /// 原地重载（数据就地变化：重建所有卡视图但**保持当前位置不变**）。
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

    /// 追加下一页数据（只测新卡高度、延长高度表；视图按窗口懒加载）。
    public func appendCards() {
        guard let source = source else { return }
        let oldCount = cardTotal
        cardTotal = source.cardCount(in: self)
        guard cardTotal > oldCount else { return }
        // 追加前已经翻到底/空态：追加后第一张新卡即成新顶卡，需吸附并驱动仪式。
        let wasExhausted = cursor >= oldCount
        if cardHeights.count == oldCount, maxCardHeight > 0, contentWidth > 0 {
            for index in oldCount..<cardTotal {
                cardHeights.append(measuredHeight(at: index))
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

    /// 代码驱动前进到下一张（用于 like / Say hi）。
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
            guard rev == self.revision else { return }   // 期间若发生 reload/删卡 → 直接丢弃
            let prev = self.cursor
            self.cursor = dest
            self.syncVisible()
            if prev != dest {
                self.observer?.baraja(self, movedToTop: dest)
            }
            // UIView.animate 不会回调 didEndDecelerating，见底/新顶卡的仪式需手动驱动。
            if self.cursor >= self.cardTotal {
                self.observer?.barajaRanOut(self)
            } else {
                self.observer?.baraja(self, restedOn: dest)
                self.preloadIfNear(index: dest)
            }
        })
    }

    /// 停靠偏移：未越过末张就停在该卡顶部；越过（index >= cardTotal）则停在「末张完全滑出顶部」处（见底）。
    private func restOffset(for index: Int) -> CGFloat {
        if index < cardTotal {
            return offsetOf(index)
        }
        let last = cardTotal - 1
        return offsetOf(last) + heightOf(last)
    }

    /// 删掉当前顶卡：**不带动画**，下一张直接补到当前位置。
    /// 约定同 remove(at:)：调用方需先删掉数据源里对应的卡。
    public func removeTop() {
        opQueue.enqueue { [weak self] in
            guard let self else { return }
            self.runRemove(indices: [self.cursor])
            self.opQueue.complete()
        }
    }

    /// 按索引批量删除（拉黑 / 已建会话等场景）。
    /// 约定：调用方须**先**在自己数据源里移除这些卡（同一批索引），再来调本方法。
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

    // MARK: 尺寸计算

    private func offsetOf(_ index: Int) -> CGFloat {
        guard index >= 0, index < offsets.count else { return 0 }
        return offsets[index]
    }

    private func heightOf(_ index: Int) -> CGFloat {
        guard index >= 0, index < cardHeights.count else { return 0 }
        return cardHeights[index]
    }

    /// 单张测高：向数据源问第 index 张卡在当前折叠档/宽度下的高度。
    private func measuredHeight(at index: Int) -> CGFloat {
        source?.baraja(self, heightForCardAt: index, maxHeight: maxCardHeight, width: contentWidth) ?? 0
    }

    /// 重新构建每张卡的高度表（cardHeights）和累加起点（offsets）。
    private func measureAll() {
        guard source != nil, maxCardHeight > 0, contentWidth > 0 else { return }
        cardHeights = (0..<cardTotal).map { measuredHeight(at: $0) }
        recomputeOffsets()
    }

    /// 直接拿现有 cardHeights 累加出 offsets（删卡后用，不重新测高）。
    /// 相当于对高度表（每项额外叠加 cardSpacing）做前缀和。
    private func recomputeOffsets() {
        offsets = [CGFloat](repeating: 0, count: cardHeights.count)
        var running: CGFloat = 0
        for i in cardHeights.indices {
            offsets[i] = running
            running += cardHeights[i] + cardSpacing
        }
    }

    // MARK: 内部实现

    /// 重建高度表（按数据实测）并按窗口加载可视卡（**不发任何回调**）。
    private func rebuild() {
        releaseAll()
        cardHeights = []
        offsets = []
        guard source != nil, cardTotal > 0 else {
            updateContentSize()
            cardHost.frame = .zero
            return
        }
        measureAll()            // 测全部高度；bounds 还没就绪就先留空，交给 layoutSubviews
        updateContentSize()
        cardHost.frame = CGRect(x: 0, y: 0, width: bounds.width,
                                height: (offsets.last ?? 0) + (cardHeights.last ?? 0))
        syncVisible()           // 只加载可视窗口附近的卡
    }

    /// 回收所有已上屏的卡，并逐个通知业务方释放引用。
    private func releaseAll() {
        let indices = Array(activeViews.keys)
        activeViews.values.forEach { $0.removeFromSuperview() }
        activeViews.removeAll()
        indices.forEach { observer?.baraja(self, releasedCardAt: $0) }
    }

    /// 重建完成后异步通知：有卡 → 展示顶卡；没卡 → 空态。放到下一轮 runloop 等布局稳定。
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

    // MARK: 窗口加载

    /// 当前应加载的卡索引区间 = 与「可视矩形 ± bufferPad」相交的那些卡。
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
                break   // offsets 递增，越过区间即可停下
            }
        }
        if first < 0 {   // 还没测好或越界：退化成当前卡 ±1
            return max(0, cursor - 1)...min(cardTotal - 1, cursor + 1)
        }
        return first...last
    }

    /// 加载进窗口的卡、回收出窗口的卡（做差集，只在变化处增删）。
    /// 顺序固定：先回收出窗口的旧卡，再挂载入窗口的新卡。
    private func syncVisible() {
        guard let range = visibleRange(), let source = source else { return }
        recycleOutside(keeping: range)
        mountInside(range: range, source: source)
    }

    /// 回收落在窗口外的已上屏卡，逐个通知业务方断开引用。
    private func recycleOutside(keeping range: ClosedRange<Int>) {
        for (index, card) in activeViews where !range.contains(index) {
            card.removeFromSuperview()
            activeViews[index] = nil
            observer?.baraja(self, releasedCardAt: index)
        }
    }

    /// 把窗口内尚未上屏的卡按数据重建、定位，并在入画同一帧通知宿主定格。
    private func mountInside(range: ClosedRange<Int>, source: BarajaSource) {
        for index in range where activeViews[index] == nil {
            let card = source.baraja(self, viewForCardAt: index)
            card.frame = CGRect(x: sideInset, y: offsetOf(index),
                                width: contentWidth, height: heightOf(index))
            cardHost.addSubview(card)
            activeViews[index] = card
            // 定位后当帧通知宿主：已展开的卡在入画同一帧就定格呈现，消掉「无→有」的一帧空白。
            card.layoutIfNeeded()
            observer?.baraja(self, aboutToShowCardAt: index)
        }
    }

    private func updateContentSize() {
        let stackHeight = (offsets.last ?? 0) + (cardHeights.last ?? 0)
        scroller.contentSize = CGSize(width: bounds.width, height: stackHeight)
        // 底部预留一屏内距：让偏矮的末张也能吸附到顶，并为「末张上划移除」留出滚动余量。
        scroller.contentInset.bottom = max(0, bounds.height)
    }

    /// 找出彻底向上划出屏幕的卡（= pass），按 index 去重，每张只回调一次。
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

    /// 删除若干卡（全量索引，降序处理）：移除 cardHeights 项、重算 offsets、修正 contentOffset，
    /// 回收全部上屏卡后按窗口重建，并派发删除/展示/空态/续拉等回调。
    private func runRemove(indices localIndices: [Int]) {
        let valid = localIndices.filter { $0 >= 0 && $0 < cardTotal }.sorted()
        guard !valid.isEmpty else { return }
        revision += 1   // 让进行中的动画回调失效

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
        handleWillSettle(scrollView, targetContentOffset: targetContentOffset)
    }

    /// 拖动松手将停：算出吸附落点、征询配额放行，通过则提交。
    private func handleWillSettle(_ scrollView: UIScrollView,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard !opQueue.busy else { return }   // 删卡/前进还在跑，先让行
        let h = heightOf(cursor)
        guard h > 0 else { return }

        let delta = scrollView.contentOffset.y - offsetOf(cursor)
        let dest = snapDestination(delta: delta, cardHeight: h)
        let swipe: BarajaSwipe = dest > cursor ? .discard : .recall

        if dest != cursor,
           let observer = observer,
           !observer.baraja(self, permitSwipe: swipe, toward: dest) {
            targetContentOffset.pointee.y = offsetOf(cursor)
            return
        }
        commitSettle(to: dest, swipe: swipe, targetContentOffset: targetContentOffset)
    }

    /// 位移换算吸附档：带符号的位移比例越过阈值就走向相邻卡；
    /// 落点夹在 [0, cardTotal]，上限 cardTotal 表示末张向上划走（见底）。
    private func snapDestination(delta: CGFloat, cardHeight h: CGFloat) -> Int {
        let fraction = delta / h
        let stepped: Int
        if fraction >= snapRatio {
            stepped = cursor + 1
        } else if fraction <= -snapRatio {
            stepped = cursor - 1
        } else {
            stepped = cursor
        }
        return max(0, min(stepped, cardTotal))
    }

    /// 提交落点：更新 cursor、写回停靠偏移，按需派发顶卡切换与临近续拉。
    private func commitSettle(to dest: Int, swipe: BarajaSwipe,
                             targetContentOffset: UnsafeMutablePointer<CGPoint>) {
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
        guard !opQueue.busy else { return }   // 删卡过程中不检测划出、也不派发拖动进度
        syncVisible()
        checkSweptCards()
        emitDragProgress(at: scrollView.contentOffset.y)
    }

    /// 拖动进度播报：把当前偏移换算成对顶卡的位移比例，越过极小阈值才通知（含方向）。
    private func emitDragProgress(at offsetY: CGFloat) {
        let h = heightOf(cursor)
        guard h > 0 else { return }
        let delta = offsetY - offsetOf(cursor)
        let progress = abs(delta) / h
        guard progress > 0.01 else { return }
        let swipe: BarajaSwipe = delta > 0 ? .discard : .recall
        observer?.baraja(self, draggedBy: progress, swipe: swipe)
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

    /// 停稳后回调：越过最后一张 → 见底；否则驱动顶卡展示。
    private func emitSettle() {
        if cursor >= cardTotal {
            observer?.barajaRanOut(self)
        } else {
            observer?.baraja(self, restedOn: cursor)
        }
    }
}
