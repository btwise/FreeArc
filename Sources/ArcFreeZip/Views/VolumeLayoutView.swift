import SwiftUI
import UniformTypeIdentifiers

/// 磁盘映像根层自由布局：以映像自带的背景图为设计画布（无背景图时按图标包围盒推导），
/// .DS_Store 的 Iloc 坐标即图标**中心点**，等比缩放铺满文件区——
/// / 访达打开 DMG 的效果（背景图 + 大图标 + 设计位置）。
/// 窗口缩放时按同一比例缩放，保持布局与边距比例。
struct VolumeLayoutView: View {
    @Bindable var browser: ArchiveBrowser

    var body: some View {
        GeometryReader { geo in
            let fitted = fit(geo: geo.size)
            ZStack {
                if let background = browser.volumeBackground {
                    Image(nsImage: background)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.canvasW, height: fitted.canvasH)
                }
                ForEach(browser.visibleNodes) { node in
                    if let center = fitted.centers[node.path] ?? fitted.centers[node.name] {
                        VolumeIconTile(browser: browser, node: node, side: fitted.iconSide)
                            .frame(width: fitted.tileWidth)
                            .position(center)
                    }
                }
            }
            .frame(width: fitted.canvasW, height: fitted.canvasH)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: 布局计算

    private struct FittedLayout {
        var centers: [String: CGPoint] = [:]
        var canvasW: CGFloat = 100
        var canvasH: CGFloat = 100
        var iconSide: CGFloat = 64
        var tileWidth: CGFloat = 104
    }

    /// 无背景图时，设计稿中图标位图约占的尺寸（pt）。
    private static let fallbackIconSpan: CGFloat = 128

    /// 把设计坐标等比缩放到当前可用区域：
    /// - 有背景图：画布 = 背景图尺寸，Iloc 为图标中心，整体居中铺满；
    /// - 无背景图：画布 = 图标中心包围盒 ± 图标位宽/2 + 边距。
    private func fit(geo: CGSize) -> FittedLayout {
        var result = FittedLayout()
        let rawPoints = browser.volumeLayout
        guard !rawPoints.isEmpty else { return result }

        let pad: CGFloat = 12
        let availableW = max(geo.width - pad * 2, 80)
        let availableH = max(geo.height - pad * 2, 80)

        let canvas: CGSize
        let origin: CGPoint  // 设计坐标 → 画布坐标的平移
        if let size = browser.volumeCanvasSize, size.width > 1, size.height > 1 {
            canvas = size
            origin = .zero
        } else {
            let xs = rawPoints.values.map(\.x)
            let ys = rawPoints.values.map(\.y)
            let half = Self.fallbackIconSpan / 2
            let minX = (xs.min() ?? 0) - half - 20
            let minY = (ys.min() ?? 0) - half - 20
            canvas = CGSize(
                width: (xs.max() ?? 0) + half + 20 - minX,
                height: (ys.max() ?? 0) + half + 20 - minY
            )
            origin = CGPoint(x: minX, y: minY)
        }

        let scale = min(availableW / canvas.width, availableH / canvas.height, 1.5)
        result.canvasW = canvas.width * scale
        result.canvasH = canvas.height * scale

        // 图标位宽 ≈ 画布宽的 20%（660 宽背景图对应 ~132pt，观感）
        result.iconSide = max(56, canvas.width * 0.2 * scale)
        result.tileWidth = result.iconSide + 48

        for (name, point) in rawPoints {
            result.centers[name] = CGPoint(
                x: (point.x - origin.x) * scale,
                y: (point.y - origin.y) * scale
            )
        }
        return result
    }
}

/// 自由布局中的图标磁贴：交互与 IconTile 一致（选择/进入/拖拽/拖放安装），无网格约束。
struct VolumeIconTile: View {
    @Bindable var browser: ArchiveBrowser
    let node: ArchiveNode
    var side: CGFloat = 64

    private var isSelected: Bool { browser.selectedPaths.contains(node.path) }
    /// 拖拽悬停在本磁贴（仅 Applications 快捷方式需要提示）
    @State private var isDropTarget = false
    /// 仅 Applications 目标显示放置高亮（其他磁贴也接受同类型但无放置语义）
    private var showsDropHighlight: Bool {
        isDropTarget && browser.isApplicationsFolderNode(node)
    }

    var body: some View {
        VStack(spacing: 8) {
            EntryIconView(browser: browser, node: node, side: side)
            Text(node.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    ArchiveBrowser.isHiddenName(node.name) ? Theme.textTertiary : Theme.textPrimary
                )
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .archiveHoverPreview(browser: browser, node: node)

            if node.entry?.isSymbolicLink == true, let target = node.entry?.linkTarget {
                Text("→ \(target)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(isSelected ? Theme.accentLight : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    showsDropHighlight || isSelected ? Theme.accent : .clear,
                    lineWidth: showsDropHighlight ? 2.5 : 1.5
                )
        )
        // 拖到 Applications 上时高亮，明确"松手即安装"
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(showsDropHighlight ? Theme.accent.opacity(0.14) : .clear)
        )
        .scaleEffect(showsDropHighlight ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: showsDropHighlight)
        .opacity(ArchiveBrowser.isHiddenName(node.name) ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if node.isDirectory {
                browser.navigate(to: node.path)
            } else if browser.canEnterNested(node) {
                browser.enterNested(node)
            } else {
                // 普通文件：双击弹出系统预览窗口（与空格一致）
                browser.previewNode(node)
            }
        }
        .onTapGesture {
            browser.selectedPaths = [node.path]
        }
        .multiDragHover(browser: browser, node: node)
        .onDrag { browser.dragProvider(for: node) } preview: {
            FileDragPreview(node: node)
        }
        .onDrop(
            of: [ArchiveBrowser.nodePathsUTI, UTType.data, UTType.folder],
            isTargeted: $isDropTarget
        ) { providers in
            browser.acceptDrop(on: node, providers: providers)
        }
        .contextMenu {
            if !node.isDirectory {
                Button("解压…") {
                    browser.selectedPaths = [node.path]
                    browser.extractSelected()
                }
                .disabled(browser.isExtracting)
            }
        }
    }
}
