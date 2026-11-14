import Foundation
import ArchiveCore

/// DMG 磁盘映像引擎：只读挂载 → 建树浏览 → 卸载清理，全程不留残留，
/// 调用系统 /usr/bin/hdiutil 挂载后浏览：
/// - 挂载到隐藏临时目录（-mountpoint），访达中看不到挂载盘
/// - 挂载时默认先校验，解析进度回调；可请求跳过校验（kill 后以 -noverify 重挂）
/// - 卷内容构建虚拟条目树；符号链接保留（如 Applications → /Applications）
/// - close 时 detach 清理
public final class DmgArchiveReader: ArchiveReading {
    /// hdiutil attach 能挂载的磁盘映像族：DMG/稀疏映像 + ISO/CDR 光盘镜像
    /// （与访达双击一致：ISO 同样由 hdiutil 挂出 HFS/ISO 卷，而不是按原始结构罗列）。
    public static let supportedExtensions: Set<String> = ["dmg", "sparseimage", "sparsebundle", "iso", "cdr"]

    /// 磁盘映像内容嗅探结果（按文件头判定真实格式，扩展名可能不可信）。
    public enum DiscImageKind: Sendable, Equatable {
        /// UDIF（DMG 原生格式）：文件尾 512 字节是 "koly" 魔数。
        case udif
        /// 光盘镜像：ISO9660（0x8001 处 "CD001"）或 UDF（"BEA01"/"NSR02"/"NSR03"）。
        case optical
        /// 无法识别（可能是稀疏映像、加密 DMG 或任意文件）。
        case unknown
    }

    /// 按内容嗅探磁盘映像的真实格式。
    /// ISO9660 主卷描述符固定在扇区 16（0x8000 起，类型字段后 1 字节即标识符）；
    /// UDF 挂载点在此处为 BEA01/NSR02/NSR03；UDIF 尾部 512 字节以 koly 开头。
    public static func sniff(_ url: URL) -> DiscImageKind {
        let fm = FileManager.default
        guard let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64),
              size > 0x8008 else { return .unknown }
        // UDIF 尾部
        if let trailer = readRange(url, offset: size - 512, length: 4),
           trailer == Data("koly".utf8) {
            return .udif
        }
        // ISO9660 / UDF 标识符
        if let id = readRange(url, offset: 0x8001, length: 5) {
            switch String(decoding: id, as: UTF8.self) {
            case "CD001", "BEA01", "NSR02", "NSR03":
                return .optical
            default:
                break
            }
        }
        return .unknown
    }

    private static func readRange(_ url: URL, offset: Int64, length: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.read(upToCount: length), data.count == length else { return nil }
        return data
    }

    private let url: URL
    /// 本次会话涉及的挂载点（卷根目录）。
    private var mountPoints: [URL] = []
    /// 是否由本引擎 attach（false 表示映像原本就已挂载，不负责卸载）。
    private var attachedByUs = false
    private let _summary: ArchiveSummary
    private let _entries: [ArchiveEntry]
    private let fm = FileManager.default

    public static func canHandle(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { return false }
        // 磁盘映像精细分流（2026-11-09）：标准光盘镜像（ISO9660/UDF）交给 7zz 内核
        // 免挂载读取——hdiutil 对部分 ISO 报「无可装载的文件系统」（实测 Linux Mint 等
        // 混合镜像）；只有非光学内容（renamed DMG / 未知裸映像）才走 hdiutil 挂载。
        if ext == "iso" || ext == "cdr" {
            return sniff(url) != .optical
        }
        return true
    }

    /// 协议要求的默认打开方式（不回调校验进度）。
    public convenience init(url: URL) throws {
        try self.init(url: url, verifyProgress: nil, skipRequested: nil, skipVerify: false)
    }

    /// 校验进度回调；skipRequested 返回 true 时中止校验并直接挂载。
    public convenience init(
        url: URL,
        verifyProgress: (@Sendable (Double) -> Void)?,
        skipRequested: (@Sendable () -> Bool)?
    ) throws {
        try self.init(url: url, verifyProgress: verifyProgress, skipRequested: skipRequested, skipVerify: false)
    }

    private init(
        url: URL,
        verifyProgress: (@Sendable (Double) -> Void)?,
        skipRequested: (@Sendable () -> Bool)?,
        skipVerify: Bool
    ) throws {
        guard fm.fileExists(atPath: url.path) else {
            throw ArchiveEngineError.unreadable("文件不存在")
        }
        self.url = url

        // 挂载到隐藏临时目录：访达不可见；挂载点目录需预先创建且为空。
        // 前缀统一 afz-（高级设置「清理临时文件」按此前缀统计与清理）
        let mountpoint = fm.temporaryDirectory
            .appendingPathComponent("afz-dmg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: mountpoint, withIntermediateDirectories: true)

        var arguments = [
            "attach", url.path,
            "-readonly", "-nobrowse", "-noautoopen",
            "-mountpoint", mountpoint.path,
        ]
        if skipVerify {
            arguments.append("-noverify")
        }

        // 校验进度：hdiutil 校验阶段不输出百分比（只有逐分区 CRC 行），
        // 按校验速率（约 120MB/s）估算进度，上限 95%（"正在校验"体验）。
        let totalBytes = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        let estimatedSeconds = max(3.0, Double(totalBytes) / 120_000_000.0)
        let verifyStart = Date()
        var progressTimer: DispatchSourceTimer?
        if let verifyProgress {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
            timer.setEventHandler {
                verifyProgress(min(0.95, Date().timeIntervalSince(verifyStart) / estimatedSeconds))
            }
            timer.resume()
            progressTimer = timer
        }

        let attach = Self.runHDIUtilStreaming(arguments, abortCheck: skipRequested) { line in
            return true
        }
        progressTimer?.cancel()
        if attach.status == 0 {
            attachedByUs = true
            mountPoints = [mountpoint]
            Self.registerMount(image: url.standardizedFileURL.path, mountpoint: mountpoint.path)
            verifyProgress?(1.0)
        } else {
            let skippedByUser = skipRequested?() ?? false
            // 已挂载等场景：从 hdiutil info 找该映像现有挂载点复用。
            if !skippedByUser, let existing = Self.existingMountPoints(for: url), !existing.isEmpty {
                mountPoints = existing
            } else {
                try? fm.removeItem(at: mountpoint)
                let stderr = attach.stderr
                if stderr.contains("encrypted") || stderr.contains("authentication") {
                    throw ArchiveEngineError.passwordRequired
                }
                if skippedByUser {
                    // 跳过校验请求后重挂一次（不带校验）
                    let retry = Self.runHDIUtilStreaming(arguments + ["-noverify"], abortCheck: nil) { _ in true }
                    if retry.status == 0 {
                        attachedByUs = true
                        mountPoints = [mountpoint]
                        Self.registerMount(image: url.standardizedFileURL.path, mountpoint: mountpoint.path)
                    } else {
                        throw ArchiveEngineError.unreadable("无法挂载磁盘映像：\(retry.stderr.prefix(200))")
                    }
                } else {
                    throw ArchiveEngineError.unreadable("无法挂载磁盘映像：\(stderr.prefix(200))")
                }
            }
        }

        // 扫描卷内容构建条目树。单卷直接以卷内容为根；多卷以卷名为顶层目录。
        var entries: [ArchiveEntry] = []
        var fileCount = 0
        var folderCount = 0
        var totalUncompressed: Int64 = 0
        let prefixVolumes = mountPoints.count > 1

        for volume in mountPoints {
            let volumeName = volume.lastPathComponent
            // 统一标准化路径（/var → /private/var 等符号链接前缀必须一致，否则截取错位）
            let rootPath = volume.standardizedFileURL.path
            let enumerator = fm.enumerator(
                at: volume,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey,
                ],
                options: []
            )
            while let raw = enumerator?.nextObject() {
                guard let itemURL = raw as? URL else { continue }
                let values = try? itemURL.resourceValues(forKeys: [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey,
                ])
                let isSymlink = values?.isSymbolicLink ?? false
                let isDir = values?.isDirectory ?? false
                let relative = String(itemURL.standardizedFileURL.path.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let entryPath = prefixVolumes ? "\(volumeName)/\(relative)" : relative
                guard !entryPath.isEmpty else { continue }
                if isSymlink {
                    let target = try? fm.destinationOfSymbolicLink(atPath: itemURL.path)
                    entries.append(ArchiveEntry(
                        path: entryPath, size: 0,
                        modificationDate: values?.contentModificationDate,
                        isSymbolicLink: true, linkTarget: target
                    ))
                    fileCount += 1
                } else if isDir {
                    entries.append(ArchiveEntry(
                        path: entryPath, isDirectory: true,
                        modificationDate: values?.contentModificationDate
                    ))
                    folderCount += 1
                } else {
                    let size = Int64(values?.fileSize ?? 0)
                    entries.append(ArchiveEntry(
                        path: entryPath, size: size, compressedSize: size,
                        modificationDate: values?.contentModificationDate
                    ))
                    fileCount += 1
                    totalUncompressed += size
                }
            }
        }

        _entries = entries
        // 格式标签按扩展名区分（ISO 显示"ISO 磁盘映像"而非 DMG）
        let isOpticalDisc = ["iso", "cdr"].contains(url.pathExtension.lowercased())
        _summary = ArchiveSummary(
            url: url,
            format: isOpticalDisc ? .iso : .dmg,
            fileCount: fileCount,
            folderCount: folderCount,
            totalUncompressed: totalUncompressed,
            totalCompressed: ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0,
            hasEncryptedEntries: false,
            modificationDate: ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
        )
    }

    /// 打开时是否走过校验（供 UI 判断；校验本身在 init 内完成）。
    public var didVerify: Bool { true }

    public var summary: ArchiveSummary { _summary }
    public var entries: [ArchiveEntry] { _entries }

    /// 多卷时条目路径带卷名前缀；解析回真实文件系统 URL。
    private func resolve(path: String) -> URL? {
        func exists(_ candidate: URL) -> URL? {
            fm.fileExists(atPath: candidate.path) ? candidate : nil
        }
        if mountPoints.count > 1 {
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let volume = mountPoints.first { $0.lastPathComponent == parts[0] }
            return volume.map { exists($0.appendingPathComponent(parts[1])) } ?? nil
        }
        guard let root = mountPoints.first else { return nil }
        return exists(root.appendingPathComponent(path))
    }

    public func extract(
        paths: [String],
        to destination: URL,
        password: String?,
        stripCommonPrefix: Bool,
        progress: (@Sendable (ExtractionProgress) -> Void)?
    ) throws {
        let dirPaths = Set(_entries.filter(\.isDirectory).map(\.path))
        var fileSet = Set<String>()
        for path in paths {
            if dirPaths.contains(path) {
                fileSet.formUnion(_entries.filter { !$0.isDirectory && $0.path.hasPrefix(path + "/") }.map(\.path))
            } else {
                fileSet.insert(path)
            }
        }
        let selectedFiles = _entries.filter { !$0.isDirectory && fileSet.contains($0.path) }
        guard !selectedFiles.isEmpty else { return }

        let totalBytes = max(selectedFiles.reduce(Int64(0)) { $0 + $1.size }, 1)
        let prefix = stripCommonPrefix ? ZipArchiveReader.longestCommonDirectoryPrefix(of: selectedFiles.map(\.path)) : ""

        var completedBytes: Int64 = 0
        var completedCount = 0
        for entry in selectedFiles {
            try Task.checkCancellation()
            var relative = entry.path
            if !prefix.isEmpty, relative.hasPrefix(prefix + "/") {
                relative = String(relative.dropFirst(prefix.count + 1))
            }
            let destinationURL = destination.appendingPathComponent(relative)
            // 目录穿越防护：条目名理论上可能携带 ../（纵深防御），确保落点仍在目标目录内
            let stdDest = destinationURL.standardizedFileURL.path
            let stdRoot = destination.standardizedFileURL.path
            guard stdDest == stdRoot || stdDest.hasPrefix(stdRoot + "/") else {
                throw ArchiveEngineError.extractionFailed("条目路径非法：\(entry.path)")
            }
            try? fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            // 【安全修复 2026-11-06】目标已存在时绝不删除覆盖（用户文件可能同名），
            // 与 ZIP/7Z 引擎语义一致：改用唯一名（追加序号）落盘。
            var targetURL = destinationURL
            if fm.fileExists(atPath: targetURL.path) {
                targetURL = ZipArchiveReader.uniquedURL(for: targetURL, in: targetURL.deletingLastPathComponent())
            }

            if entry.isSymbolicLink {
                // 链接保持链接语义（绝不解引用拷贝，避免把 /Applications 整个拷出）
                try fm.createSymbolicLink(atPath: targetURL.path, withDestinationPath: entry.linkTarget ?? entry.path)
            } else {
                guard let sourceURL = resolve(path: entry.path) else {
                    completedBytes += entry.size
                    continue
                }
                try fm.copyItem(at: sourceURL, to: targetURL)
                if let modified = entry.modificationDate {
                    try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: targetURL.path)
                }
            }
            completedBytes += entry.size
            completedCount += 1
            progress?(ExtractionProgress(
                fraction: min(1.0, Double(completedBytes) / Double(totalBytes)),
                completed: completedCount,
                total: selectedFiles.count,
                currentName: entry.name
            ))
        }
    }

    public func previewFile(path: String, cacheDirectory: URL) throws -> URL? {
        let entry = _entries.first { $0.path == path }
        if entry?.isSymbolicLink == true { return nil } // 链接不提供内容预览
        guard let sourceURL = resolve(path: path) else { return nil }
        let target = cacheDirectory.appendingPathComponent((path as NSString).lastPathComponent)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: sourceURL, to: target)
        return target
    }

    /// 挂载类引擎：返回条目在挂载卷上的真实路径（应用图标、缩略图等用）。
    public func fileURL(for path: String) -> URL? {
        resolve(path: path)
    }

    public func previewData(path: String, maxBytes: Int) throws -> Data? {
        if _entries.first(where: { $0.path == path })?.isSymbolicLink == true { return nil }
        guard let sourceURL = resolve(path: path) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: sourceURL) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    public func close() {
        guard attachedByUs, !mountPoints.isEmpty else { return }
        for mount in mountPoints {
            _ = Self.runHDIUtil(["detach", mount.path])
            // 忙时强制卸载兜底
            if fm.fileExists(atPath: mount.path) {
                _ = Self.runHDIUtil(["detach", "-force", mount.path])
            }
            try? fm.removeItem(at: mount)
            Self.unregisterMount(image: url.standardizedFileURL.path, mountpoint: mount.path)
        }
        mountPoints = []
    }

    // MARK: - 挂载注册表（崩溃 / 强杀后的残留挂载兜底）

    private struct MountRecord: Codable {
        let image: String
        let mountpoint: String
        let pid: Int
    }

    /// 登记文件：应用支持目录下。挂载成功写入、卸载成功移除；
    /// 启动时按此清理「登记过但还挂着」的残留，绝不触碰用户自己挂载的映像。
    private static let registryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FreeArc/dmg-mounts.json")
    }()

    private static let registryLock = NSLock()

    static func registerMount(image: String, mountpoint: String) {
        registryLock.lock()
        defer { registryLock.unlock() }
        var records = (try? readRegistry()) ?? []
        records.append(MountRecord(image: image, mountpoint: mountpoint, pid: Int(ProcessInfo.processInfo.processIdentifier)))
        writeRegistry(records)
    }

    static func unregisterMount(image: String, mountpoint: String) {
        registryLock.lock()
        defer { registryLock.unlock() }
        var records = (try? readRegistry()) ?? []
        records.removeAll { $0.image == image && $0.mountpoint == mountpoint }
        writeRegistry(records)
    }

    /// 启动时清理：卸载登记过但进程已不存在的挂载（崩溃 / 强杀残留）。
    /// 只处理本应用登记过的挂载点；同 PID 的记录留给 close() 正常注销。
    public static func cleanupRecordedMounts() {
        registryLock.lock()
        defer { registryLock.unlock() }
        guard var records = try? readRegistry(), !records.isEmpty else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        var remaining = records
        for record in records where record.pid != currentPID {
            let fm = FileManager.default
            // 只信登记的挂载点路径：存在才尝试卸载（其他进程占着也由 -force 兜底）
            if fm.fileExists(atPath: record.mountpoint) {
                _ = runHDIUtil(["detach", record.mountpoint])
                if fm.fileExists(atPath: record.mountpoint) {
                    _ = runHDIUtil(["detach", "-force", record.mountpoint])
                }
                try? fm.removeItem(atPath: record.mountpoint)
                remaining.removeAll { $0.mountpoint == record.mountpoint }
            } else {
                remaining.removeAll { $0.mountpoint == record.mountpoint }
            }
        }
        records = remaining
        writeRegistry(records)
    }

    private static func readRegistry() throws -> [MountRecord] {
        guard let data = try? Data(contentsOf: registryURL) else { return [] }
        return (try? JSONDecoder().decode([MountRecord].self, from: data)) ?? []
    }

    private static func writeRegistry(_ records: [MountRecord]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    // MARK: - hdiutil 工具

    @discardableResult
    static func runHDIUtil(_ arguments: [String]) -> (status: Int32, stderr: String) {
        runHDIUtilStreaming(arguments) { _ in true }
    }

    /// 流式执行 hdiutil：逐行回传 stdout；abortCheck 由独立监控线程轮询（返回 true 终止进程）。
    static func runHDIUtilStreaming(
        _ arguments: [String],
        abortCheck: (@Sendable () -> Bool)? = nil,
        onLine: @Sendable (String) -> Bool
    ) -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }

        // 独立监控线程轮询外部中止请求（校验期间 stdout 无输出，读取循环收不到轮询机会）
        var monitor: DispatchSourceTimer?
        if let abortCheck {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 0.15, repeating: 0.15)
            timer.setEventHandler {
                if abortCheck() && process.isRunning {
                    process.terminate()
                }
            }
            timer.resume()
            monitor = timer
        }

        var aborted = false
        let handle = stdoutPipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let sep = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = buffer[buffer.startIndex..<sep]
                buffer.removeSubrange(buffer.startIndex...sep)
                let line = String(decoding: lineData, as: UTF8.self)
                if !onLine(line) {
                    aborted = true
                    process.terminate()
                    break
                }
            }
            if aborted { break }
        }
        monitor?.cancel()
        let stderr = String(decoding: (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        process.waitUntilExit()
        return (aborted ? -2 : process.terminationStatus, stderr)
    }

    /// 查询 hdiutil info：返回该映像当前已挂载的卷根（用于"映像已在挂载状态"的场景）。
    static func existingMountPoints(for image: URL) -> [URL]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        let resolved = image.standardizedFileURL.path
        var currentImagePath: String?
        var mounts: [URL] = []
        var found = false
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("image-path") {
                currentImagePath = trimmed.components(separatedBy: ":").dropFirst()
                    .joined(separator: ":").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("/dev/"), let image = currentImagePath {
                // 设备行形如 "/dev/disk10s1\tUUID\t/Volumes/卷名"，最后一段为挂载点
                let columns = line.components(separatedBy: "\t").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
                if let mount = columns.last, mount.hasPrefix("/"), image == resolved {
                    mounts.append(URL(fileURLWithPath: mount))
                    found = true
                }
            }
        }
        return found ? mounts : nil
    }
}

// 引擎实例跨任务传递：内部 mountPoints 仅在 init/close 修改，后台解压只读扫描结果。
extension DmgArchiveReader: @unchecked Sendable {}
