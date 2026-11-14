import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

// MARK: - 文件盒面板（原创设计）
//
// 功能契约：拖放登记 / 叠加⇄逐个 / 右键 8 项 / 快速压缩 / 闲置收起 / 图钉；
// 视觉自有主张：默认墨色（黑白灰）中性配色 + 顶部渐变发丝线表达个性（不做整壳彩色）；
// 其余 8 色保留在偏好里，供设置面板将来开放。触发钮用省略号，克制而不喧哗。
// 条目图标一律走 macOS 原生能力：QuickLook 缩略图优先，退回 NSWorkspace 文件类型图标。

/// 原生文件图标：有系统缩略图（QuickLook）显示真实预览，否则显示访达同款文件类型图标。
struct BoxFileIconView: View {
    let url: URL
    var isDirectory: Bool
    var side: CGFloat
    /// 叠加态里被压在底下的卡片可关掉缩略图，省去无谓的 QL 生成。
    var useThumbnail: Bool = true

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                // 真实缩略图：垫白色纸卡（与访达的文档卡质感一致）
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .padding(5)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
            } else {
                Image(nsImage: fallback)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            }
        }
        .frame(width: side, height: side)
        // 尺寸跨档（32pt 一档）时重新生成更高清的缩略图
        .task(id: "\(url.path)|\(Int(side / 32))") {
            guard useThumbnail, thumbnail == nil || thumbnail!.size.width < side * 1.5, !isDirectory else { return }
            thumbnail = await Self.loadThumbnail(url: url, side: side)
        }
    }

    /// 访达同款文件类型图标（含文件夹、无后缀文件）。
    private var fallback: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func loadThumbnail(url: URL, side: CGFloat) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: side * scale, height: side * scale),
                scale: scale,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
    }
}

/// 收集网格里每张卡片的位置（框选求交用）。
private struct BoxCardFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct BoxShelfView: View {
    @Bindable var model: BoxShelfModel
    var preferences: BoxShelfPreferences

    @State private var contentHover = false
    /// 网格态当前悬停的卡片（驱动右上角删除角标）。
    @State private var hoveredCardID: String?
    /// 框选起点与当前矩形（网格坐标系）。
    @State private var marqueeStart: CGPoint?
    @State private var marqueeRect: CGRect?
    /// 卡片在网格坐标系里的矩形（id → frame），框选求交用。
    @State private var cardFrames: [String: CGRect] = [:]

    private var accent: Color { preferences.color.primarySwiftUI }
    private var accentSoft: Color { preferences.color.softSwiftUI }
    /// 主色上的前景色（墨色配色下为黑底白字 / 白底黑字的反色）。
    private var onAccent: Color { preferences.color.onPrimarySwiftUI }
    /// 墨色（默认黑白）配色：图标不做半透明淡化，保持黑白对比度。
    private var isMono: Bool { preferences.color.isMono }

    // MARK: 颜色管理（外壳背景 / 内层容器 / 图标 / 文字全部纳入 BoxColor，浓度=整体着色强度）
    // 墨色配色走中性材质保持黑白；彩色配色按浓度给外壳、容器、图标、文字染色。

    /// 外壳着色层：叠在 regularMaterial 上（0%=纯净材质，100%=浓艳彩壳）。
    /// 墨色只给极轻的中性灰着色，保持黑白主题的克制。
    private var shellTint: Color {
        accent.opacity(isMono ? preferences.tintOpacity * 0.10 : preferences.tintOpacity * 0.32)
    }

    /// 内层容器（拖放区 / 显示区 / 胶囊底）：比外壳亮一档的色系着色。
    private var innerContainerColor: Color {
        isMono
            ? Theme.cardBackground.opacity(0.6)
            : accentSoft.opacity(0.28 + preferences.tintOpacity * 0.45)
    }

    /// 次级文字（副标题、大小、状态说明）：彩色系用主色淡化，墨色维持中性灰。
    private var secondaryText: Color {
        isMono ? Theme.textSecondary : accent.opacity(0.78)
    }

    /// 内层容器描边（虚线拖放框、显示区细线）：彩色时用主色淡描。
    private var innerBorder: Color {
        isMono ? Theme.dividerColor : accent.opacity(0.30)
    }

    /// 头部幽灵圆钮底色。
    private var ghostBackground: Color {
        isMono ? Theme.iconButtonBackground.opacity(0.7) : accentSoft.opacity(0.5)
    }

    /// 底部工具条底色：比外壳深一档（与内层亮容器区分三层）。
    private var footerBackground: Color {
        isMono ? Theme.panelBackground.opacity(0.6) : accent.opacity(preferences.tintOpacity * 0.16)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            content
            // 空态不显示底部工具条（压缩/清空无意义，避免一排灰按钮）
            if !model.isEmpty {
                footerBar
            }
        }
        // 尺寸随面板窗口伸缩（默认 300×430，用户可拖到 460×680，控制器负责记忆）
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 外壳：材质底 + 所选色着色层（颜色管理：背景随色系与浓度联动）
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(shellTint)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.dividerColor, lineWidth: 0.5)
        )
        .overlay(alignment: .top) { hairline }
        .overlay(alignment: .top) { toastOverlay }
        // 托盘弹出动画（pop 模式）：右上角锚点缩放 + 淡入，由控制器驱动模型状态
        .scaleEffect(model.appearScale, anchor: .topTrailing)
        .opacity(model.appearOpacity)
        .animation(.spring(response: 0.32 * BoxShowAnimation.speedMultiplier, dampingFraction: 0.78), value: model.appearScale)
        .animation(.easeOut(duration: 0.18 * BoxShowAnimation.speedMultiplier), value: model.appearOpacity)
        // 拖入文件已下沉到 AppKit 层（BoxDropCatcherView 包住本视图）：
        // SwiftUI .onDrop 会被 DragGesture 吞掉（macOS 已知坑）
        .simultaneousGesture(TapGesture().onEnded { model.controller?.touchActivity() })
    }

    // 顶部个性化发丝渐变线（色彩浓度偏好控制不透明度）
    private var hairline: some View {
        LinearGradient(
            colors: [accentSoft, accent, accentSoft],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 3)
        .opacity(preferences.tintOpacity)
        .allowsHitTesting(false)
    }

    // MARK: 头部

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isMono ? Theme.textPrimary : accent.opacity(max(0.55, preferences.tintOpacity)))
            VStack(alignment: .leading, spacing: 0) {
                Text("文件盒")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(model.isEmpty ? "拖入文件，随手打包" : "\(model.count) 个条目")
                    .font(.system(size: 11, weight: .medium))
                    // 副标题纳入颜色管理：彩色系用主色淡化（在着色外壳上保证可读）
                    .foregroundStyle(secondaryText)
            }
            Spacer()
            // 图钉：常驻开关（功能：禁用闲置收起与点击外部关闭）
            ghostButton(
                icon: model.lastPinned ? "pin.fill" : "pin",
                active: model.lastPinned
            ) {
                model.lastPinned.toggle()
                model.controller?.touchActivity()
            }
            .help("保持显示")
            ghostButton(icon: "xmark", active: false) {
                model.controller?.hidePanel()
            }
            .help("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        // 窗口移动改由标题栏拖动（内容区已让给框选）
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in model.controller?.dragPanel(by: value.translation) }
                .onEnded { _ in model.controller?.endPanelDrag() }
        )
    }

    private func ghostButton(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? accent : Theme.textSecondary)
                .frame(width: 24, height: 24)
                .background(ghostBackground, in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 内容区

    @ViewBuilder
    private var content: some View {
        if model.isEmpty {
            emptyDropZone
        } else if model.showsGrid {
            gridContent
        } else {
            stackContent
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 12) {
            // 图标纳入颜色管理：随色系着色（悬停投放时满饱和点亮）
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(model.isDropActive ? accent : accent.opacity(model.isDropActive ? 1 : 0.72))
            Text(model.isDropActive ? "松手登记到文件盒" : "拖入文件开始")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("文件只登记引用，不会移动或改动")
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background {
            // 内层拖拽区容器：随色系着色（颜色管理），悬停投放时点亮满饱和主色
            RoundedRectangle(cornerRadius: 14)
                .fill(model.isDropActive ? AnyShapeStyle(accent.opacity(0.22)) : AnyShapeStyle(innerContainerColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    model.isDropActive ? accent : innerBorder,
                    style: StrokeStyle(lineWidth: 1.4, dash: [5, 4])
                )
        }
        .padding(.horizontal, 12)
        .padding(.bottom, model.isEmpty ? 12 : 10)
        .animation(.easeOut(duration: 0.15), value: model.isDropActive)
    }

    // 叠加态（默认）：macOS 原生文件图标摞成一叠，翻页把下一个文件翻到顶。
    // 显示区是独立内层容器（与外层材质颜色分层）并随面板高度伸缩；
    // 图标尺寸随显示区实时联动（拖大面板 = 看更大的文件卡）。
    // 注：快捷操作条已从显示区下方移除（之后改由窗口左下角按钮弹出），
    // 释放的高度全部还给显示容器，让文件图标尽可能大。
    private var stackContent: some View {
        VStack(spacing: 0) {
            if let item = model.focusedItem {
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        // 图标随显示区实时缩放：宽度占 70%、高度占 88%，封顶 260
                        let side = min(geo.size.width * 0.70, geo.size.height * 0.88, 260)
                        ZStack {
                            ForEach(Array(model.items.enumerated().reversed()), id: \.element.id) { index, stackItem in
                                stackCard(stackItem, relative: Double(index - model.focusIndex), side: side)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .overlay {
                            if model.count > 1 {
                                HStack {
                                    pagingButton("chevron.left") { model.moveFocus(-1) }
                                    Spacer()
                                    pagingButton("chevron.right") { model.moveFocus(1) }
                                }
                                .padding(.horizontal, 10)
                            }
                        }
                    }

                    VStack(spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 14)
                        Text(item.sizeText)
                            .font(.system(size: 10))
                            .foregroundStyle(secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 10)
                .background(
                    // 内层显示容器：随色系着色（颜色管理），与底部工具条形成三层结构
                    RoundedRectangle(cornerRadius: 14)
                        .fill(innerContainerColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(innerBorder, lineWidth: 0.5)
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
                // 悬停显示区时，聚焦文件右上角出删除角标（气泡展开时让位给操作板）
                .overlay(alignment: .topTrailing) {
                    if contentHover && !model.actionBubblePresented {
                        removeBadge { model.remove(item) }
                            .padding(.horizontal, 20)
                            .padding(.top, 14)
                            .transition(.opacity)
                    }
                }

                if model.count > 1 {
                    pageDots
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                } else {
                    Spacer().frame(height: 8)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: contentHover)
        .onHover { hovering in
            contentHover = hovering
            if hovering { model.controller?.touchActivity() }
        }
    }

    /// 摞在叠里的一张卡片：聚焦的在最上，其余向后下方退开并渐隐（弹簧动画）。
    /// 尺寸由显示区 GeometryReader 实时给出（窗口拖拽过程中即时联动）。
    private func stackCard(_ item: BoxItem, relative rel: Double, side: CGFloat) -> some View {
        let distance = abs(rel)
        return BoxFileIconView(
            url: item.url,
            isDirectory: item.isDirectory,
            side: side,
            useThumbnail: rel == 0
        )
        .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 3)
        .scaleEffect(1 - min(distance, 3) * 0.06)
        .offset(x: rel * 15, y: rel * 10)
        .rotationEffect(.degrees(rel * 1.4))
        .opacity(distance > 3 ? 0 : max(0, 1 - distance * 0.22))
        .zIndex(rel == 0 ? 10 : -distance)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: model.focusIndex)
    }

    private func pagingButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent.opacity(0.8))
                .frame(width: 24, height: 24)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var pageDots: some View {
        HStack(spacing: 4) {
            ForEach(model.items.indices, id: \.self) { index in
                Capsule()
                    .fill(index == model.focusIndex ? accent : Theme.dividerColor)
                    .frame(width: index == model.focusIndex ? 12 : 4, height: 4)
            }
        }
    }

    // 逐个态：全部条目各自成卡，显示访达同款文件类型图标/缩略图，可点选。
    // 卡片与预览随面板宽度实时放大（默认 380 宽时两列大卡），条目少时居中、多时滚动。
    private var gridContent: some View {
        GeometryReader { geo in
            // 卡片宽度随面板宽度联动（120…180，默认宽度下约 141 → 两列）
            let cardSide = min(180, max(120, geo.size.width * 0.42))
            ZStack(alignment: .topLeading) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSide), spacing: 10)], spacing: 10) {
                        ForEach(model.items) { item in
                            gridCard(item, iconSide: cardSide * 0.58)
                                // 记录每张卡在网格坐标系里的位置，供框选求交
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: BoxCardFrameKey.self,
                                            value: [item.id: proxy.frame(in: .named("boxGrid"))]
                                        )
                                    }
                                )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height - 24, alignment: .center)
                }

                // 框选矩形
                if let rect = marqueeRect {
                    Rectangle()
                        .fill(accent.opacity(0.12))
                        .overlay(Rectangle().strokeBorder(accent.opacity(0.75), lineWidth: 0.8))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "boxGrid")
            .onPreferenceChange(BoxCardFrameKey.self) { frames in
                cardFrames = frames
            }
            // 拖拽框选：与卡片点击互不干扰（4pt 以上才算拖拽），优先于滚动
            .highPriorityGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("boxGrid"))
                    .onChanged { value in
                        if marqueeStart == nil { marqueeStart = value.startLocation }
                        guard let start = marqueeStart else { return }
                        let rect = CGRect(
                            x: min(start.x, value.location.x),
                            y: min(start.y, value.location.y),
                            width: abs(value.location.x - start.x),
                            height: abs(value.location.y - start.y)
                        )
                        marqueeRect = rect
                        let hits = cardFrames.filter { $0.value.intersects(rect) }.keys
                        model.setSelection(Set(hits))
                        model.controller?.touchActivity()
                    }
                    .onEnded { _ in
                        marqueeStart = nil
                        marqueeRect = nil
                    }
            )
        }
        .background(
            // 内层显示容器：随色系着色（颜色管理），与叠加态同一层次色
            RoundedRectangle(cornerRadius: 14)
                .fill(innerContainerColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(innerBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .contextMenu { gridBackgroundMenu }
    }

    private func gridCard(_ item: BoxItem, iconSide: CGFloat) -> some View {
        let isSelected = model.selectedIDs.contains(item.id)
        return Button {
            model.toggleSelection(item)
        } label: {
            VStack(spacing: 5) {
                BoxFileIconView(url: item.url, isDirectory: item.isDirectory, side: iconSide)
                Text(item.name)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                isSelected ? accentSoft.opacity(0.35) : Theme.cardBackground.opacity(0.8),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? accent : Theme.dividerColor, lineWidth: isSelected ? 1.4 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .contextMenu { entryMenu(item) }
        // 悬停时右上角删除角标（点击只移除该条目，不影响多选状态）
        .overlay(alignment: .topTrailing) {
            if hoveredCardID == item.id && !model.actionBubblePresented {
                removeBadge { model.remove(item) }
                    .offset(x: 7, y: -7)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredCardID)
        .onHover { hovering in
            hoveredCardID = hovering ? item.id : (hoveredCardID == item.id ? nil : hoveredCardID)
            if hovering { model.controller?.touchActivity() }
        }
    }

    /// 悬停删除角标：圆形 ×，点按移除对应条目。
    private func removeBadge(action: @escaping () -> Void) -> some View {
        Button {
            action()
            model.controller?.touchActivity()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.red, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .help("从文件盒移除")
    }

    // MARK: 底部工具条
    //
    // 日常不放大按钮：动作全部收进右下角 ⚡ 扇形快捷操作，
    // 左侧只在压缩/解压进行时显示进度条。

    private var footerBar: some View {
        HStack(spacing: 8) {
            // 视图切换胶囊（「N 个文件 ›/˄」的功能等价物）+ 清空按钮：靠最左
            if !model.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        model.showsGrid.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(model.count) 个文件")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: model.showsGrid ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(innerContainerColor, in: Capsule())
                    .overlay(Capsule().strokeBorder(innerBorder, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            Button {
                model.clearAll()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(accent.opacity(0.75))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(model.isEmpty)
            .opacity(model.isEmpty ? 0.35 : 1)
            .help("清空文件盒（不删除源文件）")

            // 压缩/解压进行中的进度与状态（中段）
            if let fraction = model.compressFraction {
                HStack(spacing: 6) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 60)
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(accent)
                }
            } else if !model.compressStatus.isEmpty {
                Text(model.compressStatus)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryText)
            }

            Spacer(minLength: 0)

            // 快捷操作入口（右下角小圆钮）：一行圆钮菜单弹到面板右下角之外
            // （独立透明子窗口，见 BoxFanView / BoxShelfPanelController.toggleFan）
            // 图标用「更多操作」省略号（为闪电，换符规避界面雷同）；
            // 展开时黑白反色填充（浅色黑底白点 / 深色白底黑点），与墨色默认配色一致
            Button {
                model.controller?.touchActivity()
                model.controller?.toggleFan()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(model.actionBubblePresented ? onAccent : accent)
                    .frame(width: 26, height: 26)
                    .background(
                        model.actionBubblePresented
                            ? AnyShapeStyle(accent)
                            : AnyShapeStyle(accentSoft.opacity(max(0.35, preferences.tintOpacity))),
                        in: Circle()
                    )
                    .overlay(Circle().strokeBorder(accent.opacity(0.45), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(model.isEmpty)
            .opacity(model.isEmpty ? 0.4 : 1)
            .help("快捷操作（压缩 / 解压 / 工作区…）")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(footerBackground)
    }

    // MARK: 右键菜单（8 项）

    @ViewBuilder
    private func entryMenu(_ item: BoxItem) -> some View {
        if item.isArchive {
            let openTargets = model.openArchiveTargets(for: item)
            Button(openTargets.count > 1 ? "打开 \(openTargets.count) 个压缩包" : "打开压缩包") {
                model.openArchive(item)
            }
            Button("快速解压") { model.quickExtract(item) }
            Divider()
        }
        Button("重命名") { model.rename(item) }
        Button("拷贝") { model.copyFiles([item]) }
        Divider()
        Button("在访达中显示") { model.revealInFinder([item]) }
        Button("分享") { model.share([item]) }
        Button("拷贝路径") { model.copyPath([item]) }
        Divider()
        // 多选辅助：⌘A 之外的鼠标路径
        Button("全选") { model.selectAll() }
        if !model.selectedIDs.isEmpty {
            Button("取消选择") { model.deselectAll() }
        }
        Divider()
        // 多选时批量移除（与访达一致：右键项在选中集合内 → 移除全部选中项）
        let batchRemove = model.selectedIDs.contains(item.id) && model.selectedIDs.count > 1
        Button(batchRemove ? "从文件盒移除 \(model.selectedIDs.count) 个条目" : "从文件盒移除", role: .destructive) {
            model.removeSmart(item)
        }
    }

    /// 网格空白区的右键菜单（不点中任何卡片也能全选）。
    @ViewBuilder
    private var gridBackgroundMenu: some View {
        Button("全选") { model.selectAll() }
        if !model.selectedIDs.isEmpty {
            Button("取消选择") { model.deselectAll() }
        }
    }

    // MARK: 轻提示

    @ViewBuilder
    private var toastOverlay: some View {
        if !model.toast.isEmpty {
            Text(model.toast)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.dividerColor, lineWidth: 0.5))
                .padding(.top, 26)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }
}

// MARK: - 文件 URL 拖放（登记引用，暂停闲置计时）
