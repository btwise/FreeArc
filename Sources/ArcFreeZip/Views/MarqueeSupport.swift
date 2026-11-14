import SwiftUI
import AppKit

/// 条目在浏览区坐标系里的位置（框选命中测试用）。
struct EntryFrameKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// 上报条目 frame。`space` 必须与所在 MarqueeHost 的坐标空间名一致。
    func entryFrame(path: String, in space: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: EntryFrameKey.self,
                    value: [path: proxy.frame(in: .named(space))]
                )
            }
        )
    }
}

/// 各浏览视图的坐标空间名（同一窗口内需唯一）。
enum MarqueeSpace {
    static let list = "afz.marquee.list"
    static let icon = "afz.marquee.icon"
    static let miniList = "afz.marquee.mini.list"
    static let miniIcon = "afz.marquee.mini.icon"
    static let volume = "afz.marquee.volume"
}

/// 浏览区容器：提供访达式的空白区交互。
///
/// - 在空白处按下拖动 → 橡皮筋框选（普通替换、⌘ 追加、⇧ 从锚点连续扩展）
/// - 在空白处单击 → 取消全部选择
/// - 在空白处右键 → 全选 / 取消全选
///
/// 条目自身的手势（点选、双击、拖出）不受影响：手势挂在空白背景层，
/// 条目区域被条目自己的 contentShape 接住，不会落到背景层。
struct MarqueeHost<Content: View>: View {
    let browser: ArchiveBrowser
    /// 坐标空间名（同时用于 DragGesture 与条目 frame 上报）。
    let space: String
    /// 空白层最小高度：内容不满一屏时也要能框选/取消选择。
    var minHeight: CGFloat = 0
    let content: () -> Content

    @State private var origin: CGPoint?
    @State private var currentPoint: CGPoint?
    @State private var baseSelection: Set<String> = []
    @State private var frames: [String: CGRect] = [:]

    init(
        browser: ArchiveBrowser,
        space: String,
        minHeight: CGFloat = 0,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.browser = browser
        self.space = space
        self.minHeight = minHeight
        self.content = content
    }

    private var selectionRect: CGRect? {
        guard let origin, let currentPoint else { return nil }
        return CGRect(
            x: min(origin.x, currentPoint.x),
            y: min(origin.y, currentPoint.y),
            width: abs(currentPoint.x - origin.x),
            height: abs(currentPoint.y - origin.y)
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 空白背景层（条目之间的间隙、列表下方的空白都落在这里）
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .named(space))
                        .onChanged(handleDrag)
                        .onEnded { _ in
                            origin = nil
                            currentPoint = nil
                        }
                )
                .onTapGesture { browser.clearSelection() }
                .contextMenu {
                    Button("全选") { browser.selectAllVisible() }
                        .disabled(browser.visibleNodes.isEmpty)
                    Button("取消全选") { browser.clearSelection() }
                        .disabled(browser.selectedPaths.isEmpty)
                }

            content()
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .coordinateSpace(name: space)
        .onPreferenceChange(EntryFrameKey.self) { frames = $0 }
        .overlay(alignment: .topLeading) {
            if let rect = selectionRect, rect.width > 1, rect.height > 1 {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.selectionBlue.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Theme.selectionBlue.opacity(0.8), lineWidth: 1)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func handleDrag(_ value: DragGesture.Value) {
        let flags = NSEvent.modifierFlags
        if origin == nil {
            origin = value.startLocation
            baseSelection = flags.contains(.command) ? browser.selectedPaths : []
        }
        currentPoint = value.location
        guard let rect = selectionRect else { return }
        let hits = Set(frames.filter { rect.intersects($0.value) }.map(\.key))
        let anchor = browser.selectionAnchorPath ?? browser.selectedPaths.first
        browser.applyMarqueeSelection(
            hits: hits,
            base: baseSelection,
            extendFrom: flags.contains(.shift) ? anchor : nil
        )
    }
}
