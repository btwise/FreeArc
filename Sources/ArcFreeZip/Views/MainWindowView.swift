import SwiftUI
import AppKit
import Quartz
import ArchiveCore

struct MainWindowView: View {
    @State private var browser = ArchiveBrowser()
    @State private var didHandleInitialURL = false
    /// 订阅主题配色：设置里切换配色后，已打开的主窗口 / 欢迎窗立即按新色板重绘
    @ObservedObject private var skin = SkinStore.shared
    @Environment(\.openWindow) private var openWindow
    /// AppKit 兜底直建窗口时传 false：那种宿主里 openWindow 环境是 no-op，
    /// 不能让它覆盖 router 里真正的 scene 动作（否则后续开窗全部静默失效）。
    var attachesOpenWindow: Bool = true
    /// 批量打开时由 AppKit 直建窗口注入的初始压缩包（不走 router 排队，见 openBatch）。
    var initialURL: URL? = nil

    var body: some View {
        Group {
            if browser.workMode == .create {
                // 创建工作台（"新压缩包"窗口：标题可编辑 + 添加文件 + 保存）
                CreationWorkspaceView(browser: browser)
            } else {
                switch browser.state {
                case .empty:
                    WelcomeView(browser: browser)
                case .loading:
                    if browser.dmgMountFraction != nil {
                        // 校验卡片出现在文件浏览区内，顶栏/详情面板/底栏照常显示
                        DmgVerifyWorkspaceView(browser: browser)
                    } else {
                        ProgressView("正在读取压缩包…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .failed(let message):
                    FailureView(message: message, browser: browser)
                case .locked:
                    // 加密文件名（7z 等）：窗口照常打开成「锁定态」，正文给输入密码入口
                    LockedArchiveView(browser: browser)
                case .loaded:
                    if browser.windowMode == .mini {
                        MiniView(browser: browser)
                    } else {
                        LoadedView(browser: browser)
                    }
                }
            }
        }
        // 欢迎态用启动窗尺寸（内容 561×363，窗口整体 561×391）；mini 模式允许更小；其余保持主窗口最小尺寸
        .frame(
            minWidth: isWelcome ? WindowModeController.welcomeContentSize.width
                : (browser.windowMode == .mini ? 520 : 880),
            minHeight: isWelcome ? WindowModeController.welcomeContentSize.height
                : (browser.windowMode == .mini ? 380 : 560)
        )
        .background(Theme.canvasBackground)
        // 窗口标题跟随压缩包名（多窗口时便于在"窗口"菜单中区分）
        .navigationTitle(browser.activeLayerName)
        // 窗口尺寸与置顶联动（的 mini 模式）；同时把窗口登记到多窗口路由
        .background(WindowModeController(
            mode: browser.windowMode,
            isPinned: browser.isPinned,
            browser: browser,
            isWelcome: isWelcome,
            isOptions: browser.showsCreationOptions
        ))
        // 悬停提示气泡：统一改为原生 Popover（AppKit 负责底色/箭头/避让），无需宿主
        // ⌘A 全选当前目录条目（隐藏按钮挂快捷键；mini 与完整窗口共用）
        .background {
            Button("全选") {
                // 文本输入中把 ⌘A 还给系统（搜索框、重命名框等）
                if let editor = NSApp.keyWindow?.firstResponder as? NSText, editor.isFieldEditor {
                    editor.selectAll(nil)
                } else {
                    browser.selectAllVisible()
                }
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(browser.visibleNodes.isEmpty)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        // 空格键：调用系统 Quick Look 预览选中文件
        .spaceQuickLook { browser.quickLookSelected() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        // ⌘O 命令按窗口分发（见 ArchiveCommands）
        .focusedSceneValue(\.archiveBrowser, browser)
        // 密码对话框挂在根视图：打开阶段（loading 态）也需要弹出（居中卡片样式）
        .overlay {
            if browser.showsPasswordAlert {
                PasswordDialogCard(browser: browser)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .animation(.easeOut(duration: 0.15), value: browser.showsPasswordAlert)
            }
        }
        .onAppear {
            NSApp.windows.first?.isMovableByWindowBackground = true
            // 多窗口路由：注入 scene 级 openWindow 动作（供其它入口新开窗口）；
            // AppKit 兜底直建的窗口（attachesOpenWindow=false）环境动作是 no-op，不能注入
            if attachesOpenWindow {
                ArchiveWindowRouter.shared.attach(openWindow: openWindow)
            }
            // 新窗口取走路由排队给它的压缩包 URL（多窗口打开时）→ 只处理一次
            if !didHandleInitialURL {
                didHandleInitialURL = true
                if let initialURL {
                    // 批量打开：URL 随窗口一起注入，不依赖全局队列时序
                    browser.open(url: initialURL)
                } else if let creationURLs = ArchiveWindowRouter.shared.consumePendingCreationURLs() {
                    // 文件盒「放入工作区」/ 右键「压缩为…」「加密压缩…」排队来的创建请求优先于普通打开请求
                    browser.startCreation()
                    browser.addCreationItems(urls: creationURLs)
                    if ArchiveWindowRouter.shared.consumePendingCreationEncrypt() {
                        browser.creationPasswordEnabled = true
                    }
                } else if let pendingURL = ArchiveWindowRouter.shared.consumePendingWindowURL() {
                    browser.open(url: pendingURL)
                }
            }
            // 调试探针统一开关：环境变量 AFZ_PROBE=1 或一次性标记文件 /tmp/afz-probe-enable
            // （血泪教训：/tmp 残留的探针标记曾让正常双击启动直接报"文件不存在"→ 标记文件读后即删）
            let envProbe = ProcessInfo.processInfo.environment["AFZ_PROBE"] == "1"
            guard envProbe || ProbeFlags.isActive else { return }
            if !envProbe { ProbeFlags.consumeFileGate(); ProbeFlags.markConsumed() }
            // 探针：AFZ_PROBE_CLOSE_MAIN=1 → 6 秒后程序化关闭本浏览窗口
            // （验证关窗资源回收：DMG/ISO 挂载应即时卸载，而非残留到下次启动兜底清理）
            if ProcessInfo.processInfo.environment["AFZ_PROBE_CLOSE_MAIN"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    let win = NSApp.windows.first { $0.isVisible && $0.frame.width >= 880 }
                    NSLog("AFZ-CLOSEMAIN closing=%d", win == nil ? 0 : 1)
                    win?.close()
                }
            }
            // 探针：进入 mini 的时机统一放在「压缩包加载完成」钩子里
            // （启动期进 mini 会被欢迎窗→完整窗的尺寸分支盖回 900×600）
            // 探针：存在 /tmp/afz-probe-create 标记文件 → 启动即进入创建工作台并填入测试文件（自动化实测用）
            if FileManager.default.fileExists(atPath: "/tmp/afz-probe-create") {
                browser.startCreation()
                // 探针测试：存储位置用 /tmp（绕开 Documents 的 TCC 权限，终端启动的应用无权写入）
                try? FileManager.default.createDirectory(atPath: "/tmp/afz-out", withIntermediateDirectories: true)
                browser.creationFolder = URL(fileURLWithPath: "/tmp/afz-out", isDirectory: true)
                let fm = FileManager.default
                // 待打包内容：默认枚举 /tmp/afz-create-src；
                // 可用一次性文件 /tmp/afz-probe-src 指定其它目录（测大文件进度，避免拷贝）
                let srcDir = (try? String(contentsOfFile: "/tmp/afz-probe-src", encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "/tmp/afz-create-src"
                try? fm.removeItem(atPath: "/tmp/afz-probe-src")
                let urls = (try? fm.contentsOfDirectory(atPath: srcDir))?
                    .map { "\(srcDir)/\($0)" }
                    .filter { fm.fileExists(atPath: $0) } ?? []
                browser.addCreationItems(urls: urls.map(URL.init(fileURLWithPath:)))
                // 探针：一次性标记文件 → 强制开启「保留 macOS 辅助文件」（端到端实测用）
                if FileManager.default.fileExists(atPath: "/tmp/afz-probe-preserve") {
                    try? fm.removeItem(atPath: "/tmp/afz-probe-preserve")
                    browser.creationPreserveMetadata = true
                }
                // 探针：一次性标记文件 → 直接执行创建（端到端校验产物内容）
                if FileManager.default.fileExists(atPath: "/tmp/afz-probe-autocreate") {
                    try? fm.removeItem(atPath: "/tmp/afz-probe-autocreate")
                    // 可选：/tmp/afz-probe-format 内容为 zip/7z/tar/gz/xz/zst
                    if let raw = try? String(contentsOfFile: "/tmp/afz-probe-format", encoding: .utf8) {
                        try? fm.removeItem(atPath: "/tmp/afz-probe-format")
                        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                        if let format = CreationFormat.creatableFormats.first(where: {
                            $0.shortName == key || $0.rawValue.uppercased() == key || $0.fileExtension.uppercased() == key
                        }) {
                            browser.creationFormat = format
                        }
                    }
                    // 可选：/tmp/afz-probe-split 内容为分卷大小（如 1m/10m/100m/1g）
                    if let raw = try? String(contentsOfFile: "/tmp/afz-probe-split", encoding: .utf8) {
                        try? fm.removeItem(atPath: "/tmp/afz-probe-split")
                        let size = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !size.isEmpty {
                            browser.creationSplitEnabled = true
                            browser.creationSplitSize = size
                        }
                    }
                    browser.confirmCreateArchive()
                }
                // 直接进入「创建压缩包」选项界面（自动化截图用）：环境变量或一次性标记文件
                let envCreate = ProcessInfo.processInfo.environment["AFZ_PROBE_CREATE_OPTIONS"] == "1"
                let fileCreate = FileManager.default.fileExists(atPath: "/tmp/afz-probe-create-options")
                if fileCreate { try? FileManager.default.removeItem(atPath: "/tmp/afz-probe-create-options") }
                if envCreate || fileCreate {
                    // 截图探针：残留的 /tmp/afz-probe-split → 打开分卷并预置大小
                    if let raw = try? String(contentsOfFile: "/tmp/afz-probe-split", encoding: .utf8) {
                        try? fm.removeItem(atPath: "/tmp/afz-probe-split")
                        let size = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !size.isEmpty {
                            browser.creationSplitEnabled = true
                            browser.creationSplitSize = size
                        }
                    }
                    browser.showsCreationOptions = true
                }
            }
            // 探针：/tmp/afz-probe-extract 内容 "压缩包路径|目标目录" → 打开后直接全部解压
            // （实测解压进度卡与完成后访达定位；一次性文件读后即删）
            if let raw = try? String(contentsOfFile: "/tmp/afz-probe-extract", encoding: .utf8) {
                try? FileManager.default.removeItem(atPath: "/tmp/afz-probe-extract")
                let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "|").map(String.init)
                if parts.count == 2 {
                    browser.open(url: URL(fileURLWithPath: parts[0]))
                    let dest = URL(fileURLWithPath: parts[1])
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        browser.probeExtractAll(to: dest)
                    }
                }
            }
            // 探针：/tmp/afz-probe-open 内容为文件路径 → 启动即打开该压缩包（自动化实测密码流程用）
            // 一次性标记文件：读后即删，否则残留会让正常启动永远报「文件不存在」
            if let raw = try? String(contentsOfFile: "/tmp/afz-probe-open", encoding: .utf8) {
                try? FileManager.default.removeItem(atPath: "/tmp/afz-probe-open")
                let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty {
                    browser.open(url: URL(fileURLWithPath: target))
                }
            }
            // 探针：/tmp/afz-probe-nest 内容为压缩包路径 → 打开后自动「双击」第一个嵌套压缩条目，
            // 打印层级链/详情/条目数，可选 /tmp/afz-probe-nest-extract 目录 = 嵌套态直接全部解压
            // （验证解压作用于内层），最后返回上层验证外层恢复。一次性文件读后即删。
            if let raw = try? String(contentsOfFile: "/tmp/afz-probe-nest", encoding: .utf8) {
                try? FileManager.default.removeItem(atPath: "/tmp/afz-probe-nest")
                let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty {
                    var extractDest = ""
                    if let rawDest = try? String(contentsOfFile: "/tmp/afz-probe-nest-extract", encoding: .utf8) {
                        extractDest = rawDest.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    try? FileManager.default.removeItem(atPath: "/tmp/afz-probe-nest-extract")
                    browser.open(url: URL(fileURLWithPath: target))
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        guard let node = browser.root.children.first(where: { browser.canEnterNested($0) }) else {
                            NSLog("AFZ-NEST no-nested-entry in \(target)")
                            return
                        }
                        NSLog("AFZ-NEST entering=\(node.name)")
                        browser.enterNested(node)
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        NSLog(
                            "AFZ-NEST inside chain=[\(browser.nestedTitleChain.joined(separator: " > "))] "
                                + "format=\(browser.summary?.format.rawValue ?? "?") "
                                + "visible=\(browser.visibleNodes.count) encrypted=\(browser.isArchiveEncrypted)"
                        )
                        if !extractDest.isEmpty {
                            browser.probeExtractAll(to: URL(fileURLWithPath: extractDest))
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                        }
                        browser.popNestedLayer()
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        NSLog(
                            "AFZ-NEST popped nested=\(browser.isNestedBrowsing) "
                                + "displayName=\(browser.displayName) "
                                + "format=\(browser.summary?.format.rawValue ?? "?") "
                                + "visible=\(browser.visibleNodes.count) "
                                + "mode=\(browser.workMode == .browse ? "browse" : "create")"
                        )
                    }
                }
            }
            // 探针：/tmp/afz-probe-nest-disk 内容为压缩包路径 → 创建工作台加入该文件后
            // 双击进入嵌套浏览，验证「整个工作区变为可解压浏览态 + 返回恢复创建台」。
            if let raw = try? String(contentsOfFile: "/tmp/afz-probe-nest-disk", encoding: .utf8) {
                try? FileManager.default.removeItem(atPath: "/tmp/afz-probe-nest-disk")
                let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty {
                    browser.startCreation()
                    browser.addCreationItems(urls: [URL(fileURLWithPath: target)])
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        browser.enterNestedFromDisk(url: URL(fileURLWithPath: target))
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        NSLog(
                            "AFZ-NEST-DISK inside chain=[\(browser.nestedTitleChain.joined(separator: " > "))] "
                                + "mode=\(browser.workMode == .browse ? "browse" : "create") "
                                + "visible=\(browser.visibleNodes.count)"
                        )
                        browser.popNestedLayer()
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        NSLog(
                            "AFZ-NEST-DISK popped mode=\(browser.workMode == .browse ? "browse" : "create") "
                                + "items=\(browser.creationItems.count) "
                                + "chainEmpty=\(!browser.isNestedBrowsing)"
                        )
                    }
                }
            }
        }
    }

    /// 欢迎态：未打开压缩包、也未进入创建工作台；打开失败的错误页沿用同一窗口尺寸。
    private var isWelcome: Bool {
        guard browser.workMode != .create else { return false }
        switch browser.state {
        case .empty, .failed: return true
        default: return false
        }
    }

    /// 可打开的压缩包扩展名（欢迎页拖入时区分「打开压缩包」与「创建压缩包」）。
    private static let archiveExtensions: Set<String> = [
        "zip", "zipx", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz",
        "dmg", "cab", "iso", "lz", "lzma", "zst", "jar"
    ]

    private static func isArchiveFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return false
        }
        return archiveExtensions.contains(url.pathExtension.lowercased())
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let isCreate = browser.workMode == .create
        let isWelcomePage = isWelcome
        // 先把一次拖入的全部地址收齐再统一处理：同名冲突要合并成一批确认，
        // 逐条处理会变成连续弹多个窗。
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.loadDroppedURL(from: provider) { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            if isCreate {
                // 创建工作台：拖入普通文件 → 加入待打包列表
                browser.addCreationItems(urls: urls)
                return
            }
            if isWelcomePage {
                // 欢迎页（"拖入文件以创建压缩包"）：
                // 压缩包 → 打开；普通文件 / 文件夹 → 直接进入创建工作台
                for url in urls {
                    if Self.isArchiveFile(url) {
                        browser.open(url: url)
                    } else {
                        browser.startCreation()
                        browser.addCreationItems(urls: [url])
                    }
                }
                return
            }
            if browser.state == .loaded, browser.workMode == .browse {
                // 浏览态：压缩包 → 打开；普通文件/文件夹 → 添加到压缩包（"拖入添加"，保存时落盘）
                let additions = urls.filter { !Self.isArchiveFile($0) }
                if !additions.isEmpty {
                    // 拖拽会话收尾后再弹同名确认：拖拽进行中嵌套模态窗会静默失效
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    browser.addExternalFiles(additions)
                }
                for url in urls where Self.isArchiveFile(url) {
                    browser.open(url: url)
                }
            } else {
                for url in urls { browser.open(url: url) }
            }
        }
        return true
    }

    /// 从拖放提供者读取文件地址（回调可能不在主线程，统一用续体桥接）。
    private static func loadDroppedURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

}


// MARK: - 欢迎窗顶部条（欢迎页与错误页共用：仅 logo；设置齿轮移至窗口右下角）

struct WelcomeTopBar: View {
    var body: some View {
        HStack {
            Spacer()
            BrandLogoView(iconSize: 22, fontSize: 17)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }
}

/// 设置齿轮按钮（欢迎窗右下角；错误页同款复用）
struct WelcomeSettingsGear: View {
    var body: some View {
        Button {
            ArchiveWindowRouter.shared.openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Theme.welcomeChipBackground, in: Circle())
                .overlay(Circle().strokeBorder(Theme.dividerColor, lineWidth: 0.8))
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .afzHelp("设置")
    }
}

/// 欢迎窗背景（左上白粉 → 中部淡粉 → 右下淡紫）。
struct WelcomeGradient: View {
    var body: some View {
        // ignoresSafeArea：让渐变延伸到 hiddenTitleBar 的透明标题栏后面（否则顶部露出白条）
        LinearGradient(
            colors: [Theme.welcomeGradientTop, Theme.welcomeGradientMid, Theme.welcomeGradientBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

// MARK: - 欢迎页（启动窗：561×391 渐变背景 + 中央提示 + 两个胶囊按钮 + 设置齿轮）

/// 欢迎窗顶部轮播文案：三条提示淡入淡出轮换（ZStack 叠放交叉淡化，布局不跳动）
private struct RotatingTagline: View {
    private let messages = [
        "拖入压缩包进行预览或解压",
        "支持 ZIP · 7Z · RAR · TAR · DMG 等多种格式",
        "双击包内压缩包可进入嵌套浏览",
    ]

    @State private var index = 0
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            ForEach(messages.indices, id: \.self) { i in
                Text(messages[i])
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .opacity(i == index ? 1 : 0)
                    .scaleEffect(i == index ? 1 : 0.97)
            }
        }
        .frame(height: 32)
        .animation(.easeInOut(duration: 0.55), value: index)
        .onAppear { schedule() }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.55)) {
                index = (index + 1) % messages.count
            }
        }
    }
}

struct WelcomeView: View {
    @Bindable var browser: ArchiveBrowser

    var body: some View {
        ZStack {
            WelcomeGradient()

            VStack(spacing: 0) {
                WelcomeTopBar()

                Spacer(minLength: 0)

                RotatingTagline()

                Spacer().frame(height: 38)

                HStack(spacing: 14) {
                    WelcomeActionButton(
                        icon: "archivebox",
                        title: "打开压缩包",
                        emphasized: false,
                        help: "选择一个压缩包文件打开浏览"
                    ) {
                        browser.presentOpenPanel()
                    }
                    WelcomeActionButton(
                        icon: "plus.square.dashed",
                        title: "创建压缩包",
                        emphasized: true,
                        help: "新建压缩包，加入待打包文件"
                    ) {
                        browser.startCreation()
                    }
                }

                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }

            // 设置齿轮：窗口右下角（原右上角，为按钮卡片让出视觉重心）
            VStack {
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    WelcomeSettingsGear()
                        .padding(.trailing, 16)
                        .padding(.bottom, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 欢迎按钮：大语义图标 + 文字；悬停浮现柔和卡片容器并轻微上浮
    private struct WelcomeActionButton: View {
        let icon: String
        let title: String
        let emphasized: Bool
        let help: String
        let action: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                VStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(emphasized ? Theme.accent : Theme.textSecondary)
                    Text(title)
                        .font(.system(size: 13, weight: emphasized ? .semibold : .medium))
                        .foregroundStyle(Theme.textPrimary)
                }
                .frame(width: 150, height: 116)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                // 悬停卡片随欢迎渐变色系（welcomeChip），彩色主题下不再浮出白版
                RoundedRectangle(cornerRadius: 18)
                    .fill(Theme.welcomeChipBackground)
                    .opacity(hovering ? 0.92 : 0)
                    .shadow(color: .black.opacity(hovering ? 0.07 : 0), radius: 12, y: 4)
            )
            .scaleEffect(hovering ? 1.04 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovering)
            .onHover { hovering = $0 }
            .afzHelp(help)
        }
    }
}

// MARK: - 打开失败页
// 与欢迎页同一套形态（渐变底 + 顶栏 + 中央说明 + 胶囊按钮），只是多出几行错误原因与建议：
// 出错不该出现"白版"，而是回到用户熟悉的入口界面继续操作。

struct FailureView: View {
    let message: String
    let browser: ArchiveBrowser

    private var failure: AppFailure { .open(message) }

    var body: some View {
        ZStack {
            WelcomeGradient()

            VStack(spacing: 0) {
                WelcomeTopBar()

                Spacer(minLength: 0)

                Image(systemName: failure.symbol)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.textTertiary)

                Text(failure.title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 12)

                Text(failure.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 40)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(failure.hints, id: \.self) { hint in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("•")
                            Text(hint)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.top, 14)
                .padding(.horizontal, 24)

                Spacer().frame(height: 24)

                HStack(spacing: 12) {
                    // 主操作：换一个文件再试
                    Button { openOther() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "folder")
                                .font(.system(size: 13, weight: .medium))
                            Text("打开其他压缩包")
                                .font(.system(size: 13.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 19)
                        .frame(height: 40)
                        .background(Theme.accent, in: Capsule())
                        .shadow(color: Theme.accent.opacity(0.28), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)

                    // 次操作：回到欢迎页（也是本页在出错后保持的形态）
                    Button { browser.close() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "house")
                                .font(.system(size: 12, weight: .medium))
                            Text("返回欢迎页")
                                .font(.system(size: 13.5, weight: .medium))
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 19)
                        .frame(height: 40)
                        // 随欢迎渐变色系，彩色主题下不再浮出白胶囊
                        .background(Theme.welcomeChipBackground, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.dividerColor, lineWidth: 1))
                        .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }

            // 设置齿轮：与欢迎窗一致的右下角位置
            VStack {
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    WelcomeSettingsGear()
                        .padding(.trailing, 16)
                        .padding(.bottom, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openOther() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.begin { response in
            if response == .OK, let url = panel.url {
                browser.open(url: url)
            }
        }
    }
}

// MARK: - 锁定窗口（加密文件名格式：7z/压缩包还没解锁）
// 交互与 ZIP 保持一致：窗口照常打开、顶栏是包名 + 黄锁，正文说明原因并给「输入密码」入口；
// 密码本自动尝试在后台跑，命中会自动解锁。取消密码框回到这里，不转圈也不跳错误页。

struct LockedArchiveView: View {
    @Bindable var browser: ArchiveBrowser

    var body: some View {
        ZStack {
            WelcomeGradient()

            VStack(spacing: 0) {
                WelcomeTopBar()

                Spacer(minLength: 0)

                // 锁标识：与浏览态黄锁同色系，一眼看出是「加密待解锁」而不是出错
                ZStack {
                    Circle()
                        .fill(Color(red: 0.95, green: 0.62, blue: 0.10).opacity(0.14))
                        .frame(width: 68, height: 68)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color(red: 0.95, green: 0.62, blue: 0.10))
                }

                Text(browser.displayName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 14)
                    .padding(.horizontal, 40)

                Text("该压缩包加密了文件名，验证密码后才能列出内容。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 6)

                // 密码本自动尝试进行中：显示进度而不是干等
                Group {
                    if browser.isTryingPasswordBook {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在尝试密码本…")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else if browser.openPasswordWrong {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                            Text("密码不正确")
                                .font(.system(size: 11.5))
                        }
                        .foregroundStyle(Theme.dangerText)
                    } else {
                        Color.clear.frame(height: 14)
                    }
                }
                .frame(height: 18)
                .padding(.top, 8)

                Spacer().frame(height: 18)

                HStack(spacing: 12) {
                    Button { browser.promptUnlock() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 12, weight: .medium))
                            Text("输入密码")
                                .font(.system(size: 13.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 19)
                        .frame(height: 40)
                        .background(Theme.accent, in: Capsule())
                        .shadow(color: Theme.accent.opacity(0.28), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)

                    Button { browser.close() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "house")
                                .font(.system(size: 12, weight: .medium))
                            Text("返回欢迎页")
                                .font(.system(size: 13.5, weight: .medium))
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 19)
                        .frame(height: 40)
                        .background(Theme.welcomeChipBackground, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.dividerColor, lineWidth: 1))
                        .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }

            VStack {
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    WelcomeSettingsGear()
                        .padding(.trailing, 16)
                        .padding(.bottom, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 主工作区（已加载）
// 布局圆角卡片浮在画布上，顶部工具栏，导航栏，列表，底部快捷区，右侧详情。

struct LoadedView: View {
    @Bindable var browser: ArchiveBrowser
    @State private var searchFieldVisible = false
    /// 右侧详情面板折叠状态（键与默认值收口在 AppSettings；默认折叠，用户手动调整后持久化）
    @AppStorage(AppSettings.detailCollapsedKey) private var detailCollapsed = AppSettings.detailCollapsedDefault
    /// 「通用 → 浏览」设置：默认视图模式与辅助文件显示（改动即时同步到已打开窗口）
    @AppStorage(AppSettings.defaultViewModeKey) private var defaultViewModeRaw = 1
    @AppStorage(AppSettings.showAuxiliaryFilesKey) private var showAuxiliaryFiles = false

    var body: some View {
        // 文件区白卡与右侧详情板是两个**贯穿窗口全高**的大容器，
        // 顶栏（标题/工具）与底栏都浮在左卡内部，而不是把容器压矮
        HStack(spacing: 10) {
            MainBrowserCard(browser: browser, searchFieldVisible: $searchFieldVisible)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: defaultViewModeRaw) { _, newValue in
            // 设置窗口改默认浏览方式：已打开窗口同步（磁盘映像层保持图标布局不受影响）
            if !browser.showsVolumeLayout, let mode = ArchiveBrowser.ViewMode(rawValue: newValue) {
                browser.viewMode = mode
            }
        }
        .onChange(of: showAuxiliaryFiles) { _, newValue in
            browser.showHiddenFiles = newValue
        }
        .overlay {
            // 独占进度卡（浮窗）：解压耗时任务时居中显示，与底部胶囊并存
            if browser.isExtracting {
                TaskProgressCard(
                    symbol: "archivebox",
                    title: "正在解压",
                    name: browser.extractCurrentName
                        ?? browser.url?.deletingPathExtension().lastPathComponent
                        ?? "压缩包",
                    fraction: browser.extractProgress,
                    detail: browser.extractTotal > 0 && browser.extractCompleted > 0
                        ? "\(browser.extractCompleted) / \(browser.extractTotal) 个文件"
                        : nil
                ) {
                    browser.cancelExtraction()
                }
                .transition(.opacity)
            } else if browser.isSaving {
                SaveProgressCard(
                    phase: browser.savePhase ?? "正在写入…",
                    name: browser.url?.lastPathComponent ?? "压缩包"
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: browser.isExtracting)
        .animation(.easeOut(duration: 0.15), value: browser.isSaving)
        .onAppear {
            // 调试探针（AFZ_PROBE_SELECT=1）：自动选中第一个文件，用于自动化实测预览布局
            browser.probeSelectFirstFile()
            // 探针：启动即切换视图模式（框选自动化测试用）
            if let probeMode = ProbeFlags.startViewMode {
                browser.viewMode = probeMode
            }
            // 探针：压缩包就绪后进入 mini。直接调用会被欢迎窗→完整窗的
            // 尺寸分支同步 lastMode 盖掉（900×600 盖回 560×418），所以延迟一拍再切
            if ProbeFlags.startMini, browser.windowMode != .mini {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    browser.enterMiniMode()
                }
            }
            // 探针：压缩包就绪后自动进入搜索态（搜索结果列表自动化验证用）
            if let probeTerm = ProbeFlags.startSearchTerm {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    searchFieldVisible = true
                    browser.searchText = probeTerm
                }
            }
        }
        .alert(browser.errorTitle, isPresented: $browser.showsErrorAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(browser.errorMessage)
        }
    }
}

// MARK: - 顶栏（标题 + 视图切换 + 操作按钮）

struct TopBar: View {
    @Bindable var browser: ArchiveBrowser
    @Binding var searchFieldVisible: Bool
    @FocusState private var searchFocused: Bool
    @State private var editingCreationTitle = false
    @FocusState private var creationTitleFocused: Bool
    @FocusState private var renameFocused: Bool
    /// 标题重命名提示气泡（悬停文件名/笔徽章触发，原生 Popover）
    @State private var showsRenameHint = false
    @State private var renameHintTask: Task<Void, Never>?

    private var isCreate: Bool { browser.workMode == .create }

    var body: some View {
        // 【原创布局·与区分】工具在左、标题在右（为标题居左、工具居右）
        HStack(spacing: 10) {
            // 搜索钮在最左：点击后原位向右展开搜索框，把右侧元素顺势挤开
            if searchFieldVisible {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                    TextField(isCreate ? "搜索文件" : "搜索包内文件", text: $browser.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: Theme.bodySize))
                        .focused($searchFocused)
                        .frame(width: 96)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            searchFieldVisible = false
                            browser.searchText = ""
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 18, height: 18)
                            .background(Theme.iconButtonBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .afzHelp("关闭搜索")
                }
                .padding(.leading, 12)
                .padding(.trailing, 5)
                .padding(.vertical, 6)
                .background(Theme.chipBackground, in: Capsule())
                .transition(.opacity)
            } else {
                CircleIconButton(systemName: "magnifyingglass", help: "搜索压缩包内文件") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        searchFieldVisible = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        searchFocused = true
                    }
                }
            }

            CircleIconButton(
                systemName: "trash",
                help: isCreate ? "移除选中的待打包文件" : "",
                isDestructive: true,
                isEnabled: !(browser.selectedPaths.isEmpty)
            ) {
                if isCreate {
                    browser.removeSelectedCreationItems()
                } else {
                    browser.deleteSelected()
                }
            }
            .disabled(isCreate
                ? browser.selectedPaths.isEmpty
                : browser.selectedPaths.isEmpty || browser.isBrowseLocked || !browser.isEditable)
            // disabled 会阻断内部 onHover，提示挂在外层保证禁用态也能显示
            .afzHelp(isCreate
                ? (browser.selectedPaths.isEmpty ? "选中文件后移除" : "从压缩包中移除选中项")
                : (browser.selectedPaths.isEmpty
                   ? "选中文件后删除"
                   : (browser.editBlockedReason ?? "删除包内选中项（保存后生效）")))

            ZStack(alignment: .topTrailing) {
                CircleIconButton(
                    systemName: "square.and.arrow.down",
                    help: isCreate
                        ? "保存为压缩包"
                        : (browser.isSaving ? "正在保存修改…"
                           : (browser.editBlockedReason.map { "另存副本（\($0)）" } ?? "保存修改后的压缩包")),
                    // 创建工作台有待打包内容时保存按钮绿色高亮（语义色，黑白体系中的行动色）
                    overrideColor: isCreate && !browser.creationItems.isEmpty
                        ? Color(red: 0.13, green: 0.72, blue: 0.38)
                        : nil
                ) {
                    if isCreate {
                        browser.showsCreationOptions = true
                    } else {
                        browser.saveArchive()
                    }
                }
                if !isCreate && browser.hasPendingChanges {
                    // 有未保存修改的标记点：琥珀橙（黑白体系中的语义提醒色，与创建模式保存绿色行动色同体系）
                    Circle()
                        .fill(Color(red: 0.96, green: 0.60, blue: 0.12))
                        .frame(width: 7, height: 7)
                        .offset(x: 2, y: -2)
                }
            }
            .disabled(isCreate && browser.creationItems.isEmpty
                      || (!isCreate && (browser.isBrowseLocked || browser.isSaving)))

            // 视图切换：三个圆形按钮装在浅灰胶囊容器内，选中项为带投影的白圆
            // （创建工作台同样显示，固定高亮列表视图——创建窗口即如此）
            HStack(spacing: 4) {
                viewModeButton(.icon, "square.grid.2x2", "图标视图")
                viewModeButton(.list, "list.bullet", "列表视图")
                viewModeButton(.column, "rectangle.split.3x1", "分栏视图")
            }
            .padding(4)
            .background(Theme.chipBackground, in: Capsule())

            Spacer(minLength: 12)

            // 标题组：文件名 + 重命名铅笔 + 锁徽章，靠右收边
            HStack(spacing: 8) {
                titleContent
                if !isCreate && browser.isArchiveEncrypted {
                    ArchiveLockBadgeButton(browser: browser)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    /// 标题内容（普通 / 重命名编辑 / 创建标题编辑 / 嵌套面包屑四种形态）。
    @ViewBuilder private var titleContent: some View {
        if isCreate && editingCreationTitle {
            TextField("压缩包名", text: $browser.creationTitle)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.titleSize, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .focused($creationTitleFocused)
                .frame(maxWidth: 260, alignment: .trailing)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .onSubmit { editingCreationTitle = false }
        } else if !isCreate && browser.isRenamingArchive {
            // 重命名：大圆角编辑框 + 扩展名独立灰色圆角底片
            HStack(spacing: 6) {
                TextField("压缩包名", text: $browser.renamingBaseName)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.titleSize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($renameFocused)
                    .frame(maxWidth: 150, alignment: .leading)
                    .onSubmit { browser.commitRenameArchive() }
                    .onExitCommand { browser.cancelRenameArchive() }

                Text(browser.archiveExtension.isEmpty ? "" : ".\(browser.archiveExtension)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.chipBackground, in: RoundedRectangle(cornerRadius: 7))
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1)
            )
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    renameFocused = true
                }
            }
        } else if browser.isNestedBrowsing {
            // 嵌套浏览：标题栏显示「外层.zip › 内层.zip」面包屑，点击前面的层返回上层
            // （嵌套中针对的是临时文件，不提供重命名入口）
            HStack(spacing: 5) {
                let chain = browser.nestedTitleChain
                ForEach(Array(chain.enumerated()), id: \.offset) { index, title in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text(title)
                        .font(.system(size: Theme.titleSize, weight: index == chain.count - 1 ? .medium : .regular))
                        .foregroundStyle(index == chain.count - 1 ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.7)
                        .onTapGesture {
                            if index < chain.count - 1 {
                                browser.popNestedLayer(toDepth: index)
                            }
                        }
                }
            }
        } else {
            // 文件名 + 重命名笔徽章：悬停任一区域弹出原生 Popover 提示（与锁提示同一套气泡）
            HStack(spacing: 6) {
                Text(isCreate ? browser.creationDisplayName : browser.displayName)
                    .font(.system(size: Theme.titleSize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                    .onTapGesture(count: 2) {
                        if isCreate {
                            editingCreationTitle = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                creationTitleFocused = true
                            }
                        } else {
                            browser.beginRenameArchive()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                renameFocused = true
                            }
                        }
                    }

                Button {
                    if isCreate {
                        editingCreationTitle = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            creationTitleFocused = true
                        }
                    } else {
                        browser.beginRenameArchive()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            renameFocused = true
                        }
                    }
                } label: {
                    // 彩色铅笔图标（✏️）：一眼可辨「改名」，比线条符号更直观
                    Text("✏️")
                        .font(.system(size: 13))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("")   // 关掉系统默认 tooltip：统一用下方原生气泡
            }
            // 悬停延迟出现，移出即收（避免鼠标划过就弹）
            .onHover { hovering in
                renameHintTask?.cancel()
                if hovering {
                    renameHintTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        guard !Task.isCancelled, !browser.isRenamingArchive else { return }
                        showsRenameHint = true
                    }
                } else {
                    showsRenameHint = false
                }
            }
            // 原生 Popover：浅色材质底 + 箭头 + 阴影 + 屏幕边缘避让全部由 AppKit 提供
            .popover(isPresented: $showsRenameHint, arrowEdge: .bottom) {
                AfzRenameHintBubble()
            }
            .onChange(of: browser.isRenamingArchive) { renaming in
                if renaming { showsRenameHint = false }
            }
        }
    }

    /// 视图切换圆形按钮：选中 = 白底圆 + 投影，未选中 = 透明。
    /// 创建工作台同样生效（切换待打包文件的展示视图）。
    private func viewModeButton(
        _ mode: ArchiveBrowser.ViewMode, _ systemName: String, _ help: String
    ) -> some View {
        let isSelected = browser.viewMode == mode
        return Button {
            browser.viewMode = mode
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(isSelected ? Theme.cardBackground : .clear, in: Circle())
                .shadow(color: .black.opacity(isSelected ? 0.14 : 0), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .afzHelp(help)
    }
}

struct CircleIconButton: View {
    let systemName: String
    let help: String
    var isDestructive: Bool = false
    /// 破坏性按钮仅在可用时显示红色（未选中内容时垃圾桶为普通灰钮）
    var isEnabled: Bool = true
    var overrideColor: Color? = nil
    var placement: AfzTooltipModifier.Placement = .below
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .toolIconButton(isDestructive: isDestructive && isEnabled, overrideColor: overrideColor)
        }
        .buttonStyle(.plain)
        .afzHelp(help, placement: placement)
    }
}

// MARK: - 主浏览卡片（导航行 + 表头 + 列表同属一张卡片）

let sizeColumnWidth: CGFloat = 90
let dateColumnWidth: CGFloat = 150

struct MainBrowserCard: View {
    @Bindable var browser: ArchiveBrowser
    @Binding var searchFieldVisible: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 标题工具栏在白卡内部顶端（红绿灯叠在卡左上）
            TopBar(browser: browser, searchFieldVisible: $searchFieldVisible)
            NavBarRow(browser: browser)
            Divider().overlay(Theme.dividerColor)
            EntryListCard(browser: browser)
            // 底栏浮在卡片内部底端（样式：解压/预览胶囊在白卡内左下）
            BottomBar(browser: browser)
        }
        .contentCard()
        // ⌘Z / ⇧⌘Z 撤销与重做包内编辑（隐藏按钮挂快捷键；无历史时禁用不吞键）
        .background {
            Button("撤销") { browser.undoLastEdit() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!browser.canUndoEdit)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            Button("重做") { browser.redoLastEdit() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!browser.canRedoEdit)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - 导航行（← → ↑ + 面包屑）

struct NavBarRow: View {
    @Bindable var browser: ArchiveBrowser

    /// 隐藏项切换按钮文案：关闭时显示隐藏了多少项；开启后当前层若无隐藏项则提示为已开启。
    private var hiddenItemsLabel: String {
        let count = browser.hiddenCountAtCurrentLevel
        if browser.showHiddenFiles {
            return count > 0 ? "已显示 \(count) 项" : "正在显示 macOS 辅助文件"
        }
        return "已隐藏 \(count) 项"
    }

    var body: some View {
        HStack(spacing: 8) {
            CircleIconButton(systemName: "chevron.left", help: "后退") { browser.goBack() }
                .disabled(!browser.canGoBack)
            CircleIconButton(systemName: "chevron.right", help: "前进") { browser.goForward() }
                .disabled(!browser.canGoForward)
            CircleIconButton(systemName: "chevron.up", help: "上级文件夹") { browser.goUp() }
                .disabled(!browser.canGoUp)

            HStack(spacing: 4) {
                if browser.isSearching {
                    Label("搜索 “\(browser.searchText)”", systemImage: "magnifyingglass")
                        .font(.system(size: Theme.bodySize))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    // 单个胶囊内含全部路径段，段间 chevron 分隔，当前段高亮
                    HStack(spacing: 2) {
                        BreadcrumbSegment(
                            label: browser.activeLayerName,
                            systemName: "shippingbox",
                            isCurrent: browser.currentPath.isEmpty
                        ) {
                            browser.navigate(to: "")
                        }

                        ForEach(browser.breadcrumbSegments, id: \.path) { segment in
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                            BreadcrumbSegment(
                                label: segment.name,
                                systemName: "folder.fill",
                                isCurrent: segment.path == browser.currentPath
                            ) {
                                browser.navigate(to: segment.path)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Theme.chipBackground, in: Capsule())
                }

                Spacer()

                Text(browser.itemCountDescription)
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(Theme.textTertiary)

                // 存在 macOS 特有隐藏项时显示切换按钮；
                // 已开启显示时始终保留按钮，否则走到无隐藏项的层级就无法再关回去
                if browser.hiddenCountAtCurrentLevel > 0 || browser.showHiddenFiles {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            browser.showHiddenFiles.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: browser.showHiddenFiles ? "eye" : "eye.slash")
                            Text(hiddenItemsLabel)
                        }
                        .font(.system(size: Theme.captionSize, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.accentLight, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .afzHelp(browser.showHiddenFiles ? "点击隐藏 macOS 特有文件" : "点击显示 macOS 特有文件")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
        }
    }
}

struct BreadcrumbSegment: View {
    let label: String
    let systemName: String
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: Theme.bodySize))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(isCurrent ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isCurrent ? Theme.accentLight : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 文件列表（表头：名称 | 大小 | 修改时间）


struct EntryListCard: View {
    @Bindable var browser: ArchiveBrowser

    var body: some View {
        VStack(spacing: 0) {
            // 表头（仅列表视图显示列名，保持一致；搜索态由结果列表自带表头）
            if browser.viewMode == .list && !browser.isSearching {
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
            }

            // 搜索态：全包扁平结果（名称 + 所在位置 + 定位），不随视图模式变化
            if browser.isSearching {
                SearchResultsView(browser: browser)
            } else {
                switch browser.viewMode {
                case .icon:
                    // 磁盘映像根层：按 .DS_Store 布局自由摆放（与访达打开效果一致）
                    if browser.showsVolumeLayout {
                        VolumeLayoutView(browser: browser)
                    } else {
                        IconGridView(browser: browser)
                    }
                case .list:
                    listContent
                case .column:
                    ColumnBrowserView(browser: browser)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .onChange(of: browser.selectedPaths) { _ in
            browser.updatePreview()
        }
        .overlay {
            if browser.visibleNodes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: browser.isSearching ? "magnifyingglass" : "folder")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.textTertiary)
                    Text(browser.isSearching ? "没有匹配的文件" : "这个文件夹是空的")
                        .font(.system(size: Theme.bodySize))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// 列表行高（固定值，便于空白区延续斑马纹）
    private let listRowHeight: CGFloat = 28

    private var listContent: some View {
        GeometryReader { viewport in
            ScrollView {
                MarqueeHost(
                    browser: browser,
                    space: MarqueeSpace.list,
                    minHeight: viewport.size.height
                ) {
                    LazyVStack(spacing: 0) {
                    ForEach(Array(browser.visibleNodes.enumerated()), id: \.element.id) { index, node in
                        EntryRow(browser: browser, node: node, isHidden: ArchiveBrowser.isHiddenName(node.name))
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: listRowHeight, maxHeight: listRowHeight)
                            // 斑马纹网格与文件行一一对应：偶数行白、奇数行灰；选中整行变蓝（文字变白由 EntryRow 处理）
                            .background(listRowBackground(index: index, path: node.path))
                            .contentShape(Rectangle())
                            .entryFrame(path: node.path, in: MarqueeSpace.list)
                            .onTapGesture(count: 2) {
                                // 待删除项（灰色标记）不再响应进入
                                if node.isDirectory {
                                    if !browser.isPendingDeletion(node.path) {
                                        browser.navigate(to: node.path)
                                    }
                                } else if !browser.isPendingDeletion(node.path),
                                          browser.canEnterNested(node) {
                                    // 嵌套压缩包浏览：双击包内压缩包条目进入其内部
                                    browser.enterNested(node)
                                } else {
                                    // 普通文件：双击弹出系统预览窗口（与空格一致）
                                    browser.previewNode(node)
                                }
                            }
                            .onTapGesture { handleListTap(node) }
                            // 拖拽解压：拖到 Finder/桌面即按需解压（单选拖条目、多选按条目逐个交付）
                            .multiDragHover(browser: browser, node: node)
                            .onDrag { browser.dragProvider(for: node) } preview: {
                                FileDragPreview(node: node)
                            }
                            // 拖动 .app 到 Applications 快捷方式上直接安装
                            .onDrop(of: [ArchiveBrowser.nodePathsUTI, UTType.data, UTType.folder], isTargeted: nil) { providers in
                                browser.acceptDrop(on: node, providers: providers)
                            }
                            .contextMenu {
                                if let reason = browser.editBlockedReason {
                                    Button {} label: { Label(reason, systemImage: "lock") }
                                        .disabled(true)
                                    Divider()
                                }
                                Button("解压所选…") { browser.extractSelected() }
                                    .disabled(browser.isExtracting)
                                    .disabled(browser.selectedPaths.isEmpty)
                                // 重命名（右键 → 重命名 → 输入新名 → 保存落盘）；文件与文件夹均可
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
                                Button("全选") {
                                    browser.selectedPaths = Set(browser.visibleNodes.map(\.path))
                                }
                                Button("取消全选") { browser.clearSelection() }
                                    .disabled(browser.selectedPaths.isEmpty)
                            }
                    }

                    // 空白区域延续同一斑马纹网格（行高一致、奇偶交替）
                    let fillers = max(0, Int(viewport.size.height / listRowHeight) - browser.visibleNodes.count)
                    ForEach(0..<fillers, id: \.self) { i in
                        let index = browser.visibleNodes.count + i
                        Color.clear
                            .frame(height: listRowHeight)
                            .frame(maxWidth: .infinity)
                            .background(zebraBand(index: index))
                            // 填充行不参与命中测试：否则斑马纹背景会拦住空白区的
                            // 框选拖动与点击取消（框选手势挂在 MarqueeHost 背景层）
                            .allowsHitTesting(false)
                    }
                    }
                }
            }
            .onMoveCommand { direction in
                // 上下方向键移动选中项
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
    }

    /// 行背景：选中蓝底；否则按行号奇偶铺斑马纹（左右留边、圆角 4，与一致）
    private func listRowBackground(index: Int, path: String) -> some View {
        let isSelected = browser.selectedPaths.contains(path)
        return zebraBand(index: index, color: isSelected ? Theme.selectionBlue : nil)
    }

    private func zebraBand(index: Int, color: Color? = nil) -> some View {
        let fill = color ?? (index.isMultiple(of: 2) ? .clear : Theme.zebraRow)
        return RoundedRectangle(cornerRadius: 4)
            .fill(fill)
            .padding(.horizontal, 12)
    }

    private func handleListTap(_ node: ArchiveNode) {
        // 统一选择语义：⌘切换 / ⇧范围 / 单选（待删除项不可选中）
        guard !browser.isPendingDeletion(node.path) else { return }
        browser.handleTapSelection(node, visibleNodes: browser.visibleNodes)
    }
}

// MARK: - 搜索结果（全包扁平：名称 + 所在位置 + 定位）

struct SearchResultsView: View {
    @Bindable var browser: ArchiveBrowser

    private let rowHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("名称")
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("所在位置")
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: locationColumnWidth, alignment: .leading)
                Text("大小")
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: sizeColumnWidth, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Theme.panelBackground.opacity(0.6))

            Divider().overlay(Theme.dividerColor)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(browser.searchResults.enumerated()), id: \.element.id) { index, node in
                        SearchResultRow(browser: browser, node: node)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
                            .background(rowBackground(index: index, path: node.path))
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .onMoveCommand { direction in
            // 上下方向键移动选中项（与列表视图一致）
            let results = browser.searchResults
            guard !results.isEmpty else { return }
            let paths = results.map(\.path)
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

    /// 结果所在位置列宽（随窗口收缩，长路径中段省略）。
    private var locationColumnWidth: CGFloat { 240 }

    private func rowBackground(index: Int, path: String) -> some View {
        let isSelected = browser.selectedPaths.contains(path)
        let fill = isSelected ? Theme.selectionBlue
            : (index.isMultiple(of: 2) ? Color.clear : Theme.zebraRow)
        return RoundedRectangle(cornerRadius: 4)
            .fill(fill)
    }
}

struct SearchResultRow: View {
    @Bindable var browser: ArchiveBrowser
    let node: ArchiveNode

    private var isSelected: Bool { browser.selectedPaths.contains(node.path) }

    /// 条目所在文件夹；根层直接显示「根目录」。
    private var locationText: String {
        let parent = (node.path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "根目录" : parent
    }

    private var sizeText: String {
        guard !node.isDirectory, let size = node.entry?.size else { return "" }
        return afzByteText(size)
    }

    var body: some View {
        HStack(spacing: 10) {
            EntryIconView(browser: browser, node: node, side: 18)
                .frame(width: 22)

            Text(node.name)
                .font(.system(size: Theme.bodySize))
                .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(locationText)
                .font(.system(size: Theme.captionSize))
                .foregroundStyle(isSelected ? .white.opacity(0.8) : Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 240, alignment: .leading)

            Text(sizeText)
                .font(.system(size: Theme.captionSize))
                .monospacedDigit()
                .foregroundStyle(isSelected ? .white.opacity(0.8) : Theme.textSecondary)
                .frame(width: sizeColumnWidth, alignment: .trailing)

            // 定位：跳到条目所在文件夹并选中（双击文件夹则是直接进入）
            Button {
                browser.locateEntry(node.path)
            } label: {
                Image(systemName: "location.viewfinder")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelected ? .white : Theme.textSecondary)
            .afzHelp("跳转到所在文件夹并选中")
        }
        .onTapGesture {
            guard !browser.isPendingDeletion(node.path) else { return }
            browser.handleTapSelection(node, visibleNodes: browser.searchResults)
        }
        .onTapGesture(count: 2) {
            guard !browser.isPendingDeletion(node.path) else { return }
            if node.isDirectory {
                // 进入文件夹：跳转并清除搜索，直接看该目录内容
                browser.navigate(to: node.path)
                browser.searchText = ""
            } else if browser.canEnterNested(node) {
                browser.enterNested(node)
            } else {
                browser.previewNode(node)
            }
        }
        .contextMenu {
            Button("定位到所在文件夹") { browser.locateEntry(node.path) }
            if !node.isDirectory {
                Button("打开预览") { browser.previewNode(node) }
            }
            Divider()
            Button("解压所选…") { browser.extractSelected() }
                .disabled(browser.selectedPaths.isEmpty || browser.isExtracting)
            Button("全选") {
                browser.selectedPaths = Set(browser.searchResults.map(\.path))
            }
        }
    }
}

struct EntryRow: View {
    @Bindable var browser: ArchiveBrowser
    let node: ArchiveNode
    var isHidden: Bool = false

    /// 选中行蓝底白字（系统 List 选中样式文字保持黑色，需手动覆盖）
    private var isSelected: Bool { browser.selectedPaths.contains(node.path) }
    /// 待删除项：灰色 + 删除线标记（保存后真正移除）
    private var isDeleted: Bool { browser.isPendingDeletion(node.path) }
    /// 本次编辑新增/替换的条目：绿色标记
    private var isNew: Bool { node.isPendingAdd && !isDeleted }

    var body: some View {
        HStack(spacing: 10) {
            EntryIconView(browser: browser, node: node, side: 18)
                .frame(width: 22)
                .opacity(isDeleted ? 0.4 : 1)

            Text(node.name)
                .font(.system(size: Theme.bodySize))
                .strikethrough(isDeleted)
                .foregroundStyle(rowTextColor)
                .lineLimit(1)
                .truncationMode(.middle)
                // 悬停文件名 → 悬浮预览卡片
                .archiveHoverPreview(browser: browser, node: node)

            if isNew {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white, Theme.pendingAdd)
                    .afzHelp("尚未保存的新增项")
            }

            // 符号链接（如 DMG 内 Applications → /Applications）：显示链接目标
            if node.entry?.isSymbolicLink == true, let target = node.entry?.linkTarget {
                Text("→ \(target)")
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // 条目加密标记：仅锁定态显示（解锁后不再逐行提示）
            if node.entry?.isEncrypted == true && browser.isBrowseLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Theme.textTertiary)
            }

            Spacer()

            if node.isDirectory {
                Text("—")
                    .font(.system(size: Theme.bodySize))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Theme.textTertiary)
                    .frame(width: sizeColumnWidth, alignment: .trailing)
            } else {
                Text(ByteFormatter.string(from: node.entry?.size ?? 0))
                    .font(.system(size: Theme.bodySize))
                    .foregroundStyle(rowMetaTextColor)
                    .frame(width: sizeColumnWidth, alignment: .trailing)
            }

            Text(node.entry?.modificationDate.map {
                $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened))
            } ?? "—")
                .font(.system(size: Theme.bodySize))
                .foregroundStyle(rowMetaTextColor)
                .frame(width: dateColumnWidth, alignment: .trailing)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var rowTextColor: Color {
        if isDeleted { return Theme.textTertiary }
        if isSelected { return .white }
        if isNew { return Theme.pendingAdd }
        return isHidden ? Theme.textTertiary : Theme.textPrimary
    }

    private var rowMetaTextColor: Color {
        if isDeleted { return Theme.textTertiary.opacity(0.8) }
        if isSelected { return Color.white.opacity(0.85) }
        return isHidden ? Theme.textTertiary : Theme.textSecondary
    }
}

// MARK: - 拖拽解压预览小卡片（跟随鼠标的拖拽图像）

struct FileDragPreview: View {
    let node: ArchiveNode

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
            Text(node.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.dividerColor, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 9, y: 4)
        .fixedSize()
    }
}

// MARK: - DMG 校验工作区（校验卡片在文件浏览区内，右侧详情与底栏照常显示）

struct DmgVerifyWorkspaceView: View {
    @Bindable var browser: ArchiveBrowser
    /// 详情面板折叠状态（与浏览/创建模式共用同一持久化键）
    @AppStorage(AppSettings.detailCollapsedKey) private var detailCollapsed = AppSettings.detailCollapsedDefault

    var body: some View {
        // 左白卡贯穿窗口全高（顶栏/底栏浮在卡内），右侧紫板同高
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                TopBar(browser: browser, searchFieldVisible: .constant(false))

                // 校验内容占满卡片剩余空间
                DmgMountingView(browser: browser)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - DMG 挂载校验卡片（"正在校验磁盘映像"，可跳过校验）

struct DmgMountingView: View {
    @Bindable var browser: ArchiveBrowser
    private var fraction: Double { browser.dmgMountFraction ?? 0 }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text("正在校验磁盘映像")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(browser.dmgMountingName ?? browser.url?.lastPathComponent ?? "")
                        .font(.system(size: Theme.bodySize))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button {
                    browser.dmgSkipFlag.set()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 11))
                        Text("跳过校验")
                            .font(.system(size: Theme.bodySize))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.chipBackground, in: RoundedRectangle(cornerRadius: Theme.cornerM))
                }
                .buttonStyle(.plain)
            }

            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(Theme.accent)

            HStack {
                Text("正在确认磁盘映像内容完整")
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: Theme.captionSize))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(28)
        // 浏览区内的一块浅色内嵌卡片：宽度跟随浏览区伸缩（外层由 DmgVerifyWorkspaceView 提供白卡）
        .frame(maxWidth: .infinity)
        .background(Theme.chipBackground.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 10)
    }
}

// MARK: - 底部工具条（左下快捷区）

struct BottomBar: View {
    @Bindable var browser: ArchiveBrowser

    private var isCreate: Bool { browser.workMode == .create }

    var body: some View {
        // 【原创布局】底部按钮全部靠右（与靠左区分）；进度/提示胶囊保持最右端
        // 左端放 Flow 智能推荐条（Flow：按包内内容推荐此刻最合适的操作）
        HStack(spacing: 10) {
            FlowStripView(browser: browser)

            Spacer(minLength: 0)

            // 快捷功能区：外层浅灰圆角容器；首个图标为 mini 窗口切换
            HStack(spacing: 6) {
                if !isCreate {
                    CircleIconButton(
                        systemName: "arrow.down.right.and.arrow.up.left",
                        help: "切换到 mini 窗口",
                        placement: .above
                    ) {
                        browser.toggleMiniMode()
                    }
                }

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
                .disabled(isCreate || browser.isExtracting || browser.state != .loaded)

                Button {
                    browser.previewEnabled.toggle()
                    browser.updatePreview()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: browser.previewEnabled ? "eye" : "eye.slash")
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
                .disabled(isCreate)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .fixedSize(horizontal: true, vertical: false)
            .background(Theme.chipBackground, in: RoundedRectangle(cornerRadius: Theme.cornerL))

            if isCreate {
                // 创建工作台主行动钮：石墨渐变「添加文件」
                Button {
                    browser.showAddFilesPanel()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("添加文件")
                    }
                    .primaryCapsule()
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .disabled(browser.isCreatingArchive)
            }
            // 原「解压」主胶囊已移除：多选后的解压入口统一由左下 Flow 推荐条的
            // 「解压所选」承担（同一 extractSelected 函数），避免重复按钮；
            // 右键菜单里也保留了「解压所选…」作为备用入口。

            // DMG/ISO 内选中 .app 时出现"安装应用"
            if !isCreate && !browser.selectedAppPaths.isEmpty {
                Button {
                    browser.installSelectedApps()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "app.badge")
                            .font(.system(size: 12, weight: .semibold))
                        Text("安装应用")
                    }
                    .primaryCapsule()
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .afzHelp("将选中的应用安装到\"应用程序\"文件夹")
            }

            // 解压进度胶囊 / 解压完成提示 / 创建进度胶囊（保持最右端）
            if isCreate && browser.isCreatingArchive {
                CreationProgressChip(browser: browser)
                    .transition(.opacity)
            } else if browser.isExtracting {
                ExtractionProgressChip(browser: browser)
                    .transition(.opacity)
            } else if browser.showsExtractionToast {
                ExtractionDoneChip(browser: browser)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }
}

/// 解压进行中的进度胶囊：当前文件名 + 计数 + 取消按钮。
struct ExtractionProgressChip: View {
    @Bindable var browser: ArchiveBrowser
    /// mini 窗口宽度有限时使用紧凑形态（只保留计数与取消）
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: browser.extractProgress)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .frame(width: 14, height: 14)

            Text(browser.extractTotal > 1 ? "\(browser.extractCompleted)/\(browser.extractTotal)" : "解压中")
                .font(.system(size: Theme.captionSize))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .fixedSize()

            if let name = browser.extractCurrentName, !compact {
                Text(name)
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 130, alignment: .leading)
            }

            Button {
                browser.cancelExtraction()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(Theme.dividerColor, in: Circle())
            }
            .buttonStyle(.plain)
            .afzHelp("取消解压", placement: .above)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.chipBackground, in: Capsule())
    }
}

/// 解压完成提示胶囊：文件数 + 在 Finder 中显示。
struct ExtractionDoneChip: View {
    @Bindable var browser: ArchiveBrowser
    /// mini 窗口宽度有限时使用紧凑形态（只保留"在 Finder 中显示"）
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0.20, green: 0.72, blue: 0.35))

            if !compact {
                Text(browser.flowDoneMessage
                    ?? (browser.lastInstallCount > 0
                        ? "已安装 \(browser.lastInstallCount) 个应用到应用程序文件夹"
                        : "已解压 \(browser.lastExtractionCount) 个文件"))
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }

            // Flow 动作（字体/安装包/打开文件）没有解压落盘语义，不提供 Finder 定位
            if browser.flowDoneMessage == nil {
                Button("在 Finder 中显示") { browser.revealLastExtraction() }
                    .buttonStyle(.plain)
                    .font(.system(size: Theme.captionSize, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }

            // 「每次均询问」（解压设置页）：完成后由用户决定源压缩包去留
            if browser.flowDoneMessage == nil,
               AppSettings.afterExtractAction == .ask {
                Button("移入废纸篓") { browser.trashCurrentArchive() }
                    .buttonStyle(.plain)
                    .font(.system(size: Theme.captionSize, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }

            Button {
                browser.showsExtractionToast = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16, height: 16)
                    .background(Theme.dividerColor, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.chipBackground, in: Capsule())
    }
}

// MARK: - 右侧详情面板（原创布局：标题行带折叠钮，可收起给浏览区让位）
struct DetailPanel: View {
    @Bindable var browser: ArchiveBrowser
    /// 折叠状态绑定；nil = 不提供折叠（次要窗口复用面板时）
    var collapsed: Binding<Bool>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(panelTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 4)
                Spacer(minLength: 0)
                // 折叠钮：带文字的胶囊按钮，明确告知这块面板可以收起
                if let collapsed {
                    Button {
                        collapsed.wrappedValue = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("收起")
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Theme.chipBackground, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .afzHelp("折叠详情面板，把空间让给文件浏览区")
                }
            }

            ScrollView {
                VStack(spacing: 12) {
                    if browser.workMode == .create {
                        // 选中单个文件 → 文件预览详情（与打开压缩包后的逻辑一致）
                        if let item = browser.selectedCreationItem {
                            CreationItemDetailView(item: item)
                        } else {
                            CreationDetailView(browser: browser)
                        }
                    } else if let entry = browser.previewEntry {
                        ItemDetailView(browser: browser, entry: entry)
                    } else {
                        ArchiveDetailView(browser: browser)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // 面板内一整块大的白色圆角容器，所有信息在容器内
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.detailPanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerL))
    }

    private var panelTitle: String {
        if browser.workMode == .create {
            return browser.selectedCreationItem != nil ? "项目详情" : "压缩包详情"
        }
        return browser.previewEntry != nil ? "项目详情" : "压缩包详情"
    }
}

/// 详情面板折叠后的窄条：全高细条 + 竖排「详情」文字 + 展开钮（保持可发现性）。
struct DetailCollapseStrip: View {
    @Binding var collapsed: Bool

    var body: some View {
        Button {
            collapsed = false
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                // 竖排文字：让窄条本身自我说明是「详情」面板
                Text("详情")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .rotationEffect(.degrees(90))
                    .fixedSize()
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 30)
        .background(Theme.detailPanelBackground, in: RoundedRectangle(cornerRadius: Theme.cornerL))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerL)
                .strokeBorder(Theme.dividerColor, lineWidth: 0.5)
        )
        .afzHelp("展开详情面板")
    }
}

/// 选中文件的详情（预览卡 + 文件名 + 类型描述 + 直接铺底的字段列表）。
struct ItemDetailView: View {
    @Bindable var browser: ArchiveBrowser
    let entry: ArchiveEntry

    var body: some View {
        VStack(spacing: 12) {
            // 缩略图直接铺在白色容器上（无内嵌卡片），预览内容自带页面投影
            // 锁定态：预览需要密码（占位卡提示）
            if browser.isBrowseLocked {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.primary.opacity(0.04))
                    VStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Theme.textTertiary)
                        Text("已加密")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                        Text("输入密码后可预览内容")
                            .font(.system(size: Theme.captionSize))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { browser.promptUnlock() }
            } else {
                PreviewCard(browser: browser, entry: entry)
                    .frame(maxWidth: .infinity)
            }

            Text(entry.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            Text(browser.previewTypeDescription ?? "文件")
                .font(.system(size: Theme.captionSize))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)

            // 字段直接铺在浅紫面板上（无白色卡片）
            VStack(alignment: .leading, spacing: 12) {
                DetailRow(title: "原始大小", value: ByteFormatter.string(from: entry.size))
                DetailRow(title: "加密", value: entry.isEncrypted ? "是" : "否")
                if let date = entry.modificationDate {
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

/// 未选中时的压缩包概览（"压缩包详情"：大紫图标直接铺底 + 字段无卡片）。
struct ArchiveDetailView: View {
    @Bindable var browser: ArchiveBrowser

    var body: some View {
        VStack(spacing: 14) {
            // 紫色渐变大圆角方块图标，直接铺在白色容器上（浅紫渐变）
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

            Text(browser.activeLayerName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            Text(Self.formatLabel(browser.summary?.format, fallbackExtension: browser.url?.pathExtension))
                .font(.system(size: Theme.captionSize))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)

            if let summary = browser.summary {
                VStack(alignment: .leading, spacing: 12) {
                    DetailRow(title: "大小", value: ByteFormatter.string(from: summary.totalUncompressed))
                    DetailRow(title: "项目", value: "\(summary.fileCount + summary.folderCount)")
                    DetailRow(title: "加密", value: summary.hasEncryptedEntries ? "是" : "否")
                    if let date = summary.modificationDate {
                        DetailRow(
                            title: "修改日期",
                            value: date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened))
                        )
                    }
                    // 整包备注（如解压密码）：多行可选中文本，方便直接复制
                    if let comment = browser.archiveComment?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
                        HStack(alignment: .top) {
                            Text("备注")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                            Spacer(minLength: 8)
                            Text(comment)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(8)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
    }

    /// 详情面板格式文案：磁盘映像类不叫"压缩包"（"DMG 磁盘映像"）。
    /// 校验期 summary 尚未就绪时按扩展名兜底。
    private static func formatLabel(_ format: ArchiveFormat?, fallbackExtension: String? = nil) -> String {
        if let format {
            switch format.rawValue {
            case "DMG", "ISO", "APFS", "HFS", "UDF", "NTFS":
                return "\(format.rawValue) 磁盘映像"
            default:
                return "\(format.rawValue) 压缩包"
            }
        }
        if let ext = fallbackExtension?.lowercased(), ArchiveBrowser.diskImageFormats.contains(ext.uppercased()) {
            return "\(ext.uppercased()) 磁盘映像"
        }
        return "压缩包"
    }
}

/// 预览内容卡：QuickLook 渲染 / 图像缩略图 / 文档图标 + 扩展名标签。
struct PreviewCard: View {
    @Bindable var browser: ArchiveBrowser
    let entry: ArchiveEntry

    var body: some View {
        Group {
            if browser.isPreviewLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("正在生成预览…")
                        .font(.system(size: Theme.captionSize))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
            } else {
                switch browser.previewPayload {
                case .quickLook(let url):
                    // 预览卡高度适中，内容在卡内水平垂直居中，保证下方信息无需滚动全部可见
                    QuickLookPreviewView(url: url)
                        .frame(maxWidth: .infinity)
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerS))
                case .image(let image):
                    // 静态页面缩略图，固定尺寸、水平垂直居中，带页面投影
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 175, maxHeight: 245)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerS))
                        .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity)
                case .text(let text):
                    ScrollView {
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                default:
                    // 无法渲染的类型显示文档图标 + 扩展名标签
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.zebraRow)
                                .frame(width: 96, height: 96)
                                .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
                            Image(systemName: EntryIcon.symbol(for: entry.name, isDirectory: false))
                                .font(.system(size: 46))
                                .foregroundStyle(Theme.accent)
                        }
                        extensionLabel(entry.name)
                    }
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func extensionLabel(_ name: String) -> some View {
        let ext = (name as NSString).pathExtension.uppercased()
        return Text(ext.isEmpty ? "文件" : ext)
            .font(.system(size: Theme.captionSize, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
    }
}

/// QuickLook 渲染视图（文档/表格/演示/PDF/媒体显示真实内容）。
struct QuickLookPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.shouldCloseWithWindow = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
    }
}

struct DetailRow: View {
    let title: String
    let value: String
    var systemImage: String?

    var body: some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                }
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Flow 智能推荐条（Flow；外观差异化：底栏左端轻量胶囊组，备选走原生 Menu）

struct FlowStripView: View {
    @Bindable var browser: ArchiveBrowser

    var body: some View {
        let actions = browser.flowActions
        if let main = actions.first {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .afzHelp("Flow 快捷操作：根据压缩包内容推荐")

                // 主推荐：强调色实底胶囊（黑白体系中的行动色，与右端"全部解压"呼应）
                Button { browser.runFlowAction(main) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: main.symbolName)
                            .font(.system(size: 11, weight: .semibold))
                        Text(main.label)
                            .font(.system(size: Theme.captionSize, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .afzHelp(main.helpText)

                // 备选动作：原生 Menu 收纳（超过 1 个才出现）
                if actions.count > 1 {
                    Menu {
                        ForEach(Array(actions.dropFirst().enumerated()), id: \.offset) { _, action in
                            Button {
                                browser.runFlowAction(action)
                            } label: {
                                Label(action.label, systemImage: action.symbolName)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("另有 \(actions.count - 1) 个")
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: Theme.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Theme.chipBackground, in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .afzHelp("备选 Flow")
                }
            }
            .transition(.opacity)
        }
    }
}
