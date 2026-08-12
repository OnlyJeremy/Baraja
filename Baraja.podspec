Pod::Spec.new do |s|
  s.name             = 'Baraja'
  s.version          = '1.0.0'
  s.summary          = '垂直卡片牌组容器 UI 组件'

  s.description      = <<-DESC
    Baraja 是一个高性能的垂直卡片牌组容器视图，
    以一屏一卡的报刊翻阅方式呈现。

    特性：
    - 逐卡动态高度，数据驱动量高并缓存偏移表
    - 只物化可视窗口附近的卡视图，内存 O(窗口)
    - 一屏一卡吸附、双向回看、上滑划出（pass）
    - 临近末尾预加载、限额门控、批量删卡
  DESC

  s.homepage         = 'https://github.com/OnlyJeremy/Baraja'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'OnlyJeremy' => 'songjinfeng2@163.com' }
  s.source           = { :git => 'https://github.com/OnlyJeremy/Baraja.git', :tag => s.version.to_s }

  s.ios.deployment_target = '14.0'
  s.swift_version = '5.7'

  s.source_files = 'Pod/Classes/**/*.swift'

  s.dependency 'SnapKit'
end
