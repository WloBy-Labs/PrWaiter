import SwiftUI
import AppKit

// MARK: - 数据模型
//
// 本地只存 GitHub 不知道的东西：项目划分、描述块、PR 的树形归属、备注。
// PR 的标题 / review / CI / 合并状态每次实时从 GitHub 拉取，不存副本。
//
// 树的父子关系就是先后关系：一个 PR 挂在另一个 PR 下面，表示它要等上面那个先合并。
// 描述块（topic）只做分组，不参与先后关系判断，且只能待在根级。

enum NodeKind: String, Codable { case topic, pr }

struct Node: Codable, Identifiable {
    var id = UUID()
    var kind: NodeKind = .pr
    var title = ""      // 描述块的文字；PR 节点用不上（标题实时拉）
    var pr: Int?        // kind == .pr 时有效
    var note = ""
    var collapsed = false
    var children: [Node] = []

    init(kind: NodeKind, title: String = "", pr: Int? = nil, note: String = "") {
        self.kind = kind
        self.title = title
        self.pr = pr
        self.note = note
    }

    /// 子树里是否包含某个节点（含自身），用于拖拽时防止把父节点丢进自己的子树成环。
    func contains(_ target: UUID) -> Bool {
        id == target || children.contains { $0.contains(target) }
    }

    enum CodingKeys: String, CodingKey { case id, kind, title, pr, note, collapsed, children }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(NodeKind.self, forKey: .kind) ?? .pr
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        pr = try c.decodeIfPresent(Int.self, forKey: .pr)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        children = try c.decodeIfPresent([Node].self, forKey: .children) ?? []
    }

    // 空字段不落盘，保持 prs.json 可手工编辑
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        if !title.isEmpty { try c.encode(title, forKey: .title) }
        if let pr { try c.encode(pr, forKey: .pr) }
        if !note.isEmpty { try c.encode(note, forKey: .note) }
        if collapsed { try c.encode(collapsed, forKey: .collapsed) }
        if !children.isEmpty { try c.encode(children, forKey: .children) }
    }
}

extension Array where Element == Node {
    /// 摘除并返回整棵子树
    @discardableResult
    mutating func detach(_ target: UUID) -> Node? {
        for i in indices {
            if self[i].id == target { return remove(at: i) }
            if let found = self[i].children.detach(target) { return found }
        }
        return nil
    }

    /// 挂到指定父节点下，找不到父节点则返回 false
    @discardableResult
    mutating func attach(_ node: Node, under parent: UUID) -> Bool {
        for i in indices {
            if self[i].id == parent {
                self[i].children.append(node)
                return true
            }
            if self[i].children.attach(node, under: parent) { return true }
        }
        return false
    }

    func find(_ target: UUID) -> Node? {
        for n in self {
            if n.id == target { return n }
            if let found = n.children.find(target) { return found }
        }
        return nil
    }

    /// 就地改一个节点
    @discardableResult
    mutating func update(_ target: UUID, _ change: (inout Node) -> Void) -> Bool {
        for i in indices {
            if self[i].id == target {
                change(&self[i])
                return true
            }
            if self[i].children.update(target, change) { return true }
        }
        return false
    }

    /// 删除节点，其子节点提升到被删节点原来的位置
    @discardableResult
    mutating func removePromotingChildren(_ target: UUID) -> Bool {
        for i in indices {
            if self[i].id == target {
                let kids = self[i].children
                replaceSubrange(i...i, with: kids)
                return true
            }
            if self[i].children.removePromotingChildren(target) { return true }
        }
        return false
    }

    /// 按 PR 编号找节点 id，自动挂 backport 时用来定位父节点
    func nodeID(forPR n: Int) -> UUID? {
        for node in self {
            if node.pr == n { return node.id }
            if let f = node.children.nodeID(forPR: n) { return f }
        }
        return nil
    }

    var allPRNumbers: Set<Int> {
        reduce(into: Set<Int>()) { acc, n in
            if let p = n.pr { acc.insert(p) }
            acc.formUnion(n.children.allPRNumbers)
        }
    }
}

/// 树铺平成一行一行，带上画缩进连线所需的信息
struct Row: Identifiable {
    let node: Node
    let depth: Int
    let blocked: Bool       // 头上还有没合并的 PR 祖先
    let hidden: Bool        // 被某个折叠起来的祖先藏着
    let isLast: Bool        // 是不是同级里的最后一个
    /// 各层祖先「是否为该层最后一个」，长度等于 depth。
    /// 画竖线时用：祖先不是最后一个，说明它下面还有兄弟，那一列就要continue 竖线。
    let trail: [Bool]
    let descendants: Int    // 子孙总数，折叠时显示藏了多少

    var id: UUID { node.id }
}

enum Tree {
    /// 铺平整棵树。isMerged 由调用方提供（实时状态不属于树本身），这样这个函数是纯的、可测的。
    static func flatten(_ nodes: [Node], isMerged: (Int) -> Bool) -> [Row] {
        func countAll(_ ns: [Node]) -> Int {
            ns.reduce(0) { $0 + 1 + countAll($1.children) }
        }
        func walk(_ ns: [Node], _ depth: Int, _ blocked: Bool, _ hidden: Bool, _ trail: [Bool]) -> [Row] {
            ns.enumerated().flatMap { i, n -> [Row] in
                let isLast = i == ns.count - 1
                let row = Row(
                    node: n, depth: depth, blocked: blocked, hidden: hidden,
                    isLast: isLast, trail: trail, descendants: countAll(n.children)
                )
                // 描述块只做分组，不参与先后关系；PR 没合并才挡住下面的
                let childBlocked = n.kind == .pr
                    ? blocked || !(n.pr.map(isMerged) ?? false)
                    : blocked
                return [row] + walk(n.children, depth + 1, childBlocked, hidden || n.collapsed,
                                    trail + [isLast])
            }
        }
        return walk(nodes, 0, false, false, [])
    }

    /// 把 dragged 挂到 target 下面；target 为 nil 表示挪到根级。
    /// 非法移动（成环、描述块想当子节点、目标不存在）返回 nil，调用方原样保留。
    static func move(_ dragged: UUID, under target: UUID?, in nodes: [Node]) -> [Node]? {
        guard dragged != target else { return nil }
        var nodes = nodes
        guard let node = nodes.find(dragged) else { return nil }
        if let target {
            if node.contains(target) { return nil }   // 不能挂进自己的子树
            if node.kind == .topic { return nil }     // 描述块只能待在根级
            guard nodes.find(target) != nil else { return nil }
        }
        nodes.detach(dragged)
        if let target {
            guard nodes.attach(node, under: target) else { return nil }
            nodes.update(target) { $0.collapsed = false }   // 别让拖进去的东西看起来「消失」了
        } else {
            nodes.append(node)
        }
        return nodes
    }

    /// 把节点挪到根级的第 index 个位置（index 是「插到谁前面」，等于 count 表示放末尾）。
    /// 嵌套节点拖过来也走这里，等于同时出组 + 定位。
    static func move(_ dragged: UUID, toRootIndex index: Int, in nodes: [Node]) -> [Node]? {
        var nodes = nodes
        guard let node = nodes.find(dragged) else { return nil }
        let wasRootAt = nodes.firstIndex { $0.id == dragged }
        nodes.detach(dragged)
        // 原来就在根级且排在插入点前面的话，摘掉它之后后面的位置都往前挪了一格
        var target = index
        if let p = wasRootAt, p < index { target -= 1 }
        target = max(0, min(target, nodes.count))
        if wasRootAt == target { return nil }   // 没挪动，别白写一次盘
        nodes.insert(node, at: target)
        return nodes
    }
}

/// 从 GitHub 查到的一个 PR，只带导入决策需要的那几项
struct FoundPR {
    let number: Int
    let title: String
    let isOpen: Bool
}

struct Project: Codable, Identifiable {
    var id = UUID()
    var name = "新项目"
    var repo = ""
    var nodes: [Node] = []
    /// 已经自动导入过的 PR 编号。每个 PR 只导入一次，此后不再重来 ——
    /// 否则你删掉一个还开着的 PR，下次刷新它又冒出来了。
    var imported: [Int] = []

    init(name: String, repo: String = "", nodes: [Node] = []) {
        self.name = name
        self.repo = repo
        self.nodes = nodes
    }

    enum CodingKeys: String, CodingKey { case id, name, repo, nodes, imported }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "新项目"
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        nodes = try c.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        imported = try c.decodeIfPresent([Int].self, forKey: .imported) ?? []
    }

    /// 把查到的 PR 里没见过的那些放进树。纯函数，返回 nil 表示没有变化。
    ///
    /// 三条规则：
    /// 1. open 的一律收 —— 手头还在推进的东西
    /// 2. 已关闭 / 已合并的**只收和已跟踪 PR 有关系的**（是某个已跟踪 PR 的 backport，
    ///    或者是某个已跟踪 backport 的父 PR）。否则历史上几十个 PR 会全倒进来
    /// 3. 认得出父 PR 且父 PR 在树里的，直接挂到它下面 —— backport 本来就是
    ///    「等主干那个先合」的先后关系；认不出的落在根级顶部
    ///
    /// 「没见过」= 既不在 imported 里、也不在树里。后半个条件让手工加过的 PR
    /// 也算数，同时把它们补记进 imported，实现自动迁移。
    static func importing(_ found: [FoundPR], nodes: [Node], imported: [Int])
        -> (nodes: [Node], imported: [Int])?
    {
        let known = Set(imported).union(nodes.allPRNumbers)
        let candidates = found.filter { !known.contains($0.number) }

        // 判断「有关系」时，把这一轮要收的 open PR 也算作已跟踪，
        // 否则「新 open 主干 + 它的旧 closed backport」同时出现时后者会被漏掉
        let inTree = nodes.allPRNumbers
        let openNow = Set(candidates.filter(\.isOpen).map(\.number))
        let related = inTree.union(openNow)
        let parentOfTracked = Set(found.compactMap { f -> Int? in
            related.contains(f.number) ? GhParse.backportParent(from: f.title) : nil
        })

        let fresh = candidates.filter { c in
            if c.isOpen { return true }
            if let p = GhParse.backportParent(from: c.title), related.contains(p) { return true }
            return parentOfTracked.contains(c.number)
        }

        let merged = known.union(fresh.map(\.number)).sorted()
        if fresh.isEmpty {
            // 没有新 PR，但树里有 imported 没记的（手工加的），也要补记一次
            return merged == imported.sorted() ? nil : (nodes, merged)
        }

        var out = nodes
        // 先放认不出父 PR 的，升序插到最前 → 编号大的在最上面；
        // 再挂 backport，这样父 PR 哪怕是同一批新导入的也已经在树里了
        let (children, roots) = fresh.reduce(into: ([FoundPR](), [FoundPR]())) { acc, f in
            GhParse.backportParent(from: f.title) == nil ? acc.1.append(f) : acc.0.append(f)
        }
        for f in roots.sorted(by: { $0.number < $1.number }) {
            out.insert(Node(kind: .pr, pr: f.number), at: 0)
        }
        for f in children.sorted(by: { $0.number < $1.number }) {
            let node = Node(kind: .pr, pr: f.number)
            if let p = GhParse.backportParent(from: f.title), let pid = out.nodeID(forPR: p) {
                out.attach(node, under: pid)
                out.update(pid) { $0.collapsed = false }   // 别让新挂上去的藏在折叠里
            } else {
                out.insert(node, at: 0)
            }
        }
        return (out, merged)
    }
}

struct Store: Codable {
    var projects: [Project] = []
    var selected: UUID?

    enum CodingKeys: String, CodingKey { case projects, selected }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        selected = try c.decodeIfPresent(UUID.self, forKey: .selected)
    }

    /// 把项目挪到第 index 个位置（index 是「插到谁前面」，等于 count 表示放末尾）。
    /// 和根级块重排是同一套下标换算，非法或原地不动返回 nil。
    static func moveProject(_ id: UUID, toIndex index: Int, in projects: [Project]) -> [Project]? {
        guard let from = projects.firstIndex(where: { $0.id == id }) else { return nil }
        var to = index
        if from < index { to -= 1 }   // 摘掉自己之后，后面的位置都往前挪了一格
        var out = projects
        let p = out.remove(at: from)
        to = max(0, min(to, out.count))
        guard to != from else { return nil }
        out.insert(p, at: to)
        return out
    }

    /// 0.1.0 的格式是 {repo, prs:[{pr, after, note}]}，读到就迁移成单个项目。
    static func migrateLegacy(_ data: Data) -> Store? {
        struct LegacyPR: Codable {
            var pr: Int
            var after: [Int]?
            var note: String?
        }
        struct Legacy: Codable {
            var repo: String?
            var prs: [LegacyPR]
        }
        guard let old = try? JSONDecoder().decode(Legacy.self, from: data) else { return nil }

        let tracked = Set(old.prs.map(\.pr))
        // after 的第一个「也在跟踪列表里」的依赖当作父节点，其余依赖降级为备注
        func build(parent: Int?) -> [Node] {
            old.prs.filter { p in
                (p.after ?? []).first { tracked.contains($0) } == parent
            }.map { p in
                let extra = (p.after ?? []).filter { tracked.contains($0) }.dropFirst()
                var note = p.note ?? ""
                if !extra.isEmpty {
                    let more = extra.map { "#\($0)" }.joined(separator: " ")
                    note = note.isEmpty ? "另依赖 \(more)" : "\(note)（另依赖 \(more)）"
                }
                var n = Node(kind: .pr, pr: p.pr, note: note)
                n.children = build(parent: p.pr)
                return n
            }
        }

        var store = Store()
        let repo = old.repo ?? ""
        let name = repo.split(separator: "/").last.map(String.init) ?? "默认项目"
        let project = Project(name: name, repo: repo, nodes: build(parent: nil))
        store.projects = [project]
        store.selected = project.id
        return store
    }
}

// MARK: - 配置项

enum Prefs {
    static let ghPath = "ghPath"                   // 自定义 gh 路径，空表示自动查找
    static let refreshInterval = "refreshInterval"  // 秒；0 表示只手动刷新
    static let autoImport = "autoImport"            // 自动把我的 open PR 导进来

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [refreshInterval: 60, autoImport: true])
    }

    static var autoImportOn: Bool {
        UserDefaults.standard.bool(forKey: autoImport)
    }

    static var customGhPath: String {
        UserDefaults.standard.string(forKey: ghPath) ?? ""
    }

    static var interval: Int {
        UserDefaults.standard.integer(forKey: refreshInterval)
    }
}

// MARK: - 工具链探测

/// gh 的安装与登录情况
struct GhStatus {
    var path: String?
    var version: String?
    var account: String?      // nil 表示没登录
    var brewPath: String?

    var installed: Bool { path != nil }
    var ready: Bool { path != nil && account != nil }
}

/// 从命令输出里抠信息，纯字符串处理，可单独测试
enum GhParse {
    /// "gh version 2.96.0 (2026-06-11)" → "2.96.0"
    static func version(from out: String) -> String? {
        guard let line = out.split(separator: "\n").first(where: { $0.contains("gh version") }) else {
            return nil
        }
        let parts = line.split(separator: " ")
        guard let i = parts.firstIndex(of: "version"), i + 1 < parts.count else { return nil }
        return String(parts[i + 1])
    }

    /// "✓ Logged in to github.com account Joob1n (keyring)" → "Joob1n"
    /// 没登录时 gh 会输出 "You are not logged into any GitHub hosts"，返回 nil
    static func account(from out: String) -> String? {
        for line in out.split(separator: "\n") where line.contains("Logged in to") {
            let parts = line.split(separator: " ")
            guard let i = parts.firstIndex(of: "account"), i + 1 < parts.count else { continue }
            let name = parts[i + 1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// 从 PR 标题里认出「这是谁的 backport」。
    /// StarRocks 的 mergify 会生成 "…… (backport #77408)"，其他仓库常见
    /// "backport of #123" / "cherry-pick #123"，都收进来。
    /// 实测 51 个 PR 里 40 个能解析出父 PR，解析不出的正是主干 PR 本身。
    static func backportParent(from title: String) -> Int? {
        let pattern = #"(?i)(?:backport|cherry[- ]?pick)(?:ed)?(?:\s+(?:of|from))?[^#\d]{0,12}#(\d+)"#
        guard let m = title.range(of: pattern, options: .regularExpression) else { return nil }
        // 取匹配段里最后一串数字，也就是 # 后面那个编号
        guard let numRange = title[m].range(of: #"\d+$"#, options: .regularExpression) else { return nil }
        return Int(title[m][numRange])
    }

    /// 按优先级排出候选路径：自定义 > 常见安装位置 > PATH 里的每一段
    static func candidates(custom: String, pathEnv: String, home: String) -> [String] {
        var out: [String] = []
        let trimmed = custom.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { out.append(trimmed) }
        out += [
            "/opt/homebrew/bin/gh",     // Apple Silicon Homebrew
            "/usr/local/bin/gh",        // Intel Homebrew
            "/opt/local/bin/gh",        // MacPorts
            "/usr/bin/gh",
            "\(home)/.local/bin/gh",
        ]
        out += pathEnv.split(separator: ":").map { "\($0)/gh" }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}

// MARK: - GitHub 实时状态

struct LivePR {
    var title = ""
    var state = ""      // OPEN / MERGED / CLOSED
    var url = ""
    var author = ""
    var isDraft = false
    var review: String? // APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED
    var ci: String?     // SUCCESS / FAILURE / ERROR / PENDING / EXPECTED
}

/// 每个 PR 落在且只落在一个状态里，所以描述块上的分项计数加起来正好等于 PR 总数。
/// 顺序即优先级：先「该你动手的」，再「等上游」，再「等别人/等机器」，最后才是可以合了。
enum PRStatus: CaseIterable {
    case merged, closed, draft
    case ciFailed, changesRequested   // 问题在自己这边，即使被依赖挡着也该先修
    case blocked                      // 上游还没合
    case ciRunning, needsReview       // 等机器 / 等人
    case ready
    case unknown

    var label: String {
        switch self {
        case .ready: return "可合并"
        case .ciFailed: return "CI 失败"
        case .changesRequested: return "需修改"
        case .ciRunning: return "CI 运行中"
        case .needsReview: return "等 review"
        case .blocked: return "等依赖"
        case .draft: return "草稿"
        case .merged: return "已合并"
        case .closed: return "已关闭"
        case .unknown: return "未知"
        }
    }

    /// 配色按「这件事欠在谁身上」分，灰色只留给已经终结的 ——
    /// 「等 review」是活的、可以去催的，染成灰色等于说它没戏了
    var color: Color {
        switch self {
        case .ready: return .green                        // 可以动了
        case .ciFailed, .changesRequested: return .red    // 欠在你身上，且是坏消息
        case .ciRunning: return .orange                   // 欠在机器身上
        case .needsReview: return .blue                   // 欠在别人身上，能去催
        case .blocked: return .indigo                     // 欠在上游那个 PR 身上
        case .merged: return .purple                      // 成了（沿用 GitHub 的紫）
        case .closed, .draft, .unknown: return .secondary // 已终结 / 还没发出去 / 不知道
        }
    }

    /// 什么情况下会落到这个状态，给设置里的说明表用
    var detail: String {
        switch self {
        case .ready: return "上游全合了、已批准、CI 通过 —— 可以去催了"
        case .ciFailed: return "CI 红了。球在你脚下，所以排在「等依赖」前面"
        case .changesRequested: return "reviewer 要求改动。同样是该你动手"
        case .ciRunning: return "CI 还在跑，等机器"
        case .needsReview: return "还没人批准，等人"
        case .blocked: return "树上游还有没合并的 PR，先轮不到它"
        case .draft: return "Draft PR，还没打算让人看"
        case .merged: return "已合并"
        case .closed: return "关掉了，没合"
        case .unknown: return "拉不到数据，检查编号或仓库设置"
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .ciFailed: return "xmark.octagon.fill"
        case .changesRequested: return "exclamationmark.bubble.fill"
        case .ciRunning: return "clock.arrow.circlepath"
        case .needsReview: return "eye"
        case .blocked: return "hourglass"
        case .draft: return "pencil.circle"
        case .merged: return "checkmark.seal.fill"
        case .closed: return "xmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// 描述块上分项计数的排列顺序：先给能立刻动的，已完成的排最后
    static let summaryOrder: [PRStatus] = [
        .ready, .ciFailed, .changesRequested, .ciRunning,
        .needsReview, .blocked, .draft, .merged, .closed, .unknown,
    ]

    /// 已经尘埃落定、不需要再盯的。配色本身已经把它们压成灰或紫，
    /// 所以显示时不用再额外压暗一遍。
    var isSettled: Bool { self == .merged || self == .closed }
}

extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

struct AppError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - 状态管理

@MainActor
final class Model: ObservableObject {
    @Published var store = Store()
    // 按项目分开缓存：切标签时上一次拉到的数据还在，能立刻显示，不用等网络
    @Published private var liveByProject: [UUID: [Int: LivePR]] = [:]
    @Published private var fetchedAt: [UUID: Date] = [:]
    @Published var error: String?         // 拉取失败
    @Published var saveError: String?     // 落盘失败 —— 比拉取失败严重，改动是真丢
    @Published var loading = false
    @Published var editing = false
    @Published var gh = GhStatus()
    @Published var detecting = false
    @Published var installLog: [String] = []
    @Published var installing = false

    private var timer: Timer?

    /// 当前项目的实时状态
    var live: [Int: LivePR] {
        store.selected.flatMap { liveByProject[$0] } ?? [:]
    }

    /// 当前项目上次拉取的时间。按项目分开，否则切过去会显示别的项目的时间，是骗人的
    var updatedAt: Date? {
        store.selected.flatMap { fetchedAt[$0] }
    }

    static let dataURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrWaiter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("prs.json")
    }()

    init() {
        Prefs.registerDefaults()
        if let data = try? Data(contentsOf: Self.dataURL) {
            if let s = try? JSONDecoder().decode(Store.self, from: data), !s.projects.isEmpty {
                store = s
            } else if let migrated = Store.migrateLegacy(data) {
                store = migrated
                save()   // 立刻落盘新格式，旧格式只读一次
            }
        }
        if store.selected == nil { store.selected = store.projects.first?.id }
        Task { await self.refresh() }
        Task { await self.detectToolchain() }
        rescheduleTimer()
    }

    /// 刷新间隔改了要重排，间隔为 0 表示只手动刷新
    func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        let seconds = Prefs.interval
        guard seconds > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(seconds), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func detectToolchain() async {
        detecting = true
        gh = await Self.detectGh()
        detecting = false
    }

    /// 用 Homebrew 装 gh。输出流式显示 —— brew 可能要跑几分钟，不能让人干等一个转圈。
    func installGh() async {
        guard let brew = gh.brewPath, !installing else { return }
        installing = true
        installLog = ["$ brew install gh"]
        let code = await Self.runStreaming(brew, ["install", "gh"]) { [weak self] line in
            Task { @MainActor in
                self?.installLog.append(line)
                if self?.installLog.count ?? 0 > 400 { self?.installLog.removeFirst(100) }
            }
        }
        installLog.append(code == 0 ? "── 安装完成" : "── 失败，退出码 \(code)")
        installing = false
        await detectToolchain()
        await refresh()
    }

    /// gh auth login 是交互式的（要选协议、要按回车开浏览器），塞不进后台进程，
    /// 所以开一个终端窗口把命令跑起来，让用户在那边完成。
    func openLoginInTerminal() {
        guard let gh = gh.path else { return }
        let script = """
        tell application "Terminal"
            activate
            do script "\(gh) auth login"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    // MARK: 当前项目

    var projectIndex: Int? {
        guard let sel = store.selected else { return nil }
        return store.projects.firstIndex { $0.id == sel }
    }

    var project: Project? {
        projectIndex.map { store.projects[$0] }
    }

    func select(_ id: UUID) {
        guard store.selected != id else { return }
        store.selected = id
        error = nil
        save()
        // 切标签不重新拉取：上次的数据立刻显示，要最新的自己点刷新，
        // 定时器下一拍也会带上。只有从没拉过的项目才拉一次，不然会是一片空白。
        if liveByProject[id] == nil {
            Task { await self.refresh() }
        }
    }

    // MARK: 落盘

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            // .atomic 是关键：它先写同目录下的临时文件再 rename，rename 在文件系统
            // 层面是原子的。非原子写会先把目标文件截断再往里写，崩在中间就只剩半个
            // 文件 —— 整份数据都没了。
            try enc.encode(store).write(to: Self.dataURL, options: .atomic)
            saveError = nil
        } catch {
            // 原来这里是 try?，写失败会被静默吞掉：磁盘满了、权限坏了，界面上
            // 一点提示都没有，你以为改动存下了其实没有。这比写坏文件更阴险。
            saveError = error.localizedDescription
        }
    }

    /// 改当前项目并落盘（不触发刷新）
    func edit(_ change: (inout Project) -> Void) {
        guard let i = projectIndex else { return }
        change(&store.projects[i])
        save()
    }

    /// 改当前项目、落盘并重新拉取（增删 PR 时用）
    func editAndRefresh(_ change: (inout Project) -> Void) {
        edit(change)
        Task { await self.refresh() }
    }

    // MARK: 树操作

    func move(_ dragged: UUID, under target: UUID?) {
        guard let i = projectIndex,
              let moved = Tree.move(dragged, under: target, in: store.projects[i].nodes) else { return }
        store.projects[i].nodes = moved
        save()
    }

    /// 拖动项目标签排序。传进来的可能是块的 id（拖块时飘到标签栏上），
    /// 那样 firstIndex 找不到，直接当没发生。
    func moveProject(_ id: UUID, toIndex index: Int) {
        guard let moved = Store.moveProject(id, toIndex: index, in: store.projects) else { return }
        store.projects = moved
        save()
    }

    func move(_ dragged: UUID, toRootIndex index: Int) {
        guard let i = projectIndex,
              let moved = Tree.move(dragged, toRootIndex: index, in: store.projects[i].nodes) else { return }
        store.projects[i].nodes = moved
        save()
    }

    func deleteCurrentProject() {
        guard let i = projectIndex else { return }
        let gone = store.projects.remove(at: i).id
        liveByProject[gone] = nil     // 缓存跟着项目走，别留孤儿
        fetchedAt[gone] = nil
        store.selected = store.projects.first?.id
        error = nil
        save()
        if let now = store.selected, liveByProject[now] == nil {
            Task { await self.refresh() }
        }
    }

    // MARK: 拉取

    func refresh() async {
        guard let p = project, !p.repo.isEmpty else {
            if let pid = project?.id { liveByProject[pid] = [:]; error = nil }
            return
        }
        let pid = p.id
        if loading { return }
        loading = true
        defer { loading = false }

        // 先把 GitHub 上我的 open PR 导进来，再拉状态 —— 顺序反了的话，
        // 新导入的这一批要等下一轮刷新才有标题和状态
        if Prefs.autoImportOn {
            await importMyOpenPRs(into: pid, repo: p.repo)
        }

        guard let cur = store.projects.first(where: { $0.id == pid }) else { return }
        let numbers = cur.nodes.allPRNumbers
        guard !numbers.isEmpty else {
            // 一个 PR 都没有：也记成「拉过了」，免得每次切回来都白试一次
            liveByProject[pid] = [:]
            error = nil
            return
        }
        do {
            liveByProject[pid] = try await Self.fetchLive(repo: cur.repo, numbers: numbers)
            fetchedAt[pid] = Date()
            error = nil
        } catch let e {
            error = e.localizedDescription
        }
    }

    /// 把当前 gh 账号在该仓库下所有 open 的 PR 导进来（只导没见过的）
    func importMyOpenPRs(into pid: UUID, repo: String) async {
        guard let found = try? await Self.fetchMyPRs(repo: repo) else { return }
        guard let i = store.projects.firstIndex(where: { $0.id == pid }) else { return }
        guard let r = Project.importing(found,
                                        nodes: store.projects[i].nodes,
                                        imported: store.projects[i].imported) else { return }
        store.projects[i].nodes = r.nodes
        store.projects[i].imported = r.imported
        save()
    }

    // GUI app 不继承 shell 的 PATH，得自己找。找不到再退一步问一次登录 shell。
    nonisolated static func ghPath() -> String? {
        let fm = FileManager.default
        let candidates = GhParse.candidates(
            custom: Prefs.customGhPath,
            pathEnv: ProcessInfo.processInfo.environment["PATH"] ?? "",
            home: NSHomeDirectory()
        )
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }
        return ghPathFromLoginShell()
    }

    /// 装在非常规位置时的兜底：用登录 shell 跑一次 `command -v gh`，能读到用户 profile 里的 PATH
    nonisolated static func ghPathFromLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lc", "command -v gh"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let path = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    nonisolated static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 探测 gh 装没装、登没登
    nonisolated static func detectGh() async -> GhStatus {
        var st = GhStatus(brewPath: brewPath())
        guard let gh = ghPath() else { return st }
        st.path = gh
        st.version = GhParse.version(from: (try? await run(gh, ["--version"]))?.stdout ?? "")
        // gh auth status 未登录时以非 0 退出并写 stderr，两股都要看
        if let out = try? await run(gh, ["auth", "status"]) {
            st.account = GhParse.account(from: out.stdout + "\n" + out.stderr)
        }
        return st
    }

    /// 查当前 gh 账号在该仓库下所有 open 的 PR 编号。
    /// 用 `gh pr list` 而不是自己拼 GraphQL：一条命令的事，少一份要维护的查询。
    nonisolated static func fetchMyPRs(repo: String) async throws -> [FoundPR] {
        guard let gh = ghPath() else { throw AppError("找不到 GitHub CLI（gh）") }
        guard repo.range(of: #"^[\w.-]+/[\w.-]+$"#, options: .regularExpression) != nil else {
            throw AppError("仓库格式应为 owner/repo，当前是「\(repo)」")
        }
        // 作者是我、或者指派给我，两者取并集。
        // 机器人自动建的 backport 常常作者是 bot、只把你设成 assignee，
        // 光看 author 会漏掉。gh 的两个过滤条件是 AND，所以只能查两次再合并。
        async let mine = listPRs(gh, repo: repo, filter: ["--author", "@me"])
        async let assigned = listPRs(gh, repo: repo, filter: ["--assignee", "@me"])

        var byNumber: [Int: FoundPR] = [:]
        var failures = 0
        for r in [try? await mine, try? await assigned] {
            if let r { for p in r { byNumber[p.number] = p } } else { failures += 1 }
        }
        // 一条挂了另一条还能用，就用能用的那份；两条都挂才算失败
        if failures == 2 { throw AppError("gh pr list 调用失败") }
        return byNumber.values.sorted { $0.number < $1.number }
    }

    private nonisolated static func listPRs(
        _ gh: String, repo: String, filter: [String]
    ) async throws -> [FoundPR] {
        // --state all：已关闭的也要，好把「主干合了但 backport 被关掉」这种情况显出来。
        // 收不收由 Project.importing 决定 —— 只收和已跟踪 PR 有关系的那些。
        let out = try await run(gh, ["pr", "list", "-R", repo, "--state", "all",
                                     "--limit", "200", "--json", "number,title,state"] + filter)
        guard let arr = try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [[String: Any]]
        else {
            throw AppError(out.stderr.isEmpty ? "gh pr list 调用失败" : out.stderr)
        }
        return arr.compactMap { d in
            guard let n = d["number"] as? Int else { return nil }
            return FoundPR(number: n,
                           title: d["title"] as? String ?? "",
                           isOpen: (d["state"] as? String) == "OPEN")
        }
    }

    /// 一次 GraphQL 请求拉完整个项目的 PR 状态
    nonisolated static func fetchLive(repo: String, numbers: Set<Int>) async throws -> [Int: LivePR] {
        guard let gh = ghPath() else {
            throw AppError("找不到 GitHub CLI（gh），到设置里可以一键安装")
        }
        guard repo.range(of: #"^[\w.-]+/[\w.-]+$"#, options: .regularExpression) != nil else {
            throw AppError("仓库格式应为 owner/repo，当前是「\(repo)」")
        }
        let parts = repo.split(separator: "/")
        let fields = "number title state isDraft url reviewDecision author { login } "
            + "commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }"
        let aliases = numbers.sorted()
            .map { "pr\($0): pullRequest(number: \($0)) { \(fields) }" }
            .joined(separator: " ")
        let query = "query { repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") { \(aliases) } }"

        let out = try await run(gh, ["api", "graphql", "-f", "query=\(query)"])
        guard let obj = try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any] else {
            throw AppError(out.stderr.isEmpty ? "gh 调用失败" : out.stderr)
        }

        var live: [Int: LivePR] = [:]
        let repoData = ((obj["data"] as? [String: Any])?["repository"] as? [String: Any]) ?? [:]
        for case let v as [String: Any] in Array(repoData.values) {
            guard let n = v["number"] as? Int else { continue }
            let commit = ((v["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?
                .first?["commit"] as? [String: Any]
            let rollup = commit?["statusCheckRollup"] as? [String: Any]
            var lv = LivePR()
            lv.title = v["title"] as? String ?? ""
            lv.state = v["state"] as? String ?? ""
            lv.isDraft = v["isDraft"] as? Bool ?? false
            lv.url = v["url"] as? String ?? ""
            lv.review = v["reviewDecision"] as? String
            lv.ci = rollup?["state"] as? String
            lv.author = (v["author"] as? [String: Any])?["login"] as? String ?? ""
            live[n] = lv
        }
        // 个别编号不存在时 GraphQL 只报部分错误，能拿到的照常显示；全军覆没才抛错
        if live.isEmpty, let errs = obj["errors"] as? [[String: Any]],
           let msg = errs.first?["message"] as? String {
            throw AppError(msg)
        }
        return live
    }

    /// 边跑边把输出一行行吐出来，装 gh 时用（brew 可能要跑好几分钟，不能干等）
    nonisolated static func runStreaming(
        _ path: String, _ args: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = args
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do {
                    try proc.run()
                } catch {
                    onLine("启动失败：\(error.localizedDescription)")
                    cont.resume(returning: -1)
                    return
                }
                let handle = pipe.fileHandleForReading
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let idx = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[buffer.startIndex..<idx])
                        onLine(String(data: line, encoding: .utf8) ?? "")
                        buffer = Data(buffer[(idx + 1)...])
                    }
                }
                if !buffer.isEmpty {
                    onLine(String(data: buffer, encoding: .utf8) ?? "")
                }
                proc.waitUntilExit()
                cont.resume(returning: proc.terminationStatus)
            }
        }
    }

    nonisolated static func run(_ path: String, _ args: [String]) async throws -> (stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = args
                let outPipe = Pipe(), errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do {
                    try proc.run()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    cont.resume(returning: (
                        String(data: outData, encoding: .utf8) ?? "",
                        String(data: errData, encoding: .utf8) ?? ""
                    ))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: 状态推导

    func status(pr: Int, blocked: Bool) -> PRStatus {
        Self.classify(live[pr], blocked: blocked)
    }

    /// 纯函数，方便单独测；分类是互斥的，命中一个就返回
    nonisolated static func classify(_ lv: LivePR?, blocked: Bool) -> PRStatus {
        guard let lv else { return .unknown }
        if lv.state == "MERGED" { return .merged }
        if lv.state == "CLOSED" { return .closed }
        if lv.isDraft { return .draft }
        // CI 红了、被要求改，都是自己这边的事，被依赖挡着也一样要修
        if lv.ci == "FAILURE" || lv.ci == "ERROR" { return .ciFailed }
        if lv.review == "CHANGES_REQUESTED" { return .changesRequested }
        if blocked { return .blocked }
        if lv.ci == "PENDING" || lv.ci == "EXPECTED" { return .ciRunning }
        if lv.review != "APPROVED" { return .needsReview }
        return .ready
    }
}

// MARK: - 行与统计
//
// 统计一律基于 allRows —— 折叠只是把行藏起来，不该让 PR 从汇总里消失。

extension Model {
    /// 整棵树的所有行，含被折叠藏起来的
    var allRows: [Row] {
        Tree.flatten(project?.nodes ?? []) { live[$0]?.state == "MERGED" }
    }

    /// 实际渲染的行
    var rows: [Row] {
        allRows.filter { !$0.hidden }
    }

    /// 每个描述块下辖的 PR 按状态分桶。互斥分类，各项加起来等于总数。
    var topicSummary: [UUID: [PRStatus: Int]] {
        let all = allRows
        var out: [UUID: [PRStatus: Int]] = [:]
        for (i, row) in all.enumerated() where row.node.kind == .topic {
            var counts: [PRStatus: Int] = [:]
            var j = i + 1
            while j < all.count, all[j].depth > row.depth {
                if all[j].node.kind == .pr, let p = all[j].node.pr {
                    counts[status(pr: p, blocked: all[j].blocked), default: 0] += 1
                }
                j += 1
            }
            out[row.node.id] = counts
        }
        return out
    }

    /// 整个项目的状态分桶，给顶部汇总用
    var projectSummary: [PRStatus: Int] {
        var counts: [PRStatus: Int] = [:]
        for r in allRows where r.node.kind == .pr {
            guard let p = r.node.pr else { continue }
            counts[status(pr: p, blocked: r.blocked), default: 0] += 1
        }
        return counts
    }

    func prs(matching wanted: PRStatus) -> [Int] {
        allRows.compactMap { r in
            guard r.node.kind == .pr, let p = r.node.pr,
                  status(pr: p, blocked: r.blocked) == wanted else { return nil }
            return p
        }
    }

    var readyPRs: [Int] { prs(matching: .ready) }
    var mergedPRs: [Int] { prs(matching: .merged) }

    func toggleCollapse(_ id: UUID) {
        edit { $0.nodes.update(id) { $0.collapsed.toggle() } }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject var m: Model
    @State private var newPR = ""
    @State private var rootTargeted = false
    @State private var page = Page.board

    /// 设置不再弹窗，而是主区域里换一页 —— 看板和设置是同一个界面的两个页面
    enum Page { case board, settings }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controlRow
            Divider()
            switch page {
            case .board:
                boardPage
            case .settings:
                SettingsView().environmentObject(m)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .animation(.easeInOut(duration: 0.15), value: page)
        // 窗口标题条只留应用名和版本，不挂任何按钮 —— 保持干净
        .navigationTitle(Text(verbatim: "PrWaiter v\(Self.appVersion)"))
    }

    var boardPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if m.editing, m.project != nil {
                projectSettings
                Divider()
            }
            content
        }
    }

    // MARK: 控制条（项目切换与操作按钮同处一行，标题条不放东西）

    var controlRow: some View {
        HStack(spacing: 10) {
            if page == .settings {
                // 返回摆在内容区左侧，不去挤红黄绿那一条
                Button { page = .board } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .help("返回看板")
                .keyboardShortcut(.cancelAction)
                Text("设置").font(.headline)
                Spacer()
            } else {
                projectTabs
                boardActions
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    var boardActions: some View {
        HStack(spacing: 10) {
            // 时间戳与刷新按钮分开摆，别挤成一坨
            Group {
                if m.loading {
                    ProgressView().controlSize(.small)
                } else if let t = m.updatedAt {
                    Text("更新于 " + t.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(minWidth: 76, alignment: .trailing)   // 宽度固定，刷新时按钮不会左右跳

            Button { Task { await m.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.bordered)
            .disabled(m.loading)
            .help("立即刷新")

            Button(m.editing ? "完成" : "编辑") {
                m.editing.toggle()
                m.save()
            }
            .buttonStyle(.borderedProminent)
            .tint(m.editing ? .green : .accentColor)
            .help(m.editing ? "退出编辑，冻结布局" : "进入编辑，可拖动、增删")

            Button { page = .settings } label: {
                Image(systemName: m.gh.ready ? "gearshape" : "gearshape.badge.checkmark")
                    .frame(width: 16, height: 16)
                    .foregroundColor(m.gh.ready ? .primary : .orange)
            }
            .buttonStyle(.bordered)
            .help(m.gh.ready ? "设置" : "gh 还没配好，点这里")
        }
        .fixedSize()   // 按钮区不被标签挤压
    }

    // MARK: 项目标签

    var projectTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(m.store.projects.enumerated()), id: \.element.id) { i, p in
                    if m.editing { TabGap(index: i) }
                    tab(p)
                }
                if m.editing {
                    TabGap(index: m.store.projects.count)   // 末尾那条缝
                    Button {
                        let p = Project(name: "新项目")
                        m.store.projects.append(p)
                        m.select(p.id)
                    } label: {
                        Image(systemName: "plus").padding(.horizontal, 8).padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .help("新增项目")
                }
            }
            .padding(.vertical, 2)   // 内外边距交给控制条统一控制
        }
        .frame(maxWidth: .infinity, alignment: .leading)   // 标签占满剩余宽度，按钮靠右
    }

    /// 用普通视图 + 点击手势而不是 Button：Button 会吞掉拖拽手势，
    /// 而节点卡片正是「普通视图 + draggable」这个结构，拖拽已验证可用
    func tab(_ p: Project) -> some View {
        let active = p.id == m.store.selected
        return Text(p.name.isEmpty ? "未命名" : p.name)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(active ? Color.accentColor : .clear, lineWidth: 1)
            )
            .foregroundColor(active ? .accentColor : .primary)
            .contentShape(Rectangle())
            .onTapGesture { m.select(p.id) }
            .modifier(DragEnabled(enabled: m.editing, id: p.id))
            .help(m.editing ? "拖动可调整标签顺序" : p.repo)
    }

    // MARK: 项目设置（编辑态）

    var projectSettings: some View {
        HStack(spacing: 8) {
            TextField("项目名", text: Binding(
                get: { m.project?.name ?? "" },
                set: { v in m.edit { $0.name = v } }
            ))
            .frame(width: 140)
            TextField("owner/repo", text: Binding(
                get: { m.project?.repo ?? "" },
                set: { v in m.edit { $0.repo = v.trimmingCharacters(in: .whitespaces) } }
            ))
            .frame(width: 220)
            .onSubmit { Task { await m.refresh() } }
            Spacer()
            Button("删除本项目", role: .destructive) {
                m.deleteCurrentProject()
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: 主体

    @ViewBuilder
    var content: some View {
        if m.project == nil {
            emptyProjects
        } else {
            ScrollView {
                // spacing 为 0：每行自带上下留白，连线才能连续不断
                VStack(alignment: .leading, spacing: 0) {
                    // 落盘失败排在拉取失败前面：后者只是数据旧了，前者是改动真丢了
                    if let e = m.saveError {
                        HStack(spacing: 10) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("改动没能保存到磁盘").fontWeight(.semibold)
                                    Text(e).font(.caption)
                                }
                            } icon: {
                                Image(systemName: "externaldrive.badge.xmark")
                            }
                            Spacer()
                            Button("重试") { m.save() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        .foregroundColor(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.15)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.5)))
                        .padding(.bottom, 8)
                    }
                    if let e = m.error {
                        HStack {
                            Label(e, systemImage: "exclamationmark.triangle")
                            Spacer()
                            // gh 没配好是最常见的失败原因，直接给个去处
                            if !m.gh.ready {
                                Button("去设置") { page = .settings }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            }
                        }
                        .foregroundColor(.red)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
                        .padding(.bottom, 8)
                    }
                    // 状态图例搬到设置里了：那是查一两次就记住的参照材料，
                    // 不该长期占着主界面一行；即时查询有徽标的悬停提示兜着
                    if m.editing { addBar.padding(.bottom, 6) }
                    // 根级行之间插入投放缝，用来调整根级顺序；子行不需要（层级由父子决定）
                    ForEach(Array(m.rows.enumerated()), id: \.element.id) { _, row in
                        if m.editing, row.depth == 0 {
                            RootGap(index: rootIndex(before: row))
                        }
                        NodeRow(row: row)
                    }
                    if m.editing, !(m.project?.nodes ?? []).isEmpty {
                        RootGap(index: m.project?.nodes.count ?? 0)   // 末尾那条缝
                    }
                    if (m.project?.nodes ?? []).isEmpty {
                        Text(m.editing
                             ? "空的。用上面的「+ 描述块」建一个分组，或直接添加 PR。"
                             : "还没有内容，点右上角「编辑」开始添加。")
                            .foregroundColor(.secondary)
                            .padding(.top, 20)
                    }
                    if m.editing { rootDropZone.padding(.top, 8) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 这一行在根级数组里的下标（它是根级行时才有意义）
    func rootIndex(before row: Row) -> Int {
        m.project?.nodes.firstIndex { $0.id == row.node.id } ?? 0
    }

    var emptyProjects: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("还没有项目").font(.title3).foregroundColor(.secondary)
            Button("新建一个项目") {
                let p = Project(name: "新项目")
                m.store.projects.append(p)
                m.editing = true
                m.select(p.id)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }


    var addBar: some View {
        HStack(spacing: 8) {
            TextField("PR 编号", text: $newPR)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .onSubmit(addPR)
            Button("添加 PR", action: addPR)
            Divider().frame(height: 18)
            Button {
                // 新建的放最上面，刚加的东西不该要滚到底才看得到
                m.edit { $0.nodes.insert(Node(kind: .topic, title: "新描述块"), at: 0) }
            } label: {
                Label("描述块", systemImage: "plus")
            }
            .help("新增一个描述块，用来写功能 / bug 的说明，PR 拖进去归类")
            // 汇总行没了，这个按钮挪到编辑态的操作栏
            let merged = m.mergedPRs
            if !merged.isEmpty {
                Divider().frame(height: 18)
                Button("清理已合并 \(merged.count) 个") {
                    // 用 allRows：折叠起来的也要一起清
                    let ids = m.allRows.filter { r in
                        r.node.kind == .pr && r.node.pr.map { merged.contains($0) } == true
                    }.map(\.node.id)
                    m.editAndRefresh { p in
                        for id in ids { p.nodes.removePromotingChildren(id) }
                    }
                }
            }
            Spacer()
            Text("拖到块上归类，拖到块之间调顺序")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    func addPR() {
        guard let n = Int(newPR.trimmingCharacters(in: .whitespaces)) else { return }
        newPR = ""
        guard !(m.project?.nodes.allPRNumbers.contains(n) ?? false) else { return }
        // 新 PR 落在根级最上面，之后靠拖拽归类
        m.editAndRefresh { $0.nodes.insert(Node(kind: .pr, pr: n), at: 0) }
    }

    var rootDropZone: some View {
        HStack {
            Spacer()
            Text("拖到这里移出分组，回到根级")
                .font(.caption)
                .foregroundColor(rootTargeted ? .accentColor : .secondary)
            Spacer()
        }
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    rootTargeted ? Color.accentColor : Color.gray.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1, dash: [5])
                )
        )
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init) else { return false }
            m.move(id, under: nil)
            return true
        } isTargeted: { rootTargeted = $0 }
    }
}

// MARK: - 设置

/// 用原生 Form + grouped 样式：标签在左、控件在右，随窗口宽度自适应，
/// 不用自己拍一个 maxWidth 的魔数。这也是 macOS 系统设置的排版方式。
struct SettingsView: View {
    @EnvironmentObject var m: Model
    @AppStorage(Prefs.ghPath) private var customPath = ""
    @AppStorage(Prefs.refreshInterval) private var interval = 60
    @AppStorage(Prefs.autoImport) private var autoImport = true

    static let intervals = [(30, "30 秒"), (60, "1 分钟"), (300, "5 分钟"), (0, "只手动刷新")]

    var body: some View {
        Form {
            ghSection
            statusSection
            refreshSection
            aboutSection
        }
        .formStyle(.grouped)
    }

    // MARK: GitHub CLI

    var ghSection: some View {
        Section {
            LabeledContent("状态") { statusLine }
            if let p = m.gh.path {
                LabeledContent("可执行文件") {
                    Text(verbatim: p)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            LabeledContent("操作") { actionRow }
            if !m.installLog.isEmpty {
                installOutput
            }
            LabeledContent("自定义路径") {
                HStack {
                    // labelsHidden：LabeledContent 里 TextField 自带的 label 会被单独渲染到框外
                    TextField("留空则自动查找", text: $customPath)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)   // grouped form 里默认无框，看不出能输入
                        .font(.caption.monospaced())
                        .frame(minWidth: 220)
                        .onSubmit { Task { await m.detectToolchain() } }
                    Button("应用") { Task { await m.detectToolchain() } }
                }
            }
        } header: {
            Text("GitHub CLI")
        } footer: {
            Text("PR 的实时状态靠 gh 拉取，它不装、不登录就只能看到本地记的结构。"
                 + "自动查找依次试 Homebrew、MacPorts、PATH，最后问一次登录 shell。")
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    var statusLine: some View {
        if m.detecting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("检测中…").foregroundColor(.secondary)
            }
        } else if m.gh.ready {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text(verbatim: "gh \(m.gh.version ?? "?") · 已登录 \(m.gh.account ?? "")")
            }
        } else if m.gh.installed {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundColor(.orange)
                Text(verbatim: "gh \(m.gh.version ?? "?") · 没登录")
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                Text("没找到 gh")
            }
        }
    }

    @ViewBuilder
    var actionRow: some View {
        HStack(spacing: 8) {
            if !m.gh.installed {
                if m.gh.brewPath != nil {
                    Button {
                        Task { await m.installGh() }
                    } label: {
                        Label(m.installing ? "安装中…" : "用 Homebrew 安装", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(m.installing)
                    if m.installing { ProgressView().controlSize(.small) }
                } else {
                    // 连 brew 都没有，只能给路子，不能替他装
                    Button("安装 Homebrew") { open("https://brew.sh") }
                    Button("下载 gh 安装包") { open("https://github.com/cli/cli/releases/latest") }
                }
            } else if m.gh.account == nil {
                Button {
                    m.openLoginInTerminal()
                } label: {
                    Label("在终端登录", systemImage: "terminal")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("重新登录") { m.openLoginInTerminal() }
            }
            Button("重新检测") { Task { await m.detectToolchain() } }
                .disabled(m.detecting)
        }
    }

    var installOutput: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(m.installLog.enumerated()), id: \.offset) { i, line in
                        Text(verbatim: line)
                            .font(.caption2.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(6)
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            .onChange(of: m.installLog.count) { _, n in
                proxy.scrollTo(n - 1, anchor: .bottom)
            }
        }
    }

    // MARK: 状态说明

    /// 描述块右侧的徽标只有图标和数字，这里是那张对照表
    var statusSection: some View {
        Section {
            ForEach(PRStatus.summaryOrder.filter { $0 != .unknown }, id: \.self) { st in
                HStack(spacing: 10) {
                    Image(systemName: st.symbol)
                        .foregroundColor(st.color)
                        .frame(width: 18)
                    Text(st.label)
                        .frame(width: 82, alignment: .leading)
                    Text(st.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
            }
        } header: {
            Text("状态说明")
        } footer: {
            Text("每个 PR 只落在一个状态里，所以描述块右侧的分项数加起来正好等于 PR 总数。"
                 + "列表里把徽标悬停也能看到状态名。")
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    // MARK: 刷新

    var refreshSection: some View {
        Section {
            Picker("自动刷新间隔", selection: $interval) {
                ForEach(Self.intervals, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: interval) { _, _ in m.rescheduleTimer() }
            Toggle("自动导入我的 open PR", isOn: $autoImport)
        } header: {
            Text("刷新")
        } footer: {
            Text("每次刷新会先把该仓库下**作者是我、或指派给我**的 open PR 导进来"
                 + "（落在根级最上面），再用一条 GraphQL 请求拉回全部状态。"
                 + "算上 assignee 是因为机器人自动建的 backport 常常作者是 bot、只把你设成指派人。\n"
                 + "每个 PR 只导入一次：删掉之后不会再被导回来，已合并 / 已关闭的也不会被清走。")
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    // MARK: 关于

    var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: ContentView.appVersion)
            LabeledContent("数据文件") {
                HStack {
                    Text(verbatim: Model.dataURL.path)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([Model.dataURL])
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
// MARK: - 根级插入缝

/// 根级块之间的一条投放缝：平时几乎看不见，拖拽悬停时显示成插入线。
/// 有它才能调整根级顺序 —— 落在块身上是「成为子块」，落在缝里才是「排到这个位置」。
struct RootGap: View {
    @EnvironmentObject var m: Model
    let index: Int
    @State private var targeted = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 3)
                .padding(.horizontal, 2)
                .opacity(targeted ? 1 : 0)
        }
        // 给足高度：这是拖拽落点，太窄不好瞄
        .frame(height: 14)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init) else { return false }
            m.move(id, toRootIndex: index)
            return true
        } isTargeted: { targeted = $0 }
    }
}

// MARK: - 标签之间的插入缝

/// 项目标签之间的投放缝，和根级块的 RootGap 是一回事，只是插入线是竖的
struct TabGap: View {
    @EnvironmentObject var m: Model
    let index: Int
    @State private var targeted = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 3)
                .padding(.vertical, 1)
                .opacity(targeted ? 1 : 0)
        }
        // 高度必须写死：Color.clear 没有固有高度，只约束宽度的话会把整条标签栏撑满
        .frame(width: 10, height: 26)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init) else { return false }
            // 拖的可能是块（飘到标签栏上了），那样 id 不是项目，moveProject 会当没发生
            m.moveProject(id, toIndex: index)
            return true
        } isTargeted: { targeted = $0 }
    }
}

// MARK: - 状态分项计数

/// 一排「图标 + 数字」的小徽标，按状态分项。只显示非零项，鼠标悬停有文字说明。
struct StatusChips: View {
    let counts: [PRStatus: Int]
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 5 : 7) {
            ForEach(PRStatus.summaryOrder.filter { (counts[$0] ?? 0) > 0 }, id: \.self) { st in
                let n = counts[st] ?? 0
                HStack(spacing: 2) {
                    Image(systemName: st.symbol).font(.system(size: compact ? 9 : 10))
                    Text(verbatim: "\(n)").font(.caption2.monospacedDigit())
                }
                // 已完成的压暗，别和还要盯的抢注意力
                .foregroundColor(st.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(st.color.opacity(0.13)))
                .help("\(st.label) \(n) 个")
            }
        }
    }
}

// MARK: - 缩进连线

/// 一格缩进宽度里画的线
enum Guide {
    case blank      // 这一层的祖先已经是最后一个了，不画
    case line       // │  祖先下面还有兄弟，竖线穿过去
    case branch     // ├─ 连到自己，且自己下面还有兄弟
    case lastBranch // └─ 连到自己，自己是最后一个
}

struct GuideCell: View {
    let guide: Guide
    static let width: CGFloat = 26

    var body: some View {
        GeometryReader { g in
            Path { p in
                let x = Self.width / 2
                let midY = g.size.height / 2
                switch guide {
                case .blank:
                    break
                case .line:
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: g.size.height))
                case .branch:
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: x, y: midY))
                    p.addLine(to: CGPoint(x: g.size.width, y: midY))
                case .lastBranch:
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: midY))
                    p.addLine(to: CGPoint(x: g.size.width, y: midY))
                }
            }
            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
        }
        .frame(width: Self.width)
    }
}

extension Row {
    /// 这一行左边每一格该画什么
    var guides: [Guide] {
        guard depth > 0 else { return [] }
        return (0..<depth).map { i in
            if i < depth - 1 {
                return trail[i] ? .blank : .line   // 祖先是最后一个就不用continue 竖线
            }
            return isLast ? .lastBranch : .branch
        }
    }
}

// MARK: - 单行（描述块 / PR）

struct NodeRow: View {
    @EnvironmentObject var m: Model
    let row: Row
    @State private var targeted = false
    @State private var draft = ""
    @State private var confirmDelete = false
    @State private var hovering = false

    var body: some View {
        // 连线格和卡片并排，格子撑满整行高度（含上下留白），竖线才能连起来不断
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(row.guides.enumerated()), id: \.offset) { _, g in
                GuideCell(guide: g)
            }
            card
                .padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(targeted ? Color.accentColor : .clear, lineWidth: 2)
                        .padding(.vertical, 4)
                )
                .modifier(DragEnabled(enabled: m.editing, id: row.node.id))
                .dropDestination(for: String.self) { items, _ in
                    guard m.editing, let id = items.first.flatMap(UUID.init) else { return false }
                    m.move(id, under: row.node.id)
                    return true
                } isTargeted: { targeted = m.editing && $0 }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    var card: some View {
        if row.node.kind == .topic { topicBody } else { prBody }
    }

    /// 卡片最左边隔出的一条全高折叠区。
    /// 做成一整条而不是一个小三角，是因为小图标太难点；没有子块时留空，保持各行左边缘对齐。
    var collapseZone: some View {
        let hasKids = !row.node.children.isEmpty
        return Button {
            m.toggleCollapse(row.node.id)
        } label: {
            ZStack {
                if hasKids {
                    // 常驻一层淡底，让这一条看上去就是个可点的槽，不用等 hover 才发现
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(hovering ? 0.18 : 0.06))
                        .padding(.vertical, 4)
                        .padding(.leading, 8)    // 让开卡片左边缘的状态色条
                        .padding(.trailing, 2)
                    Image(systemName: row.node.collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(hovering ? .primary : .secondary)
                        .padding(.leading, 6)
                }
            }
            .frame(width: Self.zoneWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasKids)
        .onHover { hovering = $0 }
        .help(row.node.collapsed ? "展开（\(row.descendants) 个块）" : "折叠")
    }

    static let zoneWidth: CGFloat = 32

    /// 折叠时提示里面藏了多少块
    @ViewBuilder
    var collapsedBadge: some View {
        if row.node.collapsed, row.descendants > 0 {
            Text(verbatim: "▸ \(row.descendants)")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .foregroundColor(.secondary)
                .help("折叠了 \(row.descendants) 个块")
        }
    }

    // MARK: 描述块

    var topicBody: some View {
        let sum = m.topicSummary[row.node.id] ?? [:]
        let total = sum.values.reduce(0, +)
        return HStack(spacing: 0) {
            collapseZone
            HStack(spacing: 8) {
            if m.editing { grip }
            Image(systemName: "text.bubble").foregroundColor(.accentColor)
            if m.editing {
                TextField("写点什么，比如「修复 spill 内存统计」", text: Binding(
                    get: { row.node.title },
                    set: { v in m.edit { $0.nodes.update(row.node.id) { $0.title = v } } }
                ))
                .textFieldStyle(.plain)
                .font(.headline)
            } else {
                Text(row.node.title.isEmpty ? "（未命名描述块）" : row.node.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(row.node.title.isEmpty ? .secondary : .primary)
            }
            Spacer(minLength: 8)
            collapsedBadge
            if total > 0 {
                Text(verbatim: "\(total) 个 PR").font(.caption).foregroundColor(.secondary)
                StatusChips(counts: sum)
            }
            if m.editing { deleteButton }
            }
            .padding(EdgeInsets(top: 10, leading: 6, bottom: 10, trailing: 10))
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.25)))
    }

    // MARK: PR 块

    var prBody: some View {
        let num = row.node.pr ?? 0
        let lv = m.live[num]
        let st = m.status(pr: num, blocked: row.blocked)
        return HStack(spacing: 0) {
            collapseZone
            VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if m.editing { grip }
                // 一律 verbatim：PR 编号是标识符，不能被本地化成 "#77,255"
                if let lv, let u = URL(string: lv.url), !m.editing {
                    Link(destination: u) { Text(verbatim: "#\(num)") }
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                } else {
                    Text(verbatim: "#\(num)")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                }
                Text(lv?.title ?? "（拉取不到，检查编号或仓库设置）")
                    .lineLimit(1)
                    .foregroundColor(st == .merged ? .secondary : .primary)
                Spacer()
                collapsedBadge
                badges(lv)
                Text(st.label).font(.caption).foregroundColor(st.color)
                if m.editing { deleteButton }
            }
            HStack(spacing: 6) {
                if m.editing {
                    TextField("备注…", text: $draft)
                        .textFieldStyle(.plain)
                        .foregroundColor(.secondary)
                        .onSubmit { m.edit { $0.nodes.update(row.node.id) { $0.note = draft } } }
                } else if !row.node.note.isEmpty {
                    Text(row.node.note).foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                author(lv)
            }
            .font(.caption)
            }
            .padding(EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 10))
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
        .overlay(alignment: .leading) {
            Capsule().fill(st.color).frame(width: 3).padding(.vertical, 8).padding(.leading, 4)
        }
        .opacity(st == .merged || st == .closed ? 0.6 : 1)
        .onAppear { draft = row.node.note }
        .onChange(of: row.node.note) { _, new in draft = new }
    }

    // MARK: 零件

    var grip: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundColor(.secondary)
            .help("拖动以重新归类")
    }

    /// 创建人，靠右和上面一行的状态排成一列。
    /// 不是自己建的会加重显示 —— 机器人代建的 backport 和自己开的 PR，
    /// 处理方式不一样，值得一眼分得出来。
    @ViewBuilder
    func author(_ lv: LivePR?) -> some View {
        if let lv, !lv.author.isEmpty {
            let isMe = !m.gh.account.isNilOrEmpty && lv.author == m.gh.account
            HStack(spacing: 3) {
                Image(systemName: isMe ? "person" : "person.fill.badge.plus")
                    .font(.system(size: 9))
                Text(verbatim: "@\(lv.author)")
            }
            .foregroundColor(isMe ? .secondary : .primary)
            .help(isMe ? "你创建的" : "由 \(lv.author) 创建，不是你")
        }
    }

    var deleteButton: some View {
        Button(confirmDelete ? "确认删除" : "✕") {
            if confirmDelete {
                m.editAndRefresh { $0.nodes.removePromotingChildren(row.node.id) }
            } else {
                confirmDelete = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { confirmDelete = false }
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundColor(confirmDelete ? .red : .secondary)
        .help("删除本块，子块会提升一层")
    }

    // 状态标签已经涵盖草稿，这里只补充「review 和 CI 各自什么情况」这个维度
    @ViewBuilder
    func badges(_ lv: LivePR?) -> some View {
        if let lv {
            switch lv.review ?? "" {
            case "APPROVED": tag("已批准", .green)
            case "CHANGES_REQUESTED": tag("需修改", .red)
            default: if lv.state == "OPEN" { tag("待 review", .gray) }
            }
            switch lv.ci ?? "" {
            case "SUCCESS": tag("CI ✓", .green)
            case "FAILURE", "ERROR": tag("CI ✗", .red)
            case "PENDING", "EXPECTED": tag("CI …", .orange)
            default: EmptyView()
            }
        }
    }

    func tag(_ t: String, _ c: Color) -> some View {
        Text(t)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(c.opacity(0.15)))
            .foregroundColor(c)
    }
}

/// 冻结模式下不挂 .draggable，避免误拖
struct DragEnabled: ViewModifier {
    let enabled: Bool
    let id: UUID

    func body(content: Content) -> some View {
        if enabled {
            content.draggable(id.uuidString)
        } else {
            content
        }
    }
}

// MARK: - 入口

// TESTING 下不编译 App 入口，好让 Tests.swift 直接复用上面的真实代码（见 test.sh）
#if !TESTING
@main
struct PrWaiterApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup("PrWaiter") {
            ContentView().environmentObject(model)
        }
    }
}
#endif
