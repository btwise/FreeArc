import Foundation
import AppKit
import ArchiveCore
import FormatZip

// MARK: - 解压目标

public enum FinderExtractMode: Sendable {
    /// 就地解压到压缩包所在文件夹
    case here
    /// 每个压缩包各建一个「包名」文件夹（解压到源文件对应的文件夹）
    case ownFolder
    /// 解压到用户选择的文件夹（多选时每个包在其中各建子文件夹）
    case chosen(URL)
}

// MARK: - 执行器

/// 右键菜单动作的真实执行者（独立队列，不阻塞菜单）。
///
/// 安全约定（与主程序同一套红线）：
/// 1. 一律先解压到临时目录，全部成功后才合并进目标目录；失败不残留、不覆盖；
/// 2. 同名冲突不覆盖，自动「xx 2 / xx 3」改名；
/// 3. 「删除源文件」只走废纸篓（可恢复），只删普通文件，且必须在解压/压缩成功之后；
/// 4. 删除前重新校验：文件仍存在、仍是普通文件、仍是同一个压缩包格式。
public enum FinderTaskRunner {
    private static let queue = DispatchQueue(
        label: "org.freearc.finder-sync.tasks",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // MARK: - 主程序内调用钩子
    //
    // FinderShared 同时被主程序（Services 通道）与扩展（FinderSync）使用。
    // 主程序启动时注入这两个闭包，动作就会走 App 内既有窗口路由，
    // 而不是再 launch 一次自己；扩展进程里保持 nil，仍用 NSWorkspace。
    nonisolated(unsafe) public static var openHandler: (([URL]) -> Void)?
    nonisolated(unsafe) public static var creationHandler: (([URL], Bool) -> Void)?
    /// 解压成功后的「自动选中解压结果」回调（主程序注入 FinderReveal；
    /// 扩展进程里为 nil——右键任务成功静默，不做访达定位）。
    nonisolated(unsafe) public static var extractRevealHandler: (([URL]) -> Void)?

    /// 任务事件流（主程序注入 → 进度 HUD；扩展进程里为 nil 只写日志）。
    /// 回调在后台线程，UI 侧自行切主线程。
    /// `started` 携带标题 / 副标题（文件名）/ 语义图标，供进度卡还原「标题 + 文件名」两行布局。
    public enum TaskEvent: Sendable {
        case started(title: String, subtitle: String, symbol: String)
        case progress(fraction: Double, detail: String?)
        case finished(success: Bool, message: String)
        /// 用户点了进度卡上的「取消」——HUD 直接收起，不提示失败。
        case cancelled
    }

    nonisolated(unsafe) public static var eventHandler: (@Sendable (TaskEvent) -> Void)?

    // MARK: - 取消
    //
    // HUD 上的「取消」按钮调用 cancelCurrent()。实现方式：任务主体跑在
    // Task.detached 里（runCancellable 同步等待），取消即 task.cancel()——
    // zip 路径靠 Task.checkCancellation 中止，7zz 路径靠 run() 里的
    // Task.isCancelled 终止子进程，暂存目录由各引擎的取消清理逻辑回收。

    private static let cancelLock = NSLock()
    nonisolated(unsafe) private static var canceller: (() -> Void)?

    /// 取消当前右键任务（无任务时无操作）。可跨线程调用。
    public static func cancelCurrent() {
        cancelLock.lock()
        let action = canceller
        cancelLock.unlock()
        guard let action else { return }
        appendLog("用户取消当前任务")
        action()
    }

    private static func installCanceller(_ action: @escaping () -> Void) {
        cancelLock.lock(); canceller = action; cancelLock.unlock()
    }

    private static func clearCanceller() {
        cancelLock.lock(); canceller = nil; cancelLock.unlock()
    }

    /// 存结果的盒子（@unchecked：写入发生在 signal 之前，读取在 wait 之后）。
    private final class ResultBox<T>: @unchecked Sendable {
        var value: Result<T, Error>?
    }

    /// 在可取消的 Task 里执行并同步等待结果。
    private static func runCancellable<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .userInitiated) {
            do { box.value = .success(try await body()) }
            catch { box.value = .failure(error) }
            semaphore.signal()
        }
        installCanceller { task.cancel() }
        semaphore.wait()
        clearCanceller()
        switch box.value {
        case .success(let value): return value
        case .failure(let error): throw error
        case nil: throw FinderTaskError.cancelled
        }
    }

    /// 密码输入（主程序注入 → 居中密码卡片，样式与主窗口的 PasswordDialogCard 一致）。
    /// `wrong` = 上一次密码错误。回调返回输入的密码；nil = 用户取消。
    /// 约定：handler 总是在主线程上被调用（见 promptForPassword），非 @Sendable。
    nonisolated(unsafe) public static var passwordPromptHandler:
        ((_ archive: URL, _ wrong: Bool, _ completion: @escaping (String?) -> Void) -> Void)?

    // MARK: 密码本（主程序注入；扩展进程为 nil = 不启用自动尝试）

    /// 候选密码快照（线程安全读取；后台任务在解压前逐条试）
    nonisolated(unsafe) public static var passwordBookSnapshot: (() -> [String])?
    /// 校验某密码能否解开该压缩包（实现须线程安全，内部跑 7zz 校验）
    nonisolated(unsafe) public static var passwordBookVerifier: ((URL, String) -> Bool)?
    /// 解压成功后回写密码本（按「自动保存」开关判断，主程序侧处理）
    nonisolated(unsafe) public static var passwordBookRemember: ((URL, String) -> Void)?
    /// 手动输入密码解压成功后询问是否保存（主程序弹窗；nil = 不询问）
    nonisolated(unsafe) public static var passwordSavePromptHandler: ((URL, String) -> Void)?

    private static func emit(_ event: TaskEvent) {
        eventHandler?(event)
    }

    // MARK: 忙碌计数（后台模式任务结束后自动退出用）

    private static let busyLock = NSLock()
    nonisolated(unsafe) private static var busyCount = 0

    /// 当前是否有解压/压缩任务在跑（任意线程可读）。
    public static var isBusy: Bool {
        busyLock.lock(); defer { busyLock.unlock() }
        return busyCount > 0
    }

    private static func beginTask() {
        busyLock.lock(); busyCount += 1; busyLock.unlock()
    }

    private static func endTask() {
        busyLock.lock(); busyCount = max(0, busyCount - 1); busyLock.unlock()
    }

    /// 弹出密码卡片并等待输入（阻塞任务队列线程，主线程回调后放行）。
    /// 没有 handler（扩展进程）时直接返回 nil，走「转交主程序打开」的老路。
    private static func promptForPassword(_ archive: URL, wrong: Bool) -> String? {
        guard let handler = passwordPromptHandler else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        // 跨线程回传的小盒子（@unchecked：访问受信号量顺序保护）
        final class AnswerBox: @unchecked Sendable {
            var value: String?
        }
        let box = AnswerBox()
        DispatchQueue.main.async {
            handler(archive, wrong) { password in
                box.value = password
                semaphore.signal()
            }
        }
        semaphore.wait()
        return box.value
    }

    // MARK: 解压

    public static func extract(archives: [URL], mode: FinderExtractMode, deleteSource: Bool) {
        guard !archives.isEmpty else { return }
        appendLog("开始解压：\(archives.map(\.path).joined(separator: " | ")) mode=\(mode) 删除源=\(deleteSource)")
        let multiple = archives.count > 1
        beginTask()
        queue.async {
            defer { endTask() }
            var succeededDestinations: [URL] = []
            var failures: [String] = []
            var trashed = 0
            var needsPassword: [URL] = []
            var userCancelled = false

            for (index, archive) in archives.enumerated() {
                emit(.started(
                    title: archives.count > 1 ? "正在解压（\(index + 1)/\(archives.count)）" : "正在解压",
                    subtitle: archive.lastPathComponent,
                    symbol: "tray.and.arrow.down"
                ))
                var password: String?
                var manuallyEntered = false
                // 密码重试环：passwordRequired → 弹卡片 → 带密码重跑；取消则转交主程序浏览
                while true {
                    do {
                        let pw = password
                        let produced = try runCancellable {
                            try extractOne(
                                archive, mode: mode, isMultiple: multiple, password: pw,
                                overallBase: Double(index) / Double(archives.count),
                                overallSpan: 1.0 / Double(archives.count)
                            )
                        }
                        succeededDestinations.append(produced.destination)
                        // 手动输入密码解压成功：询问是否保存进密码本（「开启密码自动保存?」，
                        // 不静默保存；密码本命中路径由 passwordBookRemember 静默记入，无需重复询问）
                        if manuallyEntered, let pw, !pw.isEmpty, let prompt = passwordSavePromptHandler {
                            prompt(archive, pw)
                        }
                        if deleteSource {
                            if trashSource(archive, expectedFormat: FinderFormats.formatKey(for: archive)) {
                                trashed += 1
                            }
                        }
                        break
                    } catch FinderTaskError.passwordRequired {
                        let wrong = password != nil
                        // 首次需要密码：先用密码本快照逐条校验，命中就直接重跑，不再打扰用户
                        if !wrong,
                           let verifier = passwordBookVerifier,
                           let candidates = passwordBookSnapshot?(),
                           !candidates.isEmpty {
                            appendLog("尝试密码本（\(candidates.count) 条）：\(archive.lastPathComponent)")
                            if let hit = candidates.first(where: { verifier(archive, $0) }) {
                                password = hit
                                passwordBookRemember?(archive, hit)
                                appendLog("密码本命中：\(archive.lastPathComponent)")
                                continue
                            }
                            appendLog("密码本未命中：\(archive.lastPathComponent)")
                        }
                        if wrong {
                            appendLog("密码不正确，重新询问：\(archive.lastPathComponent)")
                        }
                        guard let provided = promptForPassword(archive, wrong: wrong) else {
                            needsPassword.append(archive)
                            break
                        }
                        password = provided
                        manuallyEntered = true
                    } catch ArchiveEngineError.cancelled {
                        // 用户点了进度卡的「取消」：中止全部后续包，静默收场
                        userCancelled = true
                        break
                    } catch {
                        failures.append("\(archive.lastPathComponent)：\(error.localizedDescription)")
                        break
                    }
                }
                if userCancelled { break }
            }

            if userCancelled {
                appendLog("解压已由用户取消")
                emit(.cancelled)
                return
            }

            // 用户取消输入密码的包：交给主程序浏览（那里有完整密码 UI）
            for archive in needsPassword {
                openInMainApp([archive])
            }

            let title = "FreeArc 解压"
            var parts: [String] = []
            if !succeededDestinations.isEmpty {
                parts.append("已解压 \(succeededDestinations.count) 个压缩包")
            }
            if trashed > 0 { parts.append("已移入废纸篓 \(trashed) 个源文件") }
            if !needsPassword.isEmpty { parts.append("\(needsPassword.count) 个已转交 FreeArc 打开") }
            if !failures.isEmpty {
                parts.append("\(failures.count) 个失败")
            }
            if parts.isEmpty { parts.append("没有可解压的项目") }
            // 成功静默：不弹系统通知也不显示完成提示（用户直接在访达看结果）；
            // 只有失败才提示
            if failures.isEmpty {
                appendLog("\(title)：\(parts.joined(separator: "；"))")
            } else {
                notify(title: title, body: parts.joined(separator: "；"), isError: true)
            }
            // 「自动选中解压结果」（解压设置页）：主程序注入的 reveal 回调
            //（解压到当前文件夹这种"落点即原位"的场景也统一走这里）
            let revealHandler = extractRevealHandler
            if failures.isEmpty, !succeededDestinations.isEmpty, let revealHandler {
                DispatchQueue.main.async { revealHandler(succeededDestinations) }
            }
            emit(.finished(success: failures.isEmpty, message: parts.joined(separator: "；")))

            if !failures.isEmpty {
                appendLog("解压失败明细：\n" + failures.joined(separator: "\n"))
            }
        }
    }

    /// 解压单个包，返回落点。抛 `FinderTaskError.passwordRequired` 表示需要主程序介入。
    private struct ExtractOutcome: Sendable {
        let destination: URL
        let fileCount: Int
    }

    private static func extractOne(
        _ archive: URL,
        mode: FinderExtractMode,
        isMultiple: Bool,
        password: String? = nil,
        overallBase: Double = 0,
        overallSpan: Double = 1
    ) throws -> ExtractOutcome {
        let fm = FileManager.default
        let parent = archive.deletingLastPathComponent()
        let stem = archive.deletingPathExtension().lastPathComponent

        var destination: URL
        switch mode {
        case .here:
            destination = parent
        case .ownFolder:
            destination = uniqueDirectory(in: parent, preferred: stem)
        case .chosen(let root):
            if isMultiple {
                destination = uniqueDirectory(in: root, preferred: stem)
            } else {
                destination = root
            }
        }

        // 暂存目录放在源文件旁边（同一卷，合并时是 move 而非 copy）
        let staging = parent.appendingPathComponent(
            ".freearc-tmp-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 先打开读取器再创建目标目录：7z 加密头部在「列出条目」阶段就需要密码，
        // 若目标目录先建好、随后因密码失败重试，重算落点会跳到「test 2」，
        // 留下一个空目录（实测 bug）。密码问题在这一步暴露时目标尚未落盘。
        let reader: any ArchiveReading
        do {
            reader = try ArchiveEngine.open(
                url: ArchiveVolume.openURL(for: archive),
                password: password
            )
        } catch ArchiveEngineError.passwordRequired {
            throw FinderTaskError.passwordRequired
        }
        defer { reader.close() }

        let paths = reader.entries.filter { !$0.isDirectory }.map(\.path)
        guard !paths.isEmpty else {
            throw FinderTaskError.emptyArchive(archive.lastPathComponent)
        }

        do {
            try reader.extract(
                paths: paths,
                to: staging,
                password: password,
                stripCommonPrefix: false,
                progress: { p in
                    emit(.progress(
                        fraction: overallBase + p.fraction * overallSpan,
                        detail: p.currentName
                    ))
                }
            )
        } catch ArchiveEngineError.passwordRequired {
            throw FinderTaskError.passwordRequired
        }

        // 目标目录在解压成功后才创建：ZIP 虽能无密码列出条目，但解密条目在 extract
        // 阶段才抛密码错误——先建目录会留下空文件夹、重试再跳「test 2」（实测 bug）。
        // 可写预检（防线：宁可不动作，也不写到不该写的地方）
        guard fm.fileExists(atPath: destination.path) || (try? fm.createDirectory(
            at: destination, withIntermediateDirectories: true
        )) != nil else {
            throw FinderTaskError.destinationUnwritable(destination.path)
        }
        guard fm.isWritableFile(atPath: destination.path) else {
            throw FinderTaskError.destinationUnwritable(destination.path)
        }

        let moved = try mergeMove(contentsOf: staging, into: destination)
        guard moved > 0 else {
            throw FinderTaskError.extractionProducedNothing(archive.lastPathComponent)
        }
        markMacOSXHelpersHidden(in: destination)
        return ExtractOutcome(destination: destination, fileCount: moved)
    }

    /// macOS 辅助文件默认隐藏：Windows 侧工具打包的 zip 常带 `__MACOSX/` 目录
    /// （内部是 `._*` AppleDouble，点前缀天然隐藏），但目录名本身不以点开头，
    /// 系统解压工具会给它打隐藏标记，我们同样补上（与访达/归档实用工具一致）。
    private static func markMacOSXHelpersHidden(in directory: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []
        ) else { return }
        for item in items {
            let name = item.lastPathComponent
            guard name == "__MACOSX" || name == "_MACOSX" else { continue }
            try? (item as NSURL).setResourceValue(true, forKey: .isHiddenKey)
        }
    }

    // MARK: 压缩

    /// 压缩为包。`destination` 为 nil 时自动落在源文件旁（快速压缩）；
    /// 传入则由调用方指定（右键「压缩为…」的存储面板结果）。
    /// `password` 非 nil 时创建加密包（ZIP / 7Z 均支持加密）。
    public static func compress(
        items: [URL],
        deleteSource: Bool,
        destination: URL? = nil,
        password: String? = nil,
        format: CreationFormat = .zip
    ) {
        guard !items.isEmpty else { return }
        beginTask()
        queue.async {
            defer { endTask() }
            let first = items[0]
            let parent = first.deletingLastPathComponent()
            let baseName: String
            if items.count == 1 {
                let item = first
                baseName = item.hasDirectoryPath
                    ? item.lastPathComponent
                    : item.deletingPathExtension().lastPathComponent
            } else {
                baseName = parent.lastPathComponent.isEmpty ? "归档" : parent.lastPathComponent
            }
            let target = destination ?? uniqueFile(in: parent, preferred: baseName, ext: format.fileExtension)

            emit(.started(
                title: items.count == 1 ? "正在压缩" : "正在压缩 \(items.count) 项",
                subtitle: target.lastPathComponent,
                symbol: "archivebox"
            ))

            // 快速压缩：均衡档（level 5），保留 macOS 辅助文件（与访达压缩一致）
            let options = CreationOptions(
                level: 5, format: format.archiveFormat, password: password,
                preserveMetadata: true, threadLimit: ProcessorPreference.maximumCores
            )
            do {
                try runCancellable {
                    try SevenZipWriter.create(
                        items: items,
                        to: target,
                        options: options,
                        progress: { p in
                            emit(.progress(fraction: p.fraction, detail: target.lastPathComponent))
                        }
                    )
                }
            } catch ArchiveEngineError.cancelled {
                // 用户取消：删掉半成品（避免留下一个损坏的压缩包）
                try? FileManager.default.removeItem(at: target)
                appendLog("压缩已由用户取消，已清理半成品：\(target.lastPathComponent)")
                emit(.cancelled)
                return
            } catch {
                notify(
                    title: "FreeArc 压缩",
                    body: "压缩失败：\(error.localizedDescription)",
                    isError: true
                )
                emit(.finished(success: false, message: "压缩失败：\(error.localizedDescription)"))
                appendLog("压缩失败：\(error)")
                return
            }

            var trashed = 0
            if deleteSource {
                for item in items {
                    // 目录不删（危险且不必要）：只对普通文件执行，且走废纸篓
                    if trashSource(item, expectedFormat: nil) { trashed += 1 }
                }
            }

            var body = "已创建「\(target.lastPathComponent)」"
            if password != nil { body += "（已加密）" }
            if trashed > 0 { body += "；已移入废纸篓 \(trashed) 个源文件" }
            // 成功静默（不弹完成提示）
            appendLog("FreeArc 压缩：\(body)")
            emit(.finished(success: true, message: body))
        }
    }

    // MARK: 打开主程序

    /// 用 FreeArc 打开这些文件（浏览/加密包解压/创建工作台）。
    public static func openInMainApp(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // 主程序进程内（Services 通道）：直接走 App 自己的窗口路由，避免重复启动
        if let openHandler {
            DispatchQueue.main.async { openHandler(urls) }
            return
        }
        guard let appURL = hostAppURL() else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(
                urls,
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in }
        }
    }

    // MARK: 转发命令（扩展 → 主程序）

    /// 沙盒约束下扩展进程**不能**直接写任意目录、跑子进程或转交文件给别的应用，
    /// 所以扩展的菜单动作只负责组装 `freearc://` 命令，实际执行全部由
    /// 未沙盒的主程序完成（见 WindowRouting.handleFinderRequest）。
    public static func requestExtractToHere(archives: [URL], deleteSource: Bool) {
        requestExtract(archives: archives, mode: "here", deleteSource: deleteSource)
    }

    /// 「解压到源文件对应的文件夹」：目的地为各压缩包自身所在目录。
    public static func requestExtractToOwnFolder(archives: [URL], deleteSource: Bool) {
        requestExtract(archives: archives, mode: "own", deleteSource: deleteSource)
    }

    /// 「解压到指定文件夹…」：目录选择面板由主程序展示（扩展里弹面板不可靠）。
    public static func requestExtractToChosen(archives: [URL], deleteSource: Bool) {
        requestExtract(archives: archives, mode: "chosen", deleteSource: deleteSource)
    }

    private static func requestExtract(archives: [URL], mode: String, deleteSource: Bool) {
        guard !archives.isEmpty else { return }
        send(command: "extract", query: [
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "trash", value: deleteSource ? "1" : "0"),
            URLQueryItem(name: "paths", value: archives.map(\.path).joined(separator: "\n")),
        ], activates: false, background: true)
    }

    public static func requestCompress(items: [URL], deleteSource: Bool, format: String = "zip") {
        guard !items.isEmpty else { return }
        send(command: "compress", query: [
            URLQueryItem(name: "trash", value: deleteSource ? "1" : "0"),
            URLQueryItem(name: "format", value: format),
            URLQueryItem(name: "paths", value: items.map(\.path).joined(separator: "\n")),
        ], activates: false, background: true)
    }

    public static func requestBrowse(urls: [URL]) {
        guard !urls.isEmpty else { return }
        send(command: "browse", query: [
            URLQueryItem(name: "paths", value: urls.map(\.path).joined(separator: "\n"))
        ], activates: true)
    }

    /// 「压缩为…」「加密压缩为…」：存储面板与密码卡片都在主程序里展示，
    /// 选好位置后直接压缩，全程不进主窗口（轻量交互，不打断当前工作）。
    /// `format`：预设格式（zip / 7z），面板里仍可改扩展名。
    /// `passwordName`：密码本条目的名称（只传名称，密码由主程序从钥匙串解析）。
    public static func requestCompressTo(
        items: [URL], encrypt: Bool, format: String = "zip", passwordName: String? = nil
    ) {
        guard !items.isEmpty else { return }
        var query: [URLQueryItem] = [
            URLQueryItem(name: "encrypt", value: encrypt ? "1" : "0"),
            URLQueryItem(name: "format", value: format),
            URLQueryItem(name: "paths", value: items.map(\.path).joined(separator: "\n")),
        ]
        if let passwordName, !passwordName.isEmpty {
            query.append(URLQueryItem(name: "pwname", value: passwordName))
        }
        send(command: "compressto", query: query, activates: true)
    }

    /// 背景任务标记：主程序据此以「无 Dock 图标」形态启动，任务结束后自动退出，
    /// 用户感知上完全不出现主程序。
    public static let backgroundLaunchArgument = "-afz-background"

    private static func send(command: String, query: [URLQueryItem], activates: Bool, background: Bool = false) {
        var components = URLComponents()
        components.scheme = "freearc"
        components.host = command
        components.queryItems = query
        guard let url = components.url else { return }
        DispatchQueue.main.async {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = activates
            // arguments 只在「本次调用真正启动新进程」时生效；应用已在运行则被忽略
            if background { config.arguments = [backgroundLaunchArgument] }
            NSWorkspace.shared.open(url, configuration: config) { _, _ in }
        }
    }

    /// 让主程序打开「创建工作台」并预填这些文件（文件盒「放入工作区」用）。
    public static func openCreationWorkspace(with urls: [URL], encrypt: Bool = false) {
        guard !urls.isEmpty else { return }
        if let creationHandler {
            DispatchQueue.main.async { creationHandler(urls, encrypt) }
            return
        }
        var components = URLComponents()
        components.scheme = "freearc"
        components.host = "create"
        components.queryItems = [
            URLQueryItem(name: "paths", value: urls.map(\.path).joined(separator: "\n")),
            URLQueryItem(name: "encrypt", value: encrypt ? "1" : "0"),
        ]
        guard let url = components.url else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    /// 宿主 .app 路径（工具栏图标等 UI 用途）。
    public static var hostAppPath: String? { hostAppURL()?.path }

    /// 定位宿主 .app：
    /// - 扩展进程：…/FreeArc.app/Contents/PlugIns/FreeArcFinderSync.appex → 向上找到 .app
    /// - 主程序进程：Bundle.main 本身就是 .app，直接返回
    private static func hostAppURL() -> URL? {
        var url = Bundle.main.bundleURL
        if url.pathExtension == "app" { return url }
        for _ in 0..<4 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" { return url }
        }
        return nil
    }

    // MARK: 删除源文件（废纸篓，绝不直接 unlink）

    /// 只删普通文件，且校验格式仍一致；返回是否真的移动了。
    @discardableResult
    private static func trashSource(_ url: URL, expectedFormat: String?) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        // 符号链接一律不动（删链接会误导用户，删目标更是灾难）
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isSymbolicLink != true, values?.isRegularFile == true, values?.isDirectory != true else {
            appendLog("跳过删除（不是普通文件）：\(url.path)")
            return false
        }
        if let expectedFormat {
            guard FinderFormats.formatKey(for: url) == expectedFormat else {
                appendLog("跳过删除（格式已变化）：\(url.path)")
                return false
            }
        }
        do {
            try fm.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            appendLog("移入废纸篓失败：\(url.path) — \(error.localizedDescription)")
            return false
        }
    }

    // MARK: 落位工具

    /// 把暂存目录里的顶层项目并入目标目录；同名自动改名，绝不覆盖。
    @discardableResult
    private static func mergeMove(contentsOf source: URL, into destination: URL) throws -> Int {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        var moved = 0
        // 隐藏文件（如 .DS_Store）也一并搬，避免解压结果缺文件
        let hidden = try fm.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil, options: []
        ).filter { $0.lastPathComponent.hasPrefix(".") }
        for item in items + hidden {
            var target = destination.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                let ext = item.pathExtension
                let stem = item.deletingPathExtension().lastPathComponent
                var counter = 2
                repeat {
                    let name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
                    target = destination.appendingPathComponent(name)
                    counter += 1
                    if counter > 999 { throw FinderTaskError.nameConflict(item.lastPathComponent) }
                } while fm.fileExists(atPath: target.path)
            }
            try fm.moveItem(at: item, to: target)
            moved += 1
        }
        return moved
    }

    /// 取一个不冲突的目录名（「name」「name 2」…），不创建。
    private static func uniqueDirectory(in parent: URL, preferred: String) -> URL {
        let fm = FileManager.default
        let name = preferred.isEmpty ? "解压结果" : preferred
        var candidate = parent.appendingPathComponent(name, isDirectory: true)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(name) \(counter)", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    /// 取一个不冲突的文件名（「name.zip」「name 2.zip」…），不创建。
    private static func uniqueFile(in parent: URL, preferred: String, ext: String) -> URL {
        let fm = FileManager.default
        let name = preferred.isEmpty ? "归档" : preferred
        var candidate = parent.appendingPathComponent("\(name).\(ext)")
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(name) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    // MARK: 反馈

    /// 结果提示：日志 + 系统通知（扩展进程没有自己的 UI）。
    private static func notify(title: String, body: String, isError: Bool) {
        appendLog("\(title)：\(body)")
        DispatchQueue.main.async {
            let script = "display notification \(appleScriptLiteral(body)) with title \(appleScriptLiteral(title))"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            try? process.run()
            if isError { NSSound.beep() }
        }
    }

    private static func appleScriptLiteral(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    /// 扩展自己的日志（~/Library/Logs/FreeArc/finder-extension.log），便于排查。
    public static func appendLog(_ message: String) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FreeArc", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("finder-extension.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}

// MARK: - 错误

public enum FinderTaskError: LocalizedError {
    case passwordRequired
    case cancelled
    case destinationUnwritable(String)
    case emptyArchive(String)
    case extractionProducedNothing(String)
    case nameConflict(String)

    public var errorDescription: String? {
        switch self {
        case .passwordRequired:
            return "该压缩包已加密，需要密码"
        case .cancelled:
            return "操作已取消"
        case .destinationUnwritable(let path):
            return "目标文件夹不可写入：\(path)"
        case .emptyArchive(let name):
            return "「\(name)」里没有可解压的文件"
        case .extractionProducedNothing(let name):
            return "「\(name)」解压后没有产出任何文件"
        case .nameConflict(let name):
            return "「\(name)」同名文件过多，已中止"
        }
    }
}
