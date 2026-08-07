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
}

struct Project: Codable, Identifiable {
    var id = UUID()
    var name = "新项目"
    var repo = ""
    var nodes: [Node] = []

    init(name: String, repo: String = "", nodes: [Node] = []) {
        self.name = name
        self.repo = repo
        self.nodes = nodes
    }

    enum CodingKeys: String, CodingKey { case id, name, repo, nodes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "新项目"
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        nodes = try c.decodeIfPresent([Node].self, forKey: .nodes) ?? []
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

enum PRStatus {
    case ready, waiting, blocked, merged, closed, unknown

    var label: String {
        switch self {
        case .ready: return "可合并"
        case .waiting: return "等 review/CI"
        case .blocked: return "等依赖"
        case .merged: return "已合并"
        case .closed: return "已关闭"
        case .unknown: return "未知"
        }
    }

    var color: Color {
        switch self {
        case .ready: return .green
        case .waiting: return .orange
        case .blocked: return .gray
        case .merged: return .purple
        case .closed: return .red
        case .unknown: return .gray
        }
    }
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
    @Published var live: [Int: LivePR] = [:]   // 只缓存当前项目的 PR
    @Published var error: String?
    @Published var loading = false
    @Published var updatedAt: Date?
    @Published var editing = false

    static let dataURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrWaiter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("prs.json")
    }()

    init() {
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
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
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
        live = [:]
        error = nil
        save()
        Task { await self.refresh() }
    }

    // MARK: 落盘

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(store) { try? data.write(to: Self.dataURL) }
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

    // MARK: 拉取

    func refresh() async {
        guard let p = project else {
            live = [:]
            return
        }
        let numbers = p.nodes.allPRNumbers
        guard !p.repo.isEmpty, !numbers.isEmpty else {
            live = [:]
            error = nil
            return
        }
        if loading { return }
        loading = true
        defer { loading = false }
        do {
            live = try await Self.fetchLive(repo: p.repo, numbers: numbers)
            error = nil
            updatedAt = Date()
        } catch let e {
            error = e.localizedDescription
        }
    }

    // GUI app 不继承 shell PATH，按常见安装位置找 gh
    nonisolated static func ghPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 一次 GraphQL 请求拉完整个项目的 PR 状态
    nonisolated static func fetchLive(repo: String, numbers: Set<Int>) async throws -> [Int: LivePR] {
        guard let gh = ghPath() else {
            throw AppError("找不到 gh，请先 brew install gh 并 gh auth login")
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
        guard let lv = live[pr] else { return .unknown }
        if lv.state == "MERGED" { return .merged }
        if lv.state == "CLOSED" { return .closed }
        if blocked { return .blocked }
        if !lv.isDraft, lv.review == "APPROVED", lv.ci == nil || lv.ci == "SUCCESS" { return .ready }
        return .waiting
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

    /// 每个描述块下辖的 PR 数与其中可合并的数量
    var topicSummary: [UUID: (total: Int, ready: Int)] {
        let all = allRows
        var out: [UUID: (Int, Int)] = [:]
        for (i, row) in all.enumerated() where row.node.kind == .topic {
            var total = 0, ready = 0
            var j = i + 1
            while j < all.count, all[j].depth > row.depth {
                if all[j].node.kind == .pr, let p = all[j].node.pr {
                    total += 1
                    if status(pr: p, blocked: all[j].blocked) == .ready { ready += 1 }
                }
                j += 1
            }
            out[row.node.id] = (total, ready)
        }
        return out
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            Divider()
            projectTabs
            Divider()
            if m.editing, m.project != nil {
                projectSettings
                Divider()
            }
            content
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    // MARK: 标题栏

    var titleBar: some View {
        HStack(spacing: 10) {
            Text("⏳ PrWaiter").font(.headline)
            Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if m.loading { ProgressView().controlSize(.small) }
            if let t = m.updatedAt {
                Text("更新于 " + t.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Button { Task { await m.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(m.loading)
                .help("立即刷新")
            Button(m.editing ? "完成" : "编辑") {
                m.editing.toggle()
                m.save()
            }
            .buttonStyle(.borderedProminent)
            .tint(m.editing ? .green : .accentColor)
            .help(m.editing ? "退出编辑，冻结布局" : "进入编辑，可拖动、增删")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 项目标签

    var projectTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(m.store.projects) { p in
                    let active = p.id == m.store.selected
                    Button { m.select(p.id) } label: {
                        Text(p.name.isEmpty ? "未命名" : p.name)
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
                    .buttonStyle(.plain)
                }
                if m.editing {
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
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
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
                guard let i = m.projectIndex else { return }
                m.store.projects.remove(at: i)
                m.store.selected = m.store.projects.first?.id
                m.live = [:]
                m.save()
                Task { await m.refresh() }
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
                    if let e = m.error {
                        Label(e, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
                            .padding(.bottom, 8)
                    }
                    summary.padding(.bottom, 6)
                    if m.editing { addBar.padding(.bottom, 6) }
                    ForEach(m.rows) { row in
                        NodeRow(row: row)
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

    var summary: some View {
        let ready = m.readyPRs
        let merged = m.mergedPRs
        return HStack(spacing: 14) {
            if ready.isEmpty {
                Text("暂无可合并的 PR").foregroundColor(.secondary)
            } else {
                Text(verbatim: "🟢 可合并：" + ready.map { "#\($0)" }.joined(separator: " "))
                    .fontWeight(.semibold)
                    .foregroundColor(.green)
            }
            if !merged.isEmpty {
                Text(verbatim: "✔ 已合并 \(merged.count)").foregroundColor(.secondary)
                if m.editing {
                    Button("清理已合并") {
                        let ids = m.rows.filter { r in
                            r.node.kind == .pr && r.node.pr.map { merged.contains($0) } == true
                        }.map(\.node.id)
                        m.editAndRefresh { p in
                            for id in ids { p.nodes.removePromotingChildren(id) }
                        }
                    }
                    .buttonStyle(.link)
                }
            }
            Spacer()
        }
        .font(.callout)
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
                m.edit { $0.nodes.append(Node(kind: .topic, title: "新描述块")) }
            } label: {
                Label("描述块", systemImage: "plus")
            }
            .help("新增一个描述块，用来写功能 / bug 的说明，PR 拖进去归类")
            Spacer()
            Text("拖动块可重新组织层级")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    func addPR() {
        guard let n = Int(newPR.trimmingCharacters(in: .whitespaces)) else { return }
        newPR = ""
        guard !(m.project?.nodes.allPRNumbers.contains(n) ?? false) else { return }
        m.editAndRefresh { $0.nodes.append(Node(kind: .pr, pr: n)) }   // 新 PR 一律先落在根级
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

    /// 折叠三角。冻结模式下也能用 —— 折叠只是换个看法，不算改内容。
    @ViewBuilder
    var chevron: some View {
        if row.node.children.isEmpty {
            Color.clear.frame(width: 14)
        } else {
            Button {
                m.toggleCollapse(row.node.id)
            } label: {
                Image(systemName: row.node.collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.node.collapsed ? "展开" : "折叠")
        }
    }

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
        let sum = m.topicSummary[row.node.id] ?? (total: 0, ready: 0)
        return HStack(spacing: 8) {
            if m.editing { grip }
            chevron
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
                    .foregroundColor(row.node.title.isEmpty ? .secondary : .primary)
            }
            Spacer()
            collapsedBadge
            if sum.total > 0 {
                Text(verbatim: "\(sum.total) 个 PR" + (sum.ready > 0 ? " · \(sum.ready) 个可合并" : ""))
                    .font(.caption)
                    .foregroundColor(sum.ready > 0 ? .green : .secondary)
            }
            if m.editing { deleteButton }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.25)))
    }

    // MARK: PR 块

    var prBody: some View {
        let num = row.node.pr ?? 0
        let lv = m.live[num]
        let st = m.status(pr: num, blocked: row.blocked)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if m.editing { grip }
                chevron
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
                if let lv, !lv.author.isEmpty {
                    Text("@\(lv.author)").foregroundColor(.secondary)
                }
                if m.editing {
                    TextField("备注…", text: $draft)
                        .textFieldStyle(.plain)
                        .foregroundColor(.secondary)
                        .onSubmit { m.edit { $0.nodes.update(row.node.id) { $0.note = draft } } }
                } else if !row.node.note.isEmpty {
                    Text(row.node.note).foregroundColor(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 10))
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

    @ViewBuilder
    func badges(_ lv: LivePR?) -> some View {
        if let lv {
            if lv.isDraft { tag("草稿", .gray) }
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
