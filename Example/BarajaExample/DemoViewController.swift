//
//  DemoViewController.swift
//  BarajaExample
//
//  Baraja 竖向牌组演示：一屏一卡吸附、上滑略过（pass）、下滑回看、临近末尾预加载。
//

import UIKit
import Baraja

final class DemoViewController: UIViewController {

    private let deck = BarajaView()
    private let hintLabel = UILabel()

    /// 供离屏测高复用的卡片实例（不上屏）。
    private let sizingCard = DemoStoryCardView()

    private var stories: [DemoStory] = DemoStory.samples

    private var hInset: CGFloat { 20 }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Baraja"

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh, target: self, action: #selector(reset))

        hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hintLabel.textColor = .tertiaryLabel
        hintLabel.textAlignment = .center
        hintLabel.text = "上滑略过 · 下滑回看"
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        deck.source = self
        deck.observer = self
        deck.hInset = hInset
        deck.gap = 0
        deck.peekRatio = 0.06
        deck.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(deck)
        view.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            deck.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            deck.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            deck.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            deck.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -8),

            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 首帧尺寸就绪后铺满第一批。
        if deck.topIndex() == 0, deck.mountedCards().isEmpty, !stories.isEmpty {
            deck.reloadResettingToTop()
        }
    }

    @objc private func reset() {
        stories = DemoStory.samples
        deck.reloadResettingToTop()
    }
}

// MARK: - BarajaSource

extension DemoViewController: BarajaSource {

    func numberOfCards(in deck: BarajaView) -> Int { stories.count }

    func deck(_ deck: BarajaView, cardAt index: Int) -> UIView {
        let card = DemoStoryCardView()
        card.configure(with: stories[index])
        return card
    }

    func deck(_ deck: BarajaView, heightAt index: Int, cap: CGFloat, width: CGFloat) -> CGFloat {
        sizingCard.configure(with: stories[index])
        return min(sizingCard.fittingHeight(width: width), cap)
    }
}

// MARK: - BarajaObserver

extension DemoViewController: BarajaObserver {

    func deck(_ deck: BarajaView, didSettleOn index: Int) {
        title = "Story \(index + 1) / \(stories.count)"
    }

    func deck(_ deck: BarajaView, didDismiss index: Int, by gesture: BarajaGesture) {
        print("[Baraja] pass at \(index)")
    }

    func deckNeedsMore(_ deck: BarajaView) {
        // 演示分页：临近末尾时再补一批。
        let more = DemoStory.samples
        stories.append(contentsOf: more)
        deck.appendNewCards()
    }

    func deckDidEmpty(_ deck: BarajaView) {
        title = "都看完啦"
    }
}
