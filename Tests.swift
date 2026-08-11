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
        reorderTests()
        subLevelReorderTests()
        autoImportTests()
        importOrderTests()
        reparentTests()
        projectReorderTests()
        statusTests()
        migrationTests()
        codableTests()
        ghParseTests()
        versionTests()
        tourTests()

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

    static func reorderTests() {
        print("根级重排:")
        // 根级：[topic, c]，topic 下面挂着 a → b
        let f = fixture()
        let ids = { (ns: [Node]) in ns.map(\.id) }

        // 往后挪：topic(0) 挪到末尾
        if let r = Tree.move(f.topic, toRootIndex: 2, in: f.nodes) {
            check(ids(r) == [f.c, f.topic], "根级块可以挪到末尾")
            check(r.count == 2, "重排不改变根级数量")
            check(r.find(f.a) != nil, "重排时子树跟着走")
        } else {
            check(false, "应该能挪到末尾")
        }

        // 往前挪：c(1) 挪到最前
        if let r = Tree.move(f.c, toRootIndex: 0, in: f.nodes) {
            check(ids(r) == [f.c, f.topic], "根级块可以挪到最前")
        } else {
            check(false, "应该能挪到最前")
        }

        // 下标换算：往后挪时要减掉自己占的那一格
        check(Tree.move(f.topic, toRootIndex: 1, in: f.nodes) == nil,
              "挪到自己后面紧邻的位置等于没动，返回 nil")
        check(Tree.move(f.topic, toRootIndex: 0, in: f.nodes) == nil,
              "挪到自己当前位置，返回 nil")
        check(Tree.move(f.c, toRootIndex: 2, in: f.nodes) == nil,
              "末位挪到末位，返回 nil")

        // 嵌套节点拖到根级某个位置 = 出组 + 定位
        if let r = Tree.move(f.b, toRootIndex: 0, in: f.nodes) {
            check(r.count == 3, "嵌套块拖到根级后根级多一个")
            check(r.first?.id == f.b, "落在指定位置")
            check(r.find(f.a)?.children.isEmpty == true, "原来的父块空了")
        } else {
            check(false, "嵌套块应该能拖到根级")
        }

        // 越界与不存在
        check(Tree.move(f.c, toRootIndex: 99, in: f.nodes) == nil, "越界且等于原位，返回 nil")
        check(Tree.move(UUID(), toRootIndex: 0, in: f.nodes) == nil, "拖不存在的块，返回 nil")
        if let r = Tree.move(f.b, toRootIndex: 99, in: f.nodes) {
            check(r.last?.id == f.b, "越界下标被夹到末尾")
        } else {
            check(false, "越界应该被夹住而不是失败")
        }
    }

    static func subLevelReorderTests() {
        print("子层重排:")

        // topic 下面挂三个 PR：p1, p2, p3
        var p1 = Node(kind: .pr, pr: 1), p2 = Node(kind: .pr, pr: 2), p3 = Node(kind: .pr, pr: 3)
        p1.note = "one"; p2.note = "two"; p3.note = "three"
        var topic = Node(kind: .topic, title: "组")
        topic.children = [p1, p2, p3]
        let nodes = [topic, Node(kind: .pr, pr: 9)]
        let kids = { (ns: [Node]) in ns.find(topic.id)?.children.map(\.pr) ?? [] }

        // 同层往前挪
        if let r = Tree.move(p3.id, toIndex: 0, under: topic.id, in: nodes) {
            check(kids(r) == [3, 1, 2], "子块可以在同层往前挪")
            check(r.count == 2, "根级数量没变")
        } else {
            check(false, "子层应该能重排")
        }

        // 同层往后挪：下标要减掉自己占的那一格
        if let r = Tree.move(p1.id, toIndex: 2, under: topic.id, in: nodes) {
            check(kids(r) == [2, 1, 3], "往后挪时下标减掉自己占的那一格")
        } else {
            check(false, "子层应该能往后挪")
        }
        if let r = Tree.move(p1.id, toIndex: 3, under: topic.id, in: nodes) {
            check(kids(r) == [2, 3, 1], "挪到本层末尾")
        } else {
            check(false, "应该能挪到本层末尾")
        }

        // 没挪动的不写盘
        check(Tree.move(p2.id, toIndex: 1, under: topic.id, in: nodes) == nil, "挪到自己当前位置返回 nil")
        check(Tree.move(p2.id, toIndex: 2, under: topic.id, in: nodes) == nil,
              "挪到自己后面紧邻的位置等于没动")
        check(Tree.move(p3.id, toIndex: 99, under: topic.id, in: nodes) == nil, "末位挪到末位返回 nil")

        // 从别处拖进某一层的指定位置 = 换爹 + 定位
        if let r = Tree.move(nodes[1].id, toIndex: 1, under: topic.id, in: nodes) {
            check(kids(r) == [1, 9, 2, 3], "根级块拖进子层的指定位置")
            check(r.count == 1, "根级少了一个")
        } else {
            check(false, "应该能拖进子层")
        }

        // 拖到自己的子树里 = 成环，拒绝
        var outer = Node(kind: .pr, pr: 10)
        outer.children = [Node(kind: .pr, pr: 11)]
        let inner = outer.children[0].id
        check(Tree.move(outer.id, toIndex: 0, under: inner, in: [outer]) == nil, "不能插进自己的子树")
        check(Tree.move(topic.id, toIndex: 0, under: nodes[1].id, in: nodes) == nil,
              "描述块不能插到别人下面")
        check(Tree.move(p1.id, toIndex: 0, under: UUID(), in: nodes) == nil, "父节点不存在返回 nil")

        // 插进折叠起来的块，要把它展开，不然看着像拖没了
        var folded = topic
        folded.collapsed = true
        if let r = Tree.move(nodes[1].id, toIndex: 0, under: folded.id, in: [folded, nodes[1]]) {
            check(r.find(folded.id)?.collapsed == false, "插进折叠的块会展开它")
        } else {
            check(false, "应该能插进折叠的块")
        }

        // 铺平后每行都知道自己归谁管、排第几 —— 投放缝靠这两个值定位
        let rows = Tree.flatten(nodes) { _ in false }
        check(rows.first { $0.node.pr == 2 }?.parent == topic.id, "子行知道自己的父节点")
        check(rows.first { $0.node.pr == 2 }?.index == 1, "子行知道自己在同层排第几")
        check(rows.first { $0.node.pr == 9 }?.parent == nil, "根级行没有父节点")
        check(rows.first { $0.node.pr == 9 }?.index == 1, "根级行的下标是根级下标")
    }

    static func projectReorderTests() {
        print("项目标签重排:")
        let a = Project(name: "A"), b = Project(name: "B"), c = Project(name: "C")
        let ps = [a, b, c]
        let names = { (x: [Project]) in x.map(\.name) }

        if let r = Store.moveProject(c.id, toIndex: 0, in: ps) {
            check(names(r) == ["C", "A", "B"], "末尾的标签可以挪到最前")
        } else {
            check(false, "应该能挪到最前")
        }

        if let r = Store.moveProject(a.id, toIndex: 3, in: ps) {
            check(names(r) == ["B", "C", "A"], "最前的标签可以挪到末尾")
        } else {
            check(false, "应该能挪到末尾")
        }

        if let r = Store.moveProject(a.id, toIndex: 2, in: ps) {
            check(names(r) == ["B", "A", "C"], "往后挪时下标要减掉自己占的那一格")
        } else {
            check(false, "应该能挪到中间")
        }

        check(Store.moveProject(a.id, toIndex: 0, in: ps) == nil, "挪到自己当前位置，返回 nil")
        check(Store.moveProject(a.id, toIndex: 1, in: ps) == nil, "挪到自己后面紧邻的位置等于没动")
        check(Store.moveProject(c.id, toIndex: 3, in: ps) == nil, "末位挪到末位，返回 nil")

        // 拖块的时候飘到标签栏上，传进来的是块 id，不该误伤项目顺序
        check(Store.moveProject(UUID(), toIndex: 0, in: ps) == nil, "不是项目 id 时当没发生")
        check(Store.moveProject(a.id, toIndex: 0, in: []) == nil, "空列表不炸")

        // 反过来：拖标签飘到块的投放区上，也不该动树
        var node = Node(kind: .topic, title: "T")
        node.children = [Node(kind: .pr, pr: 1)]
        check(Tree.move(a.id, toRootIndex: 0, in: [node]) == nil, "项目 id 落到块的缝里当没发生")
        check(Tree.move(a.id, under: node.id, in: [node]) == nil, "项目 id 落到块身上当没发生")
    }

    static func autoImportTests() {
        print("自动导入与 backport 聚合:")

        func open(_ n: Int, _ t: String = "") -> FoundPR { FoundPR(number: n, title: t, isOpen: true) }
        func shut(_ n: Int, _ t: String = "") -> FoundPR { FoundPR(number: n, title: t, isOpen: false) }

        // --- 标题解析 ---
        check(GhParse.backportParent(from: "[BugFix] xxx (backport #77408)") == 77408,
              "解析 StarRocks 的 (backport #N)")
        check(GhParse.backportParent(from: "Backport of #123 to 3.5") == 123, "解析 backport of #N")
        check(GhParse.backportParent(from: "cherry-pick #99") == 99, "解析 cherry-pick #N")
        check(GhParse.backportParent(from: "Cherry picked from #77") == 77, "解析 cherry picked from #N")
        check(GhParse.backportParent(from: "[BugFix] 普通 PR，没有 backport 字样") == nil,
              "主干 PR 解析不出父 PR")
        check(GhParse.backportParent(from: "fix #123 crash") == nil,
              "只是引用了 issue，不是 backport，不能误判")

        // --- 多重 backport：取最后一个引用 ---
        // backport 再 backport 时标题会一路带上来源，最后那个才是直接的上一手。
        // 挂到第一个（最上游）会跳过中间那一环，先后关系就断了。
        let chained = "[BugFix] Derive the reserve limit (backport #77408) (backport #77463)"
        check(GhParse.backportParents(from: chained) == [77408, 77463], "解析出全部引用，保持顺序")
        check(GhParse.backportParent(from: chained) == 77463, "父节点取最后一个引用，不是第一个")
        check(GhParse.backportParents(from: "[BugFix] xxx (backport #77408)") == [77408],
              "只有一个引用时就是它")
        check(GhParse.backportParents(from: "[BugFix] 主干 PR").isEmpty, "主干 PR 解析不出引用")
        check(GhParse.backportParents(from: "fix #1 and #2 crash").isEmpty,
              "光有 # 编号、没有 backport 字样的不算")

        // 链式 backport 应该挂到中间那一环下面，而不是最上游
        var trunk = Node(kind: .pr, pr: 77408)
        trunk.children = [Node(kind: .pr, pr: 77463)]
        if let r = Project.importing([FoundPR(number: 77550, title: chained, isOpen: true)],
                                     nodes: [trunk], imported: [77408, 77463]) {
            let mid = r.nodes.find(77463)
            check(mid?.children.map(\.pr) == [77550], "链式 backport 挂在上一手下面")
            check(r.nodes.find(77408)?.children.map(\.pr) == [77463], "不会跳过中间那一环")
        } else {
            check(false, "链式 backport 应该被导入")
        }

        // --- open 一律收，没有父 PR 的落根级顶部 ---
        let base = [Node(kind: .pr, pr: 100)]
        if let r = Project.importing([open(200), open(201)], nodes: base, imported: [100]) {
            check(r.nodes.map(\.pr) == [201, 200, 100], "open 的落在根级顶部，编号大的在最上")
        } else {
            check(false, "open 的应该被导入")
        }

        // --- backport 自动挂到父 PR 下面 ---
        if let r = Project.importing([open(200, "fix (backport #100)")], nodes: base, imported: [100]) {
            check(r.nodes.count == 1, "没有多出根级块")
            check(r.nodes[0].pr == 100 && r.nodes[0].children.first?.pr == 200,
                  "backport 挂到了父 PR 下面，而不是落在根级")
        } else {
            check(false, "backport 应该被导入")
        }

        // 父 PR 不在树里时，退回根级
        if let r = Project.importing([open(200, "fix (backport #999)")], nodes: base, imported: [100]) {
            check(r.nodes.first?.pr == 200 && r.nodes.count == 2, "父 PR 不在树里就落根级")
        } else {
            check(false, "应该被导入")
        }

        // 挂进折叠的父 PR 会自动展开
        var collapsed = [Node(kind: .pr, pr: 100)]
        collapsed[0].collapsed = true
        collapsed[0].children = [Node(kind: .pr, pr: 101)]
        if let r = Project.importing([open(200, "x (backport #100)")], nodes: collapsed, imported: [100, 101]) {
            check(r.nodes[0].collapsed == false, "挂进折叠的父 PR 时自动展开，别让新东西藏起来")
        } else {
            check(false, "应该被导入")
        }

        // --- 已关闭的：只收和已跟踪 PR 有关系的 ---
        check(Project.importing([shut(300, "无关的老 PR")], nodes: base, imported: [100]) == nil,
              "无关的已关闭 PR 不导入，否则历史上几十个会全倒进来")

        if let r = Project.importing([shut(300, "x (backport #100)")], nodes: base, imported: [100]) {
            check(r.nodes[0].children.first?.pr == 300,
                  "已关闭但是已跟踪 PR 的 backport，要收 —— 这正是「backport 被关掉了」的信号")
        } else {
            check(false, "相关的已关闭 backport 应该被导入")
        }

        // 同一批里「新 open 主干 + 它的旧 closed backport」都要收
        if let r = Project.importing([open(400, "主干"), shut(401, "x (backport #400)")],
                                     nodes: [], imported: []) {
            check(r.nodes.count == 1, "主干落根级，backport 挂上去")
            check(r.nodes[0].pr == 400 && r.nodes[0].children.first?.pr == 401,
                  "同一批导入时，父 PR 先落地再挂子 PR")
        } else {
            check(false, "应该被导入")
        }

        // 已跟踪的 backport 的父 PR，也要收（反向关系）
        let tracked = [Node(kind: .pr, pr: 500)]
        if let r = Project.importing([shut(499, "主干"), shut(500, "x (backport #499)")],
                                     nodes: tracked, imported: [500]) {
            check(r.nodes.contains { $0.pr == 499 }, "已跟踪 backport 的父 PR 也要收")
        } else {
            check(false, "父 PR 应该被导入")
        }

        // --- 不变量 ---
        check(Project.importing([], nodes: base, imported: [100]) == nil, "什么都没查到时不动")
        check(Project.importing([open(100)], nodes: base, imported: [100]) == nil,
              "已在树里的不重复导入")
        check(Project.importing([open(100)], nodes: base, imported: []) != nil,
              "imported 落后于树时补记")
        check(Project.importing([open(100, "x (backport #1)")], nodes: [], imported: [100]) == nil,
              "删掉过的不会被导回来")
    }

    static func importOrderTests() {
        print("导入位置:")

        func open(_ n: Int, _ t: String = "") -> FoundPR { FoundPR(number: n, title: t, isOpen: true) }
        let bp = { (n: Int) in "[BugFix] 修一个 bug (backport #\(n))" }

        // --- 根级：新来的落在所有根节点最上面 ---
        let existing = [Node(kind: .topic, title: "已有的组"), Node(kind: .pr, pr: 100)]
        if let r = Project.importing([open(300), open(200)], nodes: existing, imported: [100]) {
            check(r.nodes.map(\.pr) == [300, 200, nil, 100], "新 PR 落在最上面，编号大的更靠上")
            check(r.nodes[2].kind == .topic, "已有的描述块被顶下去，但顺序没乱")
        } else {
            check(false, "根级 PR 应该被导入")
        }

        // --- 子层：按编号倒序插进去 ---
        var parent = Node(kind: .pr, pr: 500)
        parent.children = [Node(kind: .pr, pr: 300), Node(kind: .pr, pr: 100)]
        let kids = { (ns: [Node]) in ns.find(parent.id)?.children.map(\.pr) ?? [] }

        // 最大的排最前
        if let r = Project.importing([open(400, bp(500))], nodes: [parent], imported: [500, 300, 100]) {
            check(kids(r.nodes) == [400, 300, 100], "新 backport 按编号插到比它小的那些前面")
        } else {
            check(false, "backport 应该被导入")
        }
        // 比谁都大 → 排最前
        if let r = Project.importing([open(900, bp(500))], nodes: [parent], imported: [500, 300, 100]) {
            check(kids(r.nodes) == [900, 300, 100], "编号最大的排在同层最前")
        } else {
            check(false, "backport 应该被导入")
        }
        // 比谁都小 → 排末尾
        if let r = Project.importing([open(50, bp(500))], nodes: [parent], imported: [500, 300, 100]) {
            check(kids(r.nodes) == [300, 100, 50], "编号最小的排在同层末尾")
        } else {
            check(false, "backport 应该被导入")
        }
        // 一批一起进来，彼此之间也要倒序
        if let r = Project.importing([open(200, bp(500)), open(400, bp(500)), open(150, bp(500))],
                                     nodes: [parent], imported: [500, 300, 100]) {
            check(kids(r.nodes) == [400, 300, 200, 150, 100], "同一批多个 backport 各就各位")
        } else {
            check(false, "backport 应该被导入")
        }

        // 空父块
        let bare = [Node(kind: .pr, pr: 500)]
        if let r = Project.importing([open(400, bp(500))], nodes: bare, imported: [500]) {
            check(r.nodes.first?.children.map(\.pr) == [400], "父块本来没孩子时也能挂上")
        } else {
            check(false, "backport 应该被导入")
        }

        // 手工摆的顺序不是倒序时，也得给个说得通的位置：插到第一个比它小的前面
        var messy = Node(kind: .pr, pr: 500)
        messy.children = [Node(kind: .pr, pr: 100), Node(kind: .pr, pr: 400)]
        if let r = Project.importing([open(200, bp(500))], nodes: [messy], imported: [500, 100, 400]) {
            check(r.nodes.find(messy.id)?.children.map(\.pr) == [200, 100, 400],
                  "同层顺序被手工打乱过时，插到第一个比它小的前面，不重排别人")
        } else {
            check(false, "backport 应该被导入")
        }

        // 认不出父 PR 的 backport 照旧落根级顶部
        if let r = Project.importing([open(700, bp(999))], nodes: [parent], imported: [500, 300, 100]) {
            check(r.nodes.map(\.pr) == [700, 500], "父 PR 不在树里的落在根级最上面")
        } else {
            check(false, "应该被导入")
        }
    }

    static func reparentTests() {
        print("多重 backport 的父节点修正:")

        let chained = "[BugFix] Derive the reserve limit (backport #77408) (backport #77463)"
        let titles = [77408: "[BugFix] Derive the reserve limit",
                      77463: "[BugFix] Derive the reserve limit (backport #77408)",
                      77550: chained,
                      77461: "[BugFix] Derive the reserve limit (backport #77408)"]

        // 老规则把 77550 挂到了最上游的 77408 下面，应该搬到 77463 下面
        var trunk = Node(kind: .pr, pr: 77408)
        trunk.children = [Node(kind: .pr, pr: 77463), Node(kind: .pr, pr: 77550)]
        guard let fixed = Tree.reparenting([trunk], titles: titles) else {
            check(false, "摆错了位置的应该被搬走"); return
        }
        check(fixed.find(77463)?.children.map(\.pr) == [77550], "搬到了正确的上一手下面")
        check(fixed.find(77408)?.children.map(\.pr) == [77463], "原来的位置腾出来了")
        check(fixed.allPRNumbers.sorted() == [77408, 77463, 77550], "一个都没丢")

        // 已经在对的地方：不动，也不白写一次盘
        var mid = Node(kind: .pr, pr: 77463)
        mid.children = [Node(kind: .pr, pr: 77550)]
        var root = Node(kind: .pr, pr: 77408)
        root.children = [mid]
        check(Tree.reparenting([root], titles: titles) == nil, "已经挂对了就不动")

        // 只有一个引用的，谈不上摆错
        var single = Node(kind: .pr, pr: 77408)
        single.children = [Node(kind: .pr, pr: 77461)]
        check(Tree.reparenting([single], titles: titles) == nil, "单个引用的不参与修正")

        // 你自己拖到别处的不动 —— 当前父节点不是标题里更早的引用，就不是老规则摆的
        var elsewhere = Node(kind: .topic, title: "手工分的组")
        elsewhere.children = [Node(kind: .pr, pr: 77550)]
        check(Tree.reparenting([elsewhere, Node(kind: .pr, pr: 77463)], titles: titles) == nil,
              "手工拖到描述块下的不动")
        var other = Node(kind: .pr, pr: 99999)
        other.children = [Node(kind: .pr, pr: 77550)]
        check(Tree.reparenting([other, Node(kind: .pr, pr: 77463)], titles: titles) == nil,
              "挂在无关 PR 下的不动（那是手工摆的）")

        // 正确的上一手不在树里：没处搬，就别搬
        var lonely = Node(kind: .pr, pr: 77408)
        lonely.children = [Node(kind: .pr, pr: 77550)]
        check(Tree.reparenting([lonely], titles: titles) == nil, "目标不在树里就不动")

        // 拉不到标题时不猜
        check(Tree.reparenting([trunk], titles: [:]) == nil, "没有标题就不动")
    }

    static func statusTests() {
        print("状态分类:")
        func lv(state: String = "OPEN", draft: Bool = false,
                review: String? = nil, ci: String? = nil) -> LivePR {
            var v = LivePR()
            v.state = state
            v.isDraft = draft
            v.review = review
            v.ci = ci
            return v
        }

        check(Model.classify(nil, blocked: false) == .unknown, "拉不到数据是未知")
        check(Model.classify(lv(state: "MERGED"), blocked: true) == .merged, "已合并压倒一切")
        check(Model.classify(lv(state: "CLOSED"), blocked: true) == .closed, "已关闭压倒一切")
        check(Model.classify(lv(draft: true, review: "APPROVED", ci: "SUCCESS"), blocked: false) == .draft,
              "草稿即使批准且 CI 绿也还是草稿")

        // 自己这边的问题排在「等依赖」前面：被挡着也该先修
        check(Model.classify(lv(ci: "FAILURE"), blocked: true) == .ciFailed, "CI 失败优先于等依赖")
        check(Model.classify(lv(ci: "ERROR"), blocked: false) == .ciFailed, "ERROR 也算 CI 失败")
        check(Model.classify(lv(review: "CHANGES_REQUESTED"), blocked: true) == .changesRequested,
              "需修改优先于等依赖")

        check(Model.classify(lv(review: "APPROVED", ci: "SUCCESS"), blocked: true) == .blocked,
              "万事俱备但上游没合，是等依赖")
        check(Model.classify(lv(review: "APPROVED", ci: "PENDING"), blocked: false) == .ciRunning,
              "CI 跑着呢")
        check(Model.classify(lv(review: "APPROVED", ci: "EXPECTED"), blocked: false) == .ciRunning,
              "EXPECTED 也算跑着")
        check(Model.classify(lv(review: "REVIEW_REQUIRED", ci: "SUCCESS"), blocked: false) == .needsReview,
              "CI 绿了但还没批准，是等 review")
        check(Model.classify(lv(ci: "SUCCESS"), blocked: false) == .needsReview,
              "没有 review 结论也算等 review")

        check(Model.classify(lv(review: "APPROVED", ci: "SUCCESS"), blocked: false) == .ready,
              "批准 + CI 绿 + 无阻塞才是可合并")
        check(Model.classify(lv(review: "APPROVED", ci: nil), blocked: false) == .ready,
              "仓库没配 CI 时，批准即可合并")

        // 分类互斥，所以描述块上的分项加起来必然等于 PR 总数
        let cases = [
            lv(state: "MERGED"), lv(draft: true), lv(ci: "FAILURE"),
            lv(review: "CHANGES_REQUESTED"), lv(review: "APPROVED", ci: "SUCCESS"),
        ]
        let kinds = Set(cases.map { Model.classify($0, blocked: false) })
        check(kinds.count == cases.count, "不同情形落在不同桶里，分类互斥")

        check(PRStatus.merged.isSettled && PRStatus.closed.isSettled, "已合并/已关闭算尘埃落定")
        check(!PRStatus.ready.isSettled, "可合并还需要盯着")
        check(Set(PRStatus.summaryOrder).count == PRStatus.allCases.count,
              "分项排列顺序覆盖了所有状态，不会漏显示")
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

    static func ghParseTests() {
        print("gh 输出解析:")

        check(GhParse.version(from: "gh version 2.96.0 (2026-06-11)\nhttps://...") == "2.96.0",
              "解析出 gh 版本号")
        check(GhParse.version(from: "") == nil, "空输出没有版本号")
        check(GhParse.version(from: "command not found") == nil, "无关输出不误判成版本号")

        // 登录态：gh auth status 的实际输出格式
        let loggedIn = """
        github.com
          ✓ Logged in to github.com account Joob1n (keyring)
          - Active account: true
          - Token scopes: 'gist', 'read:org', 'repo'
        """
        check(GhParse.account(from: loggedIn) == "Joob1n", "解析出登录账号")

        check(GhParse.account(from: "You are not logged into any GitHub hosts.") == nil,
              "未登录时返回 nil")
        check(GhParse.account(from: "") == nil, "空输出返回 nil")

        // 路径优先级
        let c1 = GhParse.candidates(custom: "", pathEnv: "/usr/bin:/bin", home: "/Users/x")
        check(c1.first == "/opt/homebrew/bin/gh", "没自定义时 Homebrew 排最前")
        check(c1.contains("/opt/local/bin/gh"), "包含 MacPorts 路径")
        check(c1.contains("/Users/x/.local/bin/gh"), "包含用户级安装路径")
        check(c1.contains("/usr/bin/gh"), "PATH 里的目录也纳入候选")
        check(Set(c1).count == c1.count, "候选路径不重复")

        let c2 = GhParse.candidates(custom: "/my/gh", pathEnv: "", home: "/Users/x")
        check(c2.first == "/my/gh", "自定义路径优先级最高")

        let c3 = GhParse.candidates(custom: "  /my/gh  ", pathEnv: "", home: "/Users/x")
        check(c3.first == "/my/gh", "自定义路径两端空白被去掉")

        let c4 = GhParse.candidates(custom: "/opt/homebrew/bin/gh", pathEnv: "", home: "/Users/x")
        check(c4.filter { $0 == "/opt/homebrew/bin/gh" }.count == 1,
              "自定义路径与内置路径相同时不重复")
    }

    static func versionTests() {
        print("版本号比较:")
        check(Version.isNewer("0.9.0", than: "0.8.1"), "0.9.0 比 0.8.1 新")
        check(Version.isNewer("0.8.2", than: "0.8.1"), "补丁位递增")
        check(Version.isNewer("1.0.0", than: "0.9.9"), "跨大版本")

        // 字符串比较会在这里翻车："0.10.0" < "0.9.0"
        check(Version.isNewer("0.10.0", than: "0.9.0"), "0.10.0 比 0.9.0 新（字符串比较会判错）")
        check(Version.isNewer("1.10.0", than: "1.9.20"), "次版本按数字比，不按字符串")
        check(!Version.isNewer("0.9.0", than: "0.10.0"), "反过来不成立")

        check(!Version.isNewer("0.8.1", than: "0.8.1"), "同版本不算新")
        check(!Version.isNewer("0.8.0", than: "0.8.1"), "旧版本不算新")

        // tag 带 v 前缀
        check(Version.isNewer("v0.9.0", than: "0.8.1"), "带 v 前缀也能比")
        check(!Version.isNewer("v0.8.1", than: "0.8.1"), "带 v 前缀的同版本不算新")

        // 段数不同时短的补 0
        check(Version.compare("1.0", "1.0.0") == .orderedSame, "1.0 和 1.0.0 相等")
        check(Version.isNewer("1.0.1", than: "1.0"), "1.0.1 比 1.0 新")

        check(Version.parts("v0.9.0") == [0, 9, 0], "解析出各段数字")
        check(Version.parts("1.2.3-beta") == [1, 2, 3], "带后缀时只取数字部分")
    }

    static func tourTests() {
        print("上手导览:")

        // 导览的全部价值就是「指着某个控件讲」。哪一步没有目标，
        // 遮罩就挖不出洞，那一步会退化成一个居中的对话框 —— 那不叫导览。
        check(TourStep.all.allSatisfy { $0.target != nil }, "每一步都指着一个真实控件")
        check(!TourStep.all.isEmpty, "至少有一步")

        // 首次启动用户一条数据都没有，靠样板数据兜底
        let rows = Tree.flatten(TourDemo.nodes) { TourDemo.live[$0]?.state == "MERGED" }
        check(rows.contains { $0.node.kind == .topic }, "样板里有描述块，第 2、4 步才有得指")
        check(rows.contains { $0.node.kind == .pr }, "样板里有 PR 行，第 3、6 步才有得指")

        // 每一步的目标都得真能在样板界面上出现，否则等于没目标
        let reachable: Set<TourTarget> = [
            .projectTabs, .editButton, .gearButton, .refreshButton,   // 控制条常驻
            .topicRow, .collapseZone,                                 // 描述块样板行
            .statusBadges, .dragGrip,                                 // PR 样板行
        ]
        check(TourStep.all.allSatisfy { reachable.contains($0.target!) }, "目标都在样板界面里存在")

        // 讲颜色那一步得有几种不同的颜色可看，一水儿的灰讲不清楚
        let statuses = rows.filter { $0.node.kind == .pr }.map {
            Model.classify(TourDemo.live[$0.node.pr ?? 0], blocked: $0.blocked)
        }
        check(Set(statuses).count >= 3, "样板 PR 覆盖至少三种状态")
        check(statuses.contains(.ready), "有「可以合了」")
        check(statuses.contains(.blocked), "有「等上游」—— 缩进的意义全在这")
        check(statuses.contains(.ciFailed), "有「CI 挂了」")

        // 「缩进就是先后关系」那一步靠嵌套演示，样板必须真的是嵌套的
        check(rows.contains { $0.depth >= 2 }, "样板有两层以上嵌套")
        check(rows.contains { $0.node.kind == .pr && $0.blocked }, "有 PR 被上游挡着")

        // 拖动手柄只在编辑态出现，所以那一步得声明自己要编辑态
        let grip = TourStep.all.first { $0.target == .dragGrip }
        check(grip?.needsEditing == true, "讲拖拽那一步会把手柄显出来")
        check(TourStep.all.filter { $0.needsEditing }.count == 1, "只有拖拽那一步需要编辑态")

        // 编号用 900+，跟真 PR 一眼分得开
        check(TourDemo.live.keys.allSatisfy { $0 >= 900 }, "样板编号不会跟真 PR 混淆")
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
