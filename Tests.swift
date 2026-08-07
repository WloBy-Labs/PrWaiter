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
