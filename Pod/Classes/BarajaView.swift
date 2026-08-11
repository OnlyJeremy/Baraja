//
//  BarajaView.swift
//  Baraja
//
//  垂直卡片牌组容器：逐卡动态高度 + 只物化可视窗口的卡视图。
//  偏移表（heights/tops）保存全量高度，离屏卡无视图也能精确吸附；一屏一卡吸附、
//  双向回看、上滑划出（pass）、临近末尾预加载、限额门控、删卡皆具备。
//

import UIKit
import SnapKit

// MARK: - 有序变更队列

/// 卡片增删/前进等有序操作的串行执行器。
/// 动画进行时把后续操作排队，避免并发改写 topmost 游标与偏移表导致状态错乱。
final class BarajaMutationQueue {

    private var pending: [() -> Void] = []
    /// 是否有操作正在跑（滚动代理据此让行，避免与删卡争用状态）。
    private(set) var isRunning = false

    var isEmpty: Bool { pending.isEmpty }

    /// 排入一个操作；空闲则马上跑。
    func submit(_ work: @escaping () -> Void) {
        pending.append(work)
        pump()
    }

    /// 标记当前操作结束，接着跑下一个。
    func finish() {
        isRunning = false
        pump()
    }

    /// 丢弃全部待执行（reload 时用）。
    func flush() {
        pending.removeAll()
        isRunning = false
    }

    private func pump() {
        guard !isRunning, !pending.isEmpty else { return }
        isRunning = true
        let work = pending.removeFirst()
        DispatchQueue.main.async { work() }
    }
}

/// 卡片手势去向。
public enum BarajaGesture {
    case dismiss   // 上滑划出 = 略过（pass）
    case revisit   // 下滑回看（不产生业务动作）
}

// MARK: - 数据源

public protocol BarajaSource: AnyObject {
    func numberOfCards(in deck: BarajaView) -> Int
    func deck(_ deck: BarajaView, cardAt index: Int) -> UIView
    /// 第 index 张卡按 `width` 宽折叠到 `cap` 高后的实测高度。
    func deck(_ deck: BarajaView, heightAt index: Int, cap: CGFloat, width: CGFloat) -> CGFloat
}

// MARK: - 观察者

public protocol BarajaObserver: AnyObject {
    /// 吸附目标确定、顶卡切换时调用。
    func deck(_ deck: BarajaView, didAdvanceTo index: Int)
    /// 顶卡完全停稳后调用（驱动解读仪式等）。
    func deck(_ deck: BarajaView, didSettleOn index: Int)
    /// 卡片划出屏幕（带手势方向）；pass 上报走这里，**纯 index**，去重由业务层自取。
    func deck(_ deck: BarajaView, didDismiss index: Int, by gesture: BarajaGesture)
    /// 是否允许朝目标方向滑动（限额门控）。
    func deck(_ deck: BarajaView, shouldAllow gesture: BarajaGesture, to index: Int) -> Bool
    /// 临近末尾（倒数第 3 张）触发预加载。
    func deckNeedsMore(_ deck: BarajaView)
    /// 拖拽进度变化（震动反馈等）。
    func deck(_ deck: BarajaView, didDrag progress: CGFloat, gesture: BarajaGesture)
    /// 卡片被**删除**（非滑出），携原始 index；删除绝不触发 didDismiss。
    func deck(_ deck: BarajaView, didDropCardAt index: Int)
    /// 卡片视图被**回收**（滑出窗口、暂不在内存）；业务据此释放引用。
    func deck(_ deck: BarajaView, didRecycleCardAt index: Int)
    /// 卡片物化进窗口、已定帧上屏（本帧同步）；宿主据此同步定格已解读卡，避免滑回时闪一帧空白。
    func deck(_ deck: BarajaView, willDisplayCardAt index: Int)
    /// 卡高整表重测完成（首帧/旋转/分屏）；宿主据此把在场活卡按最新折叠档重新同步。
    func deckDidRemeasure(_ deck: BarajaView)
    /// 卡片全部用完（刷新拉空 / 删到空）。
    func deckDidEmpty(_ deck: BarajaView)
    /// 每帧滚动回调（宿主用于阴影渐隐等）。
    func deckDidScroll(_ deck: BarajaView)
}

// 默认空实现，让观察者各方法可选。
public extension BarajaObserver {
    func deck(_ deck: BarajaView, didAdvanceTo index: Int) {}
    func deck(_ deck: BarajaView, didSettleOn index: Int) {}
    func deck(_ deck: BarajaView, didDismiss index: Int, by gesture: BarajaGesture) {}
    func deck(_ deck: BarajaView, shouldAllow gesture: BarajaGesture, to index: Int) -> Bool { true }
    func deckNeedsMore(_ deck: BarajaView) {}
    func deck(_ deck: BarajaView, didDrag progress: CGFloat, gesture: BarajaGesture) {}
    func deck(_ deck: BarajaView, didDropCardAt index: Int) {}
    func deck(_ deck: BarajaView, didRecycleCardAt index: Int) {}
    func deck(_ deck: BarajaView, willDisplayCardAt index: Int) {}
    func deckDidRemeasure(_ deck: BarajaView) {}
    func deckDidEmpty(_ deck: BarajaView) {}
    func deckDidScroll(_ deck: BarajaView) {}
}

// MARK: - 容器

/// 自定义垂直卡片牌组。
///
/// **动态高度 + 窗口物化**：每张卡按折叠后的高度排布（heights/tops 全量偏移表），
/// 但**只让可视窗口附近的卡上屏**（liveCards），滑出即回收、滚回按数据重建 —— 内存
/// O(窗口)，不随预加载增长。高度由数据源**数据驱动**测得并缓存进偏移表，离屏卡无视图
/// 也能精确吸附。一屏一卡吸附、双向回看、滑出去重（pass 幂等）、预加载、限额门控、删除俱全。
public final class BarajaView: UIView {

    public weak var observer: BarajaObserver?
    public weak var source: BarajaSource?

    /// 卡片左右内缩（外部设置，= hPadding）。
    public var hInset: CGFloat = 0
    /// 卡间距（外部设置）。
    public var gap: CGFloat = 0

    private var total = 0
    private var topmost = 0

    /// 下一张露出自身高度的比例（微妙的偷看）。宿主可设 0 关闭偷看。
    public var peekRatio: CGFloat = 0.06

    /// 越过当前卡 5% 即吸附到相邻卡。
    private let snapThreshold: CGFloat = 0.05

    /// 卡高上限：留 peek 给下一张。
    private var cardCap: CGFloat { bounds.height * (1 - peekRatio) }
    /// 卡内容宽（去掉左右内缩）。
    private var innerWidth: CGFloat { bounds.width - 2 * hInset }

    /// 逐卡高度与累加 y 起点。
    private var heights: [CGFloat] = []
    private var tops: [CGFloat] = []

    /// 已回调过滑出的卡索引（防刷屏：滚动中同一张别每帧重复上报）。
    /// **纯 index**，权威去重在业务层；删卡后清空。
    private var dismissedFired: Set<Int> = []

    /// 有序变更队列（删卡/前进入队；reload 不入队，直接 flush 后重建）。
    private let mutations = BarajaMutationQueue()

    /// 重载代际：每次 reload 自增；过期动画 completion 检测到代际不符即跳过。
    private var generation = 0

    /// 上次预加载时的数据量，防止重复触发。
    private var lastPreloadCount = 0

    /// 上次完成布局的尺寸，避免每次 layoutSubviews 都重测。
    private var lastLayoutSize: CGSize = .zero

    private lazy var scrollView: UIScrollView = {
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

    private let canvas = UIView()
    /// **窗口物化**：只持有可视窗口附近已上屏的卡（index→view），其余回收。
    /// heights/tops 仍是全量偏移表，滚回时按数据重建即可。
    private var liveCards: [Int: UIView] = [:]

    /// 可视区上下额外保留的缓冲（各约一屏），确保上一张/下一张提前物化、滚动不见白。
    private var windowPad: CGFloat { bounds.height }

    // MARK: 只读透出（供宿主做阴影渐隐）

    /// 暴露内部滚动视图供 fadeShadows 计算相对偏移。
    public var scrollProxy: UIScrollView { scrollView }

    /// 当前已上屏的卡视图集合。
    public func mountedCards() -> [UIView] { Array(liveCards.values) }

    // MARK: 初始化

    public override init(frame: CGRect) {
        super.init(frame: frame)
        assemble()
    }

    public required init?(coder: NSCoder) { fatalError() }

    private func assemble() {
        backgroundColor = .clear
        addSubview(scrollView)
        scrollView.addSubview(canvas)
        scrollView.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard total > 0, bounds.height > 0, bounds.width > 0 else { return }
        // 卡高只是「内容 × 内容宽」的纯函数：仅在卡数或内容宽变化（首帧/旋转/分屏）时才重测重折；
        // 导航转场里视口高会瞬时抖动，若跟着重测会让跨挡卡忽折忽展造成跳变，故高度变化只做轻量重排。
        let needsMeasure = heights.count != total || bounds.width != lastLayoutSize.width
        let sizeChanged = bounds.size != lastLayoutSize
        if needsMeasure { remeasure() }
        if needsMeasure || sizeChanged {
            syncContentSize()
            scrollView.contentOffset.y = topOf(topmost)
            refreshWindow()
            relayout()
            // 真重测后（如旋转）折叠档可能变了，通知宿主把活卡按新档重新同步，避免内容与帧错位。
            if needsMeasure { observer?.deckDidRemeasure(self) }
        }
        lastLayoutSize = bounds.size
    }

    // MARK: 对外方法

    /// 整表重置到第一张（首批加载 / 空态重试 / 切数据）。
    public func reloadResettingToTop() {
        guard let source = source else { return }
        generation += 1
        mutations.flush()
        total = source.numberOfCards(in: self)
        topmost = 0
        lastPreloadCount = 0
        resetSwipeTracking()
        rebuildFromScratch()
        announceAfterRebuild()
    }

    /// 保位重载（原地数据变化：重建全部卡视图但**保留当前位置**）。
    public func reloadKeepingPosition() {
        guard let source = source else { return }
        generation += 1
        mutations.flush()
        total = source.numberOfCards(in: self)
        topmost = max(0, min(topmost, total - 1))
        lastPreloadCount = min(lastPreloadCount, total)
        resetSwipeTracking()
        rebuildFromScratch()
        scrollView.contentOffset.y = topOf(topmost)
        announceAfterRebuild()
    }

    /// 追加分页数据（只量新卡高度、延长偏移表；视图按窗口懒物化）。
    public func appendNewCards() {
        guard let source = source else { return }
        let oldCount = total
        total = source.numberOfCards(in: self)
        guard total > oldCount else { return }
        // 追加前已划到底/空态：追加后首张新卡即新顶卡，需吸附并驱动仪式。
        let wasExhausted = topmost >= oldCount
        if heights.count == oldCount, cardCap > 0, innerWidth > 0 {
            for index in oldCount..<total {
                heights.append(source.deck(self, heightAt: index, cap: cardCap, width: innerWidth))
            }
            rebuildTops()
        } else {
            remeasure()
        }
        syncContentSize()
        if wasExhausted {
            topmost = min(topmost, total - 1)
            scrollView.contentOffset.y = topOf(topmost)
        }
        refreshWindow()
        relayout()
        if wasExhausted {
            observer?.deck(self, didSettleOn: topmost)
        }
    }

    public func topIndex() -> Int { topmost }

    /// 程序化前进到下一张（用于 like / Say hi）。
    public func advance() {
        mutations.submit { [weak self] in
            self?.performAdvance()
        }
    }

    private func performAdvance() {
        let lastIndex = total - 1
        guard total > 0, topmost <= lastIndex else {
            mutations.finish()
            return
        }
        let targetIndex = topmost + 1
        let targetOffset = settleOffset(for: targetIndex)
        let gen = generation
        UIView.animate(withDuration: 0.3, animations: { [weak self] in
            self?.scrollView.contentOffset.y = targetOffset
        }, completion: { [weak self] _ in
            guard let self else { return }
            defer { self.mutations.finish() }
            guard gen == self.generation else { return }   // 期间发生 reload/删卡 → 丢弃
            let oldIndex = self.topmost
            self.topmost = targetIndex
            self.refreshWindow()
            if oldIndex != targetIndex {
                self.observer?.deck(self, didAdvanceTo: targetIndex)
            }
            // UIView.animate 不触发 didEndDecelerating，需手动驱动用尽 / 新顶卡仪式。
            if self.topmost >= self.total {
                self.observer?.deckDidEmpty(self)
            } else {
                self.observer?.deck(self, didSettleOn: targetIndex)
                self.preloadIfNeeded(targetIndex: targetIndex)
            }
        })
    }

    /// 落位偏移：已划过最后一张（index >= total）时停在「末张完全移出顶部」处（用尽）；否则停在该卡顶部。
    private func settleOffset(for index: Int) -> CGFloat {
        guard index < total else {
            let last = total - 1
            return topOf(last) + heightOf(last)
        }
        return topOf(index)
    }

    /// 删除当前顶卡：**无动画**，下一张直接顶到当前位置。
    /// 契约同 drop(at:)：调用方先删数据源对应卡。
    public func dropTop() {
        mutations.submit { [weak self] in
            guard let self else { return }
            self.performDrop(localIndices: [self.topmost])
            self.mutations.finish()
        }
    }

    /// 按索引批量删除（拉黑 / 已建会话等）。
    /// 契约：调用方须**先**把这些卡从自己的数据源移除（同一组索引），再调本方法。
    public func drop(at indices: [Int]) {
        mutations.submit { [weak self] in
            guard let self else { return }
            self.performDrop(localIndices: indices)
            self.mutations.finish()
        }
    }

    public func resetSwipeTracking() {
        dismissedFired.removeAll()
    }

    // MARK: 布局度量

    private func topOf(_ index: Int) -> CGFloat {
        guard index >= 0, index < tops.count else { return 0 }
        return tops[index]
    }

    private func heightOf(_ index: Int) -> CGFloat {
        guard index >= 0, index < heights.count else { return 0 }
        return heights[index]
    }

    /// 重建逐卡高度表（heights）与累加起点（tops）。
    private func remeasure() {
        guard let source = source, cardCap > 0, innerWidth > 0 else { return }
        heights = (0..<total).map {
            source.deck(self, heightAt: $0, cap: cardCap, width: innerWidth)
        }
        rebuildTops()
    }

    /// 由现有 heights 累加重算 tops（删卡后用，不重新量高）。
    private func rebuildTops() {
        tops = []
        var y: CGFloat = 0
        for h in heights {
            tops.append(y)
            y += h + gap
        }
    }

    // MARK: 私有

    /// 重建偏移表（数据驱动量高）并按窗口物化可视卡（**不发回调**）。
    private func rebuildFromScratch() {
        recycleAll()
        heights = []
        tops = []
        guard source != nil, total > 0 else {
            syncContentSize()
            canvas.frame = .zero
            return
        }
        remeasure()            // 量全高；bounds 未就绪则留空，交给 layoutSubviews
        syncContentSize()
        canvas.frame = CGRect(x: 0, y: 0, width: bounds.width,
                              height: (tops.last ?? 0) + (heights.last ?? 0))
        refreshWindow()        // 只物化可视窗口附近的卡
    }

    /// 回收全部已上屏卡，逐个通知业务释放引用。
    private func recycleAll() {
        let indices = Array(liveCards.keys)
        liveCards.values.forEach { $0.removeFromSuperview() }
        liveCards.removeAll()
        indices.forEach { observer?.deck(self, didRecycleCardAt: $0) }
    }

    /// 重建后异步通知：有卡 → 顶卡展示；无卡 → 空态。下一 runloop 等布局稳定。
    private func announceAfterRebuild() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.total > 0 {
                self.observer?.deck(self, didSettleOn: self.topmost)
            } else {
                self.observer?.deckDidEmpty(self)
            }
        }
    }

    private func relayout() {
        guard heights.count == total else { return }
        for (index, card) in liveCards {
            card.frame = CGRect(x: hInset, y: topOf(index),
                                width: innerWidth, height: heightOf(index))
        }
        let stackHeight = (tops.last ?? 0) + (heights.last ?? 0)
        canvas.frame = CGRect(x: 0, y: 0, width: bounds.width, height: stackHeight)
    }

    // MARK: 窗口物化

    /// 当前应物化的卡索引区间 = 与「可视矩形 ± windowPad」相交的卡。
    private func desiredWindow() -> ClosedRange<Int>? {
        guard total > 0, heights.count == total, bounds.height > 0 else { return nil }
        let topY = scrollView.contentOffset.y - windowPad
        let bottomY = scrollView.contentOffset.y + bounds.height + windowPad
        var first = -1, last = -1
        for index in 0..<total {
            let cardTopY = tops[index]
            let cardBottomY = tops[index] + heights[index]
            if cardBottomY >= topY && cardTopY <= bottomY {
                if first < 0 { first = index }
                last = index
            } else if first >= 0 {
                break   // tops 单调增，过区间即停
            }
        }
        if first < 0 {   // 还没量好/越界：退化到当前卡 ±1
            return max(0, topmost - 1)...min(total - 1, topmost + 1)
        }
        return first...last
    }

    /// 物化进窗口的卡、回收出窗口的卡（diff，只在变化时增删）。
    private func refreshWindow() {
        guard let range = desiredWindow(), let source = source else { return }
        for (index, card) in liveCards where !range.contains(index) {
            card.removeFromSuperview()
            liveCards[index] = nil
            observer?.deck(self, didRecycleCardAt: index)
        }
        for index in range where liveCards[index] == nil {
            let card = source.deck(self, cardAt: index)
            card.frame = CGRect(x: hInset, y: topOf(index),
                                width: innerWidth, height: heightOf(index))
            canvas.addSubview(card)
            liveCards[index] = card
            // 定帧后同步通知宿主：已解读卡在入画同一帧即定格揭示，去掉「无→有」的一帧空白。
            card.layoutIfNeeded()
            observer?.deck(self, willDisplayCardAt: index)
        }
    }

    private func syncContentSize() {
        let stackHeight = (tops.last ?? 0) + (heights.last ?? 0)
        scrollView.contentSize = CGSize(width: bounds.width, height: stackHeight)
        // 预留一屏底部内距：让矮的最后一张能吸附到顶，并给「末张上滑划出」留出滚动空间。
        scrollView.contentInset.bottom = max(0, bounds.height)
    }

    /// 检测向上完全滑出屏幕的卡（= pass），按 index 防刷屏回调一次。
    private func detectDismiss() {
        guard topmost > 0 else { return }
        let offsetY = scrollView.contentOffset.y
        for index in 0..<topmost {
            guard !dismissedFired.contains(index) else { continue }
            if offsetY > topOf(index) + heightOf(index) {
                fireDismiss(at: index, gesture: .dismiss)
            }
        }
    }

    private func fireDismiss(at index: Int, gesture: BarajaGesture) {
        guard index >= 0, index < total else { return }
        dismissedFired.insert(index)
        observer?.deck(self, didDismiss: index, by: gesture)
    }

    /// 删除若干卡（全量索引，降序处理）：删 heights 项、重算 tops、补偿 contentOffset，
    /// 回收全部上屏卡后按窗口重建，并发删除/展示/空态/预加载回调。
    private func performDrop(localIndices: [Int]) {
        let valid = localIndices.filter { $0 >= 0 && $0 < total }.sorted()
        guard !valid.isEmpty else { return }
        generation += 1   // 失效进行中的动画 completion

        let removedBeforeTop = valid.filter { $0 < topmost }.count
        var removedHeightAboveTop: CGFloat = 0
        for i in valid where i < topmost {
            removedHeightAboveTop += heightOf(i) + gap
        }
        let removingTop = valid.contains(topmost)

        recycleAll()

        for i in valid.sorted(by: >) where i < heights.count {
            heights.remove(at: i)
        }
        total = max(0, total - valid.count)
        topmost = max(0, min(topmost - removedBeforeTop, total - 1))
        dismissedFired.removeAll()

        rebuildTops()
        syncContentSize()

        if total > 0 {
            if removingTop {
                scrollView.contentOffset.y = topOf(topmost)
            } else if removedHeightAboveTop > 0 {
                scrollView.contentOffset.y = max(0, scrollView.contentOffset.y - removedHeightAboveTop)
            }
        }

        valid.forEach { observer?.deck(self, didDropCardAt: $0) }

        if total == 0 {
            canvas.frame = .zero
            observer?.deckDidEmpty(self)
            return
        }
        refreshWindow()
        if removingTop || removedBeforeTop > 0 {
            observer?.deck(self, didSettleOn: topmost)
        }
        lastPreloadCount = min(lastPreloadCount, total)
        preloadIfNeeded(targetIndex: topmost)
    }

    private func preloadIfNeeded(targetIndex: Int) {
        if targetIndex >= total - 3, total > lastPreloadCount {
            lastPreloadCount = total
            observer?.deckNeedsMore(self)
        }
    }
}

// MARK: - UIScrollViewDelegate

extension BarajaView: UIScrollViewDelegate {

    public func scrollViewWillEndDragging(_ scrollView: UIScrollView,
                                   withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard !mutations.isRunning else { return }   // 删卡/前进进行中，让行
        let h = heightOf(topmost)
        guard h > 0 else { return }
        let offsetFromTop = scrollView.contentOffset.y - topOf(topmost)

        var targetIndex: Int
        if offsetFromTop > 0 {
            targetIndex = (offsetFromTop / h) >= snapThreshold ? topmost + 1 : topmost
        } else {
            targetIndex = (abs(offsetFromTop) / h) >= snapThreshold ? topmost - 1 : topmost
        }
        // 允许到 total = 末张向上划出（用尽）；其余夹在有效区间。
        targetIndex = max(0, min(targetIndex, total))

        let gesture: BarajaGesture = targetIndex > topmost ? .dismiss : .revisit

        if targetIndex != topmost,
           let observer = observer,
           !observer.deck(self, shouldAllow: gesture, to: targetIndex) {
            targetContentOffset.pointee.y = topOf(topmost)
            return
        }

        let oldIndex = topmost
        topmost = targetIndex
        targetContentOffset.pointee.y = settleOffset(for: targetIndex)

        if oldIndex != targetIndex {
            observer?.deck(self, didAdvanceTo: targetIndex)
        }
        if gesture == .dismiss {
            preloadIfNeeded(targetIndex: targetIndex)
        }
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        observer?.deckDidScroll(self)
        guard !mutations.isRunning else { return }   // 删卡期间不检测滑出/不发拖拽进度
        refreshWindow()
        detectDismiss()
        let h = heightOf(topmost)
        guard h > 0 else { return }
        let offsetFromTop = scrollView.contentOffset.y - topOf(topmost)
        let progress = abs(offsetFromTop) / h
        if progress > 0.01 {
            let gesture: BarajaGesture = offsetFromTop > 0 ? .dismiss : .revisit
            observer?.deck(self, didDrag: progress, gesture: gesture)
        }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        notifySettled()
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { notifySettled() }
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        notifySettled()
    }

    /// 落定后回调：已划过最后一张 → 用尽；否则驱动顶卡展示。
    private func notifySettled() {
        if topmost >= total {
            observer?.deckDidEmpty(self)
        } else {
            observer?.deck(self, didSettleOn: topmost)
        }
    }
}
