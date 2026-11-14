import SwiftUI
import AppKit
import FinderShared
import UniformTypeIdentifiers
import ArchiveCore

/// 多窗口路由（可同时打开多个压缩包，每个包一个窗口）。
///
/// 关键事实（实测）：App 声明了 CFBundleDocumentTypes 后，Finder「打开方式」事件
/// SwiftUI 会自动新建一个窗口（先于 AppDelegate 回调），且无法阻止。
/// 因此外部打开的策略是顺势而为：
/// - 延迟一拍等系统新建的窗口成为 key 窗口，把 URL 交给它；
/// - 随后自动收掉其它从未使用过的空窗口（欢迎窗），让「打开第一个包」只留一个窗口。
///
/// 应用内打开（⌘O / 欢迎页按钮）则完全由我们控制：
/// - 当前窗口还没打开包 → 就地打开；
/// - 当前窗口正在浏览 → 新开窗口（URL 入队，新窗口 onAppear 消费）。
@MainActor
@Observable
final class ArchiveWindowRouter {
    static let shared = ArchiveWindowRouter()

    private init() {}

    /// scene 级 openWindow 动作（任一窗口出现时注入）。
    @ObservationIgnored private var openWindowAction: OpenWindowAction?
    /// 等待新窗口消费的打开请求（新建窗口后由该窗口 onAppear 取走）。
    @ObservationIgnored private var pendingWindowURLs: [URL] = []
    /// 等待新窗口消费的「创建工作台」请求（文件盒「放入工作区」用）。
    @ObservationIgnored private var pendingCreationURLs: [URL]?
    /// 创建请求是否要求预开启加密（右键「加密压缩…」）。
    @ObservationIgnored private var pendingCreationEncrypt = false
    /// 已打开的窗口（弱引用，随窗口销毁自动失效）。
    @ObservationIgnored private var windows: [WeakWindow] = []
    /// AppKit 自建窗口（冷启动兜底 / 文件盒批量打开）的强持有。
    /// ARC 下必须配 `isReleasedWhenClosed = false`：默认 YES 时关窗会多 release 一次，
    /// autorelease pool 收尾再 release 悬垂指针 → EXC_BAD_ACCESS（实测关任一窗即崩）。
    @ObservationIgnored private var ownedWindows: [NSWindow] = []
    @ObservationIgnored private var windowCloseObserver: NSObjectProtocol?
    /// 设置窗口（单例复用，AppKit 生命周期下替代 SwiftUI Window("设置") 场景）。
    @ObservationIgnored private var settingsWindow: NSWindow?

    private final class WeakWindow {
        weak var window: NSWindow?
        weak var browser: ArchiveBrowser?
        init(window: NSWindow, browser: ArchiveBrowser) {
            self.window = window
            self.browser = browser
        }
    }

    // MARK: - 注册

    func attach(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
    }

    func register(window: NSWindow, browser: ArchiveBrowser) {
        prune()
        if windows.contains(where: { $0.browser === browser }) { return }
        windows.append(WeakWindow(window: window, browser: browser))
    }

    func unregister(browser: ArchiveBrowser) {
        windows.removeAll { $0.browser === browser || $0.browser == nil }
    }

    func browser(for window: NSWindow?) -> ArchiveBrowser? {
        prune()
        guard let window else { return nil }
        return windows.first { $0.window === window }?.browser
    }

    /// 自动化探针：当前已登记窗口各自正在浏览的压缩包名（验证批量开窗是否一包一窗）。
    func debugOpenedArchiveNames() -> [String] {
        prune()
        return windows.compactMap { $0.browser?.url?.lastPathComponent }
    }

    /// 把 AppKit 自建窗口纳入确定的生命周期管理。
    private func retainOwnedWindow(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        ownedWindows.append(window)
        guard windowCloseObserver == nil else { return }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let closed = note.object as? NSWindow else { return }
            // 延迟一拍再放手：让本轮 autorelease pool 先安全收尾、SwiftUI 宿主视图完成清理。
            // 闭包对 closed 的强捕获保证这段时间内窗口不会被 dealloc。
            DispatchQueue.main.async { [weak self] in
                self?.ownedWindows.removeAll { $0 === closed }
            }
        }
    }

    // MARK: - 应用内打开（⌘O / 欢迎页按钮）

    /// 请求新开一个空窗口（托盘「打开应用」用；内部持有 openWindow 动作）。
    func openNewWindow() {
        ensureRegularActivation()
        pendingWindowURLs.append(URL(fileURLWithPath: "/__afz_empty__"))
        openArchiveSceneWindow()
    }

    /// 优先复用「发起窗口」或当前 key 窗口（若为空窗），否则新开窗口。
    func open(_ url: URL, preferred: ArchiveBrowser? = nil) {
        ensureRegularActivation()
        if let preferred, preferred.canReuseForOpen {
            preferred.open(url: url)
            return
        }
        if let keyBrowser = browser(for: NSApp.keyWindow),
           keyBrowser.canReuseForOpen, keyBrowser !== preferred {
            keyBrowser.open(url: url)
            return
        }
        // 新开窗口：URL 入队，由新窗口 onAppear 取走
        pendingWindowURLs.append(url)
        openArchiveSceneWindow()
    }

    /// 文件盒批量打开：选中的多个压缩包各开一个独立窗口，各自进入浏览态。
    ///
    /// 不走「URL 入队 + 多次 openWindow(id:)」：同一 runloop 连续多次调用可能被
    /// SwiftUI 合并成一个窗口，且队列消费依赖 onAppear 时序，窗口数不足时会残留请求。
    /// 这里为每个 URL 直接建一个确定性窗口并注入初始 URL，零队列、零竞态。
    func openBatch(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        ensureRegularActivation()
        NSApp.activate(ignoringOtherApps: true)
        // 空欢迎窗不该混在批量窗口里；收掉后只剩 N 个各浏览各的窗口
        closeAllIdleWindows()
        for (index, url) in urls.enumerated() {
            openFallbackMainWindow(initialURL: url, cascadeIndex: index)
        }
    }

    // MARK: - 设置窗口

    /// 后台形态（无 Dock 图标）被要求展示用户界面时，恢复常规应用形态。
    func ensureRegularActivation() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// 打开设置窗口（欢迎窗齿轮 / 应用菜单「设置…」「关于 FreeArc」共用；单例复用）。
    /// 传 section 时定位到指定分区：新窗口以该分区初始化；已有窗口广播切换。
    func openSettings(section: SettingsSection? = nil) {
        ensureRegularActivation()
        if let settingsWindow {
            if let section {
                NotificationCenter.default.post(
                    name: .afzSelectSettingsSection, object: section)
            }
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // 探针可用 AFZ_SETTINGS_H 覆盖初始高度（像素级核对长页面用；默认 560）
        let initialHeight = Int(ProcessInfo.processInfo.environment["AFZ_SETTINGS_H"] ?? "") ?? 560
        // 宽度 880：侧栏 200 之后内容区仍足够宽，解压/通用页的长标题不换行
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: initialHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "设置"
        window.minSize = NSSize(width: 800, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(initialSection: section))
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 外部打开（Finder 双击 / 打开方式 / 冷启动）

    /// 把 URL 交给可复用的空窗，没有就新开一个窗口打开。
    /// 「默认用 FreeArc Mini 打开」开关生效后，外部打开就绪即切轻量形态。
    func openExternal(_ url: URL) {
        ensureRegularActivation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [self] in
            let target = browser(for: NSApp.keyWindow) ?? idleBrowser()
            if let target, target.canReuseForOpen {
                target.open(url: url)
                closeIdleWindows(except: target)
                enterMiniIfEnabled(target)
            } else {
                // 没有可用空窗 → 走应用内新开窗口路径（实例未知，窗口就绪后按 keyWindow 找）
                open(url)
                if AppSettings.openWithMini {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [self] in
                        if let opened = browser(for: NSApp.keyWindow) {
                            enterMiniIfEnabled(opened)
                        }
                    }
                }
            }
        }
    }

    /// 「默认用 FreeArc Mini 打开」：外部打开就绪后切到轻量形态。
    /// 延迟 0.55s：等「欢迎窗 → 完整窗」的尺寸分支跑完再切，否则 lastMode
    /// 会被 900×600 的完整窗尺寸盖回（与探针 startMini 同一个坑，见 MainWindowView）。
    private func enterMiniIfEnabled(_ browser: ArchiveBrowser) {
        guard AppSettings.openWithMini, browser.windowMode != .mini else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            browser.enterMiniMode()
        }
    }

    /// 新窗口出现时取走归它所有的压缩包 URL（⌘O 新开窗口路径）。
    func consumePendingWindowURL() -> URL? {
        guard !pendingWindowURLs.isEmpty else { return nil }
        let url = pendingWindowURLs.removeFirst()
        // 托盘「打开应用」的占位标记：不携带真实 URL，直接丢弃
        if url.path == "/__afz_empty__" {
            return consumePendingWindowURL()
        }
        return url
    }

    // MARK: - 文件盒「放入工作区」（创建模式）

    /// 把一批文件送进主窗口的待打包工作台：
    /// 已有创建模式的窗口直接追加；空窗口就地转创建；都没有则新开窗口排队消费。
    /// `encrypt` = 右键「加密压缩…」进入时预开启密码开关。
    func openCreationWorkspace(with urls: [URL], encrypt: Bool = false) {
        guard !urls.isEmpty else { return }
        ensureRegularActivation()
        prune()
        NSApp.activate(ignoringOtherApps: true)
        // 已处于创建模式的窗口：追加文件并置前
        for entry in windows {
            guard let browser = entry.browser, browser.workMode == .create else { continue }
            browser.addCreationItems(urls: urls)
            if encrypt { browser.creationPasswordEnabled = true }
            if let window = entry.window {
                window.makeKeyAndOrderFront(nil)
                bringSteadily(window)
            }
            return
        }
        // 可复用的空窗口（key 窗口优先，其次任意空窗）：就地转创建模式
        let reusable = browser(for: NSApp.keyWindow).flatMap { $0.canReuseForOpen ? $0 : nil }
            ?? idleBrowser()
        if let browser = reusable {
            browser.startCreation()
            browser.addCreationItems(urls: urls)
            if encrypt { browser.creationPasswordEnabled = true }
            if let window = windows.first(where: { $0.browser === browser })?.window {
                window.makeKeyAndOrderFront(nil)
                bringSteadily(window)
            }
            return
        }
        // 兜底：新开窗口，由新窗口 onAppear 消费
        pendingCreationURLs = urls
        pendingCreationEncrypt = encrypt
        openArchiveSceneWindow()
    }

    /// 请求新开一个「archive」主窗口。
    /// AppKit 生命周期下 openWindowAction 恒为 nil，直接走 AppKit 直建窗口。
    private func openArchiveSceneWindow() {
        if let action = openWindowAction {
            action(id: "archive")
            return
        }
        openFallbackMainWindow()
    }

    /// AppKit 主窗口：尺寸与样式与 WindowGroup 保持一致（hiddenTitleBar、900×600、最小 880×560）。
    /// `initialURL`：批量打开时直接注入压缩包，不经过 router 排队（见 openBatch）。
    /// `cascadeIndex`：批量时逐窗错开，避免 N 个窗口完全重叠看不见。
    private func openFallbackMainWindow(initialURL: URL? = nil, cascadeIndex: Int = 0) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "FreeArc"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 880, height: 560)
        // 批量窗口各有自己的位置，不共用同一个 autosave frame（否则又被拉回同一处）
        if initialURL == nil { window.setFrameAutosaveName("afz-fallback-main") }
        window.contentView = NSHostingView(rootView: MainWindowView(
            attachesOpenWindow: false,
            initialURL: initialURL
        ))
        // ARC 管理窗口寿命：关窗时不能让 AppKit 再 release 一次（见 retainOwnedWindow）
        retainOwnedWindow(window)
        window.center()
        if cascadeIndex > 0 {
            let shift = CGFloat(cascadeIndex) * 28
            var origin = NSPoint(x: window.frame.minX + shift, y: window.frame.minY - shift)
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - window.frame.width - 8)
                origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - window.frame.height - 8)
            }
            window.setFrameOrigin(origin)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 上屏保险：SwiftUI 环境就绪存在竞态，makeKeyAndOrderFront 偶发没把窗口带上屏
    /// （窗口枚举里找不到、截屏为空）。稍后补一次 orderFront 兜底。
    private func bringSteadily(_ window: NSWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak window] in
            guard let window, !window.isVisible else { return }
            window.orderFront(nil)
        }
    }

    /// 新窗口 onAppear 取走「创建工作台」请求（与压缩包 URL 互斥，创建请求优先）。
    func consumePendingCreationURLs() -> [URL]? {
        defer { pendingCreationURLs = nil }
        return pendingCreationURLs
    }

    /// 取走创建请求的加密预设（在 consumePendingCreationURLs 之后调用）。
    func consumePendingCreationEncrypt() -> Bool {
        defer { pendingCreationEncrypt = false }
        return pendingCreationEncrypt
    }

    // MARK: - 私有

    private func idleBrowser() -> ArchiveBrowser? {
        prune()
        return windows.first { $0.browser?.canReuseForOpen == true }?.browser
    }

    /// 关闭除 keeper 外所有从未打开过内容的空窗口（欢迎窗/失败窗）。
    private func closeIdleWindows(except keeper: ArchiveBrowser) {
        for entry in windows {
            guard let browser = entry.browser, browser !== keeper,
                  browser.canReuseForOpen, browser.url == nil else { continue }
            entry.window?.close()
        }
        prune()
    }

    /// 批量打开前收掉所有空欢迎窗（不留空白窗混在 N 个浏览窗口里）。
    func closeAllIdleWindows() {
        prune()
        for entry in windows where entry.browser?.canReuseForOpen == true && entry.browser?.url == nil {
            entry.window?.close()
        }
        prune()
    }

    /// 关闭承载指定 browser 的窗口（解压后自动收尾：移入废纸篓 / 自动关闭压缩包）。
    func closeWindow(containing browser: ArchiveBrowser) {
        prune()
        guard let entry = windows.first(where: { $0.browser === browser }) else { return }
        entry.window?.close()
    }

    private func prune() {
        windows.removeAll { $0.window == nil || $0.browser == nil }
    }
}

// MARK: - 菜单命令按窗口分发（focused value）

struct ArchiveBrowserFocusedKey: FocusedValueKey {
    typealias Value = ArchiveBrowser
}

extension FocusedValues {
    var archiveBrowser: ArchiveBrowser? {
        get { self[ArchiveBrowserFocusedKey.self] }
        set { self[ArchiveBrowserFocusedKey.self] = newValue }
    }
}

/// 文件菜单：⌘O 由当前获得焦点的窗口处理（多窗口下不会一次弹出多个面板）。
struct ArchiveCommands: Commands {
    @FocusedValue(\.archiveBrowser) private var browser

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("打开压缩包…") {
                browser?.presentOpenPanel()
            }
            .keyboardShortcut("o")
            .disabled(browser == nil)
        }
    }
}

/// 处理 Finder「打开方式」/双击文件（含冷启动），交给多窗口路由。
@MainActor
final class ArcFreeZipAppDelegate: NSObject, NSApplicationDelegate {

    /// SIGTERM / SIGHUP 转正常退出的信号源（需持有，防止释放后失效）
    private static var terminationSources: [DispatchSourceSignal] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        installGracefulSignalTermination()
        // 主程序进程内的动作改走既有窗口路由，避免再启动一个自己。
        FinderTaskRunner.openHandler = { urls in
            Task { @MainActor in
                for url in urls {
                    ArchiveWindowRouter.shared.openExternal(url)
                }
            }
        }
        FinderTaskRunner.creationHandler = { urls, encrypt in
            Task { @MainActor in
                ArchiveWindowRouter.shared.openCreationWorkspace(with: urls, encrypt: encrypt)
            }
        }
        // 「自动选中解压结果」（解压设置页）：FinderTaskRunner 解压成功后由这里定位访达。
        // 右键后台任务保持成功静默——解压设置只作用于主窗口的解压动作。
        FinderTaskRunner.extractRevealHandler = { [weak self] urls in
            guard let self, !self.launchedInBackground else { return }
            for url in urls { FinderReveal.reveal(url) }
        }
        // 右键菜单任务进度 HUD（解压/压缩的真实进度；成功静默，仅失败提示）
        FinderTaskRunner.eventHandler = { [weak self] event in
            DispatchQueue.main.async {
                switch event {
                case .started(let title, let subtitle, let symbol):
                    FinderTaskHUD.shared.show(title: title, subtitle: subtitle, symbol: symbol)
                case .progress(let fraction, let detail):
                    FinderTaskHUD.shared.update(fraction: fraction, detail: detail)
                case .finished(let success, let message):
                    FinderTaskHUD.shared.finish(message: message, success: success)
                    self?.scheduleBackgroundQuitIfIdle(success: success)
                case .cancelled:
                    FinderTaskHUD.shared.cancel()
                    self?.scheduleBackgroundQuitIfIdle(success: false)
                }
            }
        }
        // 右键解压加密包：居中密码卡片（与主窗口 PasswordDialogCard 同一套样式），
        // 输入后带密码重试；取消则由 FinderTaskRunner 转交主程序浏览
        // （约定：handler 已在主线程被调用，assumeIsolated 进入 MainActor 域）
        FinderTaskRunner.passwordPromptHandler = { archive, wrong, completion in
            MainActor.assumeIsolated {
                FinderPasswordPanel.shared.prompt(
                    archiveName: archive.lastPathComponent,
                    wrong: wrong,
                    completion: completion
                )
            }
        }
        // 密码本：右键解压加密包时先在后台逐条校验，命中就直接解压（不打扰用户）
        FinderTaskRunner.passwordBookSnapshot = { PasswordBook.threadSafePasswords() }
        FinderTaskRunner.passwordBookVerifier = { url, password in
            PasswordBookTrial.verify(url: url, password: password)
        }
        FinderTaskRunner.passwordBookRemember = { url, password in
            DispatchQueue.main.async {
                let name = (url.lastPathComponent as NSString).deletingPathExtension
                PasswordBook.shared.rememberIfEnabled(password: password, suggestedName: name)
            }
        }
        // 手动输密码解压成功 → 主程序弹「保存密码到密码本？」询问（不静默保存）
        FinderTaskRunner.passwordSavePromptHandler = { url, password in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard PasswordSavePrompt.shouldAsk(password: password) else { return }
                    PasswordSavePrompt.present(
                        archiveName: url.lastPathComponent, password: password
                    )
                }
            }
        }
    }

    /// SIGTERM / SIGHUP（外部 kill、pkill、Bash 会话回收）→ 走 NSApp.terminate 正常退出。
    ///
    /// 背景：AppKit 不处理传统信号，进程被 kill 会被 macOS 记为「意外退出」，
    /// 下次启动弹「上次打开时意外退出，要重新打开窗口吗」恢复提示（用户实测每次启动都弹）。
    /// 转成 terminate 后进程干净退场，系统不再标记。
    private func installGracefulSignalTermination() {
        for sig in [SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)   // 交给 DispatchSource 接管
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            Self.terminationSources.append(source)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock 图标：icns 是静态石墨默认；运行中由 IconArtwork 按 AppSettings 实时重绘（换主题色即跟随）
        AppIconSync.install()
        // 访达右键扩展：首次启动自动注册（幂等），并注销历史 build/ 副本的重复登记
        FinderExtensionRegistrar.install()
        // 文件盒托盘（设置开关驱动；默认启用）
        if BoxShelfPreferences.shared.isEnabled {
            BoxShelfPanelController.shared.install()
        }
        // 系统层文档类型注册跟随「在访达里提供打开入口」开关（全量注册，不随文件关联变化）
        //（每次重装/升级后 Info.plist 都是新包的完整声明，这里按开关状态重新同步）
        LSDocTypesManager.sync(
            browseEntryEnabled: UserDefaults.standard.object(forKey: FinderMenuBridge.browseKey) as? Bool ?? true
        )
        // 正常启动（双击 / Launchpad / Spotlight）：主动开欢迎窗。
        // AppKit 生命周期下「不主动开窗就没有窗」——之前只给右键后台任务做了不建窗，
        // 漏了正常启动这一支，表现为应用只停在 Dock 栏、点一下 Dock 才出欢迎窗。
        scheduleWelcomeWindowIfNeeded()
    }

    /// 正常启动补一个欢迎窗。三个例外不建窗：
    /// ① `-afz-background` 右键任务冷启动；② 本次已处理访达右键请求；
    /// ③ 本次已由「双击压缩包 / 打开方式」开出浏览窗。
    /// 延迟一小拍是为了等 LaunchServices 的 open 事件先落地，避免先闪欢迎窗再变浏览窗。
    private func scheduleWelcomeWindowIfNeeded() {
        guard !launchedInBackground else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            guard !self.launchedInBackground, !self.receivedFinderRequestThisLaunch else { return }
            // 已有主窗口（外部打开 / 恢复）就不再补；文件盒托盘是不带 .titled 的无边框面板，不会被误判
            let hasMainWindow = NSApp.windows.contains {
                $0.isVisible && $0.styleMask.contains(.titled) && $0.frame.width > 400
            }
            guard !hasMainWindow else { return }
            ArchiveWindowRouter.shared.openEmptyWindowIfNeeded()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 点 Dock 图标时若没有任何可见窗口（只剩托盘），重新拉出欢迎窗。
    /// 注意：SwiftUI WindowGroup 在新版 macOS 的 reopen 时**自己也会补一个默认窗口**，
    /// 我们若立刻再建就出现双欢迎窗——延迟一拍复查，系统没补我们才补。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                // 只认真正的主窗口（排除托盘小面板/状态项窗口）
                let hasMainWindow = NSApp.windows.contains {
                    $0.isVisible && $0.styleMask.contains(.titled) && $0.frame.width > 400
                }
                if !hasMainWindow {
                    ArchiveWindowRouter.shared.openEmptyWindowIfNeeded()
                }
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == "freearc" {
                handleFinderRequest(url)
            } else {
                // 用 FreeArc 打开任何文件都进浏览窗口：本应用只作为「打开方式」里的
                // 候选程序，不接管系统默认的双击行为（Info.plist 里 LSHandlerRank=Alternate）。
                ArchiveWindowRouter.shared.openExternal(url)
            }
        }
    }

    /// 访达右键扩展发来的内部请求（`freearc://create|extract|compress|browse?…`）。
    /// 扩展在沙盒里不能写盘/跑子进程/转交文件，动作全部由主程序（无沙盒）执行。
    private func handleFinderRequest(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host
        else { return }
        func q(_ name: String) -> String? {
            components.queryItems?.first(where: { $0.name == name })?.value
        }
        let paths = (q("paths") ?? "")
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        // 记一笔：本次启动是「右键任务」拉起的，别再补欢迎窗
        receivedFinderRequestThisLaunch = true
        let trash = q("trash") == "1"
        /// 右键压缩目标格式（zip / 7z；缺省 zip）
        func format() -> CreationFormat {
            (q("format") ?? "").lowercased() == "7z" ? .sevenZip : .zip
        }

        switch host {
        case "create":
            guard !paths.isEmpty else { return }
            ArchiveWindowRouter.shared.openCreationWorkspace(
                with: paths, encrypt: q("encrypt") == "1"
            )

        case "extract":
            guard !paths.isEmpty else { return }
            enterBackgroundModeIfIdleLaunch()
            switch q("mode") {
            case "own":
                FinderTaskRunner.extract(archives: paths, mode: .ownFolder, deleteSource: trash)
            case "chosen":
                // 交互式选目录面板需要正常激活形态（后台形态下面板没有菜单栏，输入体验差）
                ArchiveWindowRouter.shared.ensureRegularActivation()
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = true
                panel.prompt = trash ? "解压并删除源文件" : "解压到这里"
                panel.message = "选择解压结果的存放文件夹"
                NSApp.activate(ignoringOtherApps: true)
                guard panel.runModal() == .OK, let directory = panel.url else { return }
                FinderTaskRunner.extract(archives: paths, mode: .chosen(directory), deleteSource: trash)
            default:
                FinderTaskRunner.extract(archives: paths, mode: .here, deleteSource: trash)
            }

        case "compress":
            guard !paths.isEmpty else { return }
            enterBackgroundModeIfIdleLaunch()
            FinderTaskRunner.compress(items: paths, deleteSource: trash, format: format())

        case "compressto":
            // 右键「压缩为…」「加密压缩为…」：存储面板选位置 → 直接压缩，不进主窗口
            guard !paths.isEmpty else { return }
            // 密码本条目：只传名称，密码在主程序侧解析（扩展拿不到钥匙串）
            let prefilled = q("pwname").flatMap { name in
                PasswordBook.shared.entries.first { $0.name == name }?.password
            }
            FinderTaskRunner.appendLog(
                "compressto：pwname=\(q("pwname") ?? "-")，解析=\(prefilled != nil ? "命中" : "未命中/无")"
            )
            runQuickCompressTo(
                items: paths, encrypt: q("encrypt") == "1", format: format(),
                prefilledPassword: prefilled
            )

        case "browse":
            guard !paths.isEmpty else { return }
            if paths.count == 1 {
                ArchiveWindowRouter.shared.openExternal(paths[0])
            } else {
                // 多选：每个压缩包各开一个窗口（与主窗口的多开策略一致）
                ArchiveWindowRouter.shared.openBatch(paths)
            }

        default:
            break
        }
    }

    /// 右键「压缩为…」「加密压缩为…」：存储面板选保存位置 → 直接压缩出包，
    /// **全程不进主窗口**：任务在后台跑完即退出，不打断用户手上的事。
    /// 加密时追加居中密码卡片（"设置密码"语境）；取消面板或密码即放弃，绝不误压。
    /// 选完位置后应用转回后台形态（无 Dock 图标），任务结束自动退出——用完即走。
    private func runQuickCompressTo(
        items: [URL], encrypt: Bool, format: CreationFormat, prefilledPassword: String? = nil
    ) {
        ArchiveWindowRouter.shared.ensureRegularActivation()
        NSApp.activate(ignoringOtherApps: true)

        let first = items[0]
        let panel = NSSavePanel()
        // 允许 zip / 7z 两种扩展名（面板默认名按预设格式，用户可改）
        panel.allowedContentTypes = [
            UTType(filenameExtension: "zip"),
            UTType(filenameExtension: "7z"),
        ].compactMap { $0 }
        panel.directoryURL = first.deletingLastPathComponent()
        panel.nameFieldStringValue = quickCompressBaseName(for: items) + "." + format.fileExtension
        panel.prompt = encrypt ? "加密压缩" : "压缩"
        panel.message = "选择压缩包的保存位置"
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }

            // 没有用户窗口（右键任务冷启动）才转后台形态：
            // 已在运行且开着窗口的会话保持常规形态，Dock 图标不受影响
            let hasUserWindow = NSApp.windows.contains {
                $0.isVisible && $0.styleMask.contains(.titled) && $0.frame.width > 400
            }
            if !hasUserWindow {
                self.launchedInBackground = true
                NSApp.setActivationPolicy(.accessory)
            }

            // 实际格式跟随用户最终选的扩展名（预设只决定默认名）
            let chosen = destination.pathExtension.lowercased() == "7z"
                ? CreationFormat.sevenZip
                : CreationFormat.zip

            let proceed: (String?) -> Void = { [weak self] password in
                guard let self else { return }
                if encrypt && password == nil { return }  // 取消密码输入 → 放弃压缩
                FinderTaskRunner.compress(
                    items: items,
                    deleteSource: false,
                    destination: destination,
                    password: password,
                    format: chosen
                )
            }
            if encrypt {
                if let prefilledPassword, !prefilledPassword.isEmpty {
                    // 密码本条目：跳过密码卡片，直接按选中密码打包
                    proceed(prefilledPassword)
                } else {
                    FinderPasswordPanel.shared.prompt(
                        archiveName: destination.lastPathComponent,
                        wrong: false,
                        title: "设置压缩包密码",
                        message: "「\(destination.lastPathComponent)」将以密码加密创建。",
                        completion: proceed
                    )
                }
            } else {
                proceed(nil)
            }
        }
    }

    /// 与扩展端 compressBaseName 同规则：单项目取自身名，多选取所在文件夹名。
    private func quickCompressBaseName(for items: [URL]) -> String {
        guard let first = items.first else { return "归档" }
        if items.count == 1 {
            return first.hasDirectoryPath
                ? first.lastPathComponent
                : first.deletingPathExtension().lastPathComponent
        }
        let parent = first.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? "归档" : parent
    }

    // MARK: - 后台形态收尾

    /// 是否以「右键任务」后台形态启动（无 Dock 图标，任务结束自动退出）。
    private var launchedInBackground = CommandLine.arguments.contains(
        FinderTaskRunner.backgroundLaunchArgument
    )
    /// 本次启动是否处理过访达右键请求（extract / compress / compressto / create / browse）。
    /// 用于区分「用户主动启动」与「右键任务拉起」：后者绝不补欢迎窗。
    private var receivedFinderRequestThisLaunch = false
    private let processStartedAt = Date()
    private var backgroundQuitWork: DispatchWorkItem?

    /// 兜底：即便启动参数没送到（LaunchServices 差异），冷启动处理右键任务时
    /// 也切到无 Dock 图标形态——用户看不到主程序被打开。
    private func enterBackgroundModeIfIdleLaunch() {
        guard !launchedInBackground else { return }
        guard Date().timeIntervalSince(processStartedAt) < 8 else { return }
        let hasUserWindow = NSApp.windows.contains {
            $0.isVisible && $0.styleMask.contains(.titled) && $0.frame.width > 400
        }
        guard !hasUserWindow else { return }
        launchedInBackground = true
        NSApp.setActivationPolicy(.accessory)
    }

    /// 后台形态下任务结束即退出：用户感知不到主程序被打开过。
    /// 若期间拉起了用户窗口（例如加密包转交浏览），或还有任务在跑，则不退出。
    /// 成功时 HUD 立即消失 → 1.2s 后退出；失败时留出读完提示的时间 → 3.6s。
    private func scheduleBackgroundQuitIfIdle(success: Bool) {
        guard launchedInBackground else { return }
        backgroundQuitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.launchedInBackground else { return }
            guard !FinderTaskRunner.isBusy else { return }
            let hasUserWindow = NSApp.windows.contains {
                $0.isVisible && $0.styleMask.contains(.titled) && $0.frame.width > 400
            }
            guard !hasUserWindow else { return }
            NSApp.terminate(nil)
        }
        backgroundQuitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (success ? 1.2 : 3.6), execute: work)
    }
}
