import SwiftUI

// MARK: - 快捷操作菜单几何（视图与子窗口位置共用同一套计算）
//
// 约定（改这里就够，控制器不再硬编码任何数字）：
//   · 菜单是一行圆形按钮，与面板底栏的触发钮同一行、同一尺寸，从触发钮右侧依次向右弹出；
//   · 尺寸固定（26pt，与触发钮一致），不随面板缩放——永远与触发钮等大等圆；
//   · 所有按钮完全统一：同尺寸、同材质、同描边、同字重；
//   · 悬停时才出现一枚灰底黑字的提示条（按钮正下方）。

enum BoxFanGeometry {
    /// 触发钮中心距面板右下角的内缩。
    /// footer：水平 12pt 边距 + 26pt 按钮的一半 = 25；垂直 10pt 边距 + 一半 = 23。
    static let triggerInset = CGSize(width: 25, height: 23)

    /// 按钮直径：与面板底栏触发钮完全一致。
    static let buttonSize: CGFloat = 26
    /// 相邻按钮中心距（留 14pt 间隙）。
    static let pitch: CGFloat = 40
    /// 首个按钮中心与面板右缘的距离。
    static let leadingGap: CGFloat = 8
    /// 悬停提示条的高度与它到按钮底部的间距。
    static let tipHeight: CGFloat = 16
    static let tipGap: CGFloat = 7
    /// 左右两侧预留的空白，给首尾按钮的提示条溢出留位置。
    /// 注意：窗口左缘 = 面板右缘 + leadingGap - sidePad，会压住面板右下角与触发钮的右半；
    /// 被子窗口压住的区域靠宿主视图穿透 + 控制器全局监控兜底（见 BoxShelf 触发钮命中分支）。
    static let sidePad: CGFloat = 30
    static let topPad: CGFloat = 4

    static func layout(count: Int) -> BoxFanLayout {
        let n = max(count, 1)
        let anchor = CGPoint(x: sidePad + buttonSize / 2, y: topPad + buttonSize / 2)
        let size = CGSize(
            width: anchor.x + CGFloat(n - 1) * pitch + buttonSize / 2 + sidePad,
            height: anchor.y + buttonSize / 2 + tipGap + tipHeight + topPad
        )
        return BoxFanLayout(
            count: n,
            buttonSize: buttonSize,
            pitch: pitch,
            tipHeight: tipHeight,
            tipGap: tipGap,
            anchor: anchor,
            size: size
        )
    }
}

/// 一次展开所需的全部布局数据（SwiftUI 坐标：原点在窗口左上角，y 向下）。
struct BoxFanLayout {
    let count: Int
    let buttonSize: CGFloat
    let pitch: CGFloat
    let tipHeight: CGFloat
    let tipGap: CGFloat
    /// 首个按钮中心在窗口内的位置。
    let anchor: CGPoint
    let size: CGSize

    var iconFontSize: CGFloat { 12.5 }
    var tipFontSize: CGFloat { 10.5 }

    /// 第 index 个按钮中心：同一水平线上等距向右排布。
    func center(index: Int) -> CGPoint {
        CGPoint(x: anchor.x + pitch * CGFloat(index), y: anchor.y)
    }
}

// MARK: - 快捷操作菜单视图（渲染在面板右侧的透明子窗口里）

struct BoxFanView: View {
    let model: BoxShelfModel
    let close: () -> Void

    @State private var menuOpen = false

    /// 供子窗口的命中测试使用（只让按钮区域接收点击，其余透明区域穿透）。
    var layout: BoxFanLayout {
        BoxFanGeometry.layout(count: actions.count)
    }

    private var actions: [BoxQuickAction] {
        model.primaryActions + model.commonActions
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                menuButton(action, index: index)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        // 首帧全部收拢在首个按钮位置，下一拍向右依次弹出
        .onAppear {
            menuOpen = false
            DispatchQueue.main.async { menuOpen = true }
        }
    }

    private func menuButton(_ action: BoxQuickAction, index: Int) -> some View {
        let open = menuOpen
        let hovered = model.hoveredFanAction == action.id
        let target = layout.center(index: index)
        let d = layout.buttonSize
        return Button {
            if action == .share {
                // 分享面板要锚定在本按钮上（见控制器 showSharePicker），菜单必须保持展开；
                // 点外部 / Esc 时监控会照常收起菜单
                model.perform(action)
            } else {
                close()
                model.perform(action)
            }
        } label: {
            Image(systemName: action.icon)
                .font(.system(size: layout.iconFontSize, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: d, height: d)
                // 统一圆形底：磨砂玻璃，任何壁纸上都清晰；悬停时略微提亮
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill(Color.primary.opacity(hovered ? 0.12 : 0)))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                }
                // 悬停提示：灰底黑字，落在按钮正下方
                .overlay(alignment: .bottom) {
                    Text(model.actionTitle(action))
                        .font(.system(size: layout.tipFontSize, weight: .medium))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .frame(height: layout.tipHeight)
                        .background(
                            Color(white: 0.86),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                        .shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 1)
                        .offset(y: layout.tipGap + layout.tipHeight)
                        .opacity(hovered ? 1 : 0)
                        .scaleEffect(hovered ? 1 : 0.94, anchor: .top)
                        .allowsHitTesting(false)
                }
                .contentShape(Circle())
                .scaleEffect(hovered ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .disabled(model.compressFraction != nil || !model.compressStatus.isEmpty)
        .onHover { hovering in
            model.hoveredFanAction = hovering ? action.id : (model.hoveredFanAction == action.id ? nil : model.hoveredFanAction)
            if hovering { model.controller?.touchActivity() }
        }
        .position(open ? target : layout.anchor)
        .opacity(open ? 1 : 0)
        .animation(
            .spring(response: 0.2 * BoxShowAnimation.speedMultiplier, dampingFraction: 0.7),
            value: model.hoveredFanAction
        )
        // 向右错峰弹出：最靠近触发钮的按钮先出，依次向右
        .animation(
            .spring(response: 0.3 * BoxShowAnimation.speedMultiplier, dampingFraction: 0.74)
                .delay(Double(index) * 0.03 * BoxShowAnimation.speedMultiplier),
            value: menuOpen
        )
    }
}

// MARK: - 菜单子窗口的宿主视图

/// 只让按钮（含少量余量）区域接收鼠标，其余透明区域一律穿透到下层窗口。
/// 这样菜单即使与面板右下角重叠，也不会吞掉触发钮、垃圾桶等控件的点击。
final class BoxFanHostingView: NSHostingView<BoxFanView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        // NSHostingView 是 flipped 视图：convert 后已是「左上原点」的 SwiftUI 坐标，不能再翻转一次
        let p = isFlipped ? local : NSPoint(x: local.x, y: bounds.height - local.y)
        let layout = rootView.layout
        let half = layout.buttonSize / 2 + 5
        for index in 0..<layout.count {
            let center = layout.center(index: index)
            if abs(p.x - center.x) <= half, abs(p.y - center.y) <= half {
                return super.hitTest(point)
            }
        }
        return nil
    }
}
