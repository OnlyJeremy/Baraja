//
//  DemoStoryCardView.swift
//  BarajaExample
//
//  报刊风格的竖向故事卡：用 Auto Layout 自排版，供 Baraja 物化与离屏测高使用。
//

import UIKit

struct DemoStory {
    let kicker: String
    let title: String
    let body: String
    let author: String
}

final class DemoStoryCardView: UIView {

    private let card = UIView()
    private let kickerLabel = UILabel()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let divider = UIView()
    private let authorLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .clear

        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        kickerLabel.font = .systemFont(ofSize: 12, weight: .heavy)
        kickerLabel.textColor = .systemPink
        kickerLabel.numberOfLines = 1

        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0

        bodyLabel.font = .systemFont(ofSize: 16, weight: .regular)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 0

        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        authorLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        authorLabel.textColor = .tertiaryLabel
        authorLabel.numberOfLines = 1

        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        [kickerLabel, titleLabel, bodyLabel, divider, authorLabel].forEach { stack.addArrangedSubview($0) }
        stack.setCustomSpacing(8, after: kickerLabel)
        stack.setCustomSpacing(16, after: bodyLabel)
        stack.setCustomSpacing(16, after: divider)

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
        ])
    }

    func configure(with story: DemoStory) {
        kickerLabel.text = story.kicker.uppercased()
        titleLabel.text = story.title
        bodyLabel.text = story.body
        authorLabel.text = "— \(story.author)"
    }

    /// 给定宽度下自排版得到的高度（用于 Baraja 的离屏测高）。
    func fittingHeight(width: CGFloat) -> CGFloat {
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let size = systemLayoutSizeFitting(target,
                                           withHorizontalFittingPriority: .required,
                                           verticalFittingPriority: .fittingSizeLevel)
        return ceil(size.height)
    }
}
