# Baraja

垂直卡片牌组容器 —— 以「一屏一卡」的报刊翻阅方式呈现内容。

*Baraja*（西班牙语「一副牌」）是一个高性能的垂直卡片堆叠视图：逐卡动态高度、
只物化可视窗口附近的卡视图，内存占用 O(窗口)，不随预加载增长。

## 特性

- **动态高度**：每张卡按折叠后的高度排布，高度由数据源数据驱动测得并缓存进偏移表，离屏卡无视图也能精确吸附。
- **窗口物化**：只让可视窗口附近的卡上屏，滑出即回收、滚回按数据重建。
- **一屏一卡吸附**：越过当前卡阈值即吸附到相邻卡。
- **双向回看**：上滑划出（pass），下滑回看。
- **预加载与门控**：临近末尾触发预加载，可对滑动方向做限额门控。
- **批量删卡**：按索引删除或删除顶卡。

## 安装

CocoaPods：

```ruby
pod 'Baraja'
```

## 使用

```swift
import Baraja

let deck = BarajaView()
deck.source = self
deck.observer = self
deck.sideInset = 16
deck.cardSpacing = 12
deck.peekFraction = 0.06
```

### 数据源 `BarajaSource`

```swift
func cardCount(in board: BarajaView) -> Int
func baraja(_ board: BarajaView, viewForCardAt index: Int) -> UIView
func baraja(_ board: BarajaView, heightForCardAt index: Int, maxHeight: CGFloat, width: CGFloat) -> CGFloat
```

`heightForCardAt` 返回第 `index` 张卡按 `width` 宽折叠到 `maxHeight` 高后的实测高度。

### 观察者 `BarajaObserver`

所有方法均有默认空实现，按需实现即可：

```swift
func baraja(_ board: BarajaView, movedToTop index: Int)
func baraja(_ board: BarajaView, restedOn index: Int)
func baraja(_ board: BarajaView, sweptAway index: Int, via swipe: BarajaSwipe)
func baraja(_ board: BarajaView, permitSwipe swipe: BarajaSwipe, toward index: Int) -> Bool
func barajaWantsMore(_ board: BarajaView)
func baraja(_ board: BarajaView, draggedBy progress: CGFloat, swipe: BarajaSwipe)
func baraja(_ board: BarajaView, removedCardAt index: Int)
func baraja(_ board: BarajaView, releasedCardAt index: Int)
func baraja(_ board: BarajaView, aboutToShowCardAt index: Int)
func barajaDidResize(_ board: BarajaView)
func barajaRanOut(_ board: BarajaView)
func barajaDidScroll(_ board: BarajaView)
```

### 常用方法

| 方法 | 说明 |
| --- | --- |
| `reloadFromStart()` | 整表重置到第一张（首批加载 / 空态重试 / 切数据） |
| `reloadInPlace()` | 保位重载（原地数据变化，保留当前位置） |
| `appendCards()` | 追加分页数据 |
| `stepForward()` | 程序化前进到下一张 |
| `removeTop()` | 删除当前顶卡 |
| `remove(at:)` | 按索引批量删除 |
| `currentIndex()` | 当前顶卡索引 |
| `clearSwipeState()` | 重置滑出去重记录 |
| `visibleCards()` | 当前已上屏的卡视图集合 |
| `scrollHost` | 内部滚动视图（供阴影渐隐等计算相对偏移） |

> 删卡契约：调用 `removeTop()` / `remove(at:)` 前，须先把对应卡从你自己的数据源移除（同一组索引）。

## 环境要求

- iOS 14.0+
- Swift 5.0+

## License

Baraja 基于 MIT 协议开源，详见 [LICENSE](LICENSE)。
