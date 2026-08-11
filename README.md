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

## 下载与安装

[Releases](https://github.com/WloBy-Labs/PrWaiter/releases) 里有拖拽安装的 DMG。
打开后把 PrWaiter 拖进 Applications 即可。

> Release 包用固定的自签身份签名（`PrWaiter Signing`），但证书没经过 Apple 公证，
> 所以**首次打开 Gatekeeper 会警告**：在「系统设置 → 隐私与安全性」里点一次
> 「仍要打开」，或者右键点 App 选「打开」。去掉这个警告需要付费的 Developer ID 加公证。

运行还需要 [GitHub CLI](https://cli.github.com/)，PR 的实时状态靠它拉取。
**不用先自己装**：首次打开如果没检测到 gh，齿轮按钮会变橙色，进设置页可以一键用
Homebrew 装，装完再点「在终端登录」完成授权。想手动来也行：

```bash
brew install gh && gh auth login
```

没有 gh 时 App 不会崩，树结构、描述块、拖拽、折叠都照常可用，
只是拉不到 PR 的标题和 review / CI 状态 —— 因为本地只存结构，状态是实时拉的。

### 自己构建

依赖只有 macOS 14+ 与 Command Line Tools（提供 `swiftc`，**不需要** Xcode 工程）。

```bash
./build.sh && open PrWaiter.app     # 开发时这样就够
```

要出和 Release 一样的产物：

```bash
scripts/bootstrap_local_signing.sh   # 一次性：建立稳定的本地签名身份（可选）
scripts/package_app.sh               # 产出 dist/PrWaiter.app
scripts/make_dmg.sh                  # 产出 dist/PrWaiter-<版本>.dmg
```

不跑 `bootstrap_local_signing.sh` 的话走 ad-hoc 签名，一样能用，只是每次构建的
签名都不同。PrWaiter 不申请任何系统权限（屏幕录制之类），所以稳定签名在这里
**不涉及「保住权限」**，只是让 App 在系统眼里始终是同一个身份。

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
- **自动导入**：每次刷新会把该仓库下**作者是你、或指派给你**的 open PR 导进来，
  落在根级**最上面**，之后靠拖拽归类。**每个 PR 只导入一次** —— 删掉之后不会被导回来，
  已合并 / 已关闭的也不会被自动清走（树上游那些已合并的 PR 正是判断下游解没解除阻塞的依据）。
  算上 assignee 是因为机器人（如 `app/mergify`）自动建的 backport 作者是 bot、
  只把你设成指派人，光看 author 会漏掉。可以在设置里关掉
- **backport 自动聚合**：标题里认出 `(backport #77408)` 就直接挂到父 PR 下面 ——
  backport 本来就是「等主干先合」的先后关系。也认 `backport of #N` / `cherry-pick #N`。
  认不出父 PR、或父 PR 不在树里的，照旧落在根级
- **已关闭的关联 PR 也会进来**：只收和已跟踪 PR 有关系的那些（某个已跟踪 PR 的 backport，
  或某个已跟踪 backport 的父 PR）。这样「主干合了但某个 backport 被关掉」会直接显在树上，
  而不是把历史上几十个无关 PR 全倒进来
- **手工添加 PR**：填编号点「添加 PR」，用于导入别人的 PR 或已关掉自动导入时
  （新建的描述块同样放最上面）
- **折叠**：有子块的块最左边有一条整高的折叠区，**整条都可点**，收起 / 展开。
  `▸ N` 表示里面藏了几个块。折叠状态会存下来，重开 App 依然保持；
  冻结模式下也能折叠（它只是换个看法，不算改内容）。
  折叠**不影响统计** —— 汇总栏与描述块的计数仍把折叠起来的 PR 算在内
- **拖拽**：编辑模式下拖动块左侧的手柄。落点决定意图：
  - 落在**块身上** = 成为它的子块（拖进描述块即归类，拖到 PR 下即表示「要等它先合并」）
  - 落在**根级块之间** = 排到那个位置（拖拽时会显示一条插入线）；嵌套的块拖到缝里
    等于同时出组 + 定位
  - 落在**底部虚线区** = 回到根级末尾

  拖动会连整棵子树一起搬；成环或把描述块拖进别人下面会被拒绝。
  拖到已折叠的块上会自动展开，不会让东西看起来「拖没了」
- **删除**：点 `✕` 两次确认。子块会提升一层，不会跟着被删

### 状态

每个 PR 落在且只落在一个状态里，所以描述块右侧的分项数加起来正好等于 PR 总数。
优先级从上到下，先命中先算：

| 状态 | 颜色 | 含义 |
| --- | --- | --- |
| 已合并 | 紫 | 成了 |
| 已关闭 | 灰 | 关掉了，没合 |
| 草稿 | 灰 | Draft PR，还没打算让人看 |
| CI 失败 | 红 | CI 红了 —— **该你动手**，所以排在「等依赖」前面 |
| 需修改 | 红 | reviewer 要求改 —— 同上，该你动手 |
| 等依赖 | 靛 | 树上游还有没合并的 PR |
| CI 运行中 | 橙 | 等机器 |
| 等 review | 蓝 | 等人，可以去催 |
| 可合并 | 绿 | 上游全合了 + 已批准 + CI 通过 —— **该去催了** |

配色按「这件事欠在谁身上」分，**灰色只留给已终结的**：绿=可以动了、红=欠在你身上、
橙=等机器、蓝=等人、靛=等上游、紫=已合并、灰=已关闭 / 草稿。

「CI 失败」「需修改」排在「等依赖」前面是刻意的：你的 CI 红了就是红了，
上游合没合并不影响这件事该你去修。

描述块右侧按状态分项显示徽标（图标 + 数量），每个图标是什么状态见设置里的「状态说明」。
默认每分钟自动刷新（可在设置里改成 30 秒 / 5 分钟 / 只手动），也可点刷新按钮手动触发。
冻结模式下点击 PR 编号可跳转 GitHub。每行右侧显示 PR 的创建人，
**不是你创建的会加重显示** —— 机器人代建的 backport 一眼认得出。

**切换项目标签不会重新拉取**：每个项目的状态分开缓存，切过去上次的数据立刻显示，
「更新于」的时间也是那个项目自己的。要最新的自己点刷新，定时器下一拍也会带上。
只有从没拉过的项目才会在切过去时拉一次。

### 设置

项目标签那一行最右端的齿轮切换到设置页（不是弹窗，看板与设置是同一界面的两个页面），
设置页同一行左侧的返回箭头切回来，Esc 也行。窗口标题条只放应用名和版本，不挂按钮。
设置里有三块：

- **GitHub CLI** —— 显示 gh 的安装与登录状态、版本、可执行文件路径。没装可以一键安装，
  没登录可以开终端登录。装在非常规位置时可以填自定义路径
  （自动查找依次试 Homebrew、MacPorts、`PATH`，最后问一次登录 shell）
- **刷新** —— 自动刷新间隔、是否自动导入我的 open PR
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
      ],
      "imported": [77255, 77354, 77408]
    }
  ]
}
```

节点的父子关系就是先后关系：`children` 里的 PR 要等父 PR 先合并。
描述块（`kind: "topic"`）只做分组，不参与先后判断。
`imported` 记录自动导入过的编号，删掉的 PR 靠它避免被反复导回来。

> 从 0.1.0 升级上来时，旧的 `{repo, prs:[{pr, after}]}` 会在首次启动时自动迁移，
> `after` 的第一个依赖成为父节点，其余降级写进备注。

## 开发

项目刻意保持极简，全部界面与逻辑就是一个 Swift 文件：

| 文件 | 作用 |
| --- | --- |
| `PrWaiter.swift` | 整个 App：数据模型、树操作、GitHub 拉取、SwiftUI 界面 |
| `Tests.swift` | 纯逻辑测试：树操作、拖拽合法性、数据迁移、JSON 往返 |
| `make-icon.swift` | 用代码画 App 图标，构建时生成 `.icns`，不往仓库塞二进制 |
| `build.sh` | 一条 `swiftc` 命令产出 `PrWaiter.app` |
| `test.sh` | 跑测试（`-DTESTING` 关掉 `@main`，改由 `Tests.swift` 提供入口） |
| `release.sh` | 校验 + 打 tag，构建交给 CI |
| `scripts/package_app.sh` | 构建并签名 `dist/PrWaiter.app` |
| `scripts/make_dmg.sh` | 打成带 Applications 拖拽目标的 DMG |
| `scripts/bootstrap_local_signing.sh` | 一次性建立本地稳定签名身份 |
| `scripts/make_signing_cert.sh` | 生成给 CI 用的固定自签证书 |
| `VERSION` | 版本号的唯一来源，构建时注入 Info.plist |

改完代码 `./test.sh && ./build.sh && open PrWaiter.app` 即可验证。
界面交互（尤其拖拽）测试覆盖不到，需要手动过一遍。

### 图标

图标是程序化绘制的，不是图片资产：`make-icon.swift` 输出一整套 iconset，
`build.sh` 再用 `iconutil` 打成 `.icns` 塞进 app bundle。想单独预览：

```bash
swift make-icon.swift /tmp/preview.iconset
```

`.icns` 允许每个尺寸用不同画面，所以这里做了尺寸降级：128px 以上带 WLOBY PR 字标，
64px 及以下只留树形图，16px 再简化成两层。这不是偷懒 —— 七个字符在 32px 下
每个只有约 4px 宽，画上去只是一团噪点。

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

版本号唯一来源是 `VERSION` 文件，构建时注入 Info.plist，设置页里能看到。

发版流程：

1. 更新 `VERSION`
2. 在 `CHANGELOG.md` 顶部新增对应版本小节，把 `[Unreleased]` 里累积的条目挪过去
3. 写 `release_notes/v<版本>.md`（没有的话 CI 会自动生成，但不如手写）
4. 提交并推送到 main
5. 执行 `./release.sh` —— 它只做校验和打 tag：工作区干净、在 main 上、
   与 origin/main 一致、CHANGELOG 有对应小节、测试通过，然后推 tag

推上 tag 之后 GitHub Actions 负责构建、签名、打 DMG 并创建 Release。

### 签名

发布签名分三档，配到哪档就到哪档，都能出包：

| 配置 | 效果 |
| --- | --- |
| 什么都不配 | ad-hoc 签名。能装能跑，但每次构建签名都不同 |
| `MACOS_CERT_P12` + `MACOS_CERT_PASSWORD` | 用固定的自签身份，身份跨版本一致 |
| 再加 `APPLE_ID` / `APPLE_TEAM_ID` / `APPLE_APP_PASSWORD` | 额外公证并装订，Gatekeeper 不再警告 |

第二档的证书用 `scripts/make_signing_cert.sh` 生成，它会打印出要贴进
Settings → Secrets and variables → Actions 的两个值，同时把证书和密码写到：

```
~/Library/Application Support/PrWaiter/signing/ci/
├── ci-signing.p12
└── ci-signing.password
```

**不放 `dist/`** —— 那是构建输出目录，语义上随时可以清空，长期密钥搁那儿早晚被误删。

这张证书的全部价值就在于**固定不变**：重新生成就换了身份，装过旧版的用户在系统看来
等于装了个不同的 App。所以脚本默认拒绝覆盖已有证书，确实要换才用 `FORCE=1`。
**这个目录务必再备份一份到机器之外**（密码管理器之类）。

要重新取出 Secrets 的值：

```bash
base64 < ~/Library/Application\ Support/PrWaiter/signing/ci/ci-signing.p12
cat ~/Library/Application\ Support/PrWaiter/signing/ci/ci-signing.password
```

第三档需要付费的 Apple 开发者账号，这是去掉 Gatekeeper 警告的唯一途径 ——
自签证书做不到，别指望。

## License

[MIT](LICENSE) © WloBy Labs
