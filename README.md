# PrWaiter

> 并行 PR 太多、合不进去，究竟该催哪一个？

PrWaiter 是一个 macOS 原生窗口 App：把手头的 PR 按**功能 / bug 归类**、按**先后关系**组织成树，
实时显示各自的 review / CI / 合并状态，一眼看出当前哪个 PR 已经万事俱备、该去催合并了。

![status](https://github.com/WloBy-Labs/PrWaiter/actions/workflows/build.yml/badge.svg)

## 设计原则

**本地只存 GitHub 不知道的事。**

PR 的标题、review 结论、CI 结论、是否已合并，GitHub 全都知道，`gh` 随时能查。
自己需要记录的只有 GitHub 不知道的那些：项目划分、功能描述、PR 之间的归属与先后。

所以本地数据文件（`~/Library/Application Support/PrWaiter/prs.json`）只存这些结构信息，
其余状态每次刷新都通过 `gh` 的**单次 GraphQL 批量查询**实时拉取，不存副本 —— 状态永远不会过期，
也没有任何同步逻辑需要维护。

## 安装

构建依赖：macOS 14+ 与 Command Line Tools（提供 `swiftc`，**不需要** Xcode 工程）。

```bash
./build.sh
open PrWaiter.app
```

运行依赖是 [GitHub CLI](https://cli.github.com/)，但**不用先自己装**：
首次打开如果没检测到 gh，齿轮按钮会变橙色，进设置页可以一键用 Homebrew 装，
装完再点「在终端登录」完成授权。想手动来也行：

```bash
brew install gh && gh auth login
```

没有 gh 时 App 不会崩，树结构、描述块、拖拽、折叠都照常可用，
只是拉不到 PR 的标题和 review / CI 状态 —— 因为本地只存结构，状态是实时拉的。

想常驻的话，把 `PrWaiter.app` 拖进 `/Applications` 即可。

> 当前处于 0.x 设计调试阶段，尚不提供预构建的 Release 包，请自行 `./build.sh`。

## 使用

界面分**冻结**与**编辑**两种模式，默认冻结（只读，防误触）。点右上角「编辑」进入编辑模式，
「完成」退回冻结。增删、拖动、改文字都只在编辑模式下可用。

### 组织结构

```
项目标签：[ StarRocks ] [ Trino ]        ← 每个标签一个仓库，切换后只看该项目

💬 修复 spill 内存统计            4 个 PR ← 描述块：写功能 / bug 说明，把相关 PR 收在下面
├── #77255  基础改动                 已合并
│   └── #77354  backport            ← 挂在 #77255 下面，表示要等它先合并
└── #77381  压缩改进
💬 查询内存统计              ▸ 3   3 个 PR ← 折叠起来了，▸3 表示里面还藏着 3 个块
#77408                                ← 新加的、还没归类的 PR 就留在根级
```

- **项目标签**：编辑模式下点 `+` 新增项目，下方填项目名与 `owner/repo`
- **描述块**：编辑模式下点「+ 描述块」新建，写上功能或 bug 的描述。
  描述块只能待在根级，右侧显示它下辖的 PR 数与其中可合并的数量
- **添加 PR**：填编号点「添加 PR」，新 PR 一律先落在根级，之后靠拖拽归类
- **折叠**：有子块的块最左边有一条整高的折叠区，**整条都可点**，收起 / 展开。
  `▸ N` 表示里面藏了几个块。折叠状态会存下来，重开 App 依然保持；
  冻结模式下也能折叠（它只是换个看法，不算改内容）。
  折叠**不影响统计** —— 汇总栏与描述块的计数仍把折叠起来的 PR 算在内
- **拖拽**：编辑模式下拖动块左侧的手柄 ——
  拖进描述块即归类，拖到另一个 PR 下面即表示「要等它先合并」，拖到底部虚线区回到根级。
  拖动会连整棵子树一起搬；成环或把描述块拖进别人下面会被拒绝。
  拖到已折叠的块上会自动展开，不会让东西看起来「拖没了」
- **删除**：点 `✕` 两次确认。子块会提升一层，不会跟着被删

### 状态

| 状态 | 含义 |
| --- | --- |
| 🟢 可合并 | 上面的 PR 全部已合并 + 已批准 + CI 通过 —— **该去催了** |
| 🟡 等 review/CI | 前置已就绪，自身还没过 review 或 CI |
| ⏳ 等依赖 | 树上游还有没合并的 PR |
| ✔ 已合并 / ✕ 已关闭 | 淡化显示，可用顶部「清理已合并」一键移除 |

顶部汇总栏会直接点名当前可以催的 PR。默认每分钟自动刷新（可在设置里改成 30 秒 / 5 分钟 /
只手动），也可点刷新按钮手动触发。冻结模式下点击 PR 编号可跳转 GitHub。

### 设置

项目标签那一行最右端的齿轮切换到设置页（不是弹窗，看板与设置是同一界面的两个页面），
设置页同一行左侧的返回箭头切回来，Esc 也行。窗口标题条只放应用名和版本，不挂按钮。
设置里有三块：

- **GitHub CLI** —— 显示 gh 的安装与登录状态、版本、可执行文件路径。没装可以一键安装，
  没登录可以开终端登录。装在非常规位置时可以填自定义路径
  （自动查找依次试 Homebrew、MacPorts、`PATH`，最后问一次登录 shell）
- **刷新** —— 自动刷新间隔
- **关于** —— 版本号与数据文件位置

### 数据格式

`~/Library/Application Support/PrWaiter/prs.json` 是纯文本，可以直接手工编辑
（缺失字段会回落到默认值，`id` 不写会自动生成）：

```json
{
  "projects": [
    {
      "name": "StarRocks",
      "repo": "StarRocks/starrocks",
      "nodes": [
        { "kind": "topic", "title": "修复 spill 内存统计", "collapsed": false, "children": [
            { "kind": "pr", "pr": 77255, "children": [
                { "kind": "pr", "pr": 77354, "note": "backport" }
            ]}
        ]},
        { "kind": "pr", "pr": 77408 }
      ]
    }
  ]
}
```

节点的父子关系就是先后关系：`children` 里的 PR 要等父 PR 先合并。
描述块（`kind: "topic"`）只做分组，不参与先后判断。

> 从 0.1.0 升级上来时，旧的 `{repo, prs:[{pr, after}]}` 会在首次启动时自动迁移，
> `after` 的第一个依赖成为父节点，其余降级写进备注。

## 开发

项目刻意保持极简，全部界面与逻辑就是一个 Swift 文件：

| 文件 | 作用 |
| --- | --- |
| `PrWaiter.swift` | 整个 App：数据模型、树操作、GitHub 拉取、SwiftUI 界面 |
| `Tests.swift` | 纯逻辑测试：树操作、拖拽合法性、数据迁移、JSON 往返 |
| `build.sh` | 一条 `swiftc` 命令产出 `PrWaiter.app` |
| `test.sh` | 跑测试（`-DTESTING` 关掉 `@main`，改由 `Tests.swift` 提供入口） |
| `release.sh` | 打 tag、构建、上传 GitHub Release |
| `VERSION` | 版本号的唯一来源，构建时注入 Info.plist |

改完代码 `./test.sh && ./build.sh && open PrWaiter.app` 即可验证。
界面交互（尤其拖拽）测试覆盖不到，需要手动过一遍。

> 编辑器可能对 `@main` 报 `'main' attribute cannot be used in a module that contains
> top-level code` —— 这是 SourceKit 未带 `-parse-as-library` 参数导致的误报，`build.sh`
> 与 `test.sh` 都带了该参数，实际编译无此问题。

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
