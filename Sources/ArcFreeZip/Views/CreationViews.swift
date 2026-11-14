import SwiftUI
import UniformTypeIdentifiers
import ArchiveCore

// MARK: - 创建工作台（"新压缩包"窗口：同构布局，可编辑标题 + 列表 + 保存）

struct CreationWorkspaceView: View {
    @Bindable var browser: ArchiveBrowser
    @State private var searchFieldVisible = false
    /// 详情面板折叠状态（与浏览模式共用同一持久化键，默认值收口在 AppSettings）
    @AppStorage(AppSettings.detailCollapsedKey) private var detailCollapsed = AppSettings.detailCollapsedDefault

    var body: some View {
        Group {
            if browser.showsCreationOptions {
                // 点保存后选项界面**替换整个工作台**，是嵌入主窗口的整幅白色容器
                //（与主窗口同宽同高，不是浮动小卡片）
                CreationOptionsSheet(browser: browser)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 选项页是嵌入主窗口的整幅内容容器，跟随用户自选卡片色
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
            } else {
                // 左白卡贯穿窗口全高，顶栏/底栏浮在卡内部；右侧紫板同高
                HStack(spacing: 10) {
                    VStack(spacing: 0) {
                        TopBar(browser: browser, searchFieldVisible: $searchFieldVisible)

                        // 视图切换（列表/图标/分栏均作用于待打包文件）
                        Group {
                            switch browser.viewMode {
                            case .list: CreationListCard(browser: browser)
                            case .icon: CreationIconCard(browser: browser)
                            case .column: CreationColumnCard(browser: browser)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        BottomBar(browser: browser)
                    }
                    .contentCard()
                    .frame(maxWidth: .infinity)

                    if detailCollapsed {
                        DetailCollapseStrip(collapsed: $detailCollapsed)
                            .transition(.opacity)
                    } else {
                        DetailPanel(browser: browser, collapsed: $detailCollapsed)
                            .frame(width: 270)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: detailCollapsed)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay {
            // 独占进度卡（浮窗）：创建耗时任务时居中显示，与底部胶囊并存
            if browser.isCreatingArchive {
                TaskProgressCard(
                    symbol: "archivebox.fill",
                    title: "正在压缩",
                    name: browser.creationDisplayName,
                    fraction: browser.creationFraction,
                    detail: browser.creationTotalBytes > 0
                        ? "\(afzByteText(browser.creationProcessedBytes)) / \(afzByteText(browser.creationTotalBytes))"
                        : nil
                ) {
                    browser.cancelCreation()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: browser.isCreatingArchive)
        .alert(browser.errorTitle, isPresented: $browser.showsErrorAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(browser.errorMessage)
        }
    }
}

// MARK: - 待打包列表卡片

/// 搜索过滤后的可见条目（列表/图标/分栏三种视图共用）。
@MainActor
func visibleCreationItems(_ browser: ArchiveBrowser) -> [CreationItem] {
    browser.searchText.isEmpty
        ? browser.creationItems
        : browser.creationItems.filter {
            $0.name.localizedCaseInsensitiveContains(browser.searchText)
        }
}

/// 待打包条目点击选择（⌘ 多选，与列表视图一致）。
@MainActor
func handleCreationTap(_ browser: ArchiveBrowser, _ item: CreationItem) {
    if NSEvent.modifierFlags.contains(.command) {
        if browser.selectedPaths.contains(item.id) {
            browser.selectedPaths.remove(item.id)
        } else {
            browser.selectedPaths.insert(item.id)
        }
    } else {
        browser.selectedPaths = [item.id]
    }
}

/// 真实文件的系统图标（显示文件真实图标）。
func fileIcon(for item: CreationItem, side: CGFloat) -> some View {
    let nsIcon = NSWorkspace.shared.icon(forFile: item.url.path)
    return Image(nsImage: nsIcon)
        .resizable()
        .interpolation(.high)
        .frame(width: side, height: side)
}

struct CreationListCard: View {
    @Bindable var browser: ArchiveBrowser

    var body: some View {
        VStack(spacing: 0) {
            // 表头（名称 | 大小 | 修改时间）
            HStack(spacing: 10) {
                Text("名称")
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("大小")
                    .frame(width: sizeColumnWidth, alignment: .trailing)
                Text("修改时间")
                    .frame(width: dateColumnWidth, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Theme.panelBackground.opacity(0.6))

            Divider().overlay(Theme.dividerColor)

            if browser.creationItems.isEmpty {
                CreationEmptyCard {
                    browser.showAddFilesPanel()
                }
            } else {
                // 搜索过滤（创建窗口的文件搜索）
                let visibleItems = browser.searchText.isEmpty
                    ? browser.creationItems
                    : browser.creationItems.filter {
                        $0.name.localizedCaseInsensitiveContains(browser.searchText)
                    }
                GeometryReader { viewport in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                                CreationRow(browser: browser, item: item)
                                    .padding(.horizontal, 14)
                                    .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
                                    .background(rowBackground(index: index, item: item))
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        // 嵌套压缩包浏览：双击待打包的压缩文件进入其内部浏览（创建窗口）
                                        if !item.isDirectory, ArchiveBrowser.isNestedArchiveName(item.name) {
                                            browser.enterNestedFromDisk(url: item.url)
                                        } else {
                                            // 普通文件：双击弹出系统预览窗口（与空格一致）
                                            browser.previewCreationItem(item)
                                        }
                                    }
                                    .onTapGesture { handleTap(item) }
                                    .creationHoverPreview(item: item)
                            }
                            // 空白区延续斑马纹
                            let fillers = max(0, Int(viewport.size.height / 30) - visibleItems.count)
                            ForEach(0..<fillers, id: \.self) { i in
                                Color.clear
                                    .frame(height: 30)
                                    .frame(maxWidth: .infinity)
                                    .background(zebraBand(index: visibleItems.count + i))
                            }
                        }
                    }
                }
            }
        }
        // 外层由 CreationWorkspaceView 统一包一张贯穿全高的大白卡
    }

    private func rowBackground(index: Int, item: CreationItem) -> some View {
        let isSelected = browser.selectedPaths.contains(item.id)
        return zebraBand(index: index, color: isSelected ? Theme.selectionBlue : nil)
    }

    private func zebraBand(index: Int, color: Color? = nil) -> some View {
        let fill = color ?? (index.isMultiple(of: 2) ? .clear : Theme.zebraRow)
        return RoundedRectangle(cornerRadius: 4)
            .fill(fill)
            .padding(.horizontal, 12)
    }

    private func handleTap(_ item: CreationItem) {
        if NSEvent.modifierFlags.contains(.command) {
            if browser.selectedPaths.contains(item.id) {
                browser.selectedPaths.remove(item.id)
            } else {
                browser.selectedPaths.insert(item.id)
            }
        } else {
            browser.selectedPaths = [item.id]
        }
    }
}

// MARK: - 待打包图标视图卡片（沿用浏览模式图标视图：真实文件图标磁贴）

struct CreationIconCard: View {
    @Bindable var browser: ArchiveBrowser

    var body: some View {
        Group {
            if browser.creationItems.isEmpty {
                CreationEmptyCard {
                    browser.showAddFilesPanel()
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 96), spacing: 10)],
                        spacing: 14
                    ) {
                        ForEach(visibleCreationItems(browser)) { item in
                            CreationIconTile(browser: browser, item: item)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

struct CreationIconTile: View {
    @Bindable var browser: ArchiveBrowser
    let item: CreationItem

    private var isSelected: Bool { browser.selectedPaths.contains(item.id) }

    var body: some View {
        VStack(spacing: 6) {
            fileIcon(for: item, side: 56)
            Text(item.name)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(item.isDirectory ? "文件夹" : ByteFormatter.string(from: item.size))
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(isSelected ? Theme.accentLight : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // 嵌套压缩包浏览：双击待打包的压缩文件进入其内部浏览
            if !item.isDirectory, ArchiveBrowser.isNestedArchiveName(item.name) {
                browser.enterNestedFromDisk(url: item.url)
            } else {
                // 普通文件：双击弹出系统预览窗口（与空格一致）
                browser.previewCreationItem(item)
            }
        }
        .onTapGesture { handleCreationTap(browser, item) }
        .creationHoverPreview(item: item)
        .afzHelp("点击选中，⌘ 点击多选；双击压缩包进入内部浏览")
    }
}

// MARK: - 待打包分栏视图卡片（按所在文件夹分组：第一栏文件夹，第二栏文件）

struct CreationColumnCard: View {
    @Bindable var browser: ArchiveBrowser

    /// 去重的父文件夹列表（保持首次出现顺序）。
    private var parentFolders: [URL] {
        var seen = Set<String>()
        var folders: [URL] = []
        for item in visibleCreationItems(browser) {
            let parent = item.url.deletingLastPathComponent()
            if seen.insert(parent.path).inserted {
                folders.append(parent)
            }
        }
        return folders
    }

    var body: some View {
        Group {
            if browser.creationItems.isEmpty {
                CreationEmptyCard {
                    browser.showAddFilesPanel()
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        // 第一栏：父文件夹
                        VStack(spacing: 0) {
                            ForEach(parentFolders, id: \.path) { folder in
                                CreationColumnFolderRow(
                                    folder: folder,
                                    isSelected: browser.creationColumnFolder == folder
                                ) {
                                    browser.creationColumnFolder = folder
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(width: 180)
                        .background(Theme.cardBackground)
                        .overlay(alignment: .trailing) {
                            Divider().overlay(Theme.dividerColor)
                        }

                        // 第二栏：所选文件夹内的待打包文件
                        VStack(spacing: 0) {
                            ForEach(visibleCreationItems(browser).filter {
                                $0.url.deletingLastPathComponent() == browser.creationColumnFolder
                            }) { item in
                                CreationColumnItemRow(
                                    item: item,
                                    isSelected: browser.selectedPaths.contains(item.id)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    if !item.isDirectory, ArchiveBrowser.isNestedArchiveName(item.name) {
                                        browser.enterNestedFromDisk(url: item.url)
                                    } else {
                                        // 普通文件：双击弹出系统预览窗口（与空格一致）
                                        browser.previewCreationItem(item)
                                    }
                                }
                                .onTapGesture { handleCreationTap(browser, item) }
                                .creationHoverPreview(item: item)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(width: 200)
                        .background(Theme.cardBackground)
                        .overlay(alignment: .trailing) {
                            Divider().overlay(Theme.dividerColor)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
                .onAppear {
                    // 默认选中第一个文件夹
                    if browser.creationColumnFolder == nil
                        || !parentFolders.contains(where: { $0 == browser.creationColumnFolder }) {
                        browser.creationColumnFolder = parentFolders.first
                    }
                }
            }
        }
    }
}

/// 分栏第一栏：文件夹行。
struct CreationColumnFolderRow: View {
    let folder: URL
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
            Text(folder.lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(isSelected ? Theme.accentLight : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// 分栏第二栏：待打包文件行。
struct CreationColumnItemRow: View {
    let item: CreationItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            fileIcon(for: item, side: 16)
            Text(item.name)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if !item.isDirectory {
                Text(ByteFormatter.string(from: item.size))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(isSelected ? Theme.accentLight : .clear)
        .contentShape(Rectangle())
    }
}

/// 空态：虚线卡片「添加文件到压缩包」（空工作台：白色圆角容器居中，
/// 虚线边框内缩在白色容器内部，宽约为列表 2/3、高约 185pt）。
struct CreationEmptyCard: View {
    let action: () -> Void

    var body: some View {
        ZStack {
            // 斑马纹空白区
            GeometryReader { geo in
                LazyVStack(spacing: 0) {
                    let fillers = Int(geo.size.height / 30) + 1
                    ForEach(0..<fillers, id: \.self) { i in
                        Color.clear
                            .frame(height: 30)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(i.isMultiple(of: 2) ? .clear : Theme.zebraRow)
                                    .padding(.horizontal, 12)
                            )
                    }
                }
            }

            Button(action: action) {
                VStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(Theme.textSecondary)
                    Text("添加文件到压缩包")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("点击添加文件，或直接将文件拖到这里")
                        .font(.system(size: Theme.captionSize))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 淡强调色洗底（accentLight）：随色彩主题明显变化，石墨下仍为浅灰
                .background(Theme.accentLight, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
                // 虚线边框随强调色（石墨下呈中性灰，观感与历史一致）
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .padding(7)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .frame(width: 460, height: 185)
        }
    }
}

/// 待打包条目行（图标 + 名称 + 大小 + 修改时间，选中蓝底白字）。
struct CreationRow: View {
    @Bindable var browser: ArchiveBrowser
    let item: CreationItem

    private var isSelected: Bool { browser.selectedPaths.contains(item.id) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                .frame(width: 22)

            Text(item.name)
                .font(.system(size: Theme.bodySize, weight: isSelected ? .medium : .regular))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(item.isDirectory ? "—" : ByteFormatter.string(from: item.size))
                .font(.system(size: Theme.bodySize))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: sizeColumnWidth, alignment: .trailing)

            Text(item.modificationDate.map {
                $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened))
            } ?? "—")
                .font(.system(size: Theme.bodySize))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: dateColumnWidth, alignment: .trailing)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 创建模式详情面板内容（图标 + 名称 + 格式 + 大小/项目/加密/修改日期）

struct CreationDetailView: View {
    @Bindable var browser: ArchiveBrowser

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Theme.accentGradient)
                    .frame(width: 84, height: 84)
                    .shadow(color: Color.black.opacity(0.14), radius: 6, y: 3)
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(Theme.onAccent)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            Text(browser.creationDisplayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text("\(browser.creationFormatName) 压缩包")
                .font(.system(size: Theme.captionSize))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                DetailRow(title: "大小", value: ByteFormatter.string(from: browser.creationTotalSize))
                DetailRow(title: "项目", value: "\(browser.creationItemCount)")
                DetailRow(
                    title: "加密",
                    value: browser.creationPasswordEnabled && !browser.creationPassword.isEmpty ? "是" : "否"
                )
                DetailRow(title: "修改日期", value: "—")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }
}

/// 创建工作台：选中单个文件时的详情（与打开压缩包后的 ItemDetailView 同构：
/// 真实文件直接用 Quick Look 预览卡 + 名称 + 类型 + 字段列表）。
struct CreationItemDetailView: View {
    let item: CreationItem

    var body: some View {
        VStack(spacing: 12) {
            if item.isDirectory {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.zebraRow)
                        .frame(width: 120, height: 120)
                        .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                // 真实文件无需解压，直接交给 Quick Look 预览视图
                QuickLookPreviewView(url: item.url)
                    .frame(maxWidth: .infinity)
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerS))
            }

            Text(item.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            Text(FileTypeDescription.describe(name: item.name))
                .font(.system(size: Theme.captionSize))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                DetailRow(title: "大小", value: item.isDirectory ? "—" : ByteFormatter.string(from: item.size))
                if let date = item.modificationDate {
                    DetailRow(
                        title: "修改日期",
                        value: date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened))
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }
}

// MARK: - 创建选项窗口（sheet：目的预设五卡 + 压缩设置/概览 + 密码 + 高级选项）

/// 分组外层容器（浅灰底 + **明显描边**，三个分组统一用它）。
extension View {
    func creationGroupCard() -> some View {
        self
            .background(Theme.chipBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.groupBorderColor, lineWidth: 1)
            )
    }
}

struct CreationOptionsSheet: View {
    @Bindable var browser: ArchiveBrowser

    /// 强度滑杆吸附档位（滑杆 5 个档位：仅打包 / 更快 / 均衡 / 更小 / 极限）。
    private static let levels: [Int] = [0, 1, 5, 7, 9]

    /// 名称输入框 / 存储位置下拉框统一高度（两个控件完全等高）。
    private static let fieldHeight: CGFloat = 36

    /// 滑杆档位下标 ↔ 压缩级别。
    private var levelIndexBinding: Binding<Int> {
        Binding(
            get: { Self.levels.firstIndex(of: browser.creationLevel) ?? 2 },
            set: { browser.creationLevel = Self.levels[$0] }
        )
    }

    var body: some View {
        // 嵌入主窗口的整幅容器：内容固定一屏（超出时可滚动兜底），底部按钮固定
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // 标题行（top 34 避让窗口红绿灯）
                    HStack(spacing: 10) {
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.accent)
                        Text("创建压缩包")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                    }
                    .padding(.bottom, 6)

                    nameAndFolderRow

                    purposeSection
                        .padding(.top, 10)

                    settingsAndOverview
                        .padding(.top, 10)

                    passwordSection
                        .padding(.top, 10)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 5)
            }

            // 底部按钮（右对齐，「✕ 取消 / 创建压缩包」）
            HStack(spacing: 12) {
                Spacer()
                Button {
                    // 回到创建工作台（本视图非 sheet，dismiss 会误关整个窗口）
                    browser.showsCreationOptions = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                        Text("取消")
                    }
                    // 与创建按钮等宽；随主题取中性容器色（不再用突兀的固定深红）
                    .frame(minWidth: 84)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Theme.chipBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.dividerColor, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    // 「Windows 用户」方案：创建前检测文件名兼容性
                    //（Windows 文件名兼容性流程），有问题先出修正清单
                    if browser.creationPurpose == .windows {
                        let issues = browser.windowsFilenameIssues()
                        if !issues.isEmpty {
                            repairIssues = issues
                            showsFilenameRepair = true
                            return
                        }
                    }
                    // 不调 dismiss（会误关窗口）；confirmCreateArchive 内部会收起选项界面，
                    // 打包完成后自动转入浏览模式打开新压缩包
                    browser.confirmCreateArchive()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 12))
                        Text("创建压缩包")
                    }
                    // 主行动按钮随主题强调色渐变（与全局主按钮同一套）
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Theme.accentGradient, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(browser.creationItems.isEmpty || browser.creationTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 切到不支持分卷的格式（TAR）时自动关掉分卷开关
        .onChange(of: browser.creationFormat) { _, newFormat in
            if !newFormat.supportsSplit { browser.creationSplitEnabled = false }
        }
        .sheet(isPresented: $showsFilenameRepair) {
            FilenameRepairSheet(
                issues: repairIssues,
                onFix: {
                    showsFilenameRepair = false
                    browser.applyFilenameRepairs(repairIssues)
                    browser.confirmCreateArchive()
                },
                onSkip: {
                    showsFilenameRepair = false
                    browser.confirmCreateArchive()
                }
            )
        }
    }

    // 名称 + 存储位置（两个等宽白色圆角框，存储位置下拉框占满整列）
    private var nameAndFolderRow: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("名称")
                    .font(.system(size: Theme.captionSize, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                // 扩展名紧跟名称文字（标题用同字体隐藏文本占位实测宽度，
                // TextField 覆盖其上，扩展名 Text 可见地画在标题后面）
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        Text(browser.creationTitle)
                            .font(.system(size: Theme.bodySize))
                            .fixedSize()
                            .opacity(0)
                        Text(".\(browser.creationFormat.fileExtension)")
                            .font(.system(size: Theme.bodySize))
                            .fixedSize()
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 12)
                    TextField("未命名压缩包", text: $browser.creationTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: Theme.bodySize))
                        .padding(.horizontal, 12)
                }
                .frame(minWidth: 180, alignment: .leading)
                // 与存储位置下拉框统一高度，保证左右两个控件完全等高对齐
                .frame(height: Self.fieldHeight)
                // 明显的浅灰圆角容器 + 细边框
                .background(Theme.formFieldBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.dividerColor, lineWidth: 1)
                )
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Text("存储位置")
                    .font(.system(size: Theme.captionSize, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                // 外层盒子与左侧名称框完全同款（灰底 + 圆角 + 同高 + 细边框），
                // 点击弹出原生 Popover 列表（不是系统 Menu，Menu 的 label 自带内边距会破坏对齐）
                Button {
                    showsFolderPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                        Text(browser.creationFolder?.lastPathComponent ?? "Documents")
                            .font(.system(size: Theme.bodySize))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    // 与名称输入框统一高度
                    .frame(height: Self.fieldHeight)
                    // 明显的浅灰圆角容器 + 细边框
                    .background(Theme.formFieldBackground, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.dividerColor, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsFolderPicker, arrowEdge: .bottom) {
                    folderPickerList
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 存储位置列表弹出（原生 Popover，避免 Menu label 自带内边距破坏视觉对齐）
    @State private var showsFolderPicker = false

    /// Windows 文件名修正弹窗（点「创建压缩包」且检测到不兼容名称时出现）
    @State private var showsFilenameRepair = false
    @State private var repairIssues: [WindowsNameIssue] = []

    private var standardFolders: [(String, URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [("Desktop", home.appendingPathComponent("Desktop")),
                ("Documents", home.appendingPathComponent("Documents")),
                ("Downloads", home.appendingPathComponent("Downloads"))]
    }

    private var folderPickerList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(standardFolders, id: \.1) { folder in
                folderRow(folder.0, url: folder.1)
            }
            Divider().padding(.vertical, 3)
            folderRow("选择文件夹…", url: nil)
        }
        .padding(5)
        .frame(width: 210)
    }

    private func folderRow(_ name: String, url: URL?) -> some View {
        Button {
            showsFolderPicker = false
            if let url { browser.creationFolder = url } else { browser.chooseCreationFolder() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                Text(name)
                    .font(.system(size: Theme.bodySize))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // 目的预设五卡
    private var purposeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("这个压缩包将用于什么?")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 10) {
                ForEach(CreationPurpose.allCases) { purpose in
                    PurposeCard(
                        purpose: purpose,
                        isSelected: browser.creationPurpose == purpose
                    ) {
                        browser.creationPurpose = purpose
                        purpose.apply(to: browser)
                    }
                }
            }
        }
    }

    // 压缩设置 + 压缩包概览（同一浅灰圆角容器，中间竖线分割，左右等高）
    private var settingsAndOverview: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左：压缩设置
            VStack(alignment: .leading, spacing: 8) {
                Text("压缩设置")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("压缩格式")
                        .font(.system(size: Theme.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                    // 所有格式按钮包在同一层浅灰圆角容器里，选中 = 白底胶囊
                    HStack(spacing: 2) {
                        ForEach(CreationFormat.creatableFormats) { format in
                            FormatSegment(
                                title: format.shortName,
                                isSelected: browser.creationFormat == format
                            ) {
                                browser.creationFormat = format
                            }
                        }
                    }
                    .padding(3)
                    .background(Theme.chipBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("压缩强度")
                            .font(.system(size: Theme.captionSize))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(browser.creationFormat == .tar
                            ? CreationStrength.store.word
                            : creationLevelWord(browser.creationLevel))
                            .font(.system(size: Theme.captionSize, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    if browser.creationFormat == .tar {
                        // TAR 无压缩强度滑杆，替换为提示框（仅打包）
                        tarStrengthHint
                    } else {
                        AfzLevelSlider(currentIndex: levelIndexBinding)
                        // 滑杆下方三栏标注（更快 / 当前档紫色 + 副标题 / 更小）
                        HStack(alignment: .top) {
                            Text(CreationStrength.fast.word)
                                .font(.system(size: Theme.captionSize))
                                .foregroundStyle(Theme.textTertiary)
                            Spacer()
                            VStack(spacing: 1) {
                                Text(creationLevelWord(browser.creationLevel))
                                    .font(.system(size: Theme.captionSize, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                Text(levelSubtitle(browser.creationLevel))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Text(CreationStrength.small.word)
                                .font(.system(size: Theme.captionSize))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.leading, 12)
            .padding(.trailing, 16)

            // 中间竖线分割（随容器等高）
            Rectangle()
                .fill(Theme.dividerColor)
                .frame(width: 1)
                .padding(.vertical, 12)

            // 右：压缩包概览（勾选行随用途/格式联动）
            VStack(alignment: .leading, spacing: 6) {
                Text("压缩包概览")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                overviewRow("格式", browser.creationFormatName)
                overviewRow(
                    "压缩强度",
                    browser.creationFormat == .tar
                        ? CreationStrength.store.word
                        : creationLevelWord(browser.creationLevel)
                )
                overviewRow("用途", browser.creationPurpose.rawValue)

                Divider().overlay(Theme.dividerColor)

                overviewCheckRow(
                    title: browser.creationPreserveMetadata
                        ? "保留 macOS 辅助文件"
                        : "清理 macOS 辅助文件",
                    isOn: true
                )
                switch browser.creationFormat {
                case .tar:
                    overviewCheckRow(title: "保留目录结构与 Unix 文件属性", isOn: true)
                    overviewCheckRow(title: "使用 TAR 归档", isOn: true)
                case .zip:
                    overviewCheckRow(title: "采用通用 ZIP 设置", isOn: true)
                case .sevenZip:
                    overviewCheckRow(title: "采用所选归档格式", isOn: true)
                default:
                    overviewCheckRow(title: "采用所选归档格式", isOn: true)
                }
            }
            .frame(width: 240, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.leading, 16)
            .padding(.trailing, 12)
        }
        .creationGroupCard()
    }

    /// TAR 方案的强度提示框（图标 + 「合并为一个压缩包，不压缩内容」
    /// + 副标题「TAR 用于归档目录结构与 Unix 文件信息」）。
    private var tarStrengthHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(CreationStrength.store.subtitle)
                    .font(.system(size: Theme.captionSize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("TAR 用于归档目录结构与 Unix 文件信息")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.dividerColor, lineWidth: 1)
        )
    }

    /// 当前压缩档位的副标题（按档位描述，取值来自字符串表）。
    private func levelSubtitle(_ level: Int) -> String {
        CreationStrength.from(level: level).subtitle
    }

    private func overviewRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: Theme.captionSize))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: Theme.captionSize, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    /// 概览卡勾选行（仅显示当前选项状态，不可点击切换——点击选择请用高级选项里的开关）。
    private func overviewCheckRow(title: String, isOn: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(isOn ? Theme.accent : Theme.textTertiary)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
        }
    }

    // 底部卡：密码保护 + 可折叠高级选项（密码行 / 「高级选项」chevron 折叠行 /
    // 展开后「保留 macOS 辅助文件」「分卷压缩」两个带副标题的开关子行）
    @State private var showsAdvancedOptions = true
    /// 密码本（启用且有条目时，密码框右侧出现钥匙菜单）
    @ObservedObject private var passwordBook = PasswordBook.shared

    private var passwordSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                Text("使用密码保护")
                    .font(.system(size: Theme.bodySize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Toggle("", isOn: $browser.creationPasswordEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .padding(.horizontal, 18)
            // 行高更舒展（约 44pt），不拥挤
            .padding(.vertical, 12)

            if browser.creationPasswordEnabled {
                Divider().overlay(Theme.dividerColor)
                HStack(spacing: 10) {
                    SecureField("输入密码", text: $browser.creationPassword)
                        .textFieldStyle(.plain)
                        .font(.system(size: Theme.bodySize))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
                    if AppSettings.passwordBookEnabled, !passwordBook.entries.isEmpty {
                        Menu {
                            ForEach(passwordBook.entries) { entry in
                                Button(entry.name) {
                                    browser.creationPassword = entry.password
                                }
                            }
                        } label: {
                            Image(systemName: "key.horizontal")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 22, height: 22)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("从密码本选择")
                    }
                    Text(browser.creationFormat.supportsEncryption
                        ? (browser.creationFormat == .zip ? "ZIP AES-256 加密" : "7Z 加密（含文件名）")
                        : "TAR 不支持内置加密")
                        .font(.system(size: Theme.captionSize))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
            }

            Divider().overlay(Theme.dividerColor)

            // 高级选项折叠行（三横线图标 + 标题 + 右侧上下箭头）
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showsAdvancedOptions.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                    Text("高级选项")
                        .font(.system(size: Theme.bodySize, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(showsAdvancedOptions ? 0 : 180))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            if showsAdvancedOptions {
                advancedToggleRow(
                    title: "保留 macOS 辅助文件",
                    subtitle: browser.creationFormat.usesAppleDoubleMetadata
                        ? "扩展属性写成 __MACOSX/._*（与访达压缩一致）"
                        : "扩展属性写入 tar 扩展头，不产生 __MACOSX",
                    isOn: $browser.creationPreserveMetadata
                )
                // 子行之间也有一条淡分割线（与文字左缘对齐）
                advancedDivider
                // 分卷设置块：设置页「默认创建分卷压缩包」未启用时整块隐藏
                //（含 TAR 的置灰提示行——用户不想用分卷就不出现任何分卷内容）
                if AppSettings.defaultCreationSplitEnabled {
                    if browser.creationFormat.supportsSplit {
                        advancedToggleRow(
                            title: "分卷压缩",
                            subtitle: "将压缩包拆分成多个文件",
                            isOn: $browser.creationSplitEnabled
                        )
                        // 分卷二级选项：开启后显示每卷大小选择
                        if browser.creationSplitEnabled {
                            advancedDivider
                            splitSizeRow
                        }
                    } else {
                        // 「TAR 不支持分卷压缩」——置灰并说明
                        advancedToggleRow(
                            title: "分卷压缩",
                            subtitle: "TAR 不支持分卷压缩",
                            isOn: .constant(false),
                            isDisabled: true
                        )
                    }
                }
            }
        }
        .creationGroupCard()
    }

    /// 高级选项内子行之间的淡分割线（左侧与子行文字缩进对齐，右侧留边）。
    private var advancedDivider: some View {
        Rectangle()
            .fill(Theme.dividerColor)
            .frame(height: 1)
            .padding(.leading, 42)
            .padding(.trailing, 18)
    }

    /// 高级选项内的开关子行（标题 + 小字副标题 + 右侧开关，相对主行缩进）。
    private func advancedToggleRow(
        title: String, subtitle: String, isOn: Binding<Bool>, isDisabled: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: Theme.bodySize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(isDisabled)
        }
        .padding(.leading, 42)
        .padding(.trailing, 18)
        // 带副标题的子行更高（标题+副标题 + 上下呼吸空间）
        .padding(.vertical, 9)
    }

    /// 分卷二级选项：每卷大小。
    /// 作为「分卷压缩」的子条目：左侧竖向引导线 + 更深缩进 + 与上方子行**同构**
    /// （标题 + 小字副标题两行，右侧控件），行高自然与兄弟行一致。
    /// Popover 内既可选预设，也可自己输入数字 + KB/MB/GB 单位（十进制，与访达显示一致）。
    @State private var showsSplitSizePopover = false

    private var splitSizeRow: some View {
        HStack(spacing: 10) {
            // 子条目引导线：贯穿整行高度，视觉上「挂」在分卷压缩下面
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.dividerColor)
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                Text("每卷大小")
                    .font(.system(size: Theme.bodySize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("可自定义，范围 64 KB – 50 GB")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            Button {
                showsSplitSizePopover = true
            } label: {
                HStack(spacing: 6) {
                    Text(browser.creationSplitSizeName)
                        .font(.system(size: Theme.captionSize, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.formFieldBackground, in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Theme.dividerColor, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsSplitSizePopover, arrowEdge: .bottom) {
                splitSizePopover
            }
        }
        .padding(.leading, 42)
        .padding(.trailing, 18)
        .padding(.vertical, 9)
    }

    /// 每卷大小的 Popover：预设列表 + 自定义（数字 + 单位）+ 结果提示。
    private var splitSizePopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("预设")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)

            ForEach(ArchiveBrowser.creationSplitSizes, id: \.value) { size in
                Button {
                    browser.selectSplitPreset(value: size.value)
                } label: {
                    HStack {
                        Text(size.name)
                            .font(.system(size: Theme.bodySize))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if browser.creationSplitSize == size.value {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider().padding(.vertical, 6)

            Text("自定义")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 14)
                .padding(.bottom, 5)

            HStack(spacing: 8) {
                TextField("大小", text: $browser.creationSplitCustomNumber)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.bodySize))
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(width: 66)
                    .background(Theme.formFieldBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                browser.isCustomSplitSizeValid ? Theme.dividerColor : Color.red.opacity(0.55),
                                lineWidth: 1
                            )
                    )
                    .onSubmit { applyCustomSplit(rewrite: true) }

                Picker("", selection: $browser.creationSplitCustomUnit) {
                    Text("KB").tag("k")
                    Text("MB").tag("m")
                    Text("GB").tag("g")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 128)
                .onChange(of: browser.creationSplitCustomUnit) { _, _ in applyCustomSplit(rewrite: true) }
            }
            .padding(.horizontal, 14)

            Text(browser.isCustomSplitSizeValid
                ? "将按 \(browser.creationSplitSizeName) 分卷"
                : "超出范围，将按 \(browser.creationSplitSizeName) 分卷（64 KB – 50 GB）")
                .font(.system(size: 10))
                .foregroundStyle(browser.isCustomSplitSizeValid ? Theme.textTertiary : Color.red.opacity(0.8))
                .padding(.horizontal, 14)
                .padding(.top, 6)
        }
        .padding(.vertical, 10)
        .frame(width: 236)
        .onChange(of: browser.creationSplitCustomNumber) { _, _ in applyCustomSplit(rewrite: false) }
    }

    private func applyCustomSplit(rewrite: Bool) {
        browser.applyCustomSplitSize(rewriteInput: rewrite)
    }
}

// MARK: - 创建进度胶囊（与解压进度胶囊同一形态：进度 + 取消）

struct CreationProgressChip: View {
    @Bindable var browser: ArchiveBrowser

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: browser.creationFraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .frame(width: 14, height: 14)

            Text("\(Int(browser.creationFraction * 100))%")
                .font(.system(size: Theme.captionSize))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .fixedSize()

            Text("正在创建 \(browser.creationDisplayName)")
                .font(.system(size: Theme.captionSize))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .leading)

            Button {
                browser.cancelCreation()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(Theme.dividerColor, in: Circle())
            }
            .buttonStyle(.plain)
            .afzHelp("取消创建", placement: .above)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.chipBackground, in: Capsule())
    }
}

// MARK: - 小组件

/// 压缩强度滑杆（自绘：紫色渐变轨道 + 5 个档位圆点 + 白色圆形滑块，拖拽吸附档位）。
/// 系统 Slider 无法呈现「轨道圆点 + 阴影滑块」的样式，此处为必要的自绘。
struct AfzLevelSlider: View {
    @Binding var currentIndex: Int
    var tickCount: Int = 5

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let trackHeight: CGFloat = 20
            let midY = geo.size.height / 2
            let step = width / CGFloat(tickCount - 1)
            let thumbX = step * CGFloat(currentIndex)
            ZStack(alignment: .leading) {
                // 未填充轨道
                Capsule()
                    .fill(Theme.chipBackground)
                    .frame(height: trackHeight)
                // 已填充紫色渐变轨道
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent.opacity(0.7), Theme.accent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(trackHeight, thumbX), height: trackHeight)
                // 档位圆点（填充段内白点，段外灰点）
                ForEach(0..<tickCount, id: \.self) { i in
                    Circle()
                        .fill(i <= currentIndex ? Color.white.opacity(0.9) : Theme.dividerColor)
                        .frame(width: 8, height: 8)
                        .position(x: step * CGFloat(i), y: midY)
                }
                // 白色圆形滑块（带阴影）
                Circle()
                    .fill(Theme.cardBackground)
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.20), radius: 3, y: 1)
                    .overlay(Circle().strokeBorder(Theme.dividerColor, lineWidth: 0.5))
                    .position(x: thumbX, y: midY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let idx = Int((value.location.x / step).rounded())
                        currentIndex = min(max(idx, 0), tickCount - 1)
                    }
            )
        }
        .frame(height: 30)
    }
}

/// 目的预设卡片（图标 + 标题 + 副标题，选中紫色底白字）。
struct PurposeCard: View {
    let purpose: CreationPurpose
    let isSelected: Bool
    let action: () -> Void

    private var symbolName: String {
        switch purpose {
        case .general: return "person.2"
        case .windows: return "macwindow"
        case .mac: return "desktopcomputer"
        case .linux: return "terminal"
        case .smallest: return "leaf"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbolName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.onAccent : Theme.textPrimary)
                    .frame(height: 19)
                Text(purpose.rawValue)
                    .font(.system(size: Theme.bodySize, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.onAccent : Theme.textPrimary)
                Text(purpose.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Theme.onAccent.opacity(0.8) : Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(
                isSelected ? Theme.accent : Theme.cardBackground,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? .clear : Theme.dividerColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// 格式分段按钮（同一圆角容器内的分段，选中 = 白底胶囊紫字，未选中 = 透明灰字）。
struct FormatSegment: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    isSelected ? Theme.cardBackground : .clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isSelected ? Theme.dividerColor : .clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Windows 文件名修正弹窗（创建前的兼容性检查与批量改名）

/// 「Windows 用户」方案创建前的不兼容文件名确认清单：
/// 展示旧名 → 建议名，可选「修正并压缩」（只改包内名称）或「直接压缩」。
struct FilenameRepairSheet: View {
    let issues: [WindowsNameIssue]
    let onFix: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("修正不兼容文件名")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("以下文件名在 Windows 中可能无法正常使用。请检查或修改建议名称。")
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 22)
            .padding(.horizontal, 24)
            .padding(.bottom, 14)

            // 清单
            VStack(alignment: .leading, spacing: 6) {
                Text("待确认：\(issues.count) 个文件名")
                    .font(.system(size: Theme.captionSize, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(issues) { issue in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(issue.oldName)
                                        .font(.system(size: Theme.bodySize))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(issue.relativePath)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                Text(issue.suggested)
                                    .font(.system(size: Theme.bodySize, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(2)
                }
            }
            .padding(.horizontal, 20)

            Text("只会修改压缩包内的名称，源文件不受影响。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)

            // 按钮
            HStack(spacing: 12) {
                Button {
                    onSkip()
                } label: {
                    Text("直接压缩")
                        .font(.system(size: Theme.bodySize, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Theme.chipBackground, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.dividerColor, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    onFix()
                } label: {
                    Text("修正并压缩")
                        .font(.system(size: Theme.bodySize, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 18)
        }
        .frame(width: 440)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
    }
}
