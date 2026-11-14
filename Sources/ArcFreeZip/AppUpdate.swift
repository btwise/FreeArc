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
    static let currentVersion = "1.2.0"
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
        case downloading(fraction: Double)
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
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private var progressSession: URLSession?
    private var progressWindow: NSWindow?

    // MARK: 检查

    /// 手动检查入口（设置页按钮 / 应用菜单）；自动检查走 scheduleStartupCheck。
    func checkNow(manual: Bool) {
        guard !isBusy else { return }
        Task { await check(manual: manual) }
    }

    /// 启动 10 秒后静默检查（每 24h 最多一次；未配置或用户关闭自动检查则跳过）。
    func scheduleStartupCheck() {
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
                throw UpdateError(message: "服务器返回 HTTP \(http.statusCode)"
                    + (http.statusCode == 404 ? "（仓库还没有发布 Release）" : ""))
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

    // MARK: 更新弹窗

    /// 更新介绍弹窗：版本号 + Release Notes（滚动区）+ 三选一。
    func presentUpdateDialog() {
        guard case .available(let release) = state else { return }
        // 探针：AFZ_PROBE_UPDATE_AUTO=1 直接进入下载（端到端自动化验证用，内存态）
        if ProcessInfo.processInfo.environment["AFZ_PROBE"] == "1",
           ProcessInfo.processInfo.environment["AFZ_PROBE_UPDATE_AUTO"] == "1" {
            startDownload(release)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 v\(release.version)"
        alert.informativeText = "当前版本 v\(AppUpdate.currentVersion) · 安装包 \(afzByteText(release.assetSize))"

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        text.isEditable = false
        text.font = .systemFont(ofSize: 12)
        text.string = release.notes
        text.autoresizingMask = [.width]
        scroll.documentView = text
        alert.accessoryView = scroll

        alert.addButton(withTitle: "下载并更新")
        alert.addButton(withTitle: "跳过此版本")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            startDownload(release)
        case .alertSecondButtonReturn:
            AppSettings.updateSkippedVersion = release.version
            state = .idle
        default:
            state = .idle
        }
    }

    // MARK: 下载

    private func startDownload(_ release: ReleaseInfo) {
        state = .downloading(fraction: 0)
        showProgressPanel()
        let delegate = DownloadDelegate { [weak self] fraction in
            Task { @MainActor [weak self] in
                self?.state = .downloading(fraction: fraction)
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

    func cancelDownload() {
        progressSession?.invalidateAndCancel()
        progressSession = nil
        closeProgressPanel()
        state = .idle
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
            state = .installing
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try Self.installDownloaded(data: data, version: release.version)
                    await MainActor.run { [weak self] in
                        self?.closeProgressPanel()
                        self?.state = .idle
                        self?.relaunch()
                    }
                } catch let error as UpdateError {
                    await MainActor.run { [weak self] in
                        self?.closeProgressPanel()
                        self?.state = .failed(message: error.message)
                        self?.presentFailureAlert(stage: "安装更新", detail: error.message)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.closeProgressPanel()
                        self?.state = .failed(message: error.localizedDescription)
                        self?.presentFailureAlert(stage: "安装更新", detail: error.localizedDescription)
                    }
                }
            }
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
        if fm.fileExists(atPath: dest.path) {
            do {
                try fm.removeItem(at: dest)
            } catch {
                // 旧版本目录暂时删不掉（可能正被系统占用）：降级改名让位
                let backup = dest.deletingLastPathComponent()
                    .appendingPathComponent(".afz-old-\(UUID().uuidString)")
                if (try? fm.moveItem(at: dest, to: backup)) == nil {
                    try? fm.removeItem(at: staging)
                    throw UpdateError(message: "旧版本目录被占用，无法替换：\(dest.path)\n\(error.localizedDescription)")
                }
            }
        }
        do {
            try fm.moveItem(at: staging, to: dest)
        } catch {
            try? fm.removeItem(at: staging)
            throw UpdateError(message: "新版本就位失败：\(error.localizedDescription)")
        }
        try? runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
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

    // MARK: 下载进度浮窗

    private func showProgressPanel() {
        guard progressWindow == nil else { return }
        let hosting = NSHostingView(rootView: UpdateProgressPanelView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = hosting
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        progressWindow = window
    }

    private func closeProgressPanel() {
        progressWindow?.orderOut(nil)
        progressWindow?.close()
        progressWindow = nil
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
    private let onProgress: @Sendable (Double) -> Void
    private let completion: @Sendable (Result<Data, Error>) -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private var expectedLength: Int64 = -1

    init(onProgress: @escaping @Sendable (Double) -> Void,
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
        let received = buffer.count
        let total = expectedLength
        lock.unlock()
        if total > 0 {
            onProgress(min(1, Double(received) / Double(total)))
        }
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

// MARK: - 下载进度浮窗视图

struct UpdateProgressPanelView: View {
    @ObservedObject private var center = UpdateCenter.shared

    var body: some View {
        Group {
            switch center.state {
            case .downloading(let fraction):
                TaskProgressCard(
                    symbol: "arrow.down.circle",
                    title: "正在下载更新",
                    name: "FreeArc 新版本",
                    fraction: fraction,
                    detail: nil
                ) {
                    center.cancelDownload()
                }
            case .installing:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在安装更新…完成后将自动重启")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 22)
            default:
                EmptyView()
            }
        }
        .padding(8)
        .frame(width: 380)
    }
}
