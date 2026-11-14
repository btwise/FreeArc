import Foundation
import ArchiveCore

/// 基于 7-Zip 官方静态内核（Vendor/7zz/7zz，LGPL + unRAR 限制，见 Vendor/7zz/License.txt）的通用读取引擎。
/// 覆盖 ZIP 之外的市面主流格式：7z / RAR / tar 系 / gz / bz2 / xz / zst / Cab / Cpio /
/// ISO / WIM / HFS / APFS / LZH / ARJ / deb / rpm / msi 等。
/// DMG 不走此引擎（由 DmgArchiveReader 调系统 hdiutil 挂载）。
public struct SevenZipReader: ArchiveReading {
    public static let supportedExtensions: Set<String> = [
        "7z", "rar", "r00",
        "tar", "gz", "bz2", "xz", "zst", "lz4", "tgz", "tbz2", "txz",
        "cab", "cpio", "iso", "cdr", "wim", "swm", "hfs", "hfsx", "apfs",
        "lzh", "arj", "deb", "rpm", "msi",
    ]

    private let url: URL
    /// 打开时使用的密码：预览（单条目解密）时复用，否则加密包预览会失败。
    private let openPassword: String?
    private let _summary: ArchiveSummary
    private let _entries: [ArchiveEntry]

    public static func canHandle(url: URL) -> Bool {
        // 分卷（x.7z.001 等）按真实扩展名判定；7zz 内核直接读首卷即可自动聚合后续卷
        let ext = ArchiveVolume.formatExtension(for: url) ?? url.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    /// 带密码打开（7z 加密头部场景）。
    public static func open(url: URL, password: String?) throws -> any ArchiveReading {
        try SevenZipReader(url: url, password: password)
    }

    // MARK: - 内核定位与进程执行

    /// 内核查找顺序：App bundle Resources → 开发目录 Vendor → 常见安装位置。
    static func locateBinary() -> URL? {
        let fm = FileManager.default
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("7zz")
            if fm.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let devPath = cwd.appendingPathComponent("Vendor/7zz/7zz")
        if fm.isExecutableFile(atPath: devPath.path) { return devPath }
        for candidate in ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz", "/usr/bin/7zz"]
        where fm.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// 全局 7zz 并发闸。
    ///
    /// 主窗口、文件盒、Finder 右键扩展、拖拽解压可能同时拉起多个 7zz 进程，
    /// 每个都会按 -mmt 把核心吃满；两三个一起跑就会明显拖慢前台操作。
    /// 这里限制同时运行的解压进程数（2 个），其余排队——用户感知是「多任务时
    /// 单个任务慢一点」，而不是整机卡顿。
    private static let processSlots = DispatchSemaphore(value: 2)

    /// 同步执行 7zz；onStdoutLine 逐行回传（\r 分隔的进度输出按行拆分），返回 false 可中止（用于取消）。
    @discardableResult
    private static func run(
        _ arguments: [String],
        onStdoutLine: ((String) -> Bool)? = nil
    ) -> (status: Int32, stderr: String) {
        // 排队时也响应取消：否则用户在长队列里点「取消」要等前面的任务跑完才生效
        while processSlots.wait(timeout: .now() + 0.1) == .timedOut {
            if Task.isCancelled { return (-2, "已取消") }
        }
        defer { processSlots.signal() }

        guard let binary = locateBinary() else { return (-1, "未找到 7zz 内核") }
        let process = Process()
        process.executableURL = binary
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

        var cancelled = false
        if let onStdoutLine {
            let handle = stdoutPipe.fileHandleForReading
            var buffer = Data()
            while true {
                if Task.isCancelled {
                    cancelled = true
                    process.terminate()
                    break
                }
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                // \r、\n 与 \b 都视为行分隔（7zz 进度用 \b 原地刷新同一行，不拆则始终收不到中间值）
                while let sep = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D || $0 == 0x08 }) {
                    let lineData = buffer[buffer.startIndex..<sep]
                    buffer.removeSubrange(buffer.startIndex...sep)
                    let line = String(decoding: lineData, as: UTF8.self)
                    if !onStdoutLine(line) {
                        cancelled = true
                        process.terminate()
                        break
                    }
                }
                if cancelled { break }
            }
        } else {
            _ = try? stdoutPipe.fileHandleForReading.readToEnd()
        }
        let stderr = String(decoding: (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        if !cancelled { process.waitUntilExit() }
        return (cancelled ? -2 : process.terminationStatus, stderr)
    }

    // MARK: - 打开（条目清单）

    public init(url: URL) throws {
        try self.init(url: url, password: nil)
    }

    /// 带密码打开：7z 加密头部（-mhe=on）在列出条目阶段就需要密码。
    public init(url: URL, password: String?) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw ArchiveEngineError.unreadable("文件不存在")
        }
        guard Self.locateBinary() != nil else {
            throw ArchiveEngineError.unreadable("未找到 7zz 解压内核")
        }
        self.url = url
        self.openPassword = (password?.isEmpty == false) ? password : nil

        var arguments = ["l", "-slt", "-y"]
        if let password, !password.isEmpty {
            arguments.append("-p\(password)")
        }
        arguments.append(url.path)

        var lines: [String] = []
        var sawPasswordPrompt = false
        let result = Self.run(arguments) { line in
            // 无密码列加密头部：7zz 在 stdout 打印 "Enter password:" 后因 stdin 关闭中止
            if line.contains("Enter password") { sawPasswordPrompt = true }
            lines.append(line)
            return true
        }
        if result.status != 0 {
            let combined = result.stderr + "\n" + lines.joined(separator: "\n")
            NSLog("[SevenZipReader] l status=\(result.status) pw=\(password != nil ? "有(\(password!.count)字)" : "无") stderr=\(result.stderr.prefix(300))")
            if sawPasswordPrompt
                || combined.contains("Wrong password")
                || combined.contains("Enter password")
                || combined.contains("Break signaled") {
                throw ArchiveEngineError.passwordRequired
            }
            throw ArchiveEngineError.unreadable("不是有效的压缩包（7zz: \(result.stderr.prefix(200)))")
        }

        // 空行分块；`----------` 是归档级块与条目块的分隔线，同样作为切分点
        var blocks: [[String]] = []
        var current: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isDashes = trimmed.count >= 3 && trimmed.allSatisfy { $0 == "-" }
            if trimmed.isEmpty || isDashes {
                if !current.isEmpty { blocks.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current) }
        // 首块（含 `Type = `）是归档级元数据：备注在此，条目块从其后开始
        // （无 -ba 时前面还有 "7-Zip (z) ..." / "Listing archive: ..." 等前言块，一并丢弃）
        var archiveComment: String?
        if let infoIndex = blocks.firstIndex(where: { block in
            block.contains { $0.hasPrefix("Type = ") }
        }) {
            archiveComment = Self.parseArchiveComment(from: blocks[infoIndex])
            blocks.removeFirst(infoIndex + 1)
        }
        _entries = Self.parseListingBlocks(blocks)

        let files = _entries.filter { !$0.isDirectory }
        let ext = ArchiveVolume.formatExtension(for: url) ?? url.pathExtension.lowercased()
        let format: ArchiveFormat
        switch ext {
        case "7z": format = .sevenZip
        case "rar", "r00": format = .rar
        case "tar", "gz", "bz2", "xz", "zst", "lz4", "tgz", "tbz2", "txz": format = .tar
        default: format = ArchiveFormat(ext.uppercased())
        }
        _summary = ArchiveSummary(
            url: url,
            format: format,
            fileCount: files.count,
            folderCount: _entries.count - files.count,
            totalUncompressed: files.reduce(Int64(0)) { $0 + $1.size },
            totalCompressed: files.reduce(Int64(0)) { $0 + $1.compressedSize },
            hasEncryptedEntries: _entries.contains(where: \.isEncrypted),
            modificationDate: ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date),
            comment: archiveComment
        )
    }

    /// 解析 `7zz l -ba -slt` 的输出块（空行分隔），产出条目。
    static func parseListingBlocks(_ blocks: [[String]]) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var seen = Set<String>()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        for block in blocks {
            var path: String?
            var size: Int64 = 0
            var isDirectory = false
            var isEncrypted = false
            var modified: Date?
            for line in block {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                switch key {
                case "Path":
                    path = value
                case "Size":
                    size = Int64(value) ?? 0
                case "Folder":
                    isDirectory = (value == "+")
                case "Attributes" where !isDirectory:
                    isDirectory = value.hasPrefix("D") || value.contains("drw")
                case "Encrypted":
                    isEncrypted = (value == "+")
                case "Modified":
                    modified = dateFormatter.date(from: value)
                default:
                    break
                }
            }
            guard var entryPath = path, !entryPath.isEmpty else { continue }
            // 统一路径分隔与 "./" 前缀
            entryPath = entryPath.replacingOccurrences(of: "\\", with: "/")
            while entryPath.hasPrefix("./") { entryPath = String(entryPath.dropFirst(2)) }
            entryPath = entryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !entryPath.isEmpty, !seen.contains(entryPath) else { continue }
            seen.insert(entryPath)
            if isDirectory {
                entries.append(ArchiveEntry(path: entryPath, isDirectory: true, size: 0, compressedSize: 0, modificationDate: modified, isEncrypted: isEncrypted))
            } else {
                entries.append(ArchiveEntry(path: entryPath, isDirectory: false, size: size, compressedSize: size, modificationDate: modified, isEncrypted: isEncrypted))
            }
        }
        return entries
    }

    /// 从归档级块中取 `Comment = ...`（RAR/7z 的整包注释；WinRAR 的「备注」就在这里）。
    /// 注释可能多行——续行直到遇到下一个 `Key = value` 形式的键。
    static func parseArchiveComment(from block: [String]) -> String? {
        var collected: [String] = []
        var collecting = false
        for line in block {
            if collecting {
                // 形如 "Size = 123" 的键值行代表注释结束
                if let matched = line.range(of: "^[A-Za-z][A-Za-z0-9 ]* =", options: .regularExpression),
                   matched.lowerBound == line.startIndex {
                    break
                }
                collected.append(line)
                continue
            }
            if line.hasPrefix("Comment = ") {
                collecting = true
                collected.append(String(line.dropFirst("Comment = ".count)))
            }
        }
        let text = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - 协议实现

    public var summary: ArchiveSummary { _summary }
    public var entries: [ArchiveEntry] { _entries }

    public func extract(
        paths: [String],
        to destination: URL,
        password: String?,
        stripCommonPrefix: Bool,
        progress: (@Sendable (ExtractionProgress) -> Void)?
    ) throws {
        let fm = FileManager.default
        // 目录条目自动展开为其中的文件（与 ZIP 引擎语义一致）
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

        // 与 ZIP 引擎一致：目标盘隐藏暂存目录，成功后按唯一名移出。
        let staging = destination.appendingPathComponent(".arcfrezip-staging-\(UUID().uuidString)")
        let workDir = staging.appendingPathComponent("payload")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        func cleanupStaging() {
            try? fm.removeItem(at: staging)
        }

        // 条目太多时用 listfile，避免超出命令行长度限制；单条目直接传参。
        var arguments = ["x", url.path, "-o\(workDir.path)", "-y", "-spd", "-ba", "-bso0", "-bsp1"]
        if let password, !password.isEmpty {
            arguments.append("-p\(password)")
        }
        let listFileURL = staging.appendingPathComponent("list.txt")
        if selectedFiles.count == _entries.filter({ !$0.isDirectory }).count {
            // 全量解压：不传条目列表
        } else if selectedFiles.count > 64 {
            let listing = selectedFiles.map(\.path).joined(separator: "\n")
            try listing.write(to: listFileURL, atomically: true, encoding: .utf8)
            arguments.append("@\(listFileURL.path)")
        } else {
            arguments.append(contentsOf: selectedFiles.map(\.path))
        }

        let total = selectedFiles.count
        var lastFraction: Double = 0
        _ = lastFraction

        let result = Self.run(arguments) { line in
            // 进度行形如 " 42% 12 + name"；只取百分比做字节级进度。
            if let range = line.range(of: #"\s*(\d{1,3})%"#, options: .regularExpression) {
                let digits = line[range].filter(\.isNumber)
                if let pct = Int(digits), pct <= 100 {
                    lastFraction = Double(pct) / 100.0
                    progress?(ExtractionProgress(fraction: lastFraction, completed: 0, total: total, currentName: nil))
                }
            }
            return true
        }
        try? fm.removeItem(at: listFileURL)

        if result.status == -2 || Task.isCancelled {
            cleanupStaging()
            throw ArchiveEngineError.cancelled
        }
        if result.status != 0 {
            cleanupStaging()
            let stderr = result.stderr
            if stderr.contains("Wrong password")
                || stderr.contains("Enter password")
                || stderr.contains("Break signaled") {
                throw ArchiveEngineError.passwordRequired
            }
            throw ArchiveEngineError.extractionFailed(String(stderr.suffix(300)))
        }

        do {
            // stripCommonPrefix："解压所选"时剥掉公共父目录，选了什么就得到什么。
            if stripCommonPrefix {
                let prefix = ZipArchiveReader.longestCommonDirectoryPrefix(of: selectedFiles.map(\.path))
                let root = prefix.isEmpty ? workDir : workDir.appendingPathComponent(prefix)
                let items = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                var allocator = UniqueNameAllocator()
                for item in items {
                    try fm.moveItem(at: item, to: allocator.allocate(for: item.lastPathComponent, in: destination))
                }
            } else {
                let items = try fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
                var allocator = UniqueNameAllocator()
                for item in items {
                    try fm.moveItem(at: item, to: allocator.allocate(for: item.lastPathComponent, in: destination))
                }
            }
            try fm.removeItem(at: staging)
            progress?(ExtractionProgress(fraction: 1.0, completed: total, total: total, currentName: nil))
        } catch is CancellationError {
            cleanupStaging()
            throw ArchiveEngineError.cancelled
        } catch let error as ArchiveEngineError {
            cleanupStaging()
            throw error
        } catch {
            cleanupStaging()
            throw ArchiveEngineError.extractionFailed(error.localizedDescription)
        }
    }

    /// 校验密码（7zz t 完整性测试：密码错误时 exit 2 + "Wrong password"）。
    public func verifyPassword(_ password: String) -> Bool {
        guard !password.isEmpty else { return false }
        let result = Self.run(["t", "-y", "-p\(password)", url.path])
        return result.status == 0 && !result.stderr.contains("Wrong password")
    }

    /// 单条目解压到指定目录（预览用）。加密包需带上打开时的密码。
    public func previewFile(path: String, cacheDirectory: URL) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        var args = ["x", url.path, "-o\(cacheDirectory.path)", "-y", "-spd", "-ba", "-bso0"]
        if let openPassword { args.append("-p\(openPassword)") }
        args.append(path)
        let result = Self.run(args)
        guard result.status == 0 else { return nil }
        let candidate = cacheDirectory.appendingPathComponent(path)
        guard fm.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    public func previewData(path: String, maxBytes: Int) throws -> Data? {
        guard let binary = Self.locateBinary() else { return nil }
        let process = Process()
        process.executableURL = binary
        var args = ["x", url.path, "-so", "-y", "-spd", "-ba", "-bso0", "-bsp0"]
        if let openPassword { args.append("-p\(openPassword)") }
        args.append(path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readData(ofLength: maxBytes + 1)
        process.terminate()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || !data.isEmpty else { return nil }
        return data.count > maxBytes ? data.prefix(maxBytes) : data
    }
}

// 引擎实例为只读使用，跨任务传递安全。
extension SevenZipReader: @unchecked Sendable {}
