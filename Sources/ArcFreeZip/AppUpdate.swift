import AppKit
import SwiftUI
import Foundation
import ArchiveCore

// MARK: - 更新源配置

/// GitHub Releases 更新渠道（免费开源软件的标配升级路径，不需要自建服务器）。
///
/// 发布约定（README「发布与更新」一节同步说明）：
/// - Tag：`v1.2.0`（严格三段语义化版本，程序用它和本地版本比较）
/// - Asset：`FreeArc-1.2.0.zip`（内含 FreeArc.app）；更新器优先精确匹配，
///   找不到再退回任意名字带 freearc 的 .zip
/// - Release 介绍直接写在 Release body（Markdown），更新弹窗原样展示
enum AppUpdateConfig {
    static let repoOwner = "btwise"
    static let repoName = "FreeArc"

    /// 更新源是否可用（将来若换组织/改名只动这两个常量）
    static var isConfigured: Bool { !(repoOwner.isEmpty || repoName.isEmpty) }

    static var latestReleaseAPI: URL {
        URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
    }

    /// 探针通道：AFZ_PROBE_UPDATE_REPO="owner/name" 临时指向任一有 Releases 的
    /// 公开仓库，验证检查/解析/弹窗链路（只在 AFZ_PROBE=1 时生效，内存态）。
    static var probeRepo: (owner: String, name: String)? {
        let env = ProcessInfo.processInfo.environment
        guard env["AFZ_PROBE"] == "1",
              let raw = env["AFZ_PROBE_UPDATE_REPO"], raw.contains("/") else { return nil }
        let parts = raw.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    static var effectiveRepo: (owner: String, name: String) {
        probeRepo ?? (repoOwner, repoName)
    }

    /// 探针通道：AFZ_PROBE_UPDATE_API 直接指向完整 API 地址（本地 mock 服务），
    /// 用于端到端验证「检查 → 下载 → 安装 → 重启」全链路（内存态，发布版不生效）。
    static var probeAPIURL: URL? {
        let env = ProcessInfo.processInfo.environment
        guard env["AFZ_PROBE"] == "1",
              let raw = env["AFZ_PROBE_UPDATE_API"], !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    static var apiURL: URL {
        if let probeAPIURL { return probeAPIURL }
        let repo = effectiveRepo
        return URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.name)/releases/latest")!
    }
}

/// 本地版本号（**单一版本源**）。scripts/make_app.sh 打包时从这里抓取并
/// 同步进 Info.plist 的 CFBundleShortVersionString，两处永远一致。
enum AppUpdate {
    static let currentVersion = "1.2.2"
}

// MARK: - 更新中心

/// 检查 / 下载 / 安装 / 重启的完整状态机。
/// 安装语义与拖拽安装完全一致：staging 两段式替换当前运行的应用位置，
/// 新实例拉起后旧实例退出；安装失败按「阶段 + 路径 + 原因」逐条反馈。
@MainActor
final class UpdateCenter: ObservableObject {
    static let shared = UpdateCenter()

    enum State {
        case idle
        case checking
        case notConfigured
        case upToDate
        case available(ReleaseInfo)
        case downloading(fraction: Double, received: Int64, total: Int64)
        /// 已下载完成，等用户点「安装并重启应用」（两段式：下载与安装分离，安装前可反悔）
        case readyToInstall(ReleaseInfo)
        case installing
        case failed(message: String)
    }

    struct ReleaseInfo {
        let version: String
        let notes: String
        let downloadURL: URL
        let assetSize: Int64
    }

    @Published private(set) var state: State = .idle

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .readyToInstall, .installing: return true
        default: return false
        }
    }

    private var progressSession: URLSession?
    private var progressWindow: NSWindow?
    private var progressCloseObserver: NSObjectProtocol?
    /// 更新介绍窗口（.available 阶段）
    private var promptWindow: NSWindow?
    private var promptCloseObserver: NSObjectProtocol?
    /// 已下载待安装的数据（9~10 MB 内存态；安装或放弃后释放）
    private var pendingInstall: (release: ReleaseInfo, data: Data)?

    // MARK: 检查

    /// 手动检查入口（设置页按钮 / 应用菜单）；自动检查走 scheduleStartupCheck。
    func checkNow(manual: Bool) {
        guard !isBusy else { return }
        Task { await check(manual: manual) }
    }

    /// 启动 10 秒后静默检查（每 24h 最多一次；未配置或用户关闭自动检查则跳过）。
    func scheduleStartupCheck() {
        Self.cleanupStaleBackups()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            Task { await self?.autoCheckIfNeeded() }
        }
    }

    private func autoCheckIfNeeded() async {
        guard AppSettings.updateAutoCheck, AppUpdateConfig.isConfigured else { return }
        if let last = AppSettings.updateLastCheck,
           Date().timeIntervalSince(last) < 86_400 { return }
        await check(manual: false)
        if case .available(let release) = state {
            if release.version == AppSettings.updateSkippedVersion {
                state = .idle // 用户明确跳过的版本不再重复打扰
            } else {
                presentUpdateDialog()
            }
        }
    }

    private func check(manual: Bool) async {
        guard AppUpdateConfig.isConfigured else {
            state = .notConfigured
            if manual { presentNotConfiguredAlert() }
            return
        }
        state = .checking
        var request = URLRequest(url: AppUpdateConfig.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FreeArc-Updater", forHTTPHeaderField: "User-Agent")
        if let etag = AppSettings.updateETag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            AppSettings.updateLastCheck = Date()
            guard let http = response as? HTTPURLResponse else {
                throw UpdateError(message: "非 HTTP 响应")
            }
            if http.statusCode == 304 {
                // ETag 命中：Release 信息自上次检查以来没有任何变化
                state = .upToDate
                if manual { presentUpToDateAlert() }
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                // 403/429 是 GitHub 按 IP 限流（未登录 60 次/小时，共享代理出口
                // 很容易被用光）：先走网页回退通道，那条路也不通再给完整解释。
                if http.statusCode == 403 || http.statusCode == 429 {
                    if await checkViaWeb(manual: manual) { return }
                }
                throw UpdateError(message: Self.failedCheckMessage(
                    status: http.statusCode, detail: Self.serverMessage(from: data)))
            }
            if let etag = http.value(forHTTPHeaderField: "ETag") {
                AppSettings.updateETag = etag
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard SemVer.compare(release.tagName, to: AppUpdate.currentVersion) == .orderedDescending else {
                state = .upToDate
                if manual { presentUpToDateAlert() }
                return
            }
            let version = SemVer.normalized(release.tagName)
            guard let asset = pickAsset(from: release.assets, version: version) else {
                throw UpdateError(message: "Release v\(version) 里没有找到 .zip 安装包资产")
            }
            let notes = (release.body?.isEmpty == false)
                ? release.body!
                : "本次更新以修复与改进为主。"
            state = .available(ReleaseInfo(
                version: version,
                notes: notes,
                downloadURL: asset.browserDownloadUrl,
                assetSize: asset.size
            ))
            if manual { presentUpdateDialog() }
        } catch let error as UpdateError {
            state = manual ? .failed(message: error.message) : .idle
            if manual {
                presentFailureAlert(stage: "检查更新", detail: error.message)
            }
        } catch {
            state = manual ? .failed(message: error.localizedDescription) : .idle
            if manual {
                presentFailureAlert(stage: "检查更新", detail: error.localizedDescription)
            }
        }
    }

    /// 资产选择：精确 `FreeArc-<version>.zip` 优先，退回名字带 freearc 的 .zip。
    private func pickAsset(from assets: [GitHubRelease.Asset], version: String) -> GitHubRelease.Asset? {
        let wanted = "freearc-\(version).zip"
        if let exact = assets.first(where: { $0.name.lowercased() == wanted }) { return exact }
        return assets.first {
            $0.name.lowercased().hasSuffix(".zip") && $0.name.lowercased().contains("freearc")
        }
    }

    // MARK: 网页回退通道

    /// 不碰 api.github.com 的检查通道（API 按 IP 限流，未登录每小时 60 次）：
    /// - 版本号：releases/latest 页面会 302 到 /releases/tag/v<版本>，最终 URL 就是答案
    /// - 资产：规范名 FreeArc-<版本>.zip 试 HEAD；404 再解析 expanded_assets 页拿真实名字
    /// - 大小：对下载地址 HEAD（跟随跳转到对象存储），取 Content-Length
    /// - 说明：这条通道拿不到 Release body，弹窗里给出发布页链接
    ///
    /// 返回 true 表示检查已出结论（有新版 / 已是最新）；false 表示这条路也走不通，
    /// 由上层继续给出带原因的失败提示。
    private func checkViaWeb(manual: Bool) async -> Bool {
        let repo = AppUpdateConfig.effectiveRepo
        let webBase = "https://github.com/\(repo.owner)/\(repo.name)"

        guard let latest = URL(string: "\(webBase)/releases/latest"),
              let tagPage = await Self.finalURL(of: latest),
              let tag = Self.tagFromReleasesPageURL(tagPage) else { return false }
        guard SemVer.compare(tag, to: AppUpdate.currentVersion) == .orderedDescending else {
            state = .upToDate
            if manual { presentUpToDateAlert() }
            return true
        }
        let version = SemVer.normalized(tag)

        guard let assetURL = await Self.webAssetURL(owner: repo.owner, name: repo.name, version: version) else {
            return false
        }
        let size = await Self.remoteContentLength(of: assetURL)
        let notes = "已通过 GitHub 发布页获取版本信息（API 限流，本次走网页回退通道）。\n"
            + "更新内容请见发布页：\n\(tagPage.absoluteString)"
        state = .available(ReleaseInfo(
            version: version,
            notes: notes,
            downloadURL: assetURL,
            assetSize: max(size, 0)
        ))
        if manual { presentUpdateDialog() }
        return true
    }

    /// 跟随重定向后的最终 URL
    private static func finalURL(of url: URL) async -> URL? {
        guard let (_, response) = try? await URLSession.shared.data(for: webRequest(url)) else { return nil }
        return response.url
    }

    /// `…/releases/tag/v1.2.0` → `v1.2.0`；不是发布页 URL 返回 nil
    static func tagFromReleasesPageURL(_ url: URL) -> String? {
        guard url.path.contains("/releases/tag/") else { return nil }
        let tag = url.path.split(separator: "/").last.map(String.init) ?? ""
        return tag.isEmpty ? nil : tag
    }

    /// 网页通道的资产定位：规范名优先，然后从 expanded_assets 页面解析
    private static func webAssetURL(owner: String, name: String, version: String) async -> URL? {
        let canonical = URL(string:
            "https://github.com/\(owner)/\(name)/releases/download/v\(version)/FreeArc-\(version).zip")
        if let canonical, await headStatus(of: canonical) == 200 { return canonical }

        guard let assetsURL = URL(string:
                "https://github.com/\(owner)/\(name)/releases/expanded_assets/v\(version)"),
              let (data, _) = try? await URLSession.shared.data(for: webRequest(assetsURL)),
              let html = String(data: data, encoding: .utf8) else { return nil }
        let hrefs = zipAssetHrefs(in: html)
        guard let picked = hrefs.first(where: { $0.lowercased().contains("freearc") }) ?? hrefs.first else {
            return nil
        }
        return URL(string: "https://github.com\(picked)")
    }

    private static func webRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("FreeArc-Updater", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func headStatus(of url: URL) async -> Int {
        var request = webRequest(url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return -1 }
        return http.statusCode
    }

    private static func remoteContentLength(of url: URL) async -> Int64 {
        var request = webRequest(url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return 0 }
        return max(http.expectedContentLength, 0)
    }

    /// expanded_assets 页面里 `href="…/releases/download/….zip"` 形式的资产链接
    static func zipAssetHrefs(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"href="([^"]*/releases/download/[^"]*\.zip)""#) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .compactMap { Range($0.range(at: 1), in: html).map { String(html[$0]) } }
    }

    // MARK: 失败提示文案

    /// 服务器 JSON 错误体里的 message（GitHub 限流时这里写明了原因）
    private static func serverMessage(from data: Data?) -> String {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String else { return "" }
        return message
    }

    private static func failedCheckMessage(status: Int, detail: String) -> String {
        switch status {
        case 403, 429:
            return "GitHub 接口限流（HTTP \(status)）：未登录请求按出口 IP 计数，每小时 60 次，"
                + "共享网络或代理出口容易被其他用户用光。稍后重试或更换网络/代理节点。"
        case 404:
            return "服务器返回 HTTP 404（仓库还没有发布 Release）"
        default:
            return "服务器返回 HTTP \(status)" + (detail.isEmpty ? "" : "：\(detail)")
        }
    }

    // MARK: 更新介绍窗口

    /// 「发现新版本」窗口：图标 + 摘要 + Markdown 渲染的发布说明 + 按钮条。
    /// 不再用 NSAlert：Release Notes 需要一个能滚动、可选中的阅读区，弹窗太挤。
    func presentUpdateDialog() {
        guard case .available(let release) = state else { return }
        // 探针：AFZ_PROBE_UPDATE_AUTO=1 直接进入下载并自动安装（端到端验证用，内存态）；
        // AFZ_PROBE_UPDATE_READY=1 只自动点「立即更新」，停在就绪窗口（界面核对用）
        let env = ProcessInfo.processInfo.environment
        if env["AFZ_PROBE"] == "1" {
            FileHandle.standardError.write("PROBE: presentUpdateDialog v\(release.version)\n".data(using: .utf8)!)
        }
        if env["AFZ_PROBE"] == "1" && env["AFZ_PROBE_UPDATE_AUTO"] == "1" {
            startDownload(release)
            return
        }
        if env["AFZ_PROBE"] == "1" && env["AFZ_PROBE_UPDATE_READY"] == "1" {
            acceptUpdate()
            return
        }
        showPromptWindow(release)
    }

    private var probeAutoInstall: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["AFZ_PROBE"] == "1" && env["AFZ_PROBE_UPDATE_AUTO"] == "1"
    }

    private func showPromptWindow(_ release: ReleaseInfo) {
        if let window = promptWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 430),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "软件更新"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.contentView = NSHostingView(rootView: UpdatePromptView(release: release))
        window.center()
        promptCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.promptWindowClosedByUser()
            }
        }
        promptWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closePromptWindow() {
        if let observer = promptCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            promptCloseObserver = nil
        }
        promptWindow?.orderOut(nil)
        promptWindow?.close()
        promptWindow = nil
    }

    /// 用户点标题栏关闭钮 = 「稍后再说」（不记忆跳过版本，下次启动仍会提醒）
    private func promptWindowClosedByUser() {
        guard promptWindow != nil else { return }
        closePromptWindow()
        if case .available = state { state = .idle }
    }

    /// 立即更新（介绍窗口主按钮）
    func acceptUpdate() {
        guard case .available(let release) = state else { return }
        closePromptWindow()
        startDownload(release)
    }

    /// 跳过此版本（持久化，本版本不再自动打扰）
    func skipUpdate() {
        if case .available(let release) = state {
            AppSettings.updateSkippedVersion = release.version
        }
        closePromptWindow()
        state = .idle
    }

    /// 稍后提醒（本次不打扰）
    func deferUpdate() {
        closePromptWindow()
        state = .idle
    }

    // MARK: 下载

    private func startDownload(_ release: ReleaseInfo) {
        if ProcessInfo.processInfo.environment["AFZ_PROBE"] == "1" {
            FileHandle.standardError.write("PROBE: startDownload \(release.version) size=\(release.assetSize)\n".data(using: .utf8)!)
        }
        state = .downloading(fraction: 0, received: 0, total: release.assetSize)
        showProgressPanel()
        let delegate = DownloadDelegate { [weak self] fraction, received, total in
            Task { @MainActor [weak self] in
                // 个别响应拿不到 Content-Length（expectedContentLength = -1），
                // 回退用资产大小，保证「已下载 / 总大小」始终成对出现
                let effectiveTotal = total > 0 ? total : release.assetSize
                self?.state = .downloading(fraction: fraction, received: received, total: effectiveTotal)
            }
        } completion: { [weak self] result in
            Task { @MainActor [weak self] in
                self?.finishDownload(result, release: release)
            }
        }
        // URLSession 强持有 delegate 直到 invalidate；完成/取消路径都必须收敛到
        // finishDownload 或 cancelDownload 之一，session 只会在那里失效。
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        progressSession = session
        session.dataTask(with: release.downloadURL).resume()
    }

    /// 用户取消下载：中断会话、关窗、回到空闲。
    func cancelDownload() {
        progressSession?.invalidateAndCancel()
        progressSession = nil
        pendingInstall = nil
        closeProgressPanel()
        state = .idle
    }

    /// 放弃已下载的更新（就绪阶段点关闭/取消）：数据直接丢弃。
    func discardPendingInstall() {
        progressSession?.invalidateAndCancel()
        progressSession = nil
        pendingInstall = nil
        closeProgressPanel()
        state = .idle
    }

    /// 就绪阶段的「安装并重启应用」。
    func installNow() {
        guard case .readyToInstall = state, let pending = pendingInstall else { return }
        state = .installing
        let data = pending.data
        let version = pending.release.version
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try Self.installDownloaded(data: data, version: version)
                await MainActor.run { [weak self] in
                    self?.pendingInstall = nil
                    self?.closeProgressPanel()
                    self?.state = .idle
                    self?.relaunch()
                }
            } catch let error as UpdateError {
                await MainActor.run { [weak self] in
                    self?.pendingInstall = nil
                    self?.closeProgressPanel()
                    self?.state = .failed(message: error.message)
                    self?.presentFailureAlert(stage: "安装更新", detail: error.message)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.pendingInstall = nil
                    self?.closeProgressPanel()
                    self?.state = .failed(message: error.localizedDescription)
                    self?.presentFailureAlert(stage: "安装更新", detail: error.localizedDescription)
                }
            }
        }
    }

    private func finishDownload(_ result: Result<Data, Error>, release: ReleaseInfo) {
        progressSession?.finishTasksAndInvalidate()
        progressSession = nil
        switch result {
        case .failure(let error):
            closeProgressPanel()
            if (error as? URLError)?.code == .cancelled {
                state = .idle
                return
            }
            state = .failed(message: error.localizedDescription)
            presentFailureAlert(stage: "下载更新包", detail: error.localizedDescription)
        case .success(let data):
            guard !data.isEmpty else {
                closeProgressPanel()
                state = .failed(message: "下载内容为空")
                presentFailureAlert(stage: "下载更新包", detail: "下载内容为空，可能是网络中断")
                return
            }
            pendingInstall = (release, data)
            state = .readyToInstall(release)
            // 探针链路：下载完自动安装，不等人点按钮
            if probeAutoInstall { installNow() }
        }
    }

    // MARK: 安装（复用拖拽安装的 staging 两段式语义）

    /// 把下载的 zip 安装为当前运行的应用位置：
    /// 写临时目录 → 清 quarantine → ditto 解压 → staging 复制 → 原子就位。
    private nonisolated static func installDownloaded(data: Data, version: String) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("afz-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let zipURL = tmp.appendingPathComponent("FreeArc-\(version).zip")
        try data.write(to: zipURL)

        // 程序自己下载的文件会带 com.apple.quarantine；不清掉的话解压出的
        // 新 app 启动会被 Gatekeeper 拦（ad-hoc 签名没有 Developer ID 可验证）。
        // 清除失败不阻断安装——只影响一次启动警告。
        try? runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", zipURL.path])

        // ditto 保留符号链接与代码签名元数据，比手动遍历解压可靠
        let extractDir = tmp.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        do {
            try runTool("/usr/bin/ditto", ["-x", "-k", zipURL.path, extractDir.path])
        } catch {
            throw UpdateError(message: "解压更新包失败：\(error.localizedDescription)")
        }

        let contents = (try? fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)) ?? []
        guard let appURL = contents.first(where: { $0.lastPathComponent == "FreeArc.app" })
            ?? contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError(message: "更新包里没有找到 FreeArc.app")
        }
        try? runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appURL.path])

        let dest = Bundle.main.bundleURL
        let staging = dest.deletingLastPathComponent()
            .appendingPathComponent(".afz-install-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: appURL, to: staging)
        } catch {
            throw UpdateError(message: "复制新版本失败（目标：\(staging.path)）\n\(error.localizedDescription)")
        }
        // 运行中的应用包**不能删除**：进程虽然靠已映射的二进制继续活着，但包没了之后
        // 任何延迟的资源加载都可能崩（实测关闭窗口时 SIGSEGV）。改名让位对运行中的
        // 进程是无害的——inode 与映射都不变——新包顶上原位后，旧目录由下次启动的
        // cleanupStaleBackups() 清理。
        let backup = dest.deletingLastPathComponent()
            .appendingPathComponent(".afz-old-\(UUID().uuidString)")
        do {
            try fm.moveItem(at: dest, to: backup)
        } catch {
            try? fm.removeItem(at: staging)
            throw UpdateError(message: "旧版本目录无法让位：\(dest.path)\n\(error.localizedDescription)")
        }
        do {
            try fm.moveItem(at: staging, to: dest)
        } catch {
            // 新包就位失败：尽力把旧包挪回原位，保住可用状态
            try? fm.moveItem(at: backup, to: dest)
            try? fm.removeItem(at: staging)
            throw UpdateError(message: "新版本就位失败：\(error.localizedDescription)")
        }
        try? runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
    }

    /// 清理历史更新留下的旧包目录（`.afz-old-*` / `.afz-install-*`）。
    /// 只清创建超过 60 秒的：刚改名让位的目录可能还被上一个正在退出的实例使用。
    nonisolated static func cleanupStaleBackups() {
        let fm = FileManager.default
        let dir = Bundle.main.bundleURL.deletingLastPathComponent()
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            let name = item.lastPathComponent
            guard name.hasPrefix(".afz-old-") || name.hasPrefix(".afz-install-") else { continue }
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            guard Date().timeIntervalSince(modified) > 60 else { continue }
            try? fm.removeItem(at: item)
        }
    }

    private nonisolated static func runTool(_ path: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError(message: "\(URL(fileURLWithPath: path).lastPathComponent) 退出码 \(process.terminationStatus)")
        }
    }

    // MARK: 重启

    /// 替换完成后：拉起新实例 → 旧实例退出。顺序不能反——先退旧再拉新
    /// 可能被 LaunchServices 判定「应用已退出」而不再启动。
    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        let dest = Bundle.main.bundleURL
        Task {
            _ = try? await NSWorkspace.shared.openApplication(at: dest, configuration: config)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: 更新进度窗口

    /// 下载 / 就绪 / 安装三个阶段共用一个标准标题栏窗口（标题「正在更新 FreeArc」）。
    /// 必须设 isReleasedWhenClosed = false：ARC 下 AppKit 在 close 时对默认为 true 的
    /// 窗口多发一次 release，会把窗口过度释放——全局 willClose 观察者随后 retain 僵尸
    /// 对象直接 SIGSEGV（v1.2.1 实测崩溃，见 WindowRouting.retainOwnedWindow 注释）。
    private func showProgressPanel() {
        if let window = progressWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 168),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "正在更新 FreeArc"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.contentView = NSHostingView(rootView: UpdateProgressView())
        window.center()
        progressCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.progressWindowClosedByUser()
            }
        }
        progressWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeProgressPanel() {
        if let observer = progressCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            progressCloseObserver = nil
        }
        progressWindow?.orderOut(nil)
        progressWindow?.close()
        progressWindow = nil
    }

    /// 标题栏关闭钮的语义随阶段变化：下载中=取消下载，就绪=放弃安装，安装中=仅关窗。
    private func progressWindowClosedByUser() {
        guard progressWindow != nil else { return }
        switch state {
        case .downloading:
            cancelDownload()
        case .readyToInstall:
            discardPendingInstall()
        default:
            closeProgressPanel()
        }
    }

    // MARK: 提示弹窗

    private func presentUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "当前 FreeArc v\(AppUpdate.currentVersion) 已是最新发布版本。"
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentNotConfiguredAlert() {
        let repo = AppUpdateConfig.effectiveRepo
        let alert = NSAlert()
        alert.messageText = "更新源尚未就绪"
        alert.informativeText = "GitHub 仓库 \(repo.owner)/\(repo.name) 还没有发布版本。\n创建第一个 Release（tag 形如 v1.2.0、附 FreeArc-1.2.0.zip）后，更新检查会自动生效。"
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentFailureAlert(stage: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "更新未能完成"
        alert.informativeText = "阶段：\(stage)\n\(detail)"
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - 数据模型

private struct GitHubRelease: Decodable {
    let tagName: String
    let body: String?
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
        let size: Int64

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
            case size
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case assets
    }
}

private struct UpdateError: Error {
    let message: String
}

// MARK: - 下载进度代理

/// URLSession 数据代理：汇总进度与完成结果。
/// 所有回调都在 session 的串行队列上，buffer/expectedLength 无并发竞争。
private final class DownloadDelegate: NSObject, URLSessionDataDelegate {
    private let onProgress: @Sendable (Double, Int64, Int64) -> Void
    private let completion: @Sendable (Result<Data, Error>) -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private var expectedLength: Int64 = -1

    init(onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void,
         completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.onProgress = onProgress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse) {
        lock.lock()
        expectedLength = response.expectedContentLength
        lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.lock()
        buffer.append(data)
        let received = Int64(buffer.count)
        let total = expectedLength
        lock.unlock()
        let fraction = total > 0 ? min(1, Double(received) / Double(total)) : 0
        onProgress(fraction, received, max(total, 0))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        let data = buffer
        buffer = Data()
        lock.unlock()
        if let error {
            completion(.failure(error))
        } else {
            completion(.success(data))
        }
    }
}

// MARK: - 更新窗口视图

/// Release Notes 的块级 Markdown 渲染。
/// SwiftUI 的 `Text(AttributedString)` 只认字符级属性，不认块级意图——标题会掉字号、
/// 列表符号直接消失。这里按行自渲染：标题加粗放大、列表补圆点/编号、引用块灰字缩进，
/// 行内样式（加粗/斜体/行内代码）交给系统的 inline 解析。
private enum UpdateNotesRenderer {
    static func render(_ markdown: String) -> AttributedString {
        var result = AttributedString()
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for raw in lines {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                result.append(AttributedString("\n"))
                continue
            }
            result.append(block(for: line))
            result.append(AttributedString("\n"))
        }
        return result
    }

    private static func block(for line: String) -> AttributedString {
        // 标题：# ～ ######，两级字号足够（Release Notes 不会更深）
        if line.hasPrefix("#") {
            let level = line.prefix(while: { $0 == "#" }).count
            let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            var content = inline(text)
            if level <= 2 {
                content.mergeAttributes(fontContainer(size: level == 1 ? 16 : 14, weight: .semibold))
            }
            return content
        }
        // 无序列表：补圆点符号
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
            let body = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return AttributedString("•  ") + inline(body)
        }
        // 有序列表：编号与正文拉开固定间距
        if let body = numberedBody(line) {
            let numberEnd = line.index(line.startIndex, offsetBy: line.count - body.count)
            let number = String(line[..<numberEnd]).trimmingCharacters(in: .whitespaces)
            return AttributedString("\(number)  ") + inline(body)
        }
        // 引用块：灰字
        if line.hasPrefix(">") {
            var content = inline(line.dropFirst().trimmingCharacters(in: .whitespaces))
            content.mergeAttributes(foregroundContainer(.secondary))
            return content
        }
        return inline(line)
    }

    /// `1. xxx` / `2) xxx` → 正文部分；不是有序列表返回 nil
    private static func numberedBody(_ line: String) -> String? {
        guard let first = line.first, first.isNumber else { return nil }
        guard let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let after = line.index(after: dot)
        let body = line[after...].trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : String(body)
    }

    /// 行内 Markdown（加粗/斜体/行内代码/链接）交给系统解析；解析失败退回纯文本。
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private static func fontContainer(size: CGFloat, weight: Font.Weight) -> AttributeContainer {
        var container = AttributeContainer()
        container.font = .system(size: size, weight: weight)
        return container
    }

    private static func foregroundContainer(_ color: Color) -> AttributeContainer {
        var container = AttributeContainer()
        container.foregroundColor = color
        return container
    }
}

/// 「发现新版本」窗口：发布说明经 UpdateNotesRenderer 渲染成富文本，
/// 不再是原始符号裸奔的纯文本。
struct UpdatePromptView: View {
    @ObservedObject private var center = UpdateCenter.shared
    let release: UpdateCenter.ReleaseInfo

    private var notes: AttributedString {
        UpdateNotesRenderer.render(release.notes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("FreeArc v\(release.version) 现已发布")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("当前版本 v\(AppUpdate.currentVersion) · 安装包 \(afzByteText(release.assetSize))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                Text(notes)
                    .font(.system(size: 12.5))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerM))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerM)
                    .strokeBorder(Theme.dividerColor, lineWidth: 0.5)
            )
            .padding(.horizontal, 20)

            HStack(spacing: 12) {
                Button(action: { center.skipUpdate() }) {
                    Text("跳过此版本").secondaryCapsule()
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Button(action: { center.deferUpdate() }) {
                    Text("稍后提醒").secondaryCapsule()
                }
                .buttonStyle(.plain)
                Button(action: { center.acceptUpdate() }) {
                    Text("立即更新").primaryCapsule()
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasBackground)
    }
}

/// 下载 / 就绪 / 安装三阶段的进度窗口内容（一个窗口按状态机切换文案与动作）。
struct UpdateProgressView: View {
    @ObservedObject private var center = UpdateCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 48, height: 48)
                stageContent
            }
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.canvasBackground)
    }

    @ViewBuilder private var stageContent: some View {
        switch center.state {
        case .downloading(let fraction, let received, let total):
            VStack(alignment: .leading, spacing: 8) {
                Text("正在下载更新…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                Text(progressDetail(received: received, total: total))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
        case .readyToInstall(let release):
            VStack(alignment: .leading, spacing: 8) {
                Text("更新已下载，可以开始安装")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                ProgressView(value: 1.0)
                    .progressViewStyle(.linear)
                Text("FreeArc v\(release.version) 已就绪，安装会替换当前应用并重启。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .installing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在安装更新…")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("完成后将自动重启应用，请勿关闭窗口")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        default:
            Text("准备更新…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder private var actions: some View {
        switch center.state {
        case .downloading:
            Button(action: { center.cancelDownload() }) {
                Text("取消").secondaryCapsule()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        case .readyToInstall:
            Button(action: { center.installNow() }) {
                Text("安装并重启应用").primaryCapsule()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        default:
            EmptyView()
        }
    }

    private func progressDetail(received: Int64, total: Int64) -> String {
        if total > 0 {
            return "\(afzByteText(received)) / \(afzByteText(total))"
        }
        return "已下载 \(afzByteText(received))"
    }
}
