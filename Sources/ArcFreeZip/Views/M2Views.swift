import SwiftUI
import UniformTypeIdentifiers

// MARK: - 条目图标（有缩略图显示真实预览图，否则显示 SF Symbol）

struct EntryIconView: View {
    @Bindable var browser: ArchiveBrowser
    let node: ArchiveNode
    var side: CGFloat = 18

    /// 指向绝对目录的符号链接（如 DMG 内 Applications → /Applications）按文件夹呈现。
    private var behavesLikeDirectory: Bool {
        node.isDirectory || (
            node.entry?.isSymbolicLink == true
                && (node.entry?.linkTarget?.hasPrefix("/") ?? false)
        )
    }

    /// 指向 /Applications 的快捷方式：与访达一致显示蓝色文件夹。
    private var isApplicationsShortcut: Bool {
        node.entry?.isSymbolicLink == true
            && (node.entry?.linkTarget?.hasSuffix("/Applications") ?? false)
    }

    var body: some View {
        Group {
            if let image = browser.thumbnail(for: node) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.18))
            } else {
                Image(systemName: EntryIcon.symbol(for: node.name, isDirectory: behavesLikeDirectory))
                    .font(.system(size: side * 0.85))
                    .foregroundStyle(iconTint)
                    .frame(width: side, height: side)
            }
        }
    }

    /// 文件夹图标配色：归档内普通文件夹沿用主题紫，Applications 快捷方式用访达蓝。
    private var iconTint: Color {
        if isApplicationsShortcut {
            return Color(red: 0.25, green: 0.52, blue: 0.96)
        }
        return behavesLikeDirectory ? Theme.accent : Theme.textSecondary
    }
}

// MARK: - Mini 窗口（紧凑浮窗 + 图钉置顶，方便拖拽解压）

struct MiniView: View {
    @Bindable var browser: ArchiveBrowser

    var body: some View {
        VStack(spacing: 12) {
            // 头部：左=压缩包大图标+名称/副标题，右=应用标识+Mini
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Theme.accentLight)
                        .frame(width: 40, height: 40)
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(Theme.accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(browser.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(browser.miniSubtitle)
                        .font(.system(size: Theme.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    BrandLogoView(iconSize: 15, fontSize: 14, fontWeight: .semibold)
                    Text("Mini")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)

            NavBarRow(browser: browser)
                .frame(height: 40)

            MiniListView(browser: browser)

            // 底部：关闭 / 图钉 / 恢复完整窗口 + 预览 + 全部解压
            HStack(spacing: 8) {
                CircleIconButton(
                    systemName: "xmark",
                    help: "关闭压缩包",
                    placement: .above
                ) {
                    browser.closeFromMini()
                }

                Button {
                    browser.togglePinned()
                } label: {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(browser.isPinned ? .white : Theme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(
                            browser.isPinned ? Theme.accent : Theme.iconButtonBackground,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .afzHelp(browser.isPinned ? "取消置顶" : "置顶 mini 窗口（方便拖拽解压）", placement: .above)

                CircleIconButton(
                    systemName: "arrow.up.left.and.arrow.down.right",
                    help: "恢复完整窗口",
                    placement: .above
                ) {
                    browser.toggleMiniMode()
                }

                Spacer()

                // 解压进度 / 完成提示（紧凑形态）
                if browser.isExtracting {
                    ExtractionProgressChip(browser: browser, compact: true)
                } else if browser.showsExtractionToast {
                    ExtractionDoneChip(browser: browser, compact: true)
                }

                // 选中文件后出现紫色 ⚡解压 按钮
                if !browser.selectedPaths.isEmpty {
                    Button {
                        browser.extractSelected()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 12))
                            Text("解压")
                        }
                        .primaryCapsule()
                    }
                    .buttonStyle(.plain)
                    .disabled(browser.isExtracting)
                }

                Button {
                    if browser.previewEntry != nil {
                        browser.showsMiniPreview.toggle()
                        browser.updatePreview()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: browser.showsMiniPreview ? "eye" : "eye.slash")
                        Text("预览")
                        Text("空格")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.chipBackground, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.dividerColor, lineWidth: 0.5))
                    }
                    .whiteCapsule()
                }
                .buttonStyle(.plain)
                .disabled(browser.previewEntry == nil)

                Button {
                    browser.extractAll()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox")
                        Text("全部解压")
                        Image(systemName: "arrowshape.turn.up.right")
                            .font(.system(size: 11))
                    }
                    .whiteCapsule()
                }
                .buttonStyle(.plain)
                .disabled(browser.isExtracting)
            }
            .padding(.horizontal, 4)
            .frame(height: 40)
        }
        .padding(12)
        .background(Theme.canvasBackground)
        .popover(isPresented: $browser.showsMiniPreview, arrowEdge: .bottom) {
            if let entry = browser.previewEntry {
                ScrollView {
                    ItemDetailView(browser: browser, entry: entry)
                        .padding(14)
                }
                .frame(width: 290, height: 400)
            } else {
                Text("选择一个文件以预览")
                    .font(.system(size: Theme.bodySize))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(30)
            }
        }
    }
}

/// mini 窗口的精简列表（名称 + 大小，无日期列）。
struct MiniListView: View {
    @Bindable var browser: ArchiveBrowser

    /// mini 列表行高（固定值，空白区延续同一斑马纹网格）
    private let miniRowHeight: CGFloat = 24

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                MarqueeHost(
                    browser: browser,
                    space: MarqueeSpace.miniList,
                    minHeight: viewport.size.height
                ) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(browser.visibleNodes.enumerated()), id: \.element.id) { index, node in
                            miniRow(node: node, index: index)
                                .entryFrame(path: node.path, in: MarqueeSpace.miniList)
                        }

                        // 空白区域延续同一斑马纹网格（行高一致、奇偶交替）
                        let fillers = max(0, Int(viewport.size.height / miniRowHeight) - browser.visibleNodes.count)
                        ForEach(0..<fillers, id: \.self) { i in
                            let index = browser.visibleNodes.count + i
                            Color.clear
                                .frame(height: miniRowHeight)
                                .frame(maxWidth: .infinity)
                                .background(index.isMultiple(of: 2) ? Color.clear : Theme.zebraRow)
                                // 填充行不参与命中测试（同主窗口：别拦空白区的框选/取消手势）
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .onMoveCommand { direction in
                guard !browser.visibleNodes.isEmpty else { return }
                let paths = browser.visibleNodes.map(\.path)
                let current = browser.selectedPaths.first.flatMap { paths.firstIndex(of: $0) } ?? -1
                let next: Int
                switch direction {
                case .up: next = max(0, current - 1)
                case .down: next = min(paths.count - 1, current + 1)
                default: return
                }
                browser.selectedPaths = [paths[next]]
            }
        }
        .overlay {
            if browser.visibleNodes.isEmpty {
                Text(browser.isSearching ? "没有匹配的文件" : "这个文件夹是空的")
                    .font(.system(size: Theme.bodySize))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func miniRow(node: ArchiveNode, index: Int) -> some View {
        let isSelected = browser.selectedPaths.contains(node.path)
        return HStack(spacing: 8) {
            EntryIconView(browser: browser, node: node, side: 16)
            Text(node.name)
                .font(.system(size: Theme.bodySize))
                .foregroundStyle(isSelected ? Color.white : (ArchiveBrowser.isHiddenName(node.name) ? Theme.textTertiary : Theme.textPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
                .archiveHoverPreview(browser: browser, node: node)
            Spacer()
            if node.isDirectory {
                Text("—")
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Theme.textTertiary)
            } else {
                Text(ByteFormatter.string(from: node.entry?.size ?? 0))
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Theme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: miniRowHeight, maxHeight: miniRowHeight)
        // 选中蓝底；否则按行号奇偶铺斑马纹（与主列表一致）
        .background(
            isSelected
                ? Theme.selectionBlue
                : (index.isMultiple(of: 2) ? Color.clear : Theme.zebraRow)
        )
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
            // 与主窗口一致：⌘ 切换选中、⇧ 范围选择、普通点按单选
            browser.handleTapSelection(node, visibleNodes: browser.visibleNodes)
        }
        // 拖拽解压（与主窗口一致）
        .multiDragHover(browser: browser, node: node)
        .onDrag { browser.dragProvider(for: node) } preview: {
            FileDragPreview(node: node)
        }
        .contextMenu {
            if !browser.selectedPaths.isEmpty {
                Button("解压所选…") { browser.extractSelected() }
                    .disabled(browser.isExtracting)
                Divider()
            }
            Button("全选") { browser.selectAllVisible() }
                .disabled(browser.visibleNodes.isEmpty)
            Button("取消全选") { browser.clearSelection() }
                .disabled(browser.selectedPaths.isEmpty)
        }
    }
}

// MARK: - 图标视图（图标网格）

struct IconGridView: View {
    @Bindable var browser: ArchiveBrowser

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                MarqueeHost(
                    browser: browser,
                    space: MarqueeSpace.icon,
                    minHeight: viewport.size.height
                ) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 96), spacing: 10)],
                        spacing: 14
                    ) {
                        ForEach(browser.visibleNodes) { node in
                            IconTile(browser: browser, node: node)
                                .entryFrame(path: node.path, in: MarqueeSpace.icon)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct IconTile: View {
    @Bindable var browser: ArchiveBrowser
    let node: ArchiveNode

    private var isSelected: Bool { browser.selectedPaths.contains(node.path) }
    /// 待删除项：灰色 + 删除线标记（保存后真正移除）
    private var isDeleted: Bool { browser.isPendingDeletion(node.path) }
    /// 本次编辑新增/替换的条目：绿色标记
    private var isNew: Bool { node.isPendingAdd && !isDeleted }
    /// 拖拽悬停在本磁贴（仅 Applications 快捷方式需要提示）
    @State private var isDropTarget = false
    private var showsDropHighlight: Bool {
        isDropTarget && browser.isApplicationsFolderNode(node)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                EntryIconView(browser: browser, node: node, side: 68)
                    .opacity(isDeleted ? 0.4 : 1)
                if isNew {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, Theme.pendingAdd)
                        .offset(x: 2, y: -2)
                        .afzHelp("尚未保存的新增项")
                }
            }
            Text(node.name)
                .font(.system(size: 11))
                .strikethrough(isDeleted)
                .foregroundStyle(
                    isDeleted || ArchiveBrowser.isHiddenName(node.name)
                        ? Theme.textTertiary
                        : (isNew ? Theme.pendingAdd : Theme.textPrimary)
                )
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .archiveHoverPreview(browser: browser, node: node)

            // 符号链接副标题（"→ /Applications"）
            if node.entry?.isSymbolicLink == true, let target = node.entry?.linkTarget {
                Text("→ \(target)")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(isSelected ? Theme.accentLight : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    showsDropHighlight || isSelected ? Theme.accent : .clear,
                    lineWidth: showsDropHighlight ? 2.5 : 1.5
                )
        )
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(showsDropHighlight ? Theme.accent.opacity(0.14) : .clear)
        )
        .animation(.easeOut(duration: 0.12), value: showsDropHighlight)
        .opacity(isDeleted ? 0.5 : ArchiveBrowser.isHiddenName(node.name) ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // 待删除项（灰色标记）不再响应进入
            if node.isDirectory {
                if !isDeleted { browser.navigate(to: node.path) }
            } else if !isDeleted, browser.canEnterNested(node) {
                browser.enterNested(node)
            } else if !isDeleted {
                // 普通文件：双击弹出系统预览窗口（与空格一致）
                browser.previewNode(node)
            }
        }
        .onTapGesture {
            // 统一选择语义：⌘切换 / ⇧范围 / 单选（待删除项不可选中）
            guard !isDeleted else { return }
            browser.handleTapSelection(node, visibleNodes: browser.visibleNodes)
        }
        // 拖拽解压（与主窗口一致）
        .multiDragHover(browser: browser, node: node)
        .onDrag { browser.dragProvider(for: node) } preview: {
            FileDragPreview(node: node)
        }
        // 拖动 .app 到 Applications 快捷方式上直接安装（与访达挂载后一致）
        .onDrop(
            of: [ArchiveBrowser.nodePathsUTI, UTType.data, UTType.folder],
            isTargeted: $isDropTarget
        ) { providers in
            browser.acceptDrop(on: node, providers: providers)
        }
        .contextMenu {
            if let reason = browser.editBlockedReason {
                Button {} label: { Label(reason, systemImage: "lock") }
                    .disabled(true)
                Divider()
            }
            if !node.isDirectory {
                Button("解压…") {
                    browser.selectedPaths = [node.path]
                    browser.extractSelected()
                }
                .disabled(browser.isExtracting)
            }
            Button("重命名…") { browser.beginRenameEntry(at: node.path) }
                .disabled(!browser.isEditable || browser.isPendingDeletion(node.path))
            Button("删除", role: .destructive) {
                if browser.selectedPaths.contains(node.path) {
                    browser.deleteSelected()
                } else {
                    browser.selectedPaths = [node.path]
                    browser.deleteSelected()
                }
            }
            .disabled(!browser.isEditable)
            if browser.canUndoEdit || browser.canRedoEdit {
                Divider()
                if browser.canUndoEdit {
                    Button("撤销上次编辑") { browser.undoLastEdit() }
                }
                if browser.canRedoEdit {
                    Button("重做上次编辑") { browser.redoLastEdit() }
                }
            }
            Divider()
            Button("全选") { browser.selectAllVisible() }
                .disabled(browser.visibleNodes.isEmpty)
            Button("取消全选") { browser.clearSelection() }
                .disabled(browser.selectedPaths.isEmpty)
        }
    }
}

// MARK: - 分栏视图（分栏浏览）

struct ColumnBrowserView: View {
    @Bindable var browser: ArchiveBrowser

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(browser.columnLevels, id: \.parentPath) { level in
                    // 每栏内部竖向滚动（与访达一致）：栏高恒等于容器高度，
                    // 长目录不会被撑高——否则横向 ScrollView 的内容高度
                    // 由最高的栏决定，会把窗口顶部/底部工具条挤出可视区。
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(level.nodes) { node in
                                ColumnCellRow(
                                    browser: browser,
                                    node: node,
                                    isHighlighted:
                                        level.selectedPath == node.path
                                        || (level.parentPath == browser.currentPath
                                            && browser.selectedPaths.contains(node.path))
                                )
                            }
                        }
                    }
                    .frame(width: 180)
                    .background(Theme.cardBackground)
                    .overlay(alignment: .trailing) {
                        Divider().overlay(Theme.dividerColor)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }
}

struct ColumnCellRow: View {
    @Bindable var browser: ArchiveBrowser
    let node: ArchiveNode
    let isHighlighted: Bool

    var body: some View {
        // 待删除项：灰色 + 删除线标记（保存后真正移除）
        let isDeleted = browser.isPendingDeletion(node.path)
        // 本次编辑新增/替换的条目：绿色标记
        let isNew = node.isPendingAdd && !isDeleted
        HStack(spacing: 6) {
            EntryIconView(browser: browser, node: node, side: 16)
                .opacity(isDeleted ? 0.4 : 1)
            Text(node.name)
                .font(.system(size: 12))
                .strikethrough(isDeleted)
                .foregroundStyle(
                    isDeleted || ArchiveBrowser.isHiddenName(node.name)
                        ? Theme.textTertiary
                        : (isNew ? Theme.pendingAdd : Theme.textPrimary)
                )
                .lineLimit(1)
                .truncationMode(.middle)
            if isNew {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white, Theme.pendingAdd)
            }
            Spacer()
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(isHighlighted ? Theme.accentLight : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if node.isDirectory {
                if !isDeleted { browser.navigate(to: node.path) }
            } else if !isDeleted, browser.canEnterNested(node) {
                browser.enterNested(node)
            } else if !isDeleted {
                // 普通文件：双击弹出系统预览窗口（与空格一致）
                browser.previewNode(node)
            }
        }
        .onTapGesture {
            if isDeleted { return }
            if node.isDirectory {
                browser.navigate(to: node.path)
            } else {
                // 统一选择语义：⌘切换 / ⇧范围 / 单选（分栏视图文件夹保持点击即进入）
                browser.handleTapSelection(node, visibleNodes: browser.visibleNodes)
            }
        }
    }
}
