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
        inboxTests()
        checkRollupTests()
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

    static func inboxTests() {
        print("reviewer 视角:")

        func item(_ kind: ReviewItem.Kind, _ repo: String, _ n: Int, at: Double = 0) -> ReviewItem {
            ReviewItem(kind: kind, repo: repo, number: n, title: "t", url: "u", author: "other",
                       base: "main", isDraft: false, review: nil, ci: nil,
                       at: Date(timeIntervalSince1970: at), note: "")
        }

        // --- 分档：等我批准 > 请我 review > 指派给我 > @ 到我 ---
        // 排序就是「谁被卡得最死」：workflow 不批，对方的 CI 一步都走不了
        let mixed = [item(.mentioned, "o/a", 1), item(.assigned, "o/a", 2),
                     item(.requested, "o/a", 3), item(.approveCI, "o/a", 4)]
        check(Model.arrange(mixed).map(\.number) == [4, 3, 2, 1], "按「卡得多死」排序")

        // --- 同一个 PR 命中多个搜索：只留最该办的那一档 ---
        let dup = Model.arrange([item(.mentioned, "o/a", 5), item(.requested, "o/a", 5),
                                 item(.assigned, "o/a", 5)])
        check(dup.count == 1, "一件事只出现一次")
        check(dup[0].kind == .requested, "留最该办的那一档")
        check(Model.arrange([item(.requested, "o/a", 5), item(.mentioned, "o/a", 5)])[0].kind
              == .requested, "跟先后顺序无关")

        // 不同仓库的同号 PR 是两件事
        check(Model.arrange([item(.requested, "o/a", 5), item(.requested, "o/b", 5)]).count == 2,
              "不同仓库的同号 PR 不能被去重掉")

        // 拿不到 PR 编号的 workflow run（fork 的常这样）靠 url 区分，不能互相盖掉
        let r1 = ReviewItem(kind: .approveCI, repo: "o/a", number: 0, title: "t", url: "run/1",
                            author: "x", base: "b", isDraft: false, review: nil, ci: nil,
                            at: nil, note: "")
        let r2 = ReviewItem(kind: .approveCI, repo: "o/a", number: 0, title: "t", url: "run/2",
                            author: "x", base: "b", isDraft: false, review: nil, ci: nil,
                            at: nil, note: "")
        check(Model.arrange([r1, r2]).count == 2, "没有 PR 编号的 run 按 url 区分")

        // --- 同档之内按时间，等得久的不该被新来的埋掉：新的在上，一眼看到最新请求 ---
        let byTime = Model.arrange([item(.requested, "o/a", 1, at: 100),
                                    item(.requested, "o/a", 2, at: 300),
                                    item(.requested, "o/a", 3, at: 200)])
        check(byTime.map(\.number) == [2, 3, 1], "同档按时间倒序，刚请我的排最上面")

        // --- 解析：「别人从什么时候开始等我」要从 timeline 取 ---
        // 三天前请我 review、刚被作者推了一版，不该排到「十分钟前请我」前面
        let base: [String: Any] = [
            "number": 42, "title": "别人的 PR", "url": "u", "isDraft": false,
            "updatedAt": "2026-08-22T02:00:00Z", "baseRefName": "main",
            "author": ["login": "someone"], "repository": ["nameWithOwner": "o/a"],
            "commits": ["nodes": [["commit": [
                "statusCheckRollup": ["contexts": ["nodes": [
                    ["__typename": "CheckRun", "name": "build", "status": "COMPLETED",
                     "conclusion": "SUCCESS"],
                ]]],
                "checkSuites": ["nodes": [["status": "COMPLETED"]]],
            ]]]],
        ]
        var withReq = base
        withReq["timelineItems"] = ["nodes": [
            ["createdAt": "2026-08-19T00:00:00Z", "requestedReviewer": ["login": "someone-else"]],
            ["createdAt": "2026-08-20T06:14:00Z", "requestedReviewer": ["login": "me"]],
        ]]
        let a1 = Model.parseReviewItem(withReq, repo: "o/a", kind: .requested, account: "me")
        check(a1?.at == GhParse.date(from: "2026-08-20T06:14:00Z"), "取的是请我那次的时间")
        check(a1?.ci == "SUCCESS", "CI 结论复用同一套算法")
        check(a1?.author == "someone", "显示的是 PR 作者，也就是在等我的那个人")

        var otherOnly = base
        otherOnly["timelineItems"] = ["nodes": [
            ["createdAt": "2026-08-19T00:00:00Z", "requestedReviewer": ["login": "someone-else"]],
        ]]
        check(Model.parseReviewItem(otherOnly, repo: "o/a", kind: .requested, account: "me")?.at
              == GhParse.date(from: "2026-08-22T02:00:00Z"), "只请了别人时退回 PR 更新时间")

        var team = base
        team["timelineItems"] = ["nodes": [
            ["createdAt": "2026-08-21T00:00:00Z", "requestedReviewer": ["name": "storage-team"]],
        ]]
        check(Model.parseReviewItem(team, repo: "o/a", kind: .requested, account: "me")?.at
              == GhParse.date(from: "2026-08-21T00:00:00Z"), "按团队请我 review 也算数")

        // 指派给我也算「开始等我」的时刻
        var asg = base
        asg["timelineItems"] = ["nodes": [
            ["createdAt": "2026-08-21T10:00:00Z", "assignee": ["login": "me"]],
        ]]
        check(Model.parseReviewItem(asg, repo: "o/a", kind: .assigned, account: "me")?.at
              == GhParse.date(from: "2026-08-21T10:00:00Z"), "被指派的时间也认")

        // --- 仓库改名：显示响应里的真名 ---
        // 实测配置里的 maka-agent/maka-agent 已经转移成 apache/maka，
        // 用旧名照样能查（GitHub 重定向），但显示旧名会让人对不上号
        var renamed = base
        renamed["repository"] = ["nameWithOwner": "apache/maka"]
        let rn = Model.parseReviewItem(renamed, repo: "maka-agent/maka-agent",
                                       kind: .requested, account: "me")
        check(rn?.repo == "apache/maka", "改名后的仓库显示新名字")
        check(rn?.id == "apache/maka#42", "去重的键也跟着用新名字")
        var noRepo = base
        noRepo["repository"] = [:] as [String: Any]
        check(Model.parseReviewItem(noRepo, repo: "o/a", kind: .requested, account: "me")?.repo
              == "o/a", "响应里没带仓库名时退回查询时填的那个")

        // --- 「@ 到我」什么时候算消掉 ---
        // 规则：有人在我最后一次发言之后又点了我，才算还欠着。
        // 不必回复那条 @ 本身 —— 提交 review（含批准）、新加评论、回复他，都算我接手了。
        func talk(comments: [[String: Any]] = [], reviews: [[String: Any]] = [],
                  threads: [[String: Any]] = [], body: String = "", created: String = "2026-08-01T00:00:00Z",
                  updated: String = "2026-08-22T02:00:00Z") -> [String: Any] {
            ["bodyText": body, "createdAt": created, "updatedAt": updated,
             "author": ["login": "someone"],
             "comments": ["nodes": comments], "reviews": ["nodes": reviews],
             "reviewThreads": ["nodes": threads]]
        }
        func said(_ who: String, _ t: String, _ text: String) -> [String: Any] {
            ["author": ["login": who], "createdAt": t, "bodyText": text]
        }
        func reviewed(_ who: String, _ t: String, _ text: String = "") -> [String: Any] {
            ["author": ["login": who], "submittedAt": t, "bodyText": text]
        }

        // 别人点了我，我还没说过话 → 显示，时间是被点的那一刻
        let pinged = talk(comments: [said("other", "2026-08-21T09:00:00Z", "这块 @me 看下")])
        check(Model.pingTime(pinged, account: "me") == GhParse.date(from: "2026-08-21T09:00:00Z"),
              "别人点了我、我没回 → 还欠着，时间是被点那一刻")

        // 我之后加了条评论 → 消掉（不用回那条）
        let replied = talk(comments: [said("other", "2026-08-21T09:00:00Z", "@me 看下"),
                                      said("me", "2026-08-21T10:00:00Z", "在别处说了句别的")])
        check(Model.pingTime(replied, account: "me") == nil, "我之后随便说句话就算接手，不必回那条")

        // 我之后提交了 review（批准也算「我动了」）
        let approved = talk(comments: [said("other", "2026-08-21T09:00:00Z", "@me 看下")],
                            reviews: [reviewed("me", "2026-08-21T11:00:00Z")])
        check(Model.pingTime(approved, account: "me") == nil, "提交 review（含批准）也算接手")

        // 我说完之后又被点一次 → 重新冒出来，时间换成新那次
        let again = talk(comments: [said("other", "2026-08-21T09:00:00Z", "@me 看下"),
                                    said("me", "2026-08-21T10:00:00Z", "回了"),
                                    said("other", "2026-08-21T12:00:00Z", "@me 还有个问题")])
        check(Model.pingTime(again, account: "me") == GhParse.date(from: "2026-08-21T12:00:00Z"),
              "我回完之后又被点 → 带新时间戳重新冒出来")

        // 行内评论（review thread）里点我也算 —— 大仓库里 @ 人多半发生在具体代码行上
        let inThread = talk(threads: [["comments": ["nodes": [said("other", "2026-08-21T08:00:00Z", "@me 这行")]]]])
        check(Model.pingTime(inThread, account: "me") == GhParse.date(from: "2026-08-21T08:00:00Z"),
              "行内评论里点我也算")

        // PR 正文里点我，时间算开 PR 那一刻
        let inBody = talk(body: "cc @me 帮忙看下", created: "2026-08-20T00:00:00Z")
        check(Model.pingTime(inBody, account: "me") == GhParse.date(from: "2026-08-20T00:00:00Z"),
              "PR 正文里点我也算，时间是开 PR 的时间")

        // 我自己点自己不算
        let selfPing = talk(comments: [said("me", "2026-08-21T09:00:00Z", "@me 提醒自己")])
        check(Model.pingTime(selfPing, account: "me") == nil, "我自己写的 @我 不算别人在等我")

        // 大小写不敏感 —— GitHub 的用户名不区分大小写
        let cased = talk(comments: [said("other", "2026-08-21T09:00:00Z", "@ME 看下")])
        check(Model.pingTime(cased, account: "me") != nil, "@ 的大小写不影响判断")

        // 扫不到「@我」的字样（按团队 @ 的、或在没拉到的那些评论里）：
        // 用 PR 更新时间兜底，宁可显示出来让人自己判断，也别悄悄吞掉
        let teamPing = talk(comments: [said("other", "2026-08-21T09:00:00Z", "@storage-team 看下")])
        check(Model.pingTime(teamPing, account: "me") == GhParse.date(from: "2026-08-22T02:00:00Z"),
              "扫不到明确的 @我 时不吞掉，用更新时间兜底")
        // 但我最后说话比这还新，就当处理过了
        let teamThenMe = talk(comments: [said("other", "2026-08-21T09:00:00Z", "@storage-team"),
                                         said("me", "2026-08-22T03:00:00Z", "回了")],
                              updated: "2026-08-22T02:00:00Z")
        check(Model.pingTime(teamThenMe, account: "me") == nil, "兜底情况下我说过话也算接手")

        // 接到解析上：已处理的那条根本不进清单
        var handled = base
        for (k, v) in replied { handled[k] = v }
        check(Model.parseReviewItem(handled, repo: "o/a", kind: .mentioned, account: "me") == nil,
              "已经回过话的 @ 不进清单")
        var pendingPing = base
        for (k, v) in pinged { pendingPing[k] = v }
        let pi = Model.parseReviewItem(pendingPing, repo: "o/a", kind: .mentioned, account: "me")
        check(pi != nil, "没回过话的 @ 要进清单")
        check(pi?.at == GhParse.date(from: "2026-08-21T09:00:00Z"), "排序用的是被点那一刻")
        // 另外两档不看这个规则：请我 review / 指派给我 有各自的消除方式（GitHub 自己会撤）
        check(Model.parseReviewItem(handled, repo: "o/a", kind: .requested, account: "me") != nil,
              "「请我 review」不受这条规则影响")

        // --- 忽略这一次 @ ---
        // 有些 @ 就是知会一声，不需要我回话，那就手动消掉；下次再被点还会出现
        func ping(_ n: Int, at t: Double) -> ReviewItem {
            var it = item(.mentioned, "o/a", n)
            it = ReviewItem(kind: .mentioned, repo: "o/a", number: n, title: "t", url: "u",
                            author: "other", base: "main", isDraft: false, review: nil, ci: nil,
                            at: Date(timeIntervalSince1970: t), note: "",
                            pingedAt: Date(timeIntervalSince1970: t))
            return it
        }
        let p1 = ping(1, at: 1000)
        check(Model.applyDismissed([p1], dismissed: [:]).count == 1, "没忽略过的照常显示")
        check(Model.applyDismissed([p1], dismissed: ["o/a#1": Date(timeIntervalSince1970: 1000)]).isEmpty,
              "忽略掉这一次就不显示了")
        check(Model.applyDismissed([ping(1, at: 2000)],
                                   dismissed: ["o/a#1": Date(timeIntervalSince1970: 1000)]).count == 1,
              "忽略之后又被点一次 → 重新出现")
        check(Model.applyDismissed([ping(1, at: 1000)],
                                   dismissed: ["o/a#2": Date(timeIntervalSince1970: 1000)]).count == 1,
              "忽略的是另一个 PR，不影响这个")
        // 忽略只管 @ 这一档：另两档 GitHub 自己会撤，不该被手动记账挡住
        check(Model.applyDismissed([item(.requested, "o/a", 1)],
                                   dismissed: ["o/a#1": Date(timeIntervalSince1970: 9999)]).count == 1,
              "「请我 review」不受忽略影响")
        check(Model.applyDismissed([item(.approveCI, "o/a", 1)],
                                   dismissed: ["o/a#1": Date(timeIntervalSince1970: 9999)]).count == 1,
              "「等我批准」不受忽略影响")

        // --- 忽略记录能存能读 ---
        var st = Store()
        st.dismissedPings = ["o/a#1": Date(timeIntervalSince1970: 1000)]
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .deferredToDate
        let dec = JSONDecoder()
        if let blob = try? enc.encode(st), let back = try? dec.decode(Store.self, from: blob) {
            check(back.dismissedPings["o/a#1"] == Date(timeIntervalSince1970: 1000),
                  "忽略记录能落盘、能读回来")
        } else {
            check(false, "Store 应该能编解码")
        }
        if let blob = #"{"projects":[]}"#.data(using: .utf8),
           let back = try? dec.decode(Store.self, from: blob) {
            check(back.dismissedPings.isEmpty, "老数据文件没这个字段也能读（回落成空）")
        } else {
            check(false, "缺字段的老文件应该能读")
        }

        // --- 两个视角是两套东西：看板已经在跟的，评审清单里不再出现 ---
        // 主要挡的是机器人代建的 backport：作者是 bot、把我设成 assignee，
        // 看板按 assignee 把它导进来当我的贡献，评审清单按 assignee:@me 也会搜到它
        func tracked(_ kind: ReviewItem.Kind, repo: String, queried: String, _ n: Int) -> ReviewItem {
            ReviewItem(kind: kind, repo: repo, number: n, title: "t", url: "u", author: "bot",
                       base: "main", isDraft: false, review: nil, ci: nil, at: nil,
                       note: "", queried: queried)
        }
        let onBoard = tracked(.assigned, repo: "o/a", queried: "o/a", 7)
        check(Model.excludeTracked([onBoard], tracked: ["o/a#7"]).isEmpty, "看板在跟的不进评审清单")
        check(Model.excludeTracked([onBoard], tracked: ["o/a#8"]).count == 1, "别的编号不受影响")
        check(Model.excludeTracked([onBoard], tracked: []).count == 1, "看板没跟的照常显示")
        // 仓库改过名：看板存的是旧名，GitHub 返回新名 —— 得按查询时的名字对账
        let renamedItem = tracked(.assigned, repo: "apache/maka", queried: "maka-agent/maka-agent", 7)
        check(Model.excludeTracked([renamedItem], tracked: ["maka-agent/maka-agent#7"]).isEmpty,
              "仓库改过名时按配置里的旧名对账，不会漏掉")
        check(Model.excludeTracked([renamedItem], tracked: ["apache/maka#7"]).isEmpty,
              "按新名也认")

        check(GhParse.date(from: "2026-08-20T06:14:00Z") != nil, "解析 ISO8601 时间戳")
        check(GhParse.date(from: "不是时间") == nil, "解析不了就返回 nil")
    }

    static func checkRollupTests() {
        print("CI 结论自己算:")

        func run(_ name: String, _ state: String, _ at: String = "2026-01-01T00:00:00Z") -> CheckRollup.Item {
            CheckRollup.Item(name: name, state: state, at: at)
        }

        // --- 基本分档 ---
        check(CheckRollup.state(contexts: [run("a", "SUCCESS")], suites: [CheckRollup.Suite(status: "COMPLETED")]) == "SUCCESS",
              "全绿就是通过")
        check(CheckRollup.state(contexts: [run("a", "SUCCESS"), run("b", "FAILURE")],
                                suites: [CheckRollup.Suite(status: "COMPLETED")]) == "FAILURE", "有一个红就是红")
        check(CheckRollup.state(contexts: [run("a", "SUCCESS"), run("b", "IN_PROGRESS")],
                                suites: [CheckRollup.Suite(status: "COMPLETED")]) == "PENDING", "还有在跑的就是在跑")
        check(CheckRollup.state(contexts: [run("a", "SKIPPED"), run("b", "NEUTRAL")],
                                suites: [CheckRollup.Suite(status: "COMPLETED")]) == "SUCCESS", "跳过和 neutral 不算失败")
        check(CheckRollup.state(contexts: [run("a", "FAILURE"), run("b", "QUEUED")],
                                suites: [CheckRollup.Suite(status: "COMPLETED")]) == "FAILURE", "红优先于在跑 —— 已经该你动手了")

        // --- 没有 CI 的仓库：unknown，不是「通过」 ---
        check(CheckRollup.state(contexts: [], suites: [] as [CheckRollup.Suite]) == nil, "一条 check 都没有时是 unknown")

        // --- 关键一条：有 suite 在跑，就别说通过 ---
        // 刚推完代码，跑得快的先报绿，重活还在跑 —— 这正是「CI 没跑完却显示通过」
        check(CheckRollup.state(contexts: [run("title-check", "SUCCESS")],
                                suites: [CheckRollup.Suite(status: "COMPLETED"), CheckRollup.Suite(status: "IN_PROGRESS")]) == "PENDING",
              "还有 suite 在跑时不算通过，哪怕已报上来的全绿")

        // 但 QUEUED 不能算 —— 仓库上装的每个 GitHub App 都会挂一个 suite，
        // 多数一条 check run 都不发，永远停在 QUEUED。实测 StarRocks 每个 commit
        // 都挂着 5 个这样的空 suite，认 QUEUED 的话早就合并的 PR 会永远显示「CI 运行中」
        check(CheckRollup.state(contexts: [run("a", "SUCCESS")],
                                suites: [CheckRollup.Suite(status: "COMPLETED"), CheckRollup.Suite(status: "QUEUED")]) == "SUCCESS",
              "空转的 QUEUED suite 不算在跑（装了 App 就会有，永远不完成）")
        check(CheckRollup.state(contexts: [], suites: [CheckRollup.Suite(status: "QUEUED")]) == nil,
              "只有空 suite、一条 check 都没有，是 unknown")

        // --- 另一条关键：同名多次尝试只算最新的 ---
        // 实测 60611：54 条 context 去重后只剩 34 项，20 个名字各有两次尝试；
        // 旧的那次 FAILURE 会把 GitHub 的 rollup 带成 FAILURE
        let retried = [
            run("backport-check", "FAILURE", "2026-08-17T11:40:00Z"),
            run("backport-check", "SUCCESS", "2026-08-17T12:10:00Z"),
        ]
        check(CheckRollup.state(contexts: retried, suites: [CheckRollup.Suite(status: "COMPLETED")]) == "SUCCESS",
              "重跑绿了就是绿了，旧的那条红不算数")
        check(CheckRollup.state(contexts: retried.reversed(), suites: [CheckRollup.Suite(status: "COMPLETED")]) == "SUCCESS",
              "跟 GitHub 返回的先后顺序无关，看时间戳")
        let regressed = [
            run("BUILD", "SUCCESS", "2026-08-17T11:40:00Z"),
            run("BUILD", "FAILURE", "2026-08-17T12:10:00Z"),
        ]
        check(CheckRollup.state(contexts: regressed, suites: [CheckRollup.Suite(status: "COMPLETED")]) == "FAILURE",
              "反过来也认：重跑挂了就是挂了")

        // --- 解析 GraphQL 两种节点 ---
        let cr = CheckRollup.Item(json: ["name": "BUILD", "status": "COMPLETED",
                                         "conclusion": "SUCCESS", "startedAt": "2026-08-17T11:00:00Z"])
        check(cr.name == "BUILD" && cr.state == "SUCCESS", "CheckRun 优先取 conclusion")
        let running = CheckRollup.Item(json: ["name": "BUILD", "status": "IN_PROGRESS",
                                              "conclusion": NSNull(), "startedAt": ""])
        check(running.state == "IN_PROGRESS", "还没跑完时 conclusion 是空的，得看 status")
        let sc = CheckRollup.Item(json: ["context": "ci/jenkins", "state": "PENDING",
                                         "createdAt": "2026-08-17T11:00:00Z"])
        check(sc.name == "ci/jenkins" && sc.state == "PENDING", "老式 StatusContext 也认")

        // --- 必过项从来没报上来：界面上那条 Expected ---
        // 实测 mirrorship#60611：分支保护要求 14 项，commit 上报了 34 个 check，
        // 其中 8 项必过的一次都没露面（ADMIT TEST / BE UT / Clang-Tidy / FE UT ...），
        // GitHub 界面显示「Some checks haven't completed yet — 8 expected」，
        // 而所有 check API（含 gh pr checks）都看不见这 8 项。
        let reported = [run("BUILD", "SKIPPED"), run("behavior-check", "SUCCESS")]
        check(CheckRollup.state(contexts: reported, suites: [CheckRollup.Suite(status: "COMPLETED")],
                                required: ["BUILD", "behavior-check"]) == "SUCCESS",
              "必过项都报上来了才算通过")
        check(CheckRollup.state(contexts: reported, suites: [CheckRollup.Suite(status: "COMPLETED")],
                                required: ["BUILD", "behavior-check", "BE UT"]) == "PENDING",
              "有必过项一次都没露面 —— 那是还没轮到它跑，不是通过")
        check(CheckRollup.state(contexts: reported, suites: [CheckRollup.Suite(status: "COMPLETED")],
                                required: []) == "SUCCESS",
              "拿不到必过项清单时不瞎猜，按已报上来的算")
        check(CheckRollup.state(contexts: [run("a", "FAILURE")], suites: [CheckRollup.Suite(status: "COMPLETED")],
                                required: ["b"]) == "FAILURE",
              "已经有红的了，就别说还在跑 —— 该你动手了")
        // 必过项被 SKIPPED 也算数：GitHub 的分支保护就是这么认的
        check(CheckRollup.state(contexts: [run("BUILD", "SKIPPED")], suites: [CheckRollup.Suite(status: "COMPLETED")],
                                required: ["BUILD"]) == "SUCCESS", "必过项报了 SKIPPED 也算报过了")

        // --- workflow 等维护者批准：不是「跑完了」，也不是「还在跑」 ---
        // 线上撞到过：apache/maka #3448/#3430 是 fork PR，CI 要维护者点「批准运行」。
        // 那时 suite 长这样：status=COMPLETED、conclusion=ACTION_REQUIRED、0 条 check run。
        // 我第一版只看 status，判成「跑完了什么都不会来」，差点把它改成「未知」——
        // 而 GitHub 页面上明写着 1 workflow awaiting approval。
        let awaiting = [CheckRollup.Suite(status: "COMPLETED", conclusion: "ACTION_REQUIRED")]
        check(CheckRollup.state(contexts: [], suites: awaiting, required: ["test"]) == "ACTION_REQUIRED",
              "suite 的 conclusion 是 ACTION_REQUIRED → 等批准")
        check(CheckRollup.state(contexts: [], suites: awaiting) == "ACTION_REQUIRED",
              "没配必过项也一样认")
        check(Model.classify(LivePR(title: "", state: "OPEN", review: "APPROVED",
                                    ci: "ACTION_REQUIRED"), blocked: false) == .needsCIApproval,
              "已批准但 CI 等批准 → 显示「CI 等批准」，不是「可合并」")
        check(PRStatus.needsCIApproval.label == "CI 等批准", "有自己的名字，不跟「运行中」混")
        // 等批准不是失败
        check(!CheckRollup.failed.contains("ACTION_REQUIRED"), "ACTION_REQUIRED 不算失败")
        // check run 层面也认（有些工作流是在 run 上标的）
        check(CheckRollup.state(contexts: [run("gate", "ACTION_REQUIRED")],
                                suites: [CheckRollup.Suite(status: "COMPLETED")]) == "ACTION_REQUIRED",
              "check run 的 conclusion 是 ACTION_REQUIRED 也认")
        // 一码归一码：全绿的 suite 不该被误判
        check(CheckRollup.state(contexts: [run("a", "SUCCESS")],
                                suites: [CheckRollup.Suite(status: "COMPLETED", conclusion: "SUCCESS")])
              == "SUCCESS", "正常跑完的不受影响")
        // 上游还没合时，「等依赖」更靠前 —— 那件事得先解决
        check(Model.classify(LivePR(title: "", state: "OPEN", review: "APPROVED",
                                    ci: "ACTION_REQUIRED"), blocked: true) == .blocked,
              "被上游挡着时先说「等依赖」")

        // --- 解析分支保护的响应 ---
        let branchJSON = """
        {"name":"main","protected":true,"protection":{"enabled":true,
         "required_status_checks":{"enforcement_level":"non_admins",
         "contexts":["BE UT","Clang-Tidy","ADMIT TEST"]}}}
        """
        check(CheckRollup.requiredContexts(fromBranchJSON: Data(branchJSON.utf8))
              == ["BE UT", "Clang-Tidy", "ADMIT TEST"], "解析出必过项清单")
        check(CheckRollup.requiredContexts(fromBranchJSON: Data(#"{"name":"x","protected":false}"#.utf8)).isEmpty,
              "分支没保护时是空集")
        check(CheckRollup.requiredContexts(fromBranchJSON: Data("不是 JSON".utf8)).isEmpty,
              "响应坏了也不炸")

        // --- 接到 classify 上，界面才会变 ---
        var lv = LivePR(); lv.state = "OPEN"; lv.review = "APPROVED"
        lv.ci = CheckRollup.state(contexts: [run("fast", "SUCCESS")], suites: [CheckRollup.Suite(status: "IN_PROGRESS")])
        check(Model.classify(lv, blocked: false) == .ciRunning,
              "已批准但 CI 还在跑，显示的是「CI 运行中」而不是「可合并」")
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
