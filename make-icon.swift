import AppKit

// 程序化绘制 App 图标：图形是 PR 的树形分支（和界面里的缩进连线同一套视觉），
// 下方是 WLOBY + PR 字标，PR 用绿色区分 —— 绿色在这个 App 里就是「可合并」的意思。
//
// 关键点：小尺寸不画字标。macOS 图标常以 16/32px 出现，七个字符横排在那个尺寸下
// 只会糊成一团。.icns 允许每个尺寸用不同画面，所以大尺寸给完整设计，小尺寸只留图形。

let wordmarkMinSize: CGFloat = 128

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let bgTop = color(0x2E3D6B)
let bgBottom = color(0x141B33)
let barLight = color(0xFFFFFF, 0.93)
let barReady = color(0x35C759)      // 和界面里「可合并」的绿一致
let lineColor = color(0xFFFFFF, 0.42)
let textMain = color(0xFFFFFF)
let textAccent = barReady

func render(size px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // 画布是 bottom-left 原点，统一用「从顶部量」的坐标再翻过去
    func fromTop(_ y: CGFloat) -> CGFloat { s - y }
    func box(x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat) -> NSRect {
        NSRect(x: x, y: fromTop(top + h), width: w, height: h)
    }

    // 圆角方块底：macOS 图标本体不铺满画布，四周留白
    let inset = s * 0.085
    let side = s - inset * 2
    let plate = NSRect(x: inset, y: inset, width: side, height: side)
    let radius = side * 0.2235
    let platePath = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
    platePath.addClip()
    NSGradient(starting: bgTop, ending: bgBottom)!.draw(in: plate, angle: -90)

    let showWordmark = s >= wordmarkMinSize
    // 16px 下三层必糊，降到两层保住「有分支」这个信息
    let rows = px <= 16 ? 2 : 3

    // 细线和细条在小尺寸会退化到亚像素直接消失，给下限
    let barH = max(side * 0.095, 2)
    let lineW = max(side * 0.028, 1)
    let pitch = barH + side * 0.075
    let rightEdge = side * 0.845
    let indents: [CGFloat] = (0..<rows).map { side * (0.145 + 0.12 * CGFloat($0)) }

    // 以下坐标一律相对圆角块顶端（画的时候再加 inset），别和画布坐标混着用
    let blockH = pitch * CGFloat(rows - 1) + barH
    // 有字标时给下方留出文字位置，上下留白配平；没字标就整块居中
    let firstTop = showWordmark ? side * 0.19 : (side - blockH) / 2
    let tops: [CGFloat] = (0..<rows).map { firstTop + pitch * CGFloat($0) }
    let barRadius = barH / 2

    // 先画连接线，压在条下面
    lineColor.setFill()
    for i in 1..<rows {
        let parentX = inset + indents[i - 1] + side * 0.038
        let parentBottom = inset + tops[i - 1] + barH
        let childCenter = inset + tops[i] + barH / 2
        // 竖线：从父条底部落到子条中线
        NSBezierPath(rect: box(
            x: parentX - lineW / 2, top: parentBottom,
            w: lineW, h: childCenter - parentBottom
        )).fill()
        // 横线：拐进子条左端
        NSBezierPath(rect: box(
            x: parentX - lineW / 2, top: childCenter - lineW / 2,
            w: (inset + indents[i]) - parentX + lineW / 2, h: lineW
        )).fill()
    }

    for i in 0..<rows {
        // 最后一条用绿色：这个 App 的落点就是「哪个 PR 可以合并了」
        (i == rows - 1 ? barReady : barLight).setFill()
        let r = box(
            x: inset + indents[i], top: inset + tops[i],
            w: rightEdge - indents[i], h: barH
        )
        NSBezierPath(roundedRect: r, xRadius: barRadius, yRadius: barRadius).fill()
    }

    if showWordmark {
        let fontSize = side * 0.145
        let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: fontSize * 0.02]
        let text = NSMutableAttributedString(string: "WLOBY", attributes: attrs)
        text.addAttribute(.foregroundColor, value: textMain,
                          range: NSRange(location: 0, length: 5))
        let pr = NSMutableAttributedString(string: "PR", attributes: attrs)
        pr.addAttribute(.foregroundColor, value: textAccent,
                        range: NSRange(location: 0, length: 2))
        // 两段之间留一点气口，颜色差别才不显得是一个词
        let gap = NSAttributedString(string: " ", attributes: [.font: font])
        text.append(gap)
        text.append(pr)

        // 全是大写字母，用 capHeight 而不是行高来定位 —— 行高含上下留白，
        // 按它居中会让字看起来偏低、和图形之间空出一块
        let tw = text.size().width
        let capH = font.capHeight
        let glyphCenter = inset + side * 0.757
        let baseline = fromTop(glyphCenter + capH / 2)
        text.draw(at: NSPoint(
            x: inset + (side - tw) / 2,
            y: baseline + font.descender
        ))
    }

    return rep.representation(using: .png, properties: [:])!
}

// MARK: 输出 iconset

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "PrWaiter.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// 同一像素尺寸可能对应两个文件名（如 32 既是 16@2x 也是 32x32）
let entries: [(px: Int, names: [String])] = [
    (16, ["icon_16x16.png"]),
    (32, ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64, ["icon_32x32@2x.png"]),
    (128, ["icon_128x128.png"]),
    (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024, ["icon_512x512@2x.png"]),
]

for e in entries {
    let data = render(size: e.px)
    for name in e.names {
        try! data.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
    print("  \(e.px)x\(e.px)\(CGFloat(e.px) >= wordmarkMinSize ? "" : "（无字标）") → \(e.names.joined(separator: ", "))")
}
print("iconset 已生成：\(out)")
