# Changelog

本项目的所有值得注意的改动都记录在此文件。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> **0.x 属于设计调试阶段**：只在此维护变更记录，不打 tag、不出包。
> 等设计稳定后再提升到 1.0.0，届时才开始发布 Release 包。

## [Unreleased]

## [0.1.0] - 2026-08-07

首个可用版本。

### Added

- macOS 原生窗口 App（SwiftUI 单文件，`swiftc` 直接构建，无需 Xcode 工程）
- 记录 PR 之间的先后依赖关系，列表按依赖缩进成树状展示
- 通过 `gh` CLI 的单次 GraphQL 批量查询实时拉取 PR 标题、作者、review 结论、CI 结论与合并状态
- 四档派生状态：**可合并**（依赖全部合并 + 已批准 + CI 通过）、**等 review/CI**、**等依赖**、**已合并/已关闭**
- 顶部汇总栏直接点名当前可以催合并的 PR，并提供「清理已合并」一键移除
- 卡片内可增删依赖、编辑备注、删除记录，PR 编号可点击跳转 GitHub
- 每 60 秒自动刷新，也可手动刷新
