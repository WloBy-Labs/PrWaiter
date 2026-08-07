import SwiftUI
import AppKit

// MARK: - 数据模型
// 本地只存依赖关系和备注（prs.json）；PR 标题、review、CI、合并状态实时从 GitHub 拉取。

struct TrackedPR: Codable, Identifiable {
    var pr: Int
    var after: [Int] = []
    var note: String = ""
    var id: Int { pr }

    init(pr: Int, after: [Int] = [], note: String = "") {
        self.pr = pr
        self.after = after
        self.note = note
    }

    enum CodingKeys: String, CodingKey { case pr, after, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pr = try c.decode(Int.self, forKey: .pr)
        after = try c.decodeIfPresent([Int].self, forKey: .after) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct Store: Codable {
    var repo: String = ""
    var prs: [TrackedPR] = []
}

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

// MARK: - 状态与 GitHub 拉取

@MainActor
final class Model: ObservableObject {
    @Published var store = Store()
    @Published var live: [Int: LivePR] = [:]
    @Published var error: String?
    @Published var loading = false
    @Published var updatedAt: Date?

    static let dataURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrWaiter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("prs.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.dataURL),
           let s = try? JSONDecoder().decode(Store.self, from: data) {
            store = s
        }
        Task { await self.refresh() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(store) { try? data.write(to: Self.dataURL) }
    }

    func mutate(_ change: (inout Store) -> Void) {
        change(&store)
        save()
        Task { await self.refresh() }
    }

    func refresh() async {
        if loading { return }
        var numbers = Set(store.prs.map(\.pr))
        for p in store.prs { numbers.formUnion(p.after) }
        guard !store.repo.isEmpty, !numbers.isEmpty else {
            live = [:]
            return
        }
        loading = true
        defer { loading = false }
        do {
            live = try await Self.fetchLive(repo: store.repo, numbers: numbers)
            error = nil
            updatedAt = Date()
        } catch let e {
            error = e.localizedDescription
        }
    }

    func status(of p: TrackedPR) -> PRStatus {
        guard let lv = live[p.pr] else { return .unknown }
        if lv.state == "MERGED" { return .merged }
        if lv.state == "CLOSED" { return .closed }
        if !p.after.allSatisfy({ live[$0]?.state == "MERGED" }) { return .blocked }
        if !lv.isDraft, lv.review == "APPROVED", lv.ci == nil || lv.ci == "SUCCESS" { return .ready }
        return .waiting
    }

    // GUI app 不继承 shell PATH，按常见安装位置找 gh
    nonisolated static func ghPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // 一次 GraphQL 请求拉取所有 PR 的实时状态
    nonisolated static func fetchLive(repo: String, numbers: Set<Int>) async throws -> [Int: LivePR] {
        guard let gh = ghPath() else {
            throw AppError("找不到 gh，请先 brew install gh 并 gh auth login")
        }
        guard repo.range(of: #"^[\w.-]+/[\w.-]+$"#, options: .regularExpression) != nil else {
            throw AppError("仓库格式应为 owner/repo")
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
        // 单个 PR 编号不存在时 GraphQL 只报部分错误，能拿到的照常显示；全军覆没才抛错
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
}

// MARK: - 界面

struct Row: Identifiable {
    let p: TrackedPR
    let depth: Int
    var id: Int { p.pr }
}

struct ContentView: View {
    @EnvironmentObject var m: Model
    @State private var newPR = ""
    @State private var newDeps = ""
    @State private var newNote = ""

    // 按依赖关系铺成缩进树：无（在跟踪的）依赖的是根，其余挂在第一个被跟踪的依赖下面
    var rows: [Row] {
        let tracked = Set(m.store.prs.map(\.pr))
        var children: [Int: [TrackedPR]] = [:]
        var roots: [TrackedPR] = []
        for p in m.store.prs {
            if let parent = p.after.first(where: { tracked.contains($0) }) {
                children[parent, default: []].append(p)
            } else {
                roots.append(p)
            }
        }
        var out: [Row] = []
        var seen = Set<Int>()
        func walk(_ p: TrackedPR, _ depth: Int) {
            guard seen.insert(p.pr).inserted else { return }
            out.append(Row(p: p, depth: depth))
            for c in children[p.pr] ?? [] { walk(c, depth + 1) }
        }
        for r in roots { walk(r, 0) }
        for p in m.store.prs where !seen.contains(p.pr) { out.append(Row(p: p, depth: 0)) } // 依赖成环时兜底
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let e = m.error {
                        Label(e, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
                    }
                    summary
                    ForEach(rows) { row in
                        PRCard(p: row.p, depth: row.depth)
                    }
                    if m.store.prs.isEmpty {
                        Text(m.store.repo.isEmpty
                             ? "先在上方填写仓库（owner/repo），然后添加要跟踪的 PR。"
                             : "还没有记录，用上面的表单添加一个 PR。")
                            .foregroundColor(.secondary)
                            .padding(.top, 20)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 680, minHeight: 440)
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("⏳ PrWaiter").font(.headline)
                Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("owner/repo", text: $m.store.repo)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { m.mutate { _ in } }
                Button {
                    Task { await m.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(m.loading)
                if m.loading { ProgressView().controlSize(.small) }
                Spacer()
                if let t = m.updatedAt {
                    Text("更新于 \(t.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 8) {
                TextField("PR 编号", text: $newPR).frame(width: 90)
                TextField("依赖的 PR（逗号分隔，可空）", text: $newDeps).frame(width: 210)
                TextField("备注（可空）", text: $newNote)
                Button("添加", action: addPR)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(addPR)
        }
    }

    var summary: some View {
        let by = Dictionary(grouping: m.store.prs, by: { m.status(of: $0) })
        return HStack(spacing: 14) {
            if let ready = by[.ready], !ready.isEmpty {
                Text("🟢 可合并：" + ready.map { "#\($0.pr)" }.joined(separator: " "))
                    .fontWeight(.semibold)
                    .foregroundColor(.green)
            }
            if let w = by[.waiting] { Text("🟡 等 review/CI \(w.count)").foregroundColor(.secondary) }
            if let b = by[.blocked] { Text("⏳ 等依赖 \(b.count)").foregroundColor(.secondary) }
            if let mg = by[.merged], !mg.isEmpty {
                Text("✔ 已合并 \(mg.count)").foregroundColor(.secondary)
                Button("清理已合并") {
                    m.mutate { s in s.prs.removeAll { p in mg.contains { $0.pr == p.pr } } }
                }
                .buttonStyle(.link)
            }
            Spacer()
        }
        .font(.callout)
    }

    func addPR() {
        guard let n = Int(newPR.trimmingCharacters(in: .whitespaces)) else { return }
        let deps = newDeps.split(whereSeparator: { ",，、 ".contains($0) }).compactMap { Int($0) }
        let note = newNote.trimmingCharacters(in: .whitespaces)
        m.mutate { s in
            s.prs.removeAll { $0.pr == n }
            s.prs.append(TrackedPR(pr: n, after: deps, note: note))
        }
        newPR = ""
        newDeps = ""
        newNote = ""
    }
}

struct PRCard: View {
    @EnvironmentObject var m: Model
    let p: TrackedPR
    let depth: Int
    @State private var newDep = ""
    @State private var noteDraft = ""
    @State private var confirmDelete = false

    var body: some View {
        let lv = m.live[p.pr]
        let st = m.status(of: p)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if depth > 0 { Text("↳").foregroundColor(.secondary) }
                if let lv, let u = URL(string: lv.url) {
                    Link("#\(p.pr)", destination: u)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                } else {
                    Text("#\(p.pr)")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                }
                Text(lv?.title ?? "（拉取不到，检查编号/仓库）")
                    .lineLimit(1)
                    .foregroundColor(st == .merged ? .secondary : .primary)
                Spacer()
                badges(lv)
                Text(st.label).font(.caption).foregroundColor(st.color)
                Button(confirmDelete ? "确认删除？" : "✕") {
                    if confirmDelete {
                        m.mutate { s in s.prs.removeAll { $0.pr == p.pr } }
                    } else {
                        confirmDelete = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { confirmDelete = false }
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(confirmDelete ? .red : .secondary)
            }
            HStack(spacing: 6) {
                if let lv, !lv.author.isEmpty {
                    Text("@\(lv.author)").foregroundColor(.secondary)
                }
                ForEach(p.after, id: \.self) { d in depChip(d) }
                TextField("+依赖", text: $newDep)
                    .textFieldStyle(.plain)
                    .frame(width: 64)
                    .onSubmit {
                        if let n = Int(newDep.trimmingCharacters(in: .whitespaces)),
                           n != p.pr, !p.after.contains(n) {
                            update { $0.after.append(n) }
                        }
                        newDep = ""
                    }
                TextField("备注…", text: $noteDraft)
                    .textFieldStyle(.plain)
                    .foregroundColor(.secondary)
                    .onSubmit { update { $0.note = noteDraft } }
            }
            .font(.caption)
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
        .overlay(alignment: .leading) {
            Capsule().fill(st.color).frame(width: 3).padding(.vertical, 8).padding(.leading, 5)
        }
        .opacity(st == .merged || st == .closed ? 0.6 : 1)
        .padding(.leading, CGFloat(depth) * 28)
        .onAppear { noteDraft = p.note }
        .onChange(of: p.note) { _, new in noteDraft = new }
    }

    func update(_ f: (inout TrackedPR) -> Void) {
        m.mutate { s in
            if let i = s.prs.firstIndex(where: { $0.pr == p.pr }) { f(&s.prs[i]) }
        }
    }

    func depChip(_ d: Int) -> some View {
        let merged = m.live[d]?.state == "MERGED"
        return HStack(spacing: 3) {
            Text("依赖 #\(d) \(merged ? "✔" : "⏳")")
            Button("✕") { update { $0.after.removeAll { $0 == d } } }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(merged ? Color.green.opacity(0.12) : Color.gray.opacity(0.15)))
        .foregroundColor(merged ? .green : .secondary)
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

// MARK: - 入口

@main
struct PrWaiterApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup("PrWaiter") {
            ContentView().environmentObject(model)
        }
    }
}
