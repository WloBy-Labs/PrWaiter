# PrWaiter

> 并行 PR 太多、合不进去，究竟该催哪一个？

PrWaiter 是一个 macOS 原生窗口 App：记录 PR 之间的**先后依赖关系**，实时可视化各自的
review / CI / 合并状态，一眼看出当前哪个 PR 已经万事俱备、该去催合并了。

![status](https://github.com/WloBy-Labs/PrWaiter/actions/workflows/build.yml/badge.svg)

## 设计原则

**本地只存 GitHub 不知道的事。**

PR 的标题、review 结论、CI 结论、是否已合并，GitHub 全都知道，`gh` 随时能查。
自己需要记录的只有 GitHub 不知道的那件事：PR 之间的依赖关系，以及备注。

所以本地数据文件（`~/Library/Application Support/PrWaiter/prs.json`）只存依赖边和备注，
其余状态每次刷新都通过 `gh` 的**单次 GraphQL 批量查询**实时拉取，不存副本 —— 状态永远不会过期，
也没有任何同步逻辑需要维护。

## 安装

依赖：

- macOS 14+ 与 Command Line Tools（提供 `swiftc`，**不需要** Xcode 工程）
- [GitHub CLI](https://cli.github.com/) 且已登录：`brew install gh && gh auth login`

构建并运行：

```bash
./build.sh
open PrWaiter.app
```

想常驻的话，把 `PrWaiter.app` 拖进 `/Applications` 即可。

> 当前处于 0.x 设计调试阶段，尚不提供预构建的 Release 包，请自行 `./build.sh`。

## 使用

1. 顶部填写仓库（`owner/repo` 形式，例如 `StarRocks/starrocks`）
2. 添加 PR：**编号** + **依赖的 PR 编号**（逗号分隔，可留空）+ **备注**（可留空）
3. 列表会按依赖关系缩进成树，每 60 秒自动刷新，也可点刷新按钮手动触发

状态含义：

| 状态 | 含义 |
| --- | --- |
| 🟢 可合并 | 依赖全部已合并 + 已批准 + CI 通过 —— **该去催了** |
| 🟡 等 review/CI | 依赖已就绪，自身还没过 review 或 CI |
| ⏳ 等依赖 | 前置 PR 还没合并 |
| ✔ 已合并 / ✕ 已关闭 | 淡化显示，可用顶部「清理已合并」一键移除 |

卡片上可随时增删依赖（`+依赖` 输入框回车）、编辑备注（回车保存）、删除记录；
PR 编号可点击直接跳转 GitHub。

### 数据格式

`~/Library/Application Support/PrWaiter/prs.json` 是纯文本，可以直接手工编辑：

```json
{
  "repo": "StarRocks/starrocks",
  "prs": [
    { "pr": 77255, "after": [], "note": "" },
    { "pr": 77354, "after": [77255], "note": "#77255 的 backport" }
  ]
}
```

`after` 表示「这个 PR 需要等哪些 PR 先合并」。

## 开发

项目刻意保持极简，全部源码就是一个 Swift 文件：

| 文件 | 作用 |
| --- | --- |
| `PrWaiter.swift` | 整个 App：数据模型、GitHub 拉取、SwiftUI 界面 |
| `build.sh` | 一条 `swiftc` 命令产出 `PrWaiter.app` |
| `release.sh` | 打 tag、构建、上传 GitHub Release |
| `VERSION` | 版本号的唯一来源，构建时注入 Info.plist |

改完代码 `./build.sh && open PrWaiter.app` 即可验证。

> 编辑器可能对 `@main` 报 `'main' attribute cannot be used in a module that contains
> top-level code` —— 这是 SourceKit 未带 `-parse-as-library` 参数导致的误报，`build.sh`
> 已带该参数，实际编译无此问题。

### 协作约定

**分支**：全小写的类型前缀 + 简短描述，例如 `bugfix/ci-badge-404`、`feature/menu-bar-mode`。

**PR 标题**：以方括号类型前缀开头，类型用驼峰写法：

| 前缀 | 用途 |
| --- | --- |
| `[Feature]` | 新功能 |
| `[BugFix]` | 修复缺陷 |
| `[Enhancement]` | 已有功能的改进、体验优化 |
| `[Refactor]` | 重构，不改变外部行为 |
| `[Misc]` | 杂项：文档、CI、依赖、构建脚本等 |

例：分支 `bugfix/stale-ci-state`，PR 标题 `[BugFix] 修复 CI 状态在强推后不刷新`。

改动合入后，同步在 `CHANGELOG.md` 的 `[Unreleased]` 小节补一条。

## 版本与发版

版本号唯一来源是 `VERSION` 文件，构建时注入 Info.plist，App 界面上会显示。

当前 **0.x 属于设计调试阶段**：只维护 `CHANGELOG.md`，不打 tag、不出包
（`release.sh` 在 0.x 下会主动拒绝执行）。

等设计稳定、升到 1.0.0 之后，发版流程是：

1. 更新 `VERSION`
2. 在 `CHANGELOG.md` 顶部新增对应版本小节，把 `[Unreleased]` 里累积的条目挪过去
3. 提交并推送
4. 执行 `./release.sh` —— 它会校验工作区干净、从 CHANGELOG 抽取 release notes、
   构建并打包 `.app`、打 tag 并创建 GitHub Release

## License

[MIT](LICENSE) © WloBy Labs
