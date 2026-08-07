import Foundation

// 纯逻辑测试：树的增删改、拖拽移动的合法性、旧格式迁移、JSON 往返。
// 界面部分靠手动验证。跑法见 test.sh。

@main
struct Tests {
    static var failed = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  ✓ \(what)" : "  ✗ \(what)")
        if !ok { failed += 1 }
    }

    static func main() {
        moveTests()
        deleteTests()
        flattenTests()
        collapseTests()
        guideTests()
        migrationTests()
        codableTests()

        print(failed == 0 ? "\n全部通过" : "\n\(failed) 项失败")
        exit(failed == 0 ? 0 : 1)
    }

    /// topic ─ prA ─ prB
    ///       └ (root) prC
    static func fixture() -> (nodes: [Node], topic: UUID, a: UUID, b: UUID, c: UUID) {
        var b = Node(kind: .pr, pr: 2)
        var a = Node(kind: .pr, pr: 1)
        a.children = [b]
        var topic = Node(kind: .topic, title: "分组")
        topic.children = [a]
        let c = Node(kind: .pr, pr: 3)
        b = a.children[0]
        return ([topic, c], topic.id, a.id, b.id, c.id)
    }

    static func moveTests() {
        print("拖拽移动:")
        let f = fixture()

        // 根级 PR 拖进描述块
        if let r = Tree.move(f.c, under: f.topic, in: f.nodes) {
            check(r.count == 1, "拖进描述块后根级只剩描述块")
            check(r.find(f.c) != nil, "被拖的 PR 还在树里")
            check(r[0].children.contains { $0.id == f.c }, "PR 成为描述块的直接子节点")
        } else {
            check(false, "PR 应该能拖进描述块")
        }

        // PR 拖到另一个 PR 下面（建立先后关系）
        if let r = Tree.move(f.c, under: f.b, in: f.nodes) {
            check(r.find(f.b)?.children.first?.id == f.c, "PR 可以挂到另一个 PR 下")
        } else {
            check(false, "PR 应该能挂到 PR 下")
        }

        // 子树带着一起搬
        if let r = Tree.move(f.a, under: nil, in: f.nodes) {
            check(r.count == 3, "子树搬到根级后根级有 3 个块")
            check(r.find(f.a)?.children.first?.id == f.b, "搬动时子节点跟着走")
            check(r.find(f.topic)?.children.isEmpty == true, "原描述块被搬空")
        } else {
            check(false, "应该能搬到根级")
        }

        // 非法：描述块不能变成子节点
        check(Tree.move(f.topic, under: f.a, in: f.nodes) == nil, "描述块不能挂到 PR 下")
        check(Tree.move(f.topic, under: f.c, in: f.nodes) == nil, "描述块不能挂到别的块下")

        // 非法：成环
        check(Tree.move(f.a, under: f.b, in: f.nodes) == nil, "不能把父节点挂进自己的子树")
        check(Tree.move(f.topic, under: f.b, in: f.nodes) == nil, "描述块不能挂进自己的子孙")

        // 非法：自己挂自己 / 目标不存在
        check(Tree.move(f.a, under: f.a, in: f.nodes) == nil, "不能挂到自己身上")
        check(Tree.move(f.a, under: UUID(), in: f.nodes) == nil, "目标不存在时拒绝")
        check(Tree.move(UUID(), under: f.a, in: f.nodes) == nil, "拖动不存在的块时拒绝")

        // 已在根级的块再拖到根级：允许，只是挪到末尾
        check(Tree.move(f.c, under: nil, in: f.nodes) != nil, "根级块可以拖回根级")
    }

    static func deleteTests() {
        print("删除与收集:")
        var f = fixture()

        check(f.nodes.allPRNumbers == [1, 2, 3], "递归收集所有 PR 编号")

        var nodes = f.nodes
        check(nodes.removePromotingChildren(f.a), "删除中间的 PR 返回成功")
        check(nodes.find(f.a) == nil, "被删的块消失")
        check(nodes.find(f.b) != nil, "子节点没跟着被删")
        check(nodes[0].children.first?.id == f.b, "子节点提升到被删块的位置")

        nodes = f.nodes
        check(nodes.removePromotingChildren(f.topic), "删除描述块返回成功")
        check(nodes.first?.id == f.a, "描述块的子节点提升到根级")

        nodes = f.nodes
        check(nodes.update(f.b) { $0.note = "改过了" }, "更新嵌套节点返回成功")
        check(nodes.find(f.b)?.note == "改过了", "备注写进去了")

        f.nodes = nodes
    }

    static func flattenTests() {
        print("铺平与先后关系:")
        let f = fixture()
        let none = Tree.flatten(f.nodes) { _ in false }

        check(none.count == 4, "所有节点都铺出来了")
        check(none.map(\.depth) == [0, 1, 2, 0], "层级正确")
        check(none.allSatisfy { !$0.hidden }, "没折叠时全部可见")

        check(none[0].blocked == false, "根级描述块不被挡")
        check(none[1].blocked == false, "描述块不参与先后关系，其子 PR 不被挡")
        check(none[2].blocked == true, "父 PR 没合并时子 PR 被挡")
        check(none[3].blocked == false, "根级 PR 不被挡")

        // 父 PR 合并后，子 PR 解除阻塞
        let merged = Tree.flatten(f.nodes) { $0 == 1 }
        check(merged[2].blocked == false, "父 PR 合并后子 PR 解除阻塞")

        // 阻塞会沿着链条传递
        let deep = Tree.flatten(f.nodes) { $0 == 2 }
        check(deep[2].blocked == true, "祖先没合并时，即使自己合并了下游仍被挡")

        check(none[0].descendants == 2, "描述块子孙数含孙子")
        check(none[1].descendants == 1, "PR 子孙数正确")
        check(none[3].descendants == 0, "叶子没有子孙")
    }

    static func collapseTests() {
        print("折叠:")
        var f = fixture()

        var nodes = f.nodes
        nodes.update(f.topic) { $0.collapsed = true }
        let rows = Tree.flatten(nodes) { _ in false }
        check(rows.count == 4, "折叠不改变行总数，只是标记隐藏")
        check(rows.filter { !$0.hidden }.count == 2, "折叠描述块后只剩两行可见")
        check(rows.first { $0.node.id == f.topic }?.hidden == false, "折叠的块自身仍可见")
        check(rows.first { $0.node.id == f.a }?.hidden == true, "子节点被藏起来")
        check(rows.first { $0.node.id == f.b }?.hidden == true, "孙节点也被藏起来")
        check(rows.first { $0.node.id == f.c }?.hidden == false, "别的根级块不受影响")

        // 折叠中间节点只藏它自己下面的
        nodes = f.nodes
        nodes.update(f.a) { $0.collapsed = true }
        let mid = Tree.flatten(nodes) { _ in false }
        check(mid.first { $0.node.id == f.a }?.hidden == false, "折叠的中间节点自身可见")
        check(mid.first { $0.node.id == f.b }?.hidden == true, "它的子节点被藏")

        // 统计不受折叠影响 —— 折叠了也不能让 PR 从汇总里消失
        check(mid.filter { $0.node.kind == .pr }.count == 3, "折叠后 PR 总数不变")

        // 拖进折叠的块会自动展开
        nodes = f.nodes
        nodes.update(f.topic) { $0.collapsed = true }
        if let moved = Tree.move(f.c, under: f.topic, in: nodes) {
            check(moved.find(f.topic)?.collapsed == false, "拖进折叠的块会自动展开")
        } else {
            check(false, "应该能拖进折叠的块")
        }

        f.nodes = nodes
    }

    static func guideTests() {
        print("缩进连线:")
        // topic ─┬ #1 ── #2 ── #5     c(#3) 是根级最后一个
        //        └ #4
        let e = Node(kind: .pr, pr: 5)
        var b = Node(kind: .pr, pr: 2)
        b.children = [e]
        var a = Node(kind: .pr, pr: 1)
        a.children = [b]
        let d = Node(kind: .pr, pr: 4)
        var topic = Node(kind: .topic, title: "T")
        topic.children = [a, d]
        let c = Node(kind: .pr, pr: 3)
        let rows = Tree.flatten([topic, c]) { _ in false }

        let byPR = { (n: Int) in rows.first { $0.node.pr == n }! }
        check(rows[0].guides.isEmpty, "根级不画连线")
        check(rows[0].isLast == false, "根级描述块后面还有块")
        check(rows.last!.isLast, "根级最后一个块标记正确")

        // #1 是 topic 的第一个孩子，后面还有 #4
        check(byPR(1).guides.count == 1, "深度 1 画一格")
        check(isBranch(byPR(1).guides[0]), "还有兄弟时画 ├")
        check(isLastBranch(byPR(4).guides[0]), "最后一个兄弟画 └")

        // #2 在深度 2：第 0 格看 topic（后面还有 c），要穿竖线；第 1 格是自己的拐角
        check(byPR(2).guides.count == 2, "深度 2 画两格")
        check(isLine(byPR(2).guides[0]), "祖先后面还有兄弟时，穿过去画竖线")
        check(isLastBranch(byPR(2).guides[1]), "自己是独子，画 └")

        // #5 在深度 3：第 1 格看祖先 #1，它后面还有 #4，所以要穿竖线
        check(byPR(5).guides.count == 3, "深度 3 画三格")
        check(isLine(byPR(5).guides[1]), "中间祖先后面还有兄弟时，那一列穿竖线")

        // 把 #4 删掉后 #1 成了最后一个，#5 的那一列就该留空
        var nodes = [topic, c]
        nodes.removePromotingChildren(d.id)
        let after = Tree.flatten(nodes) { _ in false }
        check(isBlank(after.first { $0.node.pr == 5 }!.guides[1]),
              "祖先已是最后一个时，那一列留空")
    }

    static func isBlank(_ g: Guide) -> Bool { if case .blank = g { return true }; return false }
    static func isLine(_ g: Guide) -> Bool { if case .line = g { return true }; return false }
    static func isBranch(_ g: Guide) -> Bool { if case .branch = g { return true }; return false }
    static func isLastBranch(_ g: Guide) -> Bool { if case .lastBranch = g { return true }; return false }

    static func migrationTests() {
        print("0.1.0 数据迁移:")
        let legacy = """
        {"repo":"StarRocks/starrocks","prs":[
          {"pr":100,"after":[],"note":""},
          {"pr":101,"after":[100],"note":"backport"},
          {"pr":102,"after":[100,101],"note":""},
          {"pr":103}
        ]}
        """.data(using: .utf8)!

        guard let s = Store.migrateLegacy(legacy) else {
            check(false, "旧格式应该能迁移")
            return
        }
        check(s.projects.count == 1, "迁移成一个项目")
        check(s.projects[0].repo == "StarRocks/starrocks", "仓库保留")
        check(s.projects[0].name == "starrocks", "项目名取自仓库名")
        check(s.selected == s.projects[0].id, "迁移后自动选中该项目")

        let nodes = s.projects[0].nodes
        check(nodes.allPRNumbers == [100, 101, 102, 103], "所有 PR 都迁过来了")
        check(nodes.count == 2, "无依赖的 PR 留在根级")
        check(nodes.find(101) != nil, "有依赖的 PR 挂到父节点下")
        check(nodes.first { $0.pr == 100 }?.children.contains { $0.pr == 101 } == true,
              "#101 挂在 #100 下")
        check(nodes.find(102)?.note.contains("另依赖") == true, "多依赖降级成备注")
        check(nodes.find(101)?.note == "backport", "原备注保留")

        // 新格式不该被误判成旧格式
        let modern = try! JSONEncoder().encode(s)
        check(Store.migrateLegacy(modern) == nil, "新格式不会走迁移分支")
    }

    static func codableTests() {
        print("JSON 往返:")
        let f = fixture()
        var store = Store()
        store.projects = [Project(name: "P", repo: "a/b", nodes: f.nodes)]
        store.selected = store.projects[0].id

        let data = try! JSONEncoder().encode(store)
        guard let back = try? JSONDecoder().decode(Store.self, from: data) else {
            check(false, "应该能解码回来")
            return
        }
        check(back.projects[0].nodes.allPRNumbers == [1, 2, 3], "PR 结构往返一致")
        check(back.projects[0].nodes.find(f.b) != nil, "节点 id 往返一致")
        check(back.selected == store.selected, "选中项往返一致")

        // 空字段不落盘
        let json = String(data: data, encoding: .utf8)!
        check(!json.contains("\"note\""), "空备注不写进 JSON")
        check(!json.contains("\"collapsed\""), "没折叠时不写 collapsed")

        // 折叠状态要能持久化
        var withCollapse = store
        withCollapse.projects[0].nodes.update(f.topic) { $0.collapsed = true }
        let d2 = try! JSONEncoder().encode(withCollapse)
        check(String(data: d2, encoding: .utf8)!.contains("\"collapsed\""), "折叠了才写 collapsed")
        let back2 = try! JSONDecoder().decode(Store.self, from: d2)
        check(back2.projects[0].nodes.find(f.topic)?.collapsed == true, "折叠状态往返保留")

        // 缺字段的手写 JSON 也要能读
        let handwritten = """
        {"projects":[{"name":"手写","nodes":[{"kind":"pr","pr":9}]}]}
        """.data(using: .utf8)!
        if let s = try? JSONDecoder().decode(Store.self, from: handwritten) {
            check(s.projects[0].nodes.allPRNumbers == [9], "缺 id/repo 的手写 JSON 能读")
            check(s.projects[0].repo == "", "缺失字段回落到默认值")
        } else {
            check(false, "手写 JSON 应该能读")
        }
    }
}

private extension Array where Element == Node {
    /// 按 PR 编号查找，测试里用着方便
    func find(_ pr: Int) -> Node? {
        for n in self {
            if n.pr == pr { return n }
            if let f = n.children.find(pr) { return f }
        }
        return nil
    }
}
