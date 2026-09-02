import SwiftUI
import UserNotifications
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

    /// 挂到指定父节点下，找不到父节点则返回 false。
    /// at 为 nil 表示挂在末尾（拖到块身上就是这个意思），给了下标就插到那一格。
    @discardableResult
    mutating func attach(_ node: Node, under parent: UUID, at index: Int? = nil) -> Bool {
        for i in indices {
            if self[i].id == parent {
                let at = index.map { Swift.max(0, Swift.min($0, self[i].children.count)) }
                self[i].children.insert(node, at: at ?? self[i].children.count)
                return true
            }
            if self[i].children.attach(node, under: parent, at: index) { return true }
        }
        return false
    }

    /// 按编号倒序，新节点该插到父块的第几格：
    /// 插到第一个比它小的前面；都比它大就排末尾。
    ///
    /// 只看得懂编号的兄弟（PR 节点），描述块和没编号的一律跳过 ——
    /// 手工拖出来的顺序不该被自动导入打乱，这里只负责把新来的放进「明显该在的位置」。
    func descendingSlot(for number: Int, under parent: UUID) -> Int {
        let siblings = find(parent)?.children ?? []
        return siblings.firstIndex { ($0.pr ?? Int.max) < number } ?? siblings.count
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
    let parent: UUID?       // 归谁管，根级为 nil
    let index: Int          // 在同层兄弟里排第几

    var id: UUID { node.id }
}

enum Tree {
    /// 铺平整棵树。isMerged 由调用方提供（实时状态不属于树本身），这样这个函数是纯的、可测的。
    static func flatten(_ nodes: [Node], isMerged: (Int) -> Bool) -> [Row] {
        func countAll(_ ns: [Node]) -> Int {
            ns.reduce(0) { $0 + 1 + countAll($1.children) }
        }
        func walk(_ ns: [Node], _ depth: Int, _ blocked: Bool, _ hidden: Bool,
                  _ trail: [Bool], _ parent: UUID?) -> [Row] {
            ns.enumerated().flatMap { i, n -> [Row] in
                let isLast = i == ns.count - 1
                let row = Row(
                    node: n, depth: depth, blocked: blocked, hidden: hidden,
                    isLast: isLast, trail: trail, descendants: countAll(n.children),
                    parent: parent, index: i
                )
                // 描述块只做分组，不参与先后关系；PR 没合并才挡住下面的
                let childBlocked = n.kind == .pr
                    ? blocked || !(n.pr.map(isMerged) ?? false)
                    : blocked
                return [row] + walk(n.children, depth + 1, childBlocked, hidden || n.collapsed,
                                    trail + [isLast], n.id)
            }
        }
        return walk(nodes, 0, false, false, [], nil)
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

    /// 一次性修正：早先版本取标题里**第一个** backport 引用当父节点，
    /// 多重 backport（`(backport #77408) (backport #77463)`）会被挂到最上游那个，
    /// 跳过中间一环。这里把它们搬到正确的上一手下面。
    ///
    /// 只动「当前父节点正好是标题里某个更早的引用」的那些 —— 那是老规则留下的手笔。
    /// 你自己拖到别处的、或者已经在对的地方的，一律不动。
    static func reparenting(_ nodes: [Node], titles: [Int: String]) -> [Node]? {
        var out = nodes

        /// 每个 PR 节点当前挂在哪个 PR 编号下面（挂在描述块或根级的记 nil）
        func parents(_ ns: [Node], under: Int?) -> [Int: Int?] {
            var map: [Int: Int?] = [:]
            for n in ns {
                if let pr = n.pr { map[pr] = under }
                map.merge(parents(n.children, under: n.kind == .pr ? n.pr : under)) { a, _ in a }
            }
            return map
        }

        for (pr, parent) in parents(nodes, under: nil) {
            let refs = GhParse.backportParents(from: titles[pr] ?? "")
            guard refs.count > 1, let want = refs.last, want != parent else { continue }
            // 现在挂着的必须是更早的那几个引用之一，才认定是老规则摆的
            guard let parent, refs.dropLast().contains(parent) else { continue }
            guard let id = out.nodeID(forPR: pr), let target = out.nodeID(forPR: want) else { continue }
            if let moved = Tree.move(id, under: target, in: out) { out = moved }
        }
        return changed(nodes, out) ? out : nil
    }

    /// 结构变没变。编号集合一样也可能换了位置，所以比的是铺平后的父子关系
    private static func changed(_ a: [Node], _ b: [Node]) -> Bool {
        func shape(_ ns: [Node], _ depth: Int) -> [String] {
            ns.flatMap { ["\($0.pr ?? -1)@\(depth)"] + shape($0.children, depth + 1) }
        }
        return shape(a, 0) != shape(b, 0)
    }

    /// 把节点插到 parent 的第 index 个孩子的位置（index 是「插到谁前面」，等于 count 表示放末尾）。
    /// parent 为 nil 表示根级。从别处拖过来的话，等于同时换爹 + 定位。
    static func move(_ dragged: UUID, toIndex index: Int, under parent: UUID?,
                     in nodes: [Node]) -> [Node]?
    {
        var nodes = nodes
        guard let node = nodes.find(dragged) else { return nil }
        if let parent {
            if node.kind == .topic { return nil }        // 描述块只能待在根级
            if node.contains(parent) { return nil }      // 不能插进自己的子树
            guard nodes.find(parent) != nil else { return nil }
        }
        let siblings = parent.map { nodes.find($0)?.children ?? [] } ?? nodes
        let wasAt = siblings.firstIndex { $0.id == dragged }
        // 原来就在这一层、且排在插入点前面的话，摘掉它之后后面的位置都往前挪了一格
        var target = index
        if let p = wasAt, p < index { target -= 1 }
        target = max(0, min(target, siblings.count - (wasAt == nil ? 0 : 1)))
        if wasAt == target { return nil }                // 没挪动，别白写一次盘

        nodes.detach(dragged)
        if let parent {
            guard nodes.attach(node, under: parent, at: target) else { return nil }
            nodes.update(parent) { $0.collapsed = false }   // 别让插进去的看起来「消失」了
        } else {
            nodes.insert(node, at: max(0, min(target, nodes.count)))
        }
        return nodes
    }

    /// 根级排序，是上面那个的常用情形
    static func move(_ dragged: UUID, toRootIndex index: Int, in nodes: [Node]) -> [Node]? {
        move(dragged, toIndex: index, under: nil, in: nodes)
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

    /// 「多重 backport 的父节点认错了」这个修正跑过没有。一次性的，跑完就置位 ——
    /// 每次刷新都跑的话，你手动把它拖到别处，下一拍又被搬回来了。
    var reparented = false

    enum CodingKeys: String, CodingKey { case id, name, repo, nodes, imported, reparented }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "新项目"
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        nodes = try c.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        imported = try c.decodeIfPresent([Int].self, forKey: .imported) ?? []
        reparented = try c.decodeIfPresent(Bool.self, forKey: .reparented) ?? false
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
                // 挂到父块下，位置按编号倒序 —— 新的排在旧的前面，
                // 跟根级「新的落最上面」是同一个意思，别让新 backport 沉到一堆已合并的下面
                out.attach(node, under: pid, at: out.descendingSlot(for: f.number, under: pid))
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
    /// 忽略过的 @：PR → 我忽略的是哪一次（存那次被点的时间）。
    /// 一个 PR 只记一条，新的 @ 时间更晚，自然又会冒出来 —— 不用清理历史。
    var dismissedPings: [String: Date] = [:]

    enum CodingKeys: String, CodingKey { case projects, selected, dismissedPings }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        selected = try c.decodeIfPresent(UUID.self, forKey: .selected)
        dismissedPings = try c.decodeIfPresent([String: Date].self, forKey: .dismissedPings) ?? [:]
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
    static let autoCheckUpdate = "autoCheckUpdate"  // 启动时检查更新
    static let autoInstallUpdate = "autoInstallUpdate"  // 查到就自动装（默认关）
    static let tutorialDone = "tutorialDone"        // 首次引导走完没
    static let notify = "notify"                    // PR 状态变了发通知

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            refreshInterval: 60, autoImport: true,
            autoCheckUpdate: true, autoInstallUpdate: false,
            tutorialDone: false, notify: true,
        ])
    }

    static var autoImportOn: Bool { UserDefaults.standard.bool(forKey: autoImport) }
    static var autoCheckUpdateOn: Bool { UserDefaults.standard.bool(forKey: autoCheckUpdate) }
    static var autoInstallUpdateOn: Bool { UserDefaults.standard.bool(forKey: autoInstallUpdate) }
    static var tutorialDoneFlag: Bool { UserDefaults.standard.bool(forKey: tutorialDone) }
    static var notifyOn: Bool { UserDefaults.standard.bool(forKey: notify) }

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

    /// GitHub 的时间戳一律是 ISO8601（`2026-08-20T06:14:00Z`）
    static func date(from iso: String) -> Date? {
        ISO8601DateFormatter().date(from: iso)
    }

    /// 标题里所有的 backport 引用，按出现顺序。
    /// StarRocks 的 mergify 会生成 "…… (backport #77408)"，其他仓库常见
    /// "backport of #123" / "cherry-pick #123"，都收进来。
    /// 实测 51 个 PR 里 40 个能解析出父 PR，解析不出的正是主干 PR 本身。
    static func backportParents(from title: String) -> [Int] {
        let pattern = #"(?i)(?:backport|cherry[- ]?pick)(?:ed)?(?:\s+(?:of|from))?[^#\d]{0,12}#(\d+)"#
        var out: [Int] = []
        var rest = Substring(title)
        while let m = rest.range(of: pattern, options: .regularExpression) {
            // 取匹配段里最后一串数字，也就是 # 后面那个编号
            if let numRange = rest[m].range(of: #"\d+$"#, options: .regularExpression),
               let n = Int(rest[m][numRange]) {
                out.append(n)
            }
            rest = rest[m.upperBound...]
        }
        return out
    }

    /// 直接的上一手是谁。
    ///
    /// 取**最后**一个引用，不是第一个：backport 再 backport 时，
    /// 标题会一路带上来源 —— `…… (backport #77408) (backport #77463)`
    /// 说的是「先有 #77408，再有它的 backport #77463，这个是从 #77463 来的」。
    /// 挂在 #77463 下面才是真正的先后关系；挂到 #77408 下面会跳过中间那一环。
    static func backportParent(from title: String) -> Int? {
        backportParents(from: title).last
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
    var base = ""       // 目标分支
    var isDraft = false
    var review: String? // APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED
    var ci: String?     // SUCCESS / FAILURE / ERROR / PENDING / EXPECTED
}

/// reviewer 视角里的一行：**别人卡在我这里的一件事**。
///
/// 这一页只放「我不动，别人就推不下去」的东西。所以：
/// - 我自己的 PR 不在这儿（那是看板那边的事），列表一律排除 `author:@me`
/// - 我已经 review 完、批准了的也不在这儿 —— 球在作者那边，我不是瓶颈了
///
/// 这么定的目的很实际：GitHub 的邮件多到根本看不完，别人的流程卡在我这里
/// 往往是因为那封邮件被埋了。这一页就是那份「别人在等我」的清单。
struct ReviewItem: Identifiable {
    enum Kind {
        case approveCI      // workflow / 部署卡着等我批，作者干等
        case requested      // 指名（或按团队）请我 review
        case assigned       // 别人的 PR 指派给我
        case mentioned      // 有人 @ 我，等我回话

        /// 越靠前越该先处理
        var rank: Int {
            switch self {
            case .approveCI: return 0
            case .requested: return 1
            case .assigned: return 2
            case .mentioned: return 3
            }
        }

        var label: String {
            switch self {
            case .approveCI: return "等我批准"
            case .requested: return "请我 review"
            case .assigned: return "指派给我"
            case .mentioned: return "@ 到我"
            }
        }
    }

    let kind: Kind
    let repo: String        // owner/name，跨仓库清单得显示是哪个
    let number: Int         // 0 表示这条挂不到具体 PR 上（fork 的 workflow run 有时拿不到 PR）
    let title: String
    let url: String
    let author: String
    let base: String
    let isDraft: Bool
    let review: String?
    let ci: String?
    /// 别人开始等我的时间（被请求 review / 被指派 / run 挂起）；拿不到就退回更新时间
    let at: Date?
    /// 等我批准的补充说明，比如卡在哪个环境
    let note: String
    /// 查的时候用的仓库名（配置里填的那个）。跟 repo 可能不一样 —— 仓库改名后
    /// GitHub 返回新名字，但要跟看板对账得用配置里的旧名
    var queried: String = ""

    /// 「@ 到我」这一档：最近一次别人点我、而我还没回话的时间
    var pingedAt: Date? = nil


    var id: String { number > 0 ? "\(repo)#\(number)" : "\(repo)!\(url)" }

    func with(kind: Kind) -> ReviewItem {
        ReviewItem(kind: kind, repo: repo, number: number, title: title, url: url,
                   author: author, base: base, isDraft: isDraft, review: review, ci: ci,
                   at: at, note: note, queried: queried, pingedAt: pingedAt)
    }
}

/// 从 check 明细自己算 CI 结论。
///
/// 为什么不直接用 GitHub 的 `statusCheckRollup.state`：它算不准，而且**取决于你怎么问**。
/// 同一个 commit、同一时刻，实测：
///
///     statusCheckRollup { state }                      -> SUCCESS
///     statusCheckRollup { state contexts(first:100) }   -> FAILURE
///
/// 原因是它把**同名 check 的历次尝试**全算进去了：一个 check 失败后重跑成功，
/// 旧的那条 FAILURE 还挂在 commit 上。实测某个 PR 有 54 条 context，
/// 按名字去重之后只有 34 项，20 个名字各有两次尝试。
///
/// 还有一条更要命的：rollup 只看**已经报上来的**。刚推完代码时，
/// 跑得快的几个（title-check、lint 之类）先报 SUCCESS，重活还没报上来，
/// 于是 rollup 就是 SUCCESS —— 界面上显示「CI ✓」，其实正经 job 还在跑。
/// 所以这里额外看 check suite：有 suite 正在跑，就算 CI 还在跑。
///
/// **只认 IN_PROGRESS，不认 QUEUED。** 装在仓库上的每个 GitHub App 都会给每个 commit
/// 挂一个 check suite，而多数 App 一条 check run 都不会发 —— 那些 suite 就永远停在
/// QUEUED。实测 StarRocks 每个 commit 都挂着 5 个这样的空 suite
/// （sonarqubecloud、codecov、vercel、claude、cursor），把 QUEUED 也算成「在跑」的话，
/// 20 个 PR 里有 9 个（全是早就合并/关闭的）会永远显示「CI 运行中」。
enum CheckRollup {
    /// 一条 check 记录，CheckRun 和老式 StatusContext 归一化成同一个形状
    struct Item {
        let name: String
        let state: String
        let at: String      // ISO8601，同名取最新的那次

        init(name: String, state: String, at: String) {
            self.name = name
            self.state = state
            self.at = at
        }

        init(json: [String: Any]) {
            if let n = json["name"] as? String {          // CheckRun
                name = n
                // 没跑完时 conclusion 是 null，这时候 status 才是有效信息
                state = (json["conclusion"] as? String) ?? (json["status"] as? String) ?? ""
                at = json["startedAt"] as? String ?? ""
            } else {                                       // StatusContext
                name = json["context"] as? String ?? ""
                state = json["state"] as? String ?? ""
                at = json["createdAt"] as? String ?? ""
            }
        }
    }

    /// 一个 check suite 的状态。**必须连 conclusion 一起看** ——
    /// fork PR 等维护者批准 workflow 时，suite 是 `status=COMPLETED` 而
    /// `conclusion=ACTION_REQUIRED`，光看 status 会当成「跑完了、什么都不会来」。
    /// 实测 apache/maka 那几个 PR 就是这个形状：0 条 check + 一个这样的 suite。
    struct Suite {
        let status: String
        let conclusion: String

        init(status: String, conclusion: String = "") {
            self.status = status
            self.conclusion = conclusion
        }

        init(json: [String: Any]) {
            status = json["status"] as? String ?? ""
            conclusion = json["conclusion"] as? String ?? ""
        }
    }

    static let pending: Set<String> = ["QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED", "PENDING", "EXPECTED"]
    /// ACTION_REQUIRED 不在这里 —— 那是「等人批准」，不是失败，单独一档
    static let failed: Set<String> = ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE"]

    /// - required: 分支保护要求的必过项。**这些里面有一项从来没报上来，CI 就没跑完** ——
    ///   GitHub 界面上那一条「Expected — Waiting for status to be reported」就是它。
    ///   传空集表示不知道（拿不到分支保护，或者这个分支没保护），那就只按已报上来的算。
    ///
    /// nil 表示这个 PR 压根没有 CI（有些仓库就是没配），不是「通过」
    static func state(contexts: [Item], suites: [Suite], required: Set<String> = []) -> String? {
        // 等人点「批准运行」：这不是「还在跑」，不点的话一步都不会跑。
        // 排在最前面判 —— 它是这条流水线的总闸，别的信号都是它后面的事。
        if suites.contains(where: { $0.conclusion == "ACTION_REQUIRED" })
            || contexts.contains(where: { $0.state == "ACTION_REQUIRED" }) {
            return "ACTION_REQUIRED"
        }
        // 有 suite 正在跑，说明重活还没报完，先说在跑
        if suites.contains(where: { $0.status == "IN_PROGRESS" }) { return "PENDING" }

        // 同名只留最新一次尝试 —— 重跑绿了就是绿了，旧的那条红不算数
        var latest: [String: Item] = [:]
        for c in contexts where !c.name.isEmpty {
            if let old = latest[c.name], old.at > c.at { continue }
            latest[c.name] = c
        }
        let states = latest.values.map(\.state)

        // 失败排在最前：已经该你动手了，别的还在跑不改变这一点
        if states.contains(where: { failed.contains($0) }) { return "FAILURE" }
        if states.contains(where: { pending.contains($0) }) { return "PENDING" }
        // 必过项一个都没露面 —— 界面上显示 Expected，压根还没轮到它跑
        if !required.isSubset(of: Set(latest.keys)) { return "PENDING" }
        return states.isEmpty ? nil : "SUCCESS"
    }

    /// 从 `repos/{repo}/branches/{branch}` 的响应里挖出必过项清单。
    /// 只要读权限就能拿到（实测 admin=false、push=false 也读得到），
    /// 比 `branches/{b}/protection` 那个要 admin 的接口宽松得多。
    static func requiredContexts(fromBranchJSON data: Data) -> Set<String> {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prot = obj["protection"] as? [String: Any],
              let rsc = prot["required_status_checks"] as? [String: Any],
              let list = rsc["contexts"] as? [String] else { return [] }
        return Set(list)
    }
}

/// 每个 PR 落在且只落在一个状态里，所以描述块上的分项计数加起来正好等于 PR 总数。
/// 顺序即优先级：先「该你动手的」，再「等上游」，再「等别人/等机器」，最后才是可以合了。
enum PRStatus: CaseIterable {
    case merged, closed, draft
    case ciFailed, changesRequested   // 问题在自己这边，即使被依赖挡着也该先修
    case blocked                      // 上游还没合
    case needsCIApproval              // workflow 等维护者点批准，不批就一步都不跑
    case ciRunning, needsReview       // 等机器 / 等人
    case ready
    case unknown

    var label: String {
        switch self {
        case .ready: return "可合并"
        case .ciFailed: return "CI 失败"
        case .changesRequested: return "需修改"
        case .needsCIApproval: return "CI 等批准"
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
        case .needsCIApproval: return .orange             // 欠在维护者身上，得有人点一下
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
        case .needsCIApproval:
            return "workflow 等维护者点「批准运行」。不批就一步都不跑，别误当成「还在跑」"
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
        case .needsCIApproval: return "hand.raised.fill"
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
        .ready, .ciFailed, .changesRequested, .needsCIApproval, .ciRunning,
        .needsReview, .blocked, .draft, .merged, .closed, .unknown,
    ]

    /// 已经尘埃落定、不需要再盯的。配色本身已经把它们压成灰或紫，
    /// 所以显示时不用再额外压暗一遍。
    var isSettled: Bool { self == .merged || self == .closed }
}

/// 发系统通知。
///
/// 只在 app 装在正经位置（比如 /Applications）时才真的能发 —— 实测从 /private/tmp
/// 里启动的同一个包，requestAuthorization 直接返回「Notifications are not allowed
/// for this application」。所以拿不到授权时不报错，静默算了，别拿弹窗烦人。
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var asked = false

    func start() {
        UNUserNotificationCenter.current().delegate = self
        request()
    }

    func request() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// url 非空时，点通知会打开那个 PR
    func post(title: String, body: String, url: String = "") {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if !url.isEmpty { c.userInfo = ["url": url] }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// app 在前台时也把横幅显出来 —— 否则你正看着别的窗口就完全收不到
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    /// 点通知直接跳到那个 PR
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let s = r.notification.request.content.userInfo["url"] as? String,
           let u = URL(string: s) {
            NSWorkspace.shared.open(u)
        }
        done()
    }
}

/// 一次状态变化。自动刷新发现了才通知 —— 你自己点刷新看到的不用再弹一遍。
struct StatusChange {
    let repo: String
    let number: Int
    let title: String
    let url: String
    let from: PRStatus
    let to: PRStatus

    /// 「等 review → 可合并」
    var line: String { "\(from.label) → \(to.label)" }
}

enum Watcher {
    /// 比对两次刷新之间的状态。纯函数，方便单测。
    ///
    /// 几种情况不报：
    /// - **第一次拉**（没有上一份快照）—— 那不是「变化」，是刚知道。不然一启动就炸一屏
    /// - **任何一头是「未知」** —— 拉取失败或刚导进来还没状态，报了也是噪音
    /// - 状态没变的
    static func changes(from old: [Int: PRStatus], to new: [Int: PRStatus],
                        info: (Int) -> (repo: String, title: String, url: String)?) -> [StatusChange]
    {
        guard !old.isEmpty else { return [] }
        return new.compactMap { n, to -> StatusChange? in
            guard let from = old[n], from != to else { return nil }
            guard from != .unknown, to != .unknown else { return nil }
            guard let i = info(n) else { return nil }
            return StatusChange(repo: i.repo, number: n, title: i.title, url: i.url,
                                from: from, to: to)
        }
        // 编号大的排前面：新 PR 通常更要紧
        .sorted { $0.number > $1.number }
    }

    /// 通知文案。一条就说清楚是哪个 PR、怎么变的；多条就汇总，别刷屏。
    static func message(_ cs: [StatusChange]) -> (title: String, body: String)? {
        guard let first = cs.first else { return nil }
        let repo = first.repo.split(separator: "/").last.map(String.init) ?? first.repo
        if cs.count == 1 {
            return ("\(repo) #\(first.number)  \(first.line)", first.title)
        }
        return ("\(cs.count) 个 PR 状态变了",
                cs.prefix(4).map { "#\($0.number) \($0.to.label)" }.joined(separator: "、")
                    + (cs.count > 4 ? " 等" : ""))
    }
}

// MARK: - 上手导览（聚光灯式）

/// 要高亮的界面元素。用 preference 上报各自的位置，遮罩再据此挖洞。
enum TourTarget: String {
    case projectTabs, editButton, gearButton, refreshButton
    case topicRow, collapseZone, statusBadges, dragGrip
}

struct TourAnchors: PreferenceKey {
    static let defaultValue: [TourTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourTarget: Anchor<CGRect>],
                       nextValue: () -> [TourTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 铺满宿主视图的透明层，只负责上报自己的位置
private struct TourAnchorReporter: View {
    let target: TourTarget
    var body: some View {
        Color.clear.anchorPreference(key: TourAnchors.self, value: .bounds) { [target: $0] }
    }
}

extension View {
    /// 挂在要被导览指到的控件上。
    ///
    /// 用 overlay 里的透明层上报，而不是把 anchorPreference 直接挂在自己身上：
    /// preference 挂在父视图上会**盖掉整棵子树**的同键上报 —— 描述块一上报，
    /// 它内部折叠区的锚点就没了，那一步只能退化成居中的对话框。
    /// 放进 overlay 后两者是兄弟，走 reduce 合并，各报各的。
    func tourTarget(_ t: TourTarget) -> some View {
        overlay(TourAnchorReporter(target: t).allowsHitTesting(false))
    }
}

/// 只在 on 为真时上报锚点
struct TourTargetIf: ViewModifier {
    let on: Bool
    let target: TourTarget
    func body(content: Content) -> some View {
        if on { content.tourTarget(target) } else { content }
    }
}

/// 导览期间铺在看板上的样板数据。
///
/// 首次启动时用户一条数据都没有 —— 指着空看板讲「描述块」「状态颜色」，
/// 洞会挖在空气上，气泡退化成一个干巴巴的对话框。所以导览自带一份假数据，
/// 保证每一步都有真东西可指。编号用 900+，跟真 PR 一眼能分开。
enum TourDemo {
    static let projects = ["示例仓库", "另一个仓库"]

    /// 两个 backport 挂在主干 PR 下面 —— 这正好是「缩进 = 先后关系」那一步要指的东西
    static let nodes: [Node] = {
        var trunk = Node(kind: .pr, pr: 901)
        trunk.children = [Node(kind: .pr, pr: 902), Node(kind: .pr, pr: 903)]
        var topic = Node(kind: .topic, title: "spill 相关改动", note: "主干先合，backport 跟着走")
        topic.children = [trunk]
        return [topic]
    }()

    /// 三行分别落在「可以合了」「等上游」「CI 挂了」上，颜色那一步才讲得清。
    /// 902 自身条件其实齐了，是被 901 挡着 —— 这就是 blocked 那一档的意思。
    static let live: [Int: LivePR] = [
        901: LivePR(title: "[Enhancement] Enable auto-mode spill for the nestloop join",
                    state: "OPEN", author: "you", base: "main",
                    review: "APPROVED", ci: "SUCCESS"),
        902: LivePR(title: "[BugFix] Derive the reserve limit from the memory limit (backport #901)",
                    state: "OPEN", author: "mergify", base: "branch-3.5",
                    review: "APPROVED", ci: "SUCCESS"),
        903: LivePR(title: "[BugFix] Derive the reserve limit from the memory limit (backport #901)",
                    state: "OPEN", author: "mergify", base: "branch-4.0",
                    review: "REVIEW_REQUIRED", ci: "FAILURE"),
    ]
}

struct TourStep {
    let target: TourTarget?     // nil = 没有具体目标，气泡居中显示
    /// 这一步要指的控件只在编辑态才出现（拖动手柄），导览得先把它显出来
    var needsEditing = false
    let title: String
    let body: String
    /// 这一步要求主界面处于哪一页；nil 表示不改
    var page: ContentView.Page?

    /// 每一步都指着一个真实控件 —— 这就是导览该干的事，
    /// 不要没有目标的纯说明页，那种看着只是个对话框
    static let all: [TourStep] = [
        TourStep(target: .projectTabs,
                 title: "项目标签",
                 body: "一个标签对应一个仓库，切换后只看那个仓库的 PR。"
                     + "编辑模式下还能拖动标签调整顺序。"),
        TourStep(target: .topicRow,
                 title: "描述块：把相关 PR 收在一起",
                 body: "写上「这是在修什么」，相关 PR 归到它下面。\n\n"
                     + "**缩进就是先后关系** —— 子块要等父块先合并。"
                     + "这是整个 App 最核心的一条，其余都是细节。"),
        TourStep(target: .statusBadges,
                 title: "状态：颜色按「欠在谁身上」分",
                 body: "绿=可以合了、红=欠在你身上（CI 挂了 / 要改）、"
                     + "橙=等机器、蓝=等人 review、靛=等上游那个 PR、灰=已终结。\n\n"
                     + "完整对照表在设置的「状态说明」里。"),
        TourStep(target: .collapseZone,
                 title: "折叠区",
                 body: "块最左边这一整条都能点，收起 / 展开。\n\n"
                     + "折叠**不影响统计** —— 收起来的 PR 照样算在描述块右侧的数量里。"),
        TourStep(target: .editButton,
                 title: "编辑 / 冻结",
                 body: "默认冻结，只读，避免误拖误删。点它才会出现拖动手柄、增删按钮和输入框。\n\n"
                     + "**拖不动多半是忘了先点这里。**"),
        TourStep(target: .dragGrip,
                 needsEditing: true,
                 title: "拖拽：落点决定意思",
                 body: "编辑模式下拖这个手柄：\n"
                     + "· 落在**块身上** = 成为它的子块（归类，或表示「等它先合」）\n"
                     + "· 落在**块之间** = 排到那个位置\n"
                     + "· 落在**底部虚线区** = 回到根级"),
        TourStep(target: .refreshButton,
                 title: "刷新会自动导入",
                 body: "每次刷新先把**作者是你、或指派给你**的 open PR 导进来，"
                     + "backport 自动挂到主干 PR 下面，然后再拉取全部状态。\n\n"
                     + "不用手工填编号。"),
        TourStep(target: .gearButton,
                 title: "设置",
                 body: "gh 的安装与登录、刷新间隔、状态说明、检查更新都在这里。\n\n"
                     + "想重看这份导览，也在设置的「关于」里。"),
    ]
}

/// 聚光灯遮罩：四周压暗，目标位置挖个洞并描边，旁边浮一个说明气泡
struct TourOverlay: View {
    @EnvironmentObject var m: Model
    let index: Int
    let rect: CGRect?          // 目标在窗口里的位置，nil 表示居中显示
    let canvas: CGSize

    private var step: TourStep { TourStep.all[index] }
    private var hole: CGRect? { rect?.insetBy(dx: -6, dy: -6) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 压暗 + 挖洞。用 even-odd 填充规则做出真正的空洞，
            // 而不是画个亮框——空洞才能让下面的内容原色透出来
            Path { p in
                p.addRect(CGRect(origin: .zero, size: canvas))
                if let h = hole {
                    p.addRoundedRect(in: h, cornerSize: CGSize(width: 8, height: 8))
                }
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

            if let h = hole {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: h.width, height: h.height)
                    .offset(x: h.minX, y: h.minY)
            }

            bubble
                .frame(width: 380)
                .offset(x: bubbleOrigin.x, y: bubbleOrigin.y)
        }
        .frame(width: canvas.width, height: canvas.height)
        // 吃掉所有点击：导览期间只能用气泡上的按钮，免得点乱了
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    var bubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(step.title).font(.headline)
                Spacer()
                Text(verbatim: "\(index + 1) / \(TourStep.all.count)")
                    .font(.caption).foregroundColor(.secondary)
            }
            Text(.init(step.body)).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("跳过") { m.finishTour() }.buttonStyle(.link)
                Spacer()
                if index > 0 {
                    Button("上一步") { m.backTour() }
                }
                Button(index == TourStep.all.count - 1 ? "开始使用" : "下一步") { m.advanceTour() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.45)))
        .shadow(radius: 12)
    }

    /// 气泡放在洞的下方；下方放不下就放上方。左右夹在画布内，别跑出去
    var bubbleOrigin: CGPoint {
        let w: CGFloat = 380, h: CGFloat = 190, pad: CGFloat = 14
        guard let hRect = hole else {
            return CGPoint(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2)
        }
        var y = hRect.maxY + pad
        if y + h > canvas.height { y = max(pad, hRect.minY - h - pad) }
        let x = min(max(pad, hRect.midX - w / 2), canvas.width - w - pad)
        return CGPoint(x: x, y: y)
    }
}

// MARK: - 版本与自动更新

enum Version {
    /// 按数字逐段比较，不能用字符串比 —— "0.10.0" < "0.9.0" 是字符串序，是错的。
    /// 段数不同时短的补 0，所以 "1.0" 和 "1.0.0" 相等。
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// "v0.9.0" / "0.9.0" 都能吃；非数字段当 0
    static func parts(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }
}

/// 查到的最新发布
struct ReleaseInfo {
    let version: String      // 去掉 v 前缀
    let tag: String
    let assetName: String
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate            // 已经是最新
    case available(String)   // 有新版本，带版本号
    case downloading
    case failed(String)
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
    /// 拉取失败，按项目分开记 —— 所有项目并发刷新，别的项目挂了
    /// 不该显示在你正看着的这个项目头上
    @Published var errorByProject: [UUID: String] = [:]
    var error: String? { store.selected.flatMap { errorByProject[$0] } }
    @Published var saveError: String?     // 落盘失败 —— 比拉取失败严重，改动是真丢
    @Published var loading = false
    /// 正在拉的项目。所有项目并发刷新时，单个 Bool 挡不住重入
    private var inFlight = Set<UUID>()

    /// 上一轮每个 PR 是什么状态，用来比对出变化。
    /// **只放内存**：重启之后第一次拉当基线，不补报关机期间的变化 ——
    /// 一开机炸一屏通知比不通知更烦。
    private var lastStatus: [UUID: [Int: PRStatus]] = [:]
    /// 上一轮评审清单里有哪些事，用来认出「新来的」
    private var lastInboxIDs: Set<String> = []
    @Published var editing = false
    @Published var gh = GhStatus()
    @Published var detecting = false
    @Published var installLog: [String] = []
    @Published var installing = false
    // 自动更新
    @Published var tourIndex: Int?           // nil 表示不在导览中
    /// 导览要求主界面切到哪一页（比如讲设置时）
    @Published var page: ContentView.Page?
    @Published var latest: ReleaseInfo?      // 查到的最新发布
    @Published var updateState = UpdateState.idle
    @Published var updateLog: [String] = []

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
        // 没走过导览就开一次。看板空不空都能走 —— 导览期间铺的是 TourDemo 的样板数据
        if !Prefs.tutorialDoneFlag { tourIndex = 0 }
        // 先探测 gh，再干活 —— 两边都要账号。detectToolchain 内部会去重，
        // 所以这两个 Task 只会真探测一次
        if Prefs.notifyOn { Notifier.shared.start() }
        // 一上来就把所有项目和评审清单都拉一遍：切换按钮上那个待办数
        // 得一打开就是准的，否则「有人在等我」这件事要点进去才知道，等于白做
        Task { await self.refreshEverything() }
        if Prefs.autoCheckUpdateOn {
            Task { await self.checkForUpdate(auto: true) }
        }
        rescheduleTimer()
    }

    /// 刷新间隔改了要重排，间隔为 0 表示只手动刷新
    func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        let seconds = Prefs.interval
        guard seconds > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(seconds), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshEverything(auto: true) }
        }
    }

    /// 正在跑的那次探测。多处都要账号（看板的自动导入、reviewer 清单），
    /// 各自触发一次纯属浪费，而且会撞出「还没探测完就说没登录」的假错。
    private var detectTask: Task<Void, Never>?

    func detectToolchain() async {
        if let t = detectTask { await t.value; return }
        let t = Task { @MainActor in
            detecting = true
            gh = await Self.detectGh()
            detecting = false
        }
        detectTask = t
        await t.value
        detectTask = nil
    }

    /// 拿 gh 账号，必要时先等探测完。
    ///
    /// 启动时这几件事是并发跑的，账号还没探测出来就去查清单的话，
    /// 会先闪一下「还没登录 gh」再自己好 —— 那不是错误，是还没问完。
    func account() async -> String? {
        if let a = gh.account, !a.isEmpty { return a }
        await detectToolchain()
        let a = gh.account
        return (a?.isEmpty ?? true) ? nil : a
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

    func move(_ dragged: UUID, toIndex index: Int, under parent: UUID?) {
        guard let i = projectIndex,
              let moved = Tree.move(dragged, toIndex: index, under: parent,
                                    in: store.projects[i].nodes) else { return }
        store.projects[i].nodes = moved
        save()
    }

    func move(_ dragged: UUID, toRootIndex index: Int) {
        guard let i = projectIndex,
              let moved = Tree.move(dragged, toRootIndex: index, in: store.projects[i].nodes) else { return }
        store.projects[i].nodes = moved
        save()
    }

    // MARK: reviewer 视角

    /// 别人请我 review 的清单。跟看板分开缓存 —— 切过去不用重新拉
    @Published var inbox: [ReviewItem] = []
    @Published var inboxAt: Date?
    @Published var inboxLoading = false
    @Published var inboxError: String?

    /// 有没有「等我批准」那种最急的 —— 气泡变橙色
    var inboxUrgent: Bool { inbox.contains { $0.kind == .approveCI } }

    /// 只查已配置的项目仓库（去重）—— 跨全网的 review 请求先不管，
    /// 你关心的就是这几个仓库
    var inboxRepos: [String] {
        var seen = Set<String>()
        return store.projects.map(\.repo).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 看板已经在跟的 PR：`仓库#编号`。两个视角是两套东西，不该同一条 PR 两边都出现。
    ///
    /// 主要挡的是机器人代建的 backport —— 作者是 bot、把我设成 assignee，看板按
    /// assignee 把它导进来当我的贡献（本来就是我的改动被 backport），
    /// 但评审清单按 `assignee:@me` 也会搜到它。它归看板。
    var trackedPRs: Set<String> {
        var out = Set<String>()
        for p in store.projects where !p.repo.isEmpty {
            for n in p.nodes.allPRNumbers { out.insert("\(p.repo)#\(n)") }
        }
        return out
    }

    /// 滤掉看板已经在跟的那些。纯函数，方便单测。
    ///
    /// 对账用**查询时的仓库名**（配置里填的那个），不是 GitHub 返回的真名 ——
    /// 仓库改过名的话两者不一样，用真名会对不上、白白漏掉。
    nonisolated static func excludeTracked(_ items: [ReviewItem], tracked: Set<String>) -> [ReviewItem] {
        items.filter { it in
            let key = "\(it.queried.isEmpty ? it.repo : it.queried)#\(it.number)"
            return !tracked.contains(key) && !tracked.contains(it.id)
        }
    }

    /// 评审清单里新冒出来的事，通知一条。
    /// 「有人开始等我」正是最该被叫醒的时刻 —— 这功能本来就是为了别让人卡在我这里。
    func noticeInbox(auto: Bool) {
        let ids = Set(inbox.map(\.id))
        defer { lastInboxIDs = ids }
        guard auto, Prefs.notifyOn, !lastInboxIDs.isEmpty else { return }

        let fresh = inbox.filter { !lastInboxIDs.contains($0.id) }
        guard let first = fresh.first else { return }
        let repo = first.repo.split(separator: "/").last.map(String.init) ?? first.repo
        if fresh.count == 1 {
            Notifier.shared.post(title: "\(first.kind.label)：\(repo) #\(first.number)",
                                 body: first.title, url: first.url)
        } else {
            Notifier.shared.post(title: "\(fresh.count) 件事在等你",
                                 body: fresh.prefix(4)
                                    .map { "\($0.kind.label) #\($0.number)" }
                                    .joined(separator: "、"))
        }
    }

    /// 忽略这一次 @：这条从清单里去掉，下次有人再点我（时间更晚）还会重新出现
    func dismissPing(_ item: ReviewItem) {
        store.dismissedPings[item.id] = item.pingedAt ?? Date()
        inbox.removeAll { $0.id == item.id }
        save()
    }

    /// 滤掉已经忽略过的那些 @。纯函数，方便单测。
    nonisolated static func applyDismissed(_ items: [ReviewItem],
                                           dismissed: [String: Date]) -> [ReviewItem] {
        items.filter { it in
            guard it.kind == .mentioned, let cut = dismissed[it.id] else { return true }
            guard let ping = it.pingedAt else { return false }
            return ping > cut     // 忽略之后又被点了才重新冒出来
        }
    }

    func refreshInbox(auto: Bool = false) async {
        guard !inboxLoading else { return }
        inboxLoading = true
        defer { inboxLoading = false }
        guard let who = await account() else {
            inboxError = "还没登录 gh，到设置里点「在终端登录」"
            return
        }
        do {
            let got = try await Self.fetchReviewInbox(repos: inboxRepos, account: who)
            inbox = Self.applyDismissed(Self.excludeTracked(got, tracked: trackedPRs),
                                        dismissed: store.dismissedPings)
            inboxAt = Date()
            inboxError = nil
            noticeInbox(auto: auto)
        } catch let e {
            inboxError = e.localizedDescription
        }
    }

    // MARK: 上手导览

    func startTour() {
        tourIndex = 0
        page = nil          // 让主界面回到看板
    }

    func advanceTour() {
        guard let i = tourIndex else { return }
        if i + 1 < TourStep.all.count { tourIndex = i + 1 } else { finishTour() }
    }

    func backTour() {
        guard let i = tourIndex, i > 0 else { return }
        tourIndex = i - 1
    }

    func finishTour() {
        tourIndex = nil
        UserDefaults.standard.set(true, forKey: Prefs.tutorialDone)
    }

    /// 当前这一步要不要把编辑态的控件显出来（只影响显示，不动用户的编辑开关）
    var tourEditing: Bool {
        tourIndex.map { TourStep.all[$0].needsEditing } ?? false
    }

    // MARK: 更新

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// auto=true 表示是启动时自动查的：查不到就安静收场，别拿网络问题烦人
    func checkForUpdate(auto: Bool = false) async {
        if updateState == .checking || updateState == .downloading { return }
        updateState = .checking
        do {
            let r = try await Self.fetchLatestRelease()
            latest = r
            if Version.isNewer(r.version, than: currentVersion) {
                updateState = .available(r.version)
                if Prefs.autoInstallUpdateOn { await installUpdate() }
            } else {
                updateState = .upToDate
            }
        } catch {
            updateState = auto ? .idle : .failed(error.localizedDescription)
        }
    }

    func installUpdate() async {
        guard let r = latest, updateState != .downloading else { return }
        updateState = .downloading
        updateLog = []
        do {
            try await Self.downloadAndInstall(r) { [weak self] line in
                Task { @MainActor in self?.updateLog.append(line) }
            }
            // 替换脚本已经在后台等着了，这里退出让它接手
            updateLog.append("正在重启…")
            try? await Task.sleep(nanoseconds: 400_000_000)
            NSApplication.shared.terminate(nil)
        } catch {
            updateState = .failed(error.localizedDescription)
        }
    }

    func deleteCurrentProject() {
        guard let i = projectIndex else { return }
        let gone = store.projects.remove(at: i).id
        liveByProject[gone] = nil     // 缓存跟着项目走，别留孤儿
        fetchedAt[gone] = nil
        errorByProject[gone] = nil
        store.selected = store.projects.first?.id
        save()
        if let now = store.selected, liveByProject[now] == nil {
            Task { await self.refresh() }
        }
    }

    // MARK: 拉取

    /// 刷新所有项目 + 评审清单。
    ///
    /// 为什么不只刷当前那个：切到别的项目、或者切到评审视角时总得再等一次，
    /// 而且切换按钮上的待办数会一直是旧的 —— 那个数字要有用，就得一直是准的。
    /// 各项目并发拉（每个项目一次请求，慢在握手，并发起来总耗时约等于最慢的那一个）。
    func refreshEverything(auto: Bool = false) async {
        let pids = store.projects.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for pid in pids { group.addTask { @MainActor in await self.refresh(pid, auto: auto) } }
            group.addTask { @MainActor in await self.refreshInbox(auto: auto) }
        }
    }

    /// 界面上只有一个「在忙」的指示：任何一件事在拉就转圈
    var busy: Bool { loading || inboxLoading }

    func refresh() async { await refresh(store.selected) }

    /// auto=true 表示是定时器自动拉的。手动点刷新时不通知 ——
    /// 你正盯着屏幕，变化就在眼前，再弹一条纯属多余。
    func refresh(_ target: UUID?, auto: Bool = false) async {
        guard let p = store.projects.first(where: { $0.id == target }), !p.repo.isEmpty else {
            if let pid = target { liveByProject[pid] = [:]; errorByProject[pid] = nil }
            return
        }
        let pid = p.id
        if inFlight.contains(pid) { return }
        inFlight.insert(pid)
        loading = true
        defer {
            inFlight.remove(pid)
            loading = !inFlight.isEmpty
        }

        // 状态和「我的 PR」搜索挤在同一次请求里 —— 慢的是握手不是数据量，见 fetchAll
        let numbers = p.nodes.allPRNumbers
        let who = Prefs.autoImportOn ? await account() : nil
        guard !numbers.isEmpty || !(who ?? "").isEmpty else {
            // 一个 PR 都没有、也不用自动导入：记成「拉过了」，免得每次切回来都白试一次
            liveByProject[pid] = [:]
            errorByProject[pid] = nil
            return
        }
        do {
            let r = try await Self.fetchAll(repo: p.repo, numbers: numbers, account: who)
            liveByProject[pid] = r.live
            fetchedAt[pid] = Date()
            errorByProject[pid] = nil
            noticeChanges(in: pid, live: r.live, auto: auto)
            fixBackportParents(in: pid, titles: r.live.mapValues(\.title))
            // 导入放在后面：搜索结果跟状态是同一次请求带回来的，不用再跑一趟。
            // 新导进来的这一批要等下一拍才有状态 —— 换一次往返（5 秒）不值。
            if !r.found.isEmpty { importFound(r.found, into: pid) }
        } catch let e {
            errorByProject[pid] = e.localizedDescription
        }
    }

    /// 算出这个项目每个 PR 现在是什么状态。
    /// 状态跟树有关（被上游挡着算 blocked），所以不能只看 live。
    func statuses(of p: Project, live: [Int: LivePR]) -> [Int: PRStatus] {
        var out: [Int: PRStatus] = [:]
        for row in Tree.flatten(p.nodes, isMerged: { live[$0]?.state == "MERGED" })
        where row.node.kind == .pr {
            if let n = row.node.pr { out[n] = Self.classify(live[n], blocked: row.blocked) }
        }
        return out
    }

    /// 比对上一轮，把状态变化通知出去。
    ///
    /// 第一次拉只记基线不通知 —— 那不是「变了」，是刚知道。
    func noticeChanges(in pid: UUID, live: [Int: LivePR], auto: Bool) {
        guard let p = store.projects.first(where: { $0.id == pid }) else { return }
        let now = statuses(of: p, live: live)
        defer { lastStatus[pid] = now }

        guard auto, Prefs.notifyOn, let old = lastStatus[pid] else { return }
        let cs = Watcher.changes(from: old, to: now) { n in
            guard let lv = live[n] else { return nil }
            return (p.repo, lv.title, lv.url)
        }
        guard let m = Watcher.message(cs) else { return }
        Notifier.shared.post(title: m.title, body: m.body,
                             url: cs.count == 1 ? cs[0].url : "")
    }

    /// 一次性把多重 backport 的父节点摆正。要标题才能判断，所以放在拉完状态之后。
    func fixBackportParents(in pid: UUID, titles: [Int: String]) {
        guard let i = store.projects.firstIndex(where: { $0.id == pid }),
              !store.projects[i].reparented else { return }
        if let fixed = Tree.reparenting(store.projects[i].nodes, titles: titles) {
            store.projects[i].nodes = fixed
        }
        store.projects[i].reparented = true
        save()
    }

    /// 把搜索到的 PR 里没见过的导进来。搜索结果由 fetchAll 一并带回，这里不再发请求。
    func importFound(_ found: [FoundPR], into pid: UUID) {
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

    // MARK: 自动更新

    static let repoSlug = "WloBy-Labs/PrWaiter"

    /// 查最新发布。走 gh 而不是匿名 HTTP：GitHub 对未认证请求限 60 次/小时且按 IP 计，
    /// 公司出口 IP 后面很容易撞上 403（实测就撞到过）；gh 带认证，限额 5000 次/小时。
    /// 顺带也不用再引一套网络栈，仓库将来转 private 也不用改。
    nonisolated static func fetchLatestRelease() async throws -> ReleaseInfo {
        guard let gh = ghPath() else { throw AppError("找不到 GitHub CLI（gh）") }
        let out = try await run(gh, ["release", "view", "--repo", repoSlug,
                                     "--json", "tagName,assets"])
        guard let obj = try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any],
              let tag = obj["tagName"] as? String
        else {
            throw AppError(out.stderr.isEmpty ? "查不到发布信息" : out.stderr)
        }
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        guard let dmg = assets.compactMap({ $0["name"] as? String }).first(where: { $0.hasSuffix(".dmg") })
        else {
            throw AppError("最新发布 \(tag) 里没有 DMG")
        }
        return ReleaseInfo(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                           tag: tag, assetName: dmg)
    }

    /// 下载 → 校验签名 → 换掉自己 → 重启。
    /// 换掉正在运行的自己没法在进程内完成，所以最后交给一个脱离出去的脚本：
    /// 它等本进程退出后再替换并重新打开。
    nonisolated static func downloadAndInstall(
        _ release: ReleaseInfo, log: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let gh = ghPath() else { throw AppError("找不到 GitHub CLI（gh）") }
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            throw AppError("当前不是从 .app 运行的，自动更新只在安装后的 App 上可用")
        }
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            throw AppError("没有写入 \(bundle.deletingLastPathComponent().path) 的权限，请手动下载安装")
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PrWaiterUpdate-\(release.tag)")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        log("下载 \(release.assetName)…")
        let dl = try await run(gh, ["release", "download", release.tag, "--repo", repoSlug,
                                    "--pattern", "*.dmg", "--dir", tmp.path])
        let dmg = tmp.appendingPathComponent(release.assetName)
        guard FileManager.default.fileExists(atPath: dmg.path) else {
            throw AppError(dl.stderr.isEmpty ? "下载失败" : dl.stderr)
        }

        log("挂载并校验…")
        let mountPoint = tmp.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let att = try await run("/usr/bin/hdiutil",
                                ["attach", dmg.path, "-nobrowse", "-readonly",
                                 "-mountpoint", mountPoint.path])
        guard att.stderr.isEmpty || FileManager.default.fileExists(atPath: mountPoint.path) else {
            throw AppError("挂载失败：\(att.stderr)")
        }
        let newApp = mountPoint.appendingPathComponent("PrWaiter.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            _ = try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
            throw AppError("DMG 里没有 PrWaiter.app")
        }

        // 签名坏掉的包不能装进去 —— 下载可能损坏，装上就是个打不开的 App
        let verify = try await run("/usr/bin/codesign", ["--verify", "--strict", newApp.path])
        guard verify.stderr.range(of: "invalid|not signed", options: .regularExpression) == nil else {
            _ = try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
            throw AppError("下载到的包签名校验不通过，已中止：\(verify.stderr)")
        }

        // 先把新版拷到临时目录再卸载 DMG，免得替换脚本还依赖着挂载点
        let staged = tmp.appendingPathComponent("PrWaiter.app")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: newApp, to: staged)
        _ = try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])

        log("准备替换，App 将重启…")
        let script = tmp.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/bash
        # 等本体退出后再替换，否则会覆盖正在运行的可执行文件
        for _ in $(seq 1 100); do
            kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break
            sleep 0.2
        done
        rm -rf '\(bundle.path)'
        cp -R '\(staged.path)' '\(bundle.path)'
        open '\(bundle.path)'
        rm -rf '\(tmp.path)'
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        try p.run()   // 不 wait：它要活过本进程
    }

    /// 拉 reviewer 视角的清单：**别人卡在我这里的事**。
    ///
    /// 三类靠一次 GraphQL 搜索拿到（请我 review / 指派给我 / @ 到我），
    /// 一律排除 `author:@me` —— 我自己的 PR 归看板那边管。
    ///
    /// 「等我批准 workflow」得单独查：随便一个贡献者的 fork PR 卡着等我批，
    /// 没人会请我 review，搜索里根本看不到它。而且只有我有 write 权限的仓库才查得着 ——
    /// 批 workflow 要写权限，只读仓库连查都不用查（省一次 5 秒的请求）。
    nonisolated static func fetchReviewInbox(repos: [String], account: String)
        async throws -> [ReviewItem]
    {
        guard let gh = ghPath() else {
            throw AppError("找不到 GitHub CLI（gh），到设置里可以一键安装")
        }
        let valid = repos.filter { $0.range(of: #"^[\w.-]+/[\w.-]+$"#, options: .regularExpression) != nil }
        guard !valid.isEmpty, !account.isEmpty else { return [] }

        // 被请求 review 的确切时间要从 timeline 里取 —— 只按 PR 更新时间排序会把
        // 「三天前请我、刚被作者推了一版」排到「十分钟前请我」前面
        let prFields = """
        number title url isDraft updatedAt reviewDecision baseRefName \
        author { login } repository { nameWithOwner } \
        timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT, ASSIGNED_EVENT], last: 20) { nodes { \
          ... on ReviewRequestedEvent { createdAt requestedReviewer { \
            ... on User { login } ... on Team { name } } } \
          ... on AssignedEvent { createdAt assignee { ... on User { login } } } } } \
        commits(last: 1) { nodes { commit { \
          statusCheckRollup { contexts(last: 100) { nodes { \
            __typename \
            ... on CheckRun { name status conclusion startedAt } \
            ... on StatusContext { context state createdAt } \
          } } } \
          checkSuites(first: 50) { nodes { status conclusion } } } } }
        """
        // 「@ 到我」得多要一批时间戳：谁在什么时候点了我、我最后一次发言是什么时候。
        // 只给这一档要 —— 另两档不需要，白拉一堆评论纯属浪费。
        // 各拿最近 N 条：更早的 @ 就算漏了也已经是老新闻，不值得为它把请求撑大。
        let talkFields = """
        bodyText createdAt \
        comments(last: 30) { nodes { author { login } createdAt bodyText } } \
        reviews(last: 10) { nodes { author { login } submittedAt bodyText } } \
        reviewThreads(first: 20) { nodes { comments(first: 5) { \
          nodes { author { login } createdAt bodyText } } } }
        """
        let kinds: [(String, String, ReviewItem.Kind)] = [
            ("req", "review-requested:\(account)", .requested),
            ("asg", "assignee:\(account)", .assigned),
            ("men", "mentions:\(account)", .mentioned),
        ]
        // 一个仓库一条查询，并发发出去。挤在一条里的话，仓库一多同样会 504 ——
        // 跟看板那边是同一个毛病（见 fetchAll 里的注释）。
        var bodies: [String] = []
        for (i, repo) in valid.enumerated() {
            let parts = repo.split(separator: "/")
            var body = " perm\(i): repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") { viewerPermission }"
            for (tag, term, kind) in kinds {
                let fields = kind == .mentioned ? prFields + " " + talkFields : prFields
                body += " \(tag)\(i): search(query: \"repo:\(repo) is:pr is:open -author:\(account) "
                    + "\(term) sort:updated-desc\", type: ISSUE, first: 30) "
                    + "{ nodes { ... on PullRequest { \(fields) } } }"
            }
            bodies.append(body)
        }

        var data: [String: Any] = [:]
        var failure: Error?
        await withTaskGroup(of: Result<[String: Any], Error>.self) { group in
            for body in bodies {
                group.addTask {
                    do { return .success(try await graphql(gh, body)) }
                    catch { return .failure(error) }
                }
            }
            for await r in group {
                switch r {
                case .success(let obj):
                    // 每个仓库的别名都带自己的序号，键不会撞，直接合并
                    for (k, v) in (obj["data"] as? [String: Any]) ?? [:] { data[k] = v }
                case .failure(let e): failure = failure ?? e
                }
            }
        }
        // 一个仓库都没拿到才算失败；拿到一部分就先显示一部分
        if data.isEmpty, let failure { throw failure }

        var raw: [ReviewItem] = []
        var writable: [String] = []
        for (i, repo) in valid.enumerated() {
            let perm = ((data["perm\(i)"] as? [String: Any])?["viewerPermission"] as? String) ?? "READ"
            if ["WRITE", "MAINTAIN", "ADMIN"].contains(perm) { writable.append(repo) }
            for (tag, _, kind) in kinds {
                let nodes = ((data["\(tag)\(i)"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
                for d in nodes {
                    if let it = parseReviewItem(d, repo: repo, kind: kind, account: account) {
                        raw.append(it)
                    }
                }
            }
        }

        // 有写权限的仓库才去看「谁的 workflow 卡着等我批」
        var approvals: [ReviewItem] = []
        await withTaskGroup(of: [ReviewItem].self) { group in
            for repo in writable {
                group.addTask { await pendingApprovals(gh: gh, repo: repo, account: account) }
            }
            for await items in group { approvals += items }
        }
        raw += await dropSettled(approvals, gh: gh)
        return arrange(raw)
    }

    /// 扔掉那些 PR 已经合了 / 关了的批准项。
    ///
    /// 另外三档搜索里带 `is:open`，PR 一合上就自动不在了。但批准项是从 workflow run 来的：
    /// **别人先把 PR 合掉之后，那个 run 还挂在 waiting 上**，不管它就会一直显示 ——
    /// 而流程上早就走完了，没人被我卡着。
    private nonisolated static func dropSettled(_ items: [ReviewItem], gh: String) async -> [ReviewItem] {
        let withPR = items.filter { $0.number > 0 }
        guard !withPR.isEmpty else { return items }   // 挂不到 PR 上的（fork 那种）没法查，留着

        // 按仓库分组，一次 GraphQL 查完所有相关 PR 的状态
        var body = ""
        for (i, it) in withPR.enumerated() {
            let parts = it.repo.split(separator: "/")
            guard parts.count == 2 else { continue }
            body += " p\(i): repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") "
                + "{ pullRequest(number: \(it.number)) { state } }"
        }
        guard !body.isEmpty,
              let out = try? await run(gh, ["api", "graphql", "-f", "query=query {\(body) }"]),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any],
              let data = obj["data"] as? [String: Any]
        else { return items }   // 查不到就别乱删

        var settled = Set<String>()
        for (i, it) in withPR.enumerated() {
            let st = ((data["p\(i)"] as? [String: Any])?["pullRequest"] as? [String: Any])?["state"] as? String
            if st == "MERGED" || st == "CLOSED" { settled.insert(it.id) }
        }
        return items.filter { !settled.contains($0.id) }
    }

    /// 卡在等人批准的 workflow run，且**我批得动**的那些。
    ///
    /// 两种形态，都试：
    /// - 环境审批：run 处于 `waiting`，`pending_deployments` 会直说 `current_user_can_approve`
    /// - fork 首次贡献者：run 处于 `action_required` 且 `conclusion` 还是 null
    ///   （注意 `status=action_required` 也会捞到一堆「跑完了、结论是 action_required」的历史 run，
    ///   实测某仓库有 1148 个，必须靠 conclusion == null 筛掉）
    private nonisolated static func pendingApprovals(gh: String, repo: String, account: String)
        async -> [ReviewItem]
    {
        var out: [ReviewItem] = []
        for status in ["waiting", "action_required"] {
            guard let r = try? await run(gh, ["api", "repos/\(repo)/actions/runs?status=\(status)&per_page=30"]),
                  let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
                  let runs = obj["workflow_runs"] as? [[String: Any]] else { continue }

            for wr in runs where wr["conclusion"] is NSNull || wr["conclusion"] == nil {
                guard let id = wr["id"] as? Int else { continue }
                let actor = ((wr["triggering_actor"] as? [String: Any])?["login"] as? String)
                    ?? ((wr["actor"] as? [String: Any])?["login"] as? String) ?? ""
                // 自己触发的不算「别人卡在我这里」—— 那是我自己的事，看板那边看
                if actor == account { continue }

                var note = ""
                if status == "waiting" {
                    // 只有 pending_deployments 能回答「这个是不是等我批」
                    guard let pd = try? await run(gh, ["api", "repos/\(repo)/actions/runs/\(id)/pending_deployments"]),
                          let list = try? JSONSerialization.jsonObject(with: Data(pd.stdout.utf8)) as? [[String: Any]]
                    else { continue }
                    let mine = list.filter { ($0["current_user_can_approve"] as? Bool) == true }
                    guard !mine.isEmpty else { continue }
                    note = mine.compactMap { ($0["environment"] as? [String: Any])?["name"] as? String }
                        .joined(separator: "、")
                } else {
                    note = "首次贡献者，需要批准才会跑"
                }

                let prs = wr["pull_requests"] as? [[String: Any]] ?? []
                out.append(ReviewItem(
                    kind: .approveCI, repo: repo,
                    number: prs.first?["number"] as? Int ?? 0,
                    title: wr["display_title"] as? String ?? wr["name"] as? String ?? "workflow",
                    url: wr["html_url"] as? String ?? "",
                    author: actor,
                    base: wr["head_branch"] as? String ?? "",
                    isDraft: false, review: nil, ci: "PENDING",
                    at: (wr["created_at"] as? String).flatMap(GhParse.date(from:)),
                    note: note, queried: repo))
            }
        }
        return out
    }

    /// 去重 + 排序。纯函数，方便单测。
    ///
    /// 同一个 PR 可能同时命中几个搜索（请我 review + 指派给我 + @ 到我），
    /// 留最该办的那一档就行 —— 一件事在清单里出现三次只是噪音。
    nonisolated static func arrange(_ items: [ReviewItem]) -> [ReviewItem] {
        var byID: [String: ReviewItem] = [:]
        for it in items {
            if let old = byID[it.id], old.kind.rank <= it.kind.rank { continue }
            byID[it.id] = it
        }
        return byID.values.sorted {
            $0.kind.rank != $1.kind.rank ? $0.kind.rank < $1.kind.rank
                : ($0.at ?? .distantPast) > ($1.at ?? .distantPast)
        }
    }

    /// 一条「@ 到我」还该不该显示，以及最近一次被点是什么时候。
    ///
    /// 规则：**有人在我最后一次发言之后又点了我**，才算还欠着我。
    /// 所以不必回复那条 @ 本身 —— 我在这个 PR 上随便说句话、或者提交一次 review，
    /// 就算我接手了。反过来，我说完之后别人又点我一次，它会重新冒出来。
    ///
    /// nil 表示不用显示（我已经回过话了）。
    nonisolated static func pingTime(_ d: [String: Any], account: String) -> Date? {
        let me = "@\(account)".lowercased()

        /// 一条发言：谁说的、什么时候、有没有点我
        func lines(_ container: [String: Any]?, _ key: String, _ timeKey: String) -> [(String, Date, Bool)] {
            let nodes = (container?[key] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            return nodes.compactMap { n in
                guard let t = (n[timeKey] as? String).flatMap(GhParse.date(from:)) else { return nil }
                let who = (n["author"] as? [String: Any])?["login"] as? String ?? ""
                let text = (n["bodyText"] as? String ?? "").lowercased()
                return (who, t, text.contains(me))
            }
        }

        var all = lines(d, "comments", "createdAt") + lines(d, "reviews", "submittedAt")
        // 行内评论（review thread）也算 —— 大仓库里 @ 人多半发生在具体代码行上
        let threads = (d["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        for t in threads { all += lines(t, "comments", "createdAt") }
        // PR 正文里点我也算一次，时间就是开 PR 的时间
        if let body = d["bodyText"] as? String, body.lowercased().contains(me),
           let t = (d["createdAt"] as? String).flatMap(GhParse.date(from:)) {
            let who = (d["author"] as? [String: Any])?["login"] as? String ?? ""
            all.append((who, t, true))
        }

        let pinged = all.filter { $0.2 && $0.0 != account }.map(\.1).max()
        let mySay = all.filter { $0.0 == account }.map(\.1).max()

        guard let ping = pinged else {
            // 扫到了「@我」但全是我自己写的（提醒自己那种）：没人在等我
            if all.contains(where: { $0.2 }) { return nil }
            // 一条「@我的字样」都没扫到：可能是按团队 @ 的、或者在我们没拉到的那些评论里。
            // 这种情况用 PR 的更新时间兜底 —— 宁可显示出来让人自己判断，也别悄悄吞掉
            let fallback = (d["updatedAt"] as? String).flatMap(GhParse.date(from:))
            if let mine = mySay, let f = fallback, mine >= f { return nil }
            return fallback
        }
        if let mine = mySay, mine > ping { return nil }   // 我在那之后说过话了，不欠着
        return ping
    }

    nonisolated static func parseReviewItem(
        _ d: [String: Any], repo: String, kind: ReviewItem.Kind, account: String
    ) -> ReviewItem? {
        guard let n = d["number"] as? Int else { return nil }
        let commit = ((d["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?
            .first?["commit"] as? [String: Any]
        let rollup = commit?["statusCheckRollup"] as? [String: Any]
        let contexts = ((rollup?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [])
            .map(CheckRollup.Item.init(json:))
        let suites = ((commit?["checkSuites"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [])
            .map(CheckRollup.Suite.init(json:))

        // 「别人从什么时候开始等我」：请我 review / 把我设成 assignee 的那一刻。
        // 团队请求没有 login，也算我（大仓库多半按团队派 review）。
        let events = ((d["timelineItems"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let mine = events.compactMap { e -> Date? in
            let who = ((e["requestedReviewer"] as? [String: Any])?["login"] as? String)
                ?? ((e["assignee"] as? [String: Any])?["login"] as? String)
            guard who == nil || who == account else { return nil }
            return (e["createdAt"] as? String).flatMap(GhParse.date(from:))
        }
        let fallback = (d["updatedAt"] as? String).flatMap(GhParse.date(from:))

        // 仓库名以响应里的为准，不用查询时填的那个 —— 仓库改名 / 转移之后
        // GitHub 会重定向，用旧名照样查得到，但显示旧名会让人对不上号
        // （实测配置里的 maka-agent/maka-agent 现在已经是 apache/maka）
        let real = ((d["repository"] as? [String: Any])?["nameWithOwner"] as? String) ?? repo

        var ping: Date?
        if kind == .mentioned {
            guard let p = pingTime(d, account: account) else { return nil }   // 我已经回过话了
            ping = p
        }

        return ReviewItem(
            kind: kind, repo: real, number: n,
            title: d["title"] as? String ?? "",
            url: d["url"] as? String ?? "",
            author: (d["author"] as? [String: Any])?["login"] as? String ?? "",
            base: d["baseRefName"] as? String ?? "",
            isDraft: d["isDraft"] as? Bool ?? false,
            review: d["reviewDecision"] as? String,
            ci: CheckRollup.state(contexts: contexts, suites: suites),
            at: ping ?? mine.max() ?? fallback,
            note: "", queried: repo, pingedAt: ping)
    }

    /// 发一条 GraphQL，抽风就重试一次。
    ///
    /// GitHub 偶尔回 5xx，这条网络本身也不稳（TLS 握手要好几秒）。
    /// 所有项目并发刷新之后更容易撞上 —— 一个项目挂了整块就空了，
    /// 而重试一次的代价只在真失败的时候才付。
    private nonisolated static func graphql(_ gh: String, _ body: String) async throws -> [String: Any] {
        await NetLimit.shared.acquire()
        defer { Task { await NetLimit.shared.release() } }

        var last: Error = AppError("gh 调用失败")
        for attempt in 0..<2 {
            do {
                let out = try await run(gh, ["api", "graphql", "-f", "query=query {\(body) }"])
                guard let obj = try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8))
                        as? [String: Any] else {
                    throw AppError(out.stderr.isEmpty ? "gh 调用失败" : out.stderr)
                }
                return obj
            } catch {
                last = error
                if attempt == 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            }
        }
        throw last
    }

    /// 同时最多几条网络请求在飞。
    ///
    /// 两头都会出事，得卡在中间：
    /// - **一条请求装太多** —— 服务端展开不完，GraphQL 网关 504
    ///   （实测 35 个 PR 挤一条：6 轮全超时，平均 14 秒）
    /// - **同时开太多连接** —— 这条网络扛不住，gh 直接报
    ///   `Post "https://api.github.com/graphql": EOF`（实测 7 条并发，2 条被掐断）
    ///
    /// 所以：每条请求放 9 个 PR（4 块左右），全局并发压到 4 条。
    /// 刷新时 3 个项目 + 评审清单是一起发的，不设全局上限的话瞬间就十几条连接。
    actor NetLimit {
        static let shared = NetLimit()
        private let max = 4
        private var active = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if active < max { active += 1; return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            if let next = waiting.first {
                waiting.removeFirst()
                next.resume()          // 名额直接交棒，active 不变
            } else {
                active -= 1
            }
        }
    }

    /// 一条查询里最多放几个 PR。每个 PR 要展开 100 条 check context + 50 个 suite，
    /// 放多了 GitHub 网关会超时（实测 35 个一条要 12–17 秒、三次 504 一次）。
    /// 拆成小块并发发，反而更快也更稳。
    static let prPerQuery = 9

    /// 分支保护的必过项，按 repo@branch 缓存    /// 分支保护的必过项，按 repo@branch 缓存 —— 这东西几乎不变，
    /// 每次刷新都去问一遍纯属浪费（一次请求要 3–5 秒）。缓存活到进程退出。
    private final class RequiredCache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: Set<String>] = [:]
        func get(_ k: String) -> Set<String>? { lock.lock(); defer { lock.unlock() }; return map[k] }
        func put(_ k: String, _ v: Set<String>) { lock.lock(); defer { lock.unlock() }; map[k] = v }
    }
    private static let requiredCache = RequiredCache()

    /// 某个分支要求哪些 check 必过。拿不到就返回空集（当作不知道，别瞎猜）
    nonisolated static func requiredChecks(gh: String, repo: String, branch: String) async -> Set<String> {
        let key = "\(repo)@\(branch)"
        if let hit = requiredCache.get(key) { return hit }
        guard let out = try? await run(gh, ["api", "repos/\(repo)/branches/\(branch)"]) else { return [] }
        let got = CheckRollup.requiredContexts(fromBranchJSON: Data(out.stdout.utf8))
        requiredCache.put(key, got)
        return got
    }

    /// 一次 GraphQL 请求拉完所有东西：跟踪中那些 PR 的状态与 check 明细，
    /// 外加「作者是我」「指派给我」两个搜索（自动导入要用）。
    ///
    /// 为什么要挤成一次：实测这台机器到 api.github.com，**TCP 只要 2ms，TLS 握手却要 1–5 秒**。
    /// 而 gh 每调用一次就是一个新进程、一条新连接、一次新握手。所以成本几乎全在
    /// **请求个数**上，跟数据量基本无关 —— 实测同一个查询，1 个别名 5.1 秒、20 个别名 6.6 秒；
    /// 而多一次请求就要多 5 秒。把 4 次调用（两次 pr list + 两趟 GraphQL）合成 1 次，
    /// 20 秒降到 9 秒。带上全部 CI 明细多花的 2 秒，比多一次往返的 5 秒划算得多。
    nonisolated static func fetchAll(repo: String, numbers: Set<Int>, account: String?)
        async throws -> (live: [Int: LivePR], found: [FoundPR])
    {
        guard let gh = ghPath() else {
            throw AppError("找不到 GitHub CLI（gh），到设置里可以一键安装")
        }
        guard repo.range(of: #"^[\w.-]+/[\w.-]+$"#, options: .regularExpression) != nil else {
            throw AppError("仓库格式应为 owner/repo，当前是「\(repo)」")
        }
        let parts = repo.split(separator: "/")

        // contexts 用 last 不用 first：一页最多 100 条，而重跑过几轮的 PR 能到 120+
        // （实测 StarRocks#77255 有 123 条）。要截也该截掉最老的那一批。
        let fields = """
        number title state isDraft url reviewDecision baseRefName author { login } \
        commits(last: 1) { nodes { commit { \
          statusCheckRollup { contexts(last: 100) { nodes { \
            __typename \
            ... on CheckRun { name status conclusion startedAt } \
            ... on StatusContext { context state createdAt } \
          } } } \
          checkSuites(first: 50) { nodes { status conclusion } } } } }
        """
        // 一次问太多 PR，GitHub 会 504。
        //
        // 1.0.2 把所有东西挤进一条请求，理由是「慢的是握手不是数据量」—— 那句话对延迟成立，
        // 但没考虑**服务端**的开销：每个 PR 都要展开 100 条 context + 50 个 check suite，
        // PR 一多就超过 GraphQL 网关的超时。实测跟踪 35 个 PR 时，单条查询要 12–17 秒，
        // 三次里 504 一次。
        //
        // 拆成几条并发的小查询就没这问题：实测同样 35 个 PR 拆成 4 块并发，
        // 4–9 秒、零失败。并发本来就几乎不要钱（4 条并发 1.4 秒 vs 串行 6.1 秒），
        // 所以这里既更快又更稳。
        let sorted = numbers.sorted()
        var bodies: [String] = stride(from: 0, to: sorted.count, by: prPerQuery).map { start in
            let chunk = sorted[start..<min(start + prPerQuery, sorted.count)]
            let aliases = chunk
                .map { "pr\($0): pullRequest(number: \($0)) { \(fields) }" }
                .joined(separator: " ")
            return " repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") { \(aliases) }"
        }
        // 作者是我、或者指派给我，两者取并集 —— 机器人建的 backport 作者是 bot、
        // 只把你设成 assignee，光看 author 会漏掉。搜索条件是 AND，所以要两个。
        // 搜索单独发一条：它跟按编号取 PR 是两种开销，混在一起只会让那一条更容易超时。
        if let who = account, !who.isEmpty {
            let sel = "nodes { ... on PullRequest { number title state baseRefName } }"
            var search = ""
            for (alias, term) in [("mine", "author"), ("assigned", "assignee")] {
                search += " \(alias): search(query: \"repo:\(repo) is:pr \(term):\(who) sort:updated-desc\", "
                    + "type: ISSUE, first: 100) { \(sel) }"
            }
            bodies.append(search)
        }
        guard !bodies.isEmpty else { return ([:], []) }

        // 并发发出去，任何一条挂了就整体算失败 —— 半份数据比没有数据更误导人
        var merged: [String: Any] = [:]
        var failure: Error?
        var firstError: String?
        await withTaskGroup(of: Result<[String: Any], Error>.self) { group in
            for body in bodies {
                group.addTask { 
                    do { return .success(try await graphql(gh, body)) }
                    catch { return .failure(error) }
                }
            }
            for await r in group {
                switch r {
                case .success(let obj):
                    let data = (obj["data"] as? [String: Any]) ?? [:]
                    // repository 那一层每块都叫 repository，得把里面的别名摊平合并
                    for (k, v) in data {
                        if k == "repository", let inner = v as? [String: Any] {
                            var acc = (merged["repository"] as? [String: Any]) ?? [:]
                            acc.merge(inner) { a, _ in a }
                            merged["repository"] = acc
                        } else {
                            merged[k] = v
                        }
                    }
                    if firstError == nil, let errs = obj["errors"] as? [[String: Any]] {
                        firstError = errs.first?["message"] as? String
                    }
                case .failure(let e):
                    failure = failure ?? e
                }
            }
        }
        if let failure, merged.isEmpty { throw failure }

        let data = merged

        var live: [Int: LivePR] = [:]
        var checks: [Int: (items: [CheckRollup.Item], suites: [CheckRollup.Suite])] = [:]
        let repoData = (data["repository"] as? [String: Any]) ?? [:]
        for case let v as [String: Any] in Array(repoData.values) {
            guard let n = v["number"] as? Int else { continue }
            var lv = LivePR()
            lv.title = v["title"] as? String ?? ""
            lv.state = v["state"] as? String ?? ""
            lv.isDraft = v["isDraft"] as? Bool ?? false
            lv.url = v["url"] as? String ?? ""
            lv.review = v["reviewDecision"] as? String
            lv.author = (v["author"] as? [String: Any])?["login"] as? String ?? ""
            lv.base = v["baseRefName"] as? String ?? ""
            live[n] = lv

            let commit = ((v["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?
                .first?["commit"] as? [String: Any]
            let rollup = commit?["statusCheckRollup"] as? [String: Any]
            let contexts = (rollup?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            let suites = (commit?["checkSuites"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            checks[n] = (contexts.map(CheckRollup.Item.init(json:)),
                         suites.map(CheckRollup.Suite.init(json:)))
        }
        // 个别编号不存在时 GraphQL 只报部分错误，能拿到的照常显示；全军覆没才抛错。
        // 有块整个失败了（504 之类）也一样：一条都没拿到才报错，
        // 拿到一部分就先显示一部分，别把已有数据抹成「未知」
        if live.isEmpty, !numbers.isEmpty {
            if let msg = firstError { throw AppError(msg) }
            if let failure { throw failure }
        }

        // 必过项清单按分支查，只管还开着的 PR。清单进程内缓存，同一个分支只查一次。
        let openBranches = Set(live.values.filter { $0.state == "OPEN" && !$0.base.isEmpty }.map(\.base))
        var required: [String: Set<String>] = [:]
        await withTaskGroup(of: (String, Set<String>).self) { group in
            for b in openBranches {
                group.addTask { (b, await requiredChecks(gh: gh, repo: repo, branch: b)) }
            }
            for await (b, r) in group { required[b] = r }
        }
        // CI 结论只给还开着的 PR 算 —— 已合并/已关闭的状态已经是终局，
        // 那一栏只会挂着重跑前留下的假红，是噪音
        for (n, lv) in live where lv.state == "OPEN" {
            guard let c = checks[n] else { continue }
            live[n]?.ci = CheckRollup.state(contexts: c.items, suites: c.suites,
                                            required: required[lv.base] ?? [])
        }

        var found: [Int: FoundPR] = [:]
        for key in ["mine", "assigned"] {
            let nodes = ((data[key] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            for d in nodes {
                guard let n = d["number"] as? Int else { continue }
                found[n] = FoundPR(number: n,
                                   title: d["title"] as? String ?? "",
                                   isOpen: (d["state"] as? String) == "OPEN")
            }
        }
        return (live, found.values.sorted { $0.number < $1.number })
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
        Self.classify(livePR(pr), blocked: blocked)
    }

    /// 导览期间读样板数据，其余时候读实时拉到的
    func livePR(_ pr: Int) -> LivePR? {
        tourIndex == nil ? live[pr] : TourDemo.live[pr]
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
        // 等人点批准，不是「等机器」—— 不点的话一步都不会跑
        if lv.ci == "ACTION_REQUIRED" { return .needsCIApproval }
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
        let nodes = tourIndex == nil ? (project?.nodes ?? []) : TourDemo.nodes
        return Tree.flatten(nodes) { livePR($0)?.state == "MERGED" }
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
    @State private var localPage = Page.board
    /// 导览要求切页时优先听它的
    var page: Page {
        get { m.page ?? localPage }
        nonmutating set { localPage = newValue; m.page = nil }
    }

    /// 设置不再弹窗，而是主区域里换一页 —— 看板和设置是同一个界面的两个页面
    enum Page { case board, review, settings }

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
            case .review:
                InboxView().environmentObject(m)
            case .settings:
                SettingsView().environmentObject(m)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .animation(.easeInOut(duration: 0.15), value: page)
        // 窗口标题条只留应用名和版本，不挂任何按钮 —— 保持干净
        .navigationTitle(Text(verbatim: "PrWaiter v\(Self.appVersion)"))
        .overlayPreferenceValue(TourAnchors.self) { anchors in
            GeometryReader { proxy in
                if let i = m.tourIndex, i < TourStep.all.count {
                    let t = TourStep.all[i].target
                    TourOverlay(
                        index: i,
                        rect: t.flatMap { anchors[$0] }.map { proxy[$0] },
                        canvas: proxy.size
                    )
                    .environmentObject(m)
                }
            }
        }
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
            } else if page == .review {
                // 评审视角是跨仓库的一份清单，跟「当前是哪个项目」无关 ——
                // 这时候还摆着项目标签会让人以为清单被它过滤了
                HStack(spacing: 8) {
                    Image(systemName: "eyeglasses").foregroundColor(.accentColor)
                    Text("谁在等我").font(.headline)
                    Text(verbatim: "\(m.inboxRepos.count) 个仓库")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                actions
            } else {
                projectTabs
                actions
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// 操作区。两个视角共用一条 —— 切换按钮就摆在刷新和设置中间。
    var actions: some View {
        HStack(spacing: 10) {
            // 时间戳与刷新按钮分开摆，别挤成一坨
            Group {
                if m.busy {
                    ProgressView().controlSize(.small)
                } else if let t = page == .review ? m.inboxAt : m.updatedAt {
                    Text("更新于 " + t.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(minWidth: 76, alignment: .trailing)   // 宽度固定，刷新时按钮不会左右跳

            // 一次刷新把**所有项目 + 两个视角**都刷了 —— 分开刷的话，
            // 切过去总要再等一次，而且标签上的待办数会是旧的
            Button { Task { await m.refreshEverything() } } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.bordered)
            .disabled(m.busy)
            .help("刷新所有项目和评审清单")
            .tourTarget(.refreshButton)

            perspectiveButton

            if page != .review {
                Button(m.editing ? "完成" : "编辑") {
                    m.editing.toggle()
                    m.save()
                }
                .buttonStyle(.borderedProminent)
                .tint(m.editing ? .green : .accentColor)
                .help(m.editing ? "退出编辑，冻结布局" : "进入编辑，可拖动、增删")
                .tourTarget(.editButton)
            }

            Button { page = .settings } label: {
                Image(systemName: m.gh.ready ? "gearshape" : "gearshape.badge.checkmark")
                    .frame(width: 16, height: 16)
                    .foregroundColor(m.gh.ready ? .primary : .orange)
            }
            .buttonStyle(.bordered)
            .help(m.gh.ready ? "设置" : "gh 还没配好，点这里")
            .tourTarget(.gearButton)
        }
        .fixedSize()   // 按钮区不被标签挤压
    }

    /// 视角切换。两个视角是两套东西 —— 贡献视角只有我写的 PR，评审视角只有别人等我的事，
    /// 所以做成一个「换个身份看」的开关，而不是并列的第 N 个项目标签。
    var perspectiveButton: some View {
        let toReview = page != .review
        return Button {
            page = toReview ? .review : .board
        } label: {
            Label(toReview ? "切换到评审视角" : "切换回贡献视角",
                  systemImage: toReview ? "eyeglasses" : "arrow.uturn.left")
        }
        .buttonStyle(.bordered)
        // 待办数只在贡献视角显示：已经在评审视角里了，数字就在眼前，气泡纯属重复
        .overlay(alignment: .topTrailing) {
            if toReview, !m.inbox.isEmpty {
                Text(verbatim: "\(m.inbox.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(m.inboxUrgent ? Color.orange : Color.red))
                    .offset(x: 6, y: -7)
            }
        }
        .help(toReview ? "看谁在等我" : "回到我自己的 PR")
    }

    // MARK: 项目标签
    // MARK: 项目标签

    var projectTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if m.tourIndex != nil, m.store.projects.isEmpty {
                    // 首次启动一个项目都没有，导览得有东西可指
                    ForEach(Array(TourDemo.projects.enumerated()), id: \.offset) { i, name in
                        demoTab(name, active: i == 0)
                    }
                }
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
        .tourTarget(.projectTabs)
    }

    /// 导览用的假标签：只有样子，点不动
    func demoTab(_ name: String, active: Bool) -> some View {
        Text(name)
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
        if m.project == nil, m.tourIndex == nil {
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
                    // 每一行前面都有一条投放缝，落进去就是「插到它前面、和它同一层」。
                    // 子层同样需要 —— 同级的先后顺序在哪一层都该能调。
                    // 排到某一层的**末尾**靠拖到父块身上（那本来就是「挂进去」的动作）。
                    ForEach(Array(m.rows.enumerated()), id: \.element.id) { _, row in
                        if m.editing {
                            RowGap(index: row.index, parent: row.parent, depth: row.depth)
                        }
                        NodeRow(row: row, tourSample: isTourSample(row))
                    }
                    if m.editing, !(m.project?.nodes ?? []).isEmpty {
                        RowGap(index: m.project?.nodes.count ?? 0)   // 根级末尾那条缝
                    }
                    if m.rows.isEmpty {
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

    /// 导览要指的样板行：各类型的第一行
    func isTourSample(_ row: Row) -> Bool {
        guard m.tourIndex != nil else { return false }
        return m.rows.first { $0.node.kind == row.node.kind }?.id == row.id
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
// MARK: - reviewer 视角
//
// 这一页跟看板刻意长得不一样：没有树、没有拖拽、不能编辑。
// 别人的 PR 我管不着合并顺序，只需要一份「谁在等我」的清单，从上到下办完就行。

struct InboxView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let e = m.inboxError, !m.inboxLoading {
                    Label(e, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
                        .padding(.bottom, 10)
                }
                section(.approveCI, "等我批准", "workflow 不批就永远不跑，作者在那边干等")
                section(.requested, "请我 review", "指名请我看的，最近请求的排在上面")
                section(.assigned, "指派给我", "别人建的 PR 把我设成了负责人")
                section(.mentioned, "@ 到我", "有人在 PR 里点了我，等我回话")

                if m.inbox.isEmpty {
                    if m.inboxLoading {
                        loading
                    } else if m.inboxError == nil {
                        empty
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    func section(_ kind: ReviewItem.Kind, _ title: String, _ hint: String) -> some View {
        let rows = m.inbox.filter { $0.kind == kind }
        if !rows.isEmpty {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Text(verbatim: "\(rows.count)")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(hint).font(.caption).foregroundColor(.secondary)
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
            ForEach(rows) { InboxRow(item: $0) }
            Spacer().frame(height: 14)
        }
    }

    /// 第一次拉要好几秒（一次请求就得 5 秒起），空着不动会让人以为坏了
    var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在看谁在等你…").foregroundColor(.secondary)
        }
        .padding(.top, 30)
    }

    /// 空清单不是「出错了」，得说清楚为什么空 —— 尤其是批 workflow 那一档，
    /// 只读权限下永远是空的，不解释一句会让人以为坏了
    var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("现在没人等你").font(.title3).foregroundColor(.secondary)
            Text("这里只看已配置的那几个项目仓库：" + m.inboxRepos.joined(separator: "、"))
                .font(.caption).foregroundColor(.secondary)
            if m.inboxRepos.isEmpty {
                Text("还没有填过 owner/repo，先去看板那边配一个项目。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.top, 30)
    }
}

struct InboxRow: View {
    @EnvironmentObject var m: Model
    let item: ReviewItem

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Capsule().fill(barColor).frame(width: 3)
                .padding(.vertical, 8).padding(.leading, 4).padding(.trailing, 8)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    // 跨仓库的清单，仓库名要跟编号一起显示，不然不知道说的是哪个
                    Text(item.repo.split(separator: "/").last.map(String.init) ?? item.repo)
                        .font(.caption).foregroundColor(.secondary)
                    // 编号为 0 是 fork 的 workflow run 拿不到 PR 的情况，
                    // 那就直接链到 run 本身 —— 反正要点的按钮在那儿
                    let label = item.number > 0 ? "#\(item.number)" : "run"
                    if let u = URL(string: item.url) {
                        Link(destination: u) { Text(verbatim: label) }
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                    } else {
                        Text(verbatim: label)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                    }
                    Text(item.title).lineLimit(1)
                    Spacer()
                    if item.isDraft { tag("草稿", .secondary) }
                    if item.kind == .approveCI { tag(item.kind.label, .orange) }
                    ciTag
                    reviewTag
                    // 只有 @ 需要手动消：另两档 GitHub 自己会撤。
                    // 有些 @ 就是知会一声，不需要我回话，那就忽略掉
                    if item.kind == .mentioned {
                        Button {
                            m.dismissPing(item)
                        } label: {
                            Label("忽略", systemImage: "bell.slash")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("这次不用我处理。下次有人再 @ 我还会出现")
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.branch").font(.system(size: 9))
                    Text(item.base)
                    Text(verbatim: "·")
                    Image(systemName: "person").font(.system(size: 9))
                    Text(verbatim: "@\(item.author)")
                    if !item.note.isEmpty {
                        Text(verbatim: "·")
                        Text(item.note)
                    }
                    Spacer(minLength: 8)
                    if let t = item.at { Text(ago(t)) }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 10))
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
        .padding(.bottom, 6)
    }

    /// 左侧色条跟看板一个规矩：按「欠在谁身上」分。这一页全是欠在我身上的，
    /// 所以只分「多急」：等我批准最急（橙），请我 review 次之（蓝），跟进的是灰
    var barColor: Color {
        switch item.kind {
        case .approveCI: return .orange     // 最急：不点一下，别人的 CI 根本不跑
        case .requested: return .blue       // 等我看
        case .assigned: return .indigo
        case .mentioned: return .secondary
        }
    }

    @ViewBuilder var ciTag: some View {
        switch item.ci ?? "" {
        case "SUCCESS": tag("CI ✓", .green)
        case "FAILURE", "ERROR": tag("CI ✗", .red)
        case "PENDING", "EXPECTED": tag("CI …", .orange)
        case "ACTION_REQUIRED": tag("CI ✋", .orange)
        default: EmptyView()
        }
    }

    @ViewBuilder var reviewTag: some View {
        switch item.review ?? "" {
        case "APPROVED": tag("已批准", .green)
        case "CHANGES_REQUESTED": tag("已要求修改", .red)
        default: EmptyView()
        }
    }

    func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.15)))
            .foregroundColor(c)
    }

    /// 「多久之前」比一个绝对时间戳有用 —— 你关心的是它等了我多久
    func ago(_ t: Date) -> String {
        let s = Int(Date().timeIntervalSince(t))
        if s < 3600 { return "\(max(1, s / 60)) 分钟前" }
        if s < 86400 { return "\(s / 3600) 小时前" }
        return "\(s / 86400) 天前"
    }
}

struct SettingsView: View {
    @EnvironmentObject var m: Model
    @AppStorage(Prefs.ghPath) private var customPath = ""
    @AppStorage(Prefs.refreshInterval) private var interval = 60
    @AppStorage(Prefs.notify) private var notify = true
    @AppStorage(Prefs.autoImport) private var autoImport = true
    @AppStorage(Prefs.autoCheckUpdate) private var autoCheckUpdate = true
    @AppStorage(Prefs.autoInstallUpdate) private var autoInstallUpdate = false

    static let intervals = [(30, "30 秒"), (60, "1 分钟"), (300, "5 分钟"), (0, "只手动刷新")]

    var body: some View {
        Form {
            ghSection
            statusSection
            refreshSection
            updateSection
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

            Toggle("状态变了发通知", isOn: $notify)
                .onChange(of: notify) { _, on in if on { Notifier.shared.start() } }
            if notify {
                LabeledContent("通知") {
                    HStack(spacing: 8) {
                        Button("发一条试试") {
                            Notifier.shared.request()
                            Notifier.shared.post(title: "PrWaiter",
                                                 body: "通知能收到。真的状态变化长这样：#77400 等 review → 可合并")
                        }
                        Button("系统通知设置") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
                // 用 .init 显式转成 LocalizedStringKey，否则字符串拼接出来的是 String，
                // SwiftUI 不会当 markdown 解析，界面上会露出 ** 星号
                Text(.init("只有**自动刷新**发现的变化才通知 —— 你自己点刷新时变化就在眼前，不用再弹一遍。"
                     + "刚启动的第一次拉取算基线，不会补报关机期间的变化。"))
                    .font(.caption).foregroundColor(.secondary)
            }
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

    // MARK: 更新

    var updateSection: some View {
        Section {
            LabeledContent("当前版本") {
                HStack(spacing: 10) {
                    Text(verbatim: m.currentVersion)
                    updateStatusLine
                }
            }
            LabeledContent("操作") {
                HStack(spacing: 8) {
                    if case .available = m.updateState {
                        Button {
                            Task { await m.installUpdate() }
                        } label: {
                            Label("下载并安装", systemImage: "arrow.down.app")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(m.updateState == .downloading)
                    }
                    Button("检查更新") { Task { await m.checkForUpdate() } }
                        .disabled(m.updateState == .checking || m.updateState == .downloading)
                }
            }
            if !m.updateLog.isEmpty {
                ForEach(Array(m.updateLog.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.caption).foregroundColor(.secondary)
                }
            }
            Toggle("启动时检查更新", isOn: $autoCheckUpdate)
            Toggle("查到新版本就自动安装", isOn: $autoInstallUpdate)
                .disabled(!autoCheckUpdate)
        } header: {
            Text("更新")
        } footer: {
            Text("更新走 gh 拉 Release —— 匿名 API 限 60 次/小时且按 IP 计，很容易撞上限额；"
                 + "gh 带认证，限额高得多。"
                 + "安装会校验下载包的签名，然后替换 /Applications 里的 App 并重启。\n"
                 + "「自动安装」默认关：替换正在运行的 App 会让它重启，"
                 + "这种事不该在你不知情时发生。")
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    var updateStatusLine: some View {
        switch m.updateState {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("检查中…").foregroundColor(.secondary)
            }
        case .upToDate:
            Label("已是最新", systemImage: "checkmark.circle.fill").foregroundColor(.green)
        case .available(let v):
            Label("有新版本 \(v)", systemImage: "arrow.up.circle.fill").foregroundColor(.orange)
        case .downloading:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("下载安装中…").foregroundColor(.secondary)
            }
        case .failed(let e):
            Label(e, systemImage: "exclamationmark.triangle")
                .foregroundColor(.red)
                .lineLimit(2)
        }
    }

    // MARK: 关于

    var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: ContentView.appVersion)
            LabeledContent("上手导览") {
                Button("重新查看") { m.startTour() }
            }
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
/// 块与块之间的投放缝：插到这个位置，跟目标同一层。
/// 根级和子层用的是同一个东西 —— 同层排序在哪一层都该能做。
struct RowGap: View {
    @EnvironmentObject var m: Model
    let index: Int
    var parent: UUID? = nil
    var depth: Int = 0
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
        .padding(.leading, CGFloat(depth) * GuideCell.width)   // 缝跟着所在层缩进，落点才对得上
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init) else { return false }
            m.move(id, toIndex: index, under: parent)
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
    /// 导览要指的样板行。多行都上报的话锚点会互相覆盖，所以只让第一个报
    var tourSample = false
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
        .modifier(TourTargetIf(on: tourSample && row.node.kind == .topic, target: .collapseZone))
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
        .modifier(TourTargetIf(on: tourSample && row.node.kind == .topic, target: .topicRow))
    }

    // MARK: PR 块

    var prBody: some View {
        let num = row.node.pr ?? 0
        let lv = m.livePR(num)
        let st = m.status(pr: num, blocked: row.blocked)
        return HStack(spacing: 0) {
            collapseZone
            VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if m.editing || (m.tourEditing && tourSample) { grip }
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
                // 徽标和状态词一起被导览指到 —— 那一步讲的是整片状态显示
                HStack(spacing: 8) {
                    badges(lv)
                    Text(st.label).font(.caption).foregroundColor(st.color)
                }
                .modifier(TourTargetIf(on: tourSample && row.node.kind == .pr, target: .statusBadges))
                if m.editing { deleteButton }
            }
            HStack(spacing: 6) {
                baseBranch(lv)
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
            .modifier(TourTargetIf(on: tourSample && row.node.kind == .pr, target: .dragGrip))
    }

    /// 目标分支。一组 backport 的标题一字不差，唯一的区别就是打到哪个分支上 ——
    /// 不显出来，几行长得一模一样的 PR 看着就像重复了。
    @ViewBuilder
    func baseBranch(_ lv: LivePR?) -> some View {
        if let lv, !lv.base.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "arrow.branch").font(.system(size: 9))
                Text(lv.base)
            }
            .foregroundColor(.secondary)
            .help("目标分支")
        }
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
            case "ACTION_REQUIRED": tag("CI ✋", .orange)
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
