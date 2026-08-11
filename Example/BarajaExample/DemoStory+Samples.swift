//
//  DemoStory+Samples.swift
//  BarajaExample
//
//  演示用的假数据，故意让每张卡的正文长短不一，以展示逐卡动态高度。
//

import Foundation

extension DemoStory {

    static var samples: [DemoStory] {
        [
            DemoStory(
                kicker: "Headline",
                title: "潮水退去时，灯塔仍亮着",
                body: "清晨的海面像一块被揉皱又铺平的锡纸。她把最后一封没寄出的信折成纸船，放进退潮的浪里，看它摇摇晃晃地驶向那束光。",
                author: "海岸线周刊"
            ),
            DemoStory(
                kicker: "Culture",
                title: "一间只在雨天营业的旧书店",
                body: "老板说，晴天的字太亮，读起来发慌；只有雨声能把纸上的墨压得沉一些。于是这家店的招牌永远写着「今日或许开门」。常客们学会了看云——云厚到某个程度，他们就揣着伞出门，像赴一场心照不宣的约。书架之间没有分类，只有老板随手贴的便签：这本适合失眠，那本适合刚失恋，最上层那一排，适合谁都不想见的下午。",
                author: "城市漫游者"
            ),
            DemoStory(
                kicker: "Science",
                title: "候鸟如何在夜里辨认方向",
                body: "它们把星空当成一张会转动的地图，把地磁当成随身的罗盘。",
                author: "自然观察"
            ),
            DemoStory(
                kicker: "Feature",
                title: "他用二十年，把一条巷子走成了一部纪录片",
                body: "第一年，他只是拍下巷口那棵歪脖子树。第二年，树下多了个修鞋摊。第五年，修鞋的老张有了徒弟。第十年，徒弟出师，摊子搬去了街对面，树也被台风折了半边。他把这些零碎的镜头剪在一起，才发现所谓时代，不过是同一个取景框里，人来了又走、走了又来。放映那天，老张坐在最后一排，看到自己年轻的手，忽然把脸埋进了掌心。",
                author: "纪实档案"
            ),
            DemoStory(
                kicker: "Short",
                title: "便利店的第三个凳子",
                body: "没人知道它为谁而留，但每个深夜都有人坐下。",
                author: "深夜食堂"
            ),
            DemoStory(
                kicker: "Essay",
                title: "论一杯凉透了的茶",
                body: "凉茶不是失败的热茶。它只是换了一种节奏，等你终于想起它的时候，正好不烫嘴。",
                author: "慢生活手记"
            ),
        ]
    }
}
