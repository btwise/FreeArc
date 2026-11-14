import Foundation
import ZIPFoundation
import ArchiveCore

/// ZIP 条目路径解码策略。
/// 规范：bit 11（UTF-8 标志）置位时按 UTF-8 解码；未置位时的现实情况：
/// - macOS ditto/Finder、现代工具：UTF-8 但不置位标志；
/// - Windows 中文环境（Bandizip/好压/旧 WinRAR）：GBK/GB18030 编码。
/// 因此采用启发式：合法 UTF-8 优先，否则尝试 GB18030（覆盖中文 Windows），
/// 最后回退 cp437 兜底。
public enum ZipPathDecoding {
    public static let cp437: String.Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x400))
    )
    public static let gb18030: String.Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    static func decode(nameData: Data, utf8Flag: Bool) -> String {
        if let utf8 = String(data: nameData, encoding: .utf8) {
            return utf8
        }
        // GBK 兜底必须带「像不像 GBK」的前置判断：
        // 早期实现只要 UTF-8 失败就无脑 GB18030，会把西欧/CP437 包里的
        // 间隔号 ·(0xFA)、微符号 µ(0xE6)、重音字母 é(0x82) 当成双字节汉字，
        // 解出「±ê」「μ-」这类乱码。判定规则见 looksLikeGBK。
        if looksLikeGBK(nameData),
           let gbk = String(data: nameData, encoding: gb18030),
           !gbk.isEmpty {
            return gbk
        }
        // 单字节高位字节的包（西欧 / DOS）：CP437 是 ZIP 规范默认，优先；
        // 但若解出画线框字符（CP437 特有的 ░▒▓┤╡ 等），说明原意多半是
        // Windows-1252 的标点与重音字母，改用 1252 更贴近真实文件名。
        if let cp = String(data: nameData, encoding: cp437), !cp.isEmpty {
            // CP437 独有的制表符（┌┤╡）与方块（░▒▓）落在 U+2500–U+259F
            if cp.unicodeScalars.contains(where: { (0x2500...0x259F).contains($0.value) }),
               let win = String(data: nameData, encoding: .windowsCP1252), !win.isEmpty {
                return win
            }
            return cp
        }
        return String(decoding: nameData, as: UTF8.self)
    }

    /// 判断原始字节流是否具有 GBK/GB18030 双字节结构。
    ///
    /// 规则（保守，宁可回退单字节编码也不乱码）：
    /// 1. 所有高位字节必须成对出现，且尾字节落在 GBK 合法区间（0x40…0xFE，排除 0x7F）；
    /// 2. 首字节只接受 0xA1…0xF9——这是 GBK 汉字与全角符号的实际分布区：
    ///    · 0x81…0xA0 是 CP437/Latin1 的重音字母区（ü é â ä à å ç …）；
    ///    · 0xFA…0xFE 是 GBK 用户定义区，真实文件名不会用，却恰好是 CP437 的
    ///      间隔号 ·(0xFA)、微符号 µ(0xE6) 与西文字母——放过它们就会解出「鷷」这类生僻字。
    private static func looksLikeGBK(_ data: Data) -> Bool {
        var index = 0
        var sawHighByte = false
        let bytes = [UInt8](data)
        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x80 {
                index += 1
                continue
            }
            sawHighByte = true
            guard (0xA1...0xF9).contains(byte) else { return false }
            guard index + 1 < bytes.count else { return false }
            let trail = bytes[index + 1]
            guard (0x40...0xFE).contains(trail), trail != 0x7F else { return false }
            index += 2
        }
        return sawHighByte
    }

    /// 由原始字节数据解码显示路径（统一规则，与加密扫描一致）。
    static func displayName(rawNameData: Data) -> String {
        decode(nameData: rawNameData, utf8Flag: false)
    }
}

/// 基于 ZIP Foundation 的 ZIP 引擎实现（M1）。
/// 支持：浏览、选择性解压、暂存区写入（失败/取消自动清理）。
/// 加密 ZIP 在 M1 仅可识别与提示，解密能力由 M3 的 7-Zip 内核提供。
public struct ZipArchiveReader: ArchiveReading {
    public static let supportedExtensions: Set<String> = ["zip", "zipx", "jar", "apk"]

    private let archive: Archive
    private let url: URL
    private let _summary: ArchiveSummary
    private let _entries: [ArchiveEntry]
    private let entriesByPath: [String: Entry]
    private let encryptedPaths: Set<String>

    /// 每次解压操作新开一个 Archive 实例（独立文件句柄）。
    /// ZIPFoundation 的 Archive 内部只有单个读句柄且非线程安全：
    /// 缩略图泵 / 悬停预览 / 空格 Quick Look 并发解压同一压缩包时，
    /// 共享实例会互相冲断 deflate 流，产出截断文件（实测 1.37GB 视频只解出 75KB）。
    /// Entry 是纯值类型（携带本地头偏移），对同一文件的任意 Archive 实例都有效。
    private func freshArchive() throws -> Archive {
        try Archive(url: url, accessMode: .read)
    }

    public static func canHandle(url: URL) -> Bool {
        let ext = ArchiveVolume.formatExtension(for: url) ?? url.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    /// 加密 ZIP（AES-256/ZipCrypto）：ZIPFoundation 无法迭代加密条目（压缩方法 99，
    /// 会得到 0 项列表），统一委托 7zz 内核读取与解密。
    /// ZIP 分卷（x.zip.001）是物理切分文件，中央目录在末卷，ZIPFoundation 读不了 → 走 7zz 聚合。
    public static func open(url: URL, password: String?) throws -> any ArchiveReading {
        if ArchiveVolume.formatExtension(for: url) != nil
            || !ZipCentralDirectoryScanner.encryptedPaths(in: url).isEmpty {
            return try SevenZipReader(url: url, password: password)
        }
        return try ZipArchiveReader(url: url)
    }

    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ArchiveEngineError.unreadable("文件不存在")
        }
        self.url = url
        do {
            self.archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ArchiveEngineError.unreadable("不是有效的 ZIP 文件")
        }
        // 中央目录有序条目表：与 ZIPFoundation 迭代顺序一一对应，
        // 名称解码统一走 ZipPathDecoding（ZIPFoundation 自身对 GBK 包会产出 cp437 乱码）。
        let centralEntries = ZipCentralDirectoryScanner.scan(in: url)
        self.encryptedPaths = Set(centralEntries.filter(\.isEncrypted).map {
            $0.name.hasSuffix("/") ? String($0.name.dropLast()) : $0.name
        })

        var entries: [ArchiveEntry] = []
        var entriesByPath: [String: Entry] = [:]
        var fileCount = 0
        var folderCount = 0
        var totalUncompressed: Int64 = 0
        var totalCompressed: Int64 = 0
        var latestModification: Date?

        for (index, entry) in archive.enumerated() {
            // 优先使用自扫描中央目录的解码名称；配对失败时回退 ZIPFoundation 的解码。
            let rawPath: String
            if index < centralEntries.count {
                rawPath = centralEntries[index].name
            } else {
                rawPath = entry.path
            }
            guard !rawPath.isEmpty else { continue }
            let isDirectory = rawPath.hasSuffix("/")
            let path = isDirectory ? String(rawPath.dropLast(1)) : rawPath
            guard !path.isEmpty, !path.contains("\0") else { continue }

            // 安全检查：拒绝路径穿越与绝对路径。
            if path.hasPrefix("/") || path.split(separator: "/").contains("..") {
                throw ArchiveEngineError.unreadable("压缩包内包含不安全的路径（\(path)）")
            }

            if isDirectory { folderCount += 1 } else { fileCount += 1 }
            totalUncompressed += isDirectory ? 0 : Int64(entry.uncompressedSize)
            totalCompressed += isDirectory ? 0 : Int64(entry.compressedSize)
            entriesByPath[path] = entry

            // 高精度时间优先（中央目录 0x000A / 0x5455），退回 ZIPFoundation 的 DOS 时间；
            // 浏览与解压看到的是同一个值，两条路线的结果才一致。
            let modificationDate = (index < centralEntries.count ? centralEntries[index].modifiedAt : nil)
                ?? (entry.fileAttributes[.modificationDate] as? Date)
            if let date = modificationDate, date > (latestModification ?? .distantPast) {
                latestModification = date
            }

            // 符号链接：ZIPFoundation 已按 external attributes 判定类型，
            // 这里补上目标字符串（供「拖入 Applications 快捷方式安装」等逻辑使用）。
            let isSymlink = entry.type == .symlink
            var linkTarget: String?
            if isSymlink {
                var data = Data()
                let limit = 4096
                _ = try? archive.extract(entry, bufferSize: limit, skipCRC32: true) { chunk in
                    guard data.count < limit else { return }
                    data.append(chunk.prefix(limit - data.count))
                }
                if !data.isEmpty {
                    linkTarget = String(data: data, encoding: .utf8)
                        ?? String(decoding: data, as: UTF8.self)
                }
            }

            entries.append(
                ArchiveEntry(
                    path: path,
                    isDirectory: isDirectory,
                    size: Int64(entry.uncompressedSize),
                    compressedSize: Int64(entry.compressedSize),
                    modificationDate: modificationDate,
                    isEncrypted: encryptedPaths.contains(path),
                    isSymbolicLink: isSymlink,
                    linkTarget: linkTarget
                )
            )
        }

        _entries = entries
        self.entriesByPath = entriesByPath
        _summary = ArchiveSummary(
            url: url,
            format: .zip,
            fileCount: fileCount,
            folderCount: folderCount,
            totalUncompressed: totalUncompressed,
            totalCompressed: totalCompressed,
            hasEncryptedEntries: !encryptedPaths.isEmpty,
            modificationDate: latestModification,
            comment: ZipArchiveCommentReader.comment(in: url)
        )
    }

    public var summary: ArchiveSummary { _summary }
    public var entries: [ArchiveEntry] { _entries }

    public func extract(
        paths: [String],
        to destination: URL,
        password: String?,
        stripCommonPrefix: Bool = true,
        progress: (@Sendable (ExtractionProgress) -> Void)?
    ) throws {
        let fileManager = FileManager.default
        let target = destination
        if !fileManager.fileExists(atPath: target.path) {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        }

        // 选中路径的文件集合：目录自动展开为其下所有文件。
        let directoryPaths = Set(_entries.filter(\.isDirectory).map(\.path))
        let selectedFiles = _entries.filter { entry in
            guard !entry.isDirectory else { return false }
            if paths.contains(entry.path) { return true }
            return paths.contains { dir in
                directoryPaths.contains(dir) && entry.path.hasPrefix(dir + "/")
            }
        }
        guard !selectedFiles.isEmpty else { return }

        // 公共前缀剥离："解压所选"时选了什么就得到什么。
        let prefix = stripCommonPrefix ? Self.longestCommonDirectoryPrefix(of: selectedFiles.map(\.path)) : ""
        func relativePath(of path: String) -> String {
            guard !prefix.isEmpty, path.hasPrefix(prefix + "/") else { return path }
            return String(path.dropFirst(prefix.count + 1))
        }

        // 加密条目：原生引擎不解密，委托 7zz 内核（支持 ZIP AES-256）。
        // 未提供密码时抛出 passwordRequired 由调用方弹窗；提供密码则直接用内核解密。
        if selectedFiles.contains(where: { encryptedPaths.contains($0.path) }) {
            guard let password, !password.isEmpty else {
                throw ArchiveEngineError.passwordRequired
            }
            let fallback = try SevenZipReader(url: url)
            return try fallback.extract(
                paths: paths,
                to: destination,
                password: password,
                stripCommonPrefix: stripCommonPrefix,
                progress: progress
            )
        }

        let totalBytes = max(selectedFiles.reduce(Int64(0)) { $0 + $1.size }, 1)

        // 暂存区：先写入目标盘隐藏目录，全部成功后移入最终位置；
        // 失败或取消时清理暂存目录，保证目标目录不留残留。
        let staging = target.appendingPathComponent(".arcfrezip-staging-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        func cleanupStaging() {
            // 暂存区里可能有只读目录（部分失败的残留），先递归恢复可写再删，
            // 否则 removeItem 会被 0555 目录卡住、在目标位置留下隐形垃圾。
            if let enumerator = fileManager.enumerator(at: staging, includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator {
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                       isDirectory.boolValue {
                        try? fileManager.setAttributes(
                            [.posixPermissions: NSNumber(value: 0o755)],
                            ofItemAtPath: url.path
                        )
                    }
                }
            }
            try? fileManager.removeItem(at: staging)
        }

        do {
            // 独立句柄：避免与缩略图/悬停预览等并发解压共用 Archive 实例（见 freshArchive 注释）
            let operationArchive = try freshArchive()
            // 中央目录元数据：权限位与高精度时间（两条解压路线结果一致的关键）
            let metadata = ZipCentralDirectoryScanner.metadata(in: url)
            var completedBytes: Int64 = 0
            var completedCount = 0
            var succeeded = 0
            // 符号链接延后创建、目录属性延后恢复（见循环后的说明）。
            // 目录条目不在 selectedFiles 里（解压接口只收文件），这里按「选中文件的祖先」
            // 预先登记：空目录也能保留（原样解出空文件夹），属性由深到浅在最后恢复。
            var pendingSymlinks: [(url: URL, target: String)] = []
            var skipped: [String] = []
            var deferredDirectories: [(url: URL, path: String)] = []
            for dir in _entries where dir.isDirectory {
                guard selectedFiles.contains(where: { $0.path.hasPrefix(dir.path + "/") }) else { continue }
                let relative = relativePath(of: dir.path)
                guard !relative.isEmpty else { continue }
                // 统一解析符号链接（/tmp → /private/tmp）：contentsOfDirectory 返回的
                // 条目路径已解析，登记侧不解析的话 move 后的匹配永远失败。
                // Foundation 的 resolvingSymlinksInPath 只解析最后一组件，
                // 对 /tmp → /private/tmp 这类中间段链接无效，必须用 realpath。
                let dirURL = URL(fileURLWithPath: Self.realpathPath(staging.path))
                    .appendingPathComponent(Self.sanitizedRelativePath(relative))
                try? fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
                deferredDirectories.append((dirURL, dir.path))
            }

            for entry in selectedFiles {
                try Task.checkCancellation()
                let relative = relativePath(of: entry.path)
                let destinationURL = staging.appendingPathComponent(Self.sanitizedRelativePath(relative))
                // 目录穿越防护（zip-slip）：恶意压缩包的条目名可能携带 ../，
                // 必须确保落点标准化后仍在暂存区内，否则拒绝该条目
                let stdDest = destinationURL.standardizedFileURL.path
                let stdStaging = staging.standardizedFileURL.path
                guard stdDest == stdStaging || stdDest.hasPrefix(stdStaging + "/") else {
                    throw ArchiveEngineError.extractionFailed("条目路径非法：\(entry.path)")
                }
                guard let rawEntry = entriesByPath[entry.path] else {
                    throw ArchiveEngineError.extractionFailed("条目 \(entry.path) 在压缩包中不存在")
                }
                // 字节级进度：ZIPFoundation 在解压过程中更新 Progress.completedUnitCount，
                // 由轮询任务每 100ms 汇报一次（单文件很大时进度条也能平滑推进）。
                // Swift 6 严格并发：跨任务共享的计数器与 Progress 用 @unchecked Sendable 包装。
                let counter = SendableRef<(bytes: Int64, count: Int)>((completedBytes, completedCount))
                let fileProgress = SendableRef(Progress(totalUnitCount: Int64(max(entry.size, 1))))
                let entryName = entry.name
                let totalFiles = selectedFiles.count
                let pollTask = Task.detached(priority: .utility) {
                    while !Task.isCancelled {
                        let done = counter.value.bytes + Int64(fileProgress.value.completedUnitCount)
                        progress?(
                            ExtractionProgress(
                                fraction: min(1.0, Double(done) / Double(totalBytes)),
                                completed: counter.value.count,
                                total: totalFiles,
                                currentName: entryName
                            )
                        )
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                defer { pollTask.cancel() }

                do {
                    try write(
                        rawEntry,
                        from: operationArchive,
                        to: destinationURL,
                        staging: staging,
                        progress: fileProgress.value,
                        symlinks: &pendingSymlinks,
                        directories: &deferredDirectories,
                        entryPath: entry.path
                    )
                    // 文件级属性：best-effort。目标卷不支持权限/时间（exFAT、FAT、网络卷）
                    // 时静默跳过，绝不因为「属性没恢复成功」把已完成的解压报成失败。
                    Self.applyMetadata(metadata[entry.path], to: destinationURL)
                    succeeded += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // 单条目失败（同名冲突、异常压缩数据）不再连坐整批：
                    // 记录后继续，最后统一判断是否「一个都没成功」。
                    skipped.append(entry.path)
                    try? fileManager.removeItem(at: destinationURL)
                }

                completedBytes += entry.size
                completedCount += 1
                counter.value = (completedBytes, completedCount)
                progress?(
                    ExtractionProgress(
                        fraction: min(1.0, Double(completedBytes) / Double(totalBytes)),
                        completed: completedCount,
                        total: selectedFiles.count,
                        currentName: entry.name
                    )
                )
            }

            // 符号链接最后建：此时普通文件已全部落盘，链接不可能把后续写入带出暂存区
            //（zip-slip 的第二道保险）；同时也不会与「同名普通文件」抢先占位。
            for link in pendingSymlinks {
                try? fileManager.createDirectory(
                    at: link.url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? fileManager.createSymbolicLink(
                    atPath: link.url.path,
                    withDestinationPath: link.target
                )
            }

            // 目录时间在暂存区内恢复（由深到浅）。
            // 权限刻意不在暂存区恢复：macOS 对只读目录有移动限制（kAuthMoveRestriction），
            // 0555 目录 rename 会 EACCES——保持可写状态移动，落定到最终位置后再恢复权限。
            for directory in deferredDirectories.reversed() {
                Self.applyTimestamp(metadata[directory.path], to: directory.url)
            }

            if succeeded == 0, !selectedFiles.isEmpty {
                throw ArchiveEngineError.extractionFailed(
                    "没有任何条目成功解出（\(skipped.count) 个条目无法写入目标位置）"
                )
            }

            // 暂存区内容移入目标目录（顶层同名时自动追加序号，不覆盖已有文件）。
            // 用批次分配器而不是逐个 fileExists：同一批里仅大小写/Unicode 形式不同的
            // 两个顶层项在区分大小写卷上都会判为空闲，第二个 move 会覆盖失败、连坐整批。
            let stagedItems = try fileManager.contentsOfDirectory(
                at: staging,
                includingPropertiesForKeys: nil
            )
            var allocator = UniqueNameAllocator()
            for item in stagedItems {
                let finalURL = allocator.allocate(for: item.lastPathComponent, in: target)
                let itemPath = Self.realpathPath(item.path)  // move 前解析（move 后源路径不存在）
                try fileManager.moveItem(at: item, to: finalURL)
                // 落定后恢复目录权限（含随顶层一起移动的嵌套目录）
                for directory in deferredDirectories {
                    let dirPath = directory.url.path
                    guard dirPath == itemPath || dirPath.hasPrefix(itemPath + "/") else { continue }
                    let suffix = String(dirPath.dropFirst(itemPath.count))
                    Self.applyPermissions(metadata[directory.path], to: finalURL.appendingPathComponent(suffix))
                }
            }
            try fileManager.removeItem(at: staging)
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

    // MARK: - 单条目写入

    /// 解出单个条目到暂存区（自管写入，不走 ZIPFoundation 的 `extract(_:to:)`）。
    ///
    /// 自管的原因有三个，都对应真实踩过的坑：
    /// 1. 那条 API 对「指向包外的符号链接」直接抛 `uncontainedSymlink`，一条链接毁掉整批；
    /// 2. 它在写完后用 `transferAttributes` 恢复属性，目标卷不支持权限/时间时同样抛错，
    ///    于是「文件其实已经解出来了」却被报成解压失败；
    /// 3. 同名条目已存在时抛 `fileWriteFileExists`，元数据与普通文件冲突就整批中断。
    private func write(
        _ rawEntry: Entry,
        from archive: Archive,
        to url: URL,
        staging: URL,
        progress: Progress,
        symlinks: inout [(url: URL, target: String)],
        directories: inout [(url: URL, path: String)],
        entryPath: String
    ) throws {
        let fm = FileManager.default
        switch rawEntry.type {
        case .directory:
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            directories.append((url, entryPath))
            progress.completedUnitCount = progress.totalUnitCount

        case .symlink:
            var data = Data()
            let limit = 4096
            _ = try archive.extract(rawEntry, bufferSize: limit, skipCRC32: false) { chunk in
                guard data.count < limit else { return }
                data.append(chunk.prefix(limit - data.count))
            }
            guard let target = String(data: data, encoding: .utf8), !target.isEmpty else {
                throw ArchiveEngineError.extractionFailed("符号链接目标不可读")
            }
            symlinks.append((url, target))
            progress.completedUnitCount = progress.totalUnitCount

        case .file:
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw ArchiveEngineError.extractionFailed("无法在目标位置创建文件")
            }
            let handle: FileHandle
            do {
                handle = try FileHandle(forWritingTo: url)
            } catch {
                try? fm.removeItem(at: url)
                throw error
            }
            do {
                _ = try archive.extract(rawEntry, bufferSize: 1 << 20, skipCRC32: true, progress: progress) { chunk in
                    try handle.write(contentsOf: chunk)
                }
                try handle.close()
            } catch {
                try? handle.close()
                try? fm.removeItem(at: url)
                throw error
            }
        }
    }

    /// 解析路径中的全部符号链接（realpath）。
    /// Foundation 的 resolvingSymlinksInPath 只解析最后一组件，
    /// 对 /tmp → /private/tmp 这类中间段链接不生效。
    private static func realpathPath(_ path: String) -> String {
        path.withCString { cpath in
            guard let resolved = realpath(cpath, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// 调试日志（AFZ_DEBUG_ATTR=1 时启用，追加式）。
    static func debugLog(_ line: String) {
        guard ProcessInfo.processInfo.environment["AFZ_DEBUG_ATTR"] == "1" else { return }
        let path = "/tmp/afz-debug-attr.log"
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            try? handle.seekToEnd(); try? handle.write(contentsOf: Data((line + "\n").utf8)); try? handle.close()
        } else {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// 恢复权限与高精度时间：全部 best-effort。
    /// 目标卷不支持某项属性（exFAT 无 POSIX 权限、FAT 时间精度 2 秒）时静默跳过——
    /// 「属性没还原成功」不等于「内容没解出来」，不能因此让用户看到解压失败。
    static func applyMetadata(_ metadata: ZipCentralDirectoryScanner.CentralEntry?, to url: URL) {
        debugLog("apply to=\(url.path) key-mode=\(metadata.map { String($0.unixMode ?? 999, radix: 8) } ?? "NIL") key-date=\(metadata?.modifiedAt.map { "\($0)" } ?? "NIL")")
        applyPermissions(metadata, to: url)
        applyTimestamp(metadata, to: url)
    }

    /// 只恢复权限位（不动文件类型位；setuid/setgid 一并剥掉，解压产物不该带提权位）。
    static func applyPermissions(_ metadata: ZipCentralDirectoryScanner.CentralEntry?, to url: URL) {
        guard let metadata, let unixMode = metadata.unixMode else {
            debugLog("perm-SKIP to=\(url.path) (metadata NIL or no mode)")
            return
        }
        let permissions = unixMode & 0o777
        guard permissions != 0 else { return }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: permissions)],
                ofItemAtPath: url.path
            )
            debugLog("perm-OK to=\(url.path) mode=\(permissions)")
        } catch {
            debugLog("perm-ERR to=\(url.path) mode=\(permissions) err=\(error)")
        }
    }

    /// 只恢复修改时间。
    static func applyTimestamp(_ metadata: ZipCentralDirectoryScanner.CentralEntry?, to url: URL) {
        guard let metadata, let date = metadata.modifiedAt else { return }
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// 逐段收敛超长文件名（单个路径组件上限 255 字节）。
    /// 老工具打出的包偶尔带超过 APFS/HFS+ 上限的名字，直接写会 ENAMETOOLONG 中断整批。
    static func sanitizedRelativePath(_ relative: String) -> String {
        relative
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { sanitizedComponent(String($0)) }
            .joined(separator: "/")
    }

    static func sanitizedComponent(_ name: String) -> String {
        guard name.utf8.count > 255, !name.isEmpty else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        guard !ext.isEmpty, ext.utf8.count < 200 else {
            return truncatedUTF8(name, maxBytes: 255)
        }
        let budget = 255 - ext.utf8.count - 1
        return truncatedUTF8(stem, maxBytes: max(budget, 1)) + "." + ext
    }

    /// 按 UTF-8 字节预算截断（不切断多字节字符）。
    private static func truncatedUTF8(_ text: String, maxBytes: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            result.append(character)
            used += size
        }
        return result.isEmpty ? String(text.prefix(1)) : result
    }

/// 严格并发下的可变共享包装（@unchecked Sendable）：进度计数等低风险场景使用。
final class SendableRef<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    init(_ value: T) { self._value = value }
}

/// 计算多个归档内路径的最长公共父目录（不含尾部斜杠，无公共父目录时返回 ""）。
    static func longestCommonDirectoryPrefix(of paths: [String]) -> String {
        guard let first = paths.first else { return "" }
        guard paths.count > 1 else {
            return first.split(separator: "/").dropLast().joined(separator: "/")
        }
        var common: [String] = []
        let firstComponents = first.split(separator: "/").map(String.init)
        for (index, component) in firstComponents.enumerated() {
            let allContain = paths.allSatisfy { path in
                let components = path.split(separator: "/").map(String.init)
                return components.count > index + 1 && components[index] == component
            }
            if allContain { common.append(component) } else { break }
        }
        return common.joined(separator: "/")
    }

    /// 读取单个条目的预览数据（图片/文本预览用）。
    /// 通过临时目录解压实现（复用暂存区安全逻辑），返回不超过 maxBytes 的头部数据。
    public func previewData(path: String, maxBytes: Int) throws -> Data? {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("afz-preview-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: tempRoot) }

        guard let fileURL = try previewFile(path: path, cacheDirectory: tempRoot) else { return nil }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        return try handle.read(upToCount: maxBytes)
    }

    /// 将单个条目解压到调用方提供的缓存目录，返回该文件的 URL（QuickLook 预览用）。
    public func previewFile(path: String, cacheDirectory: URL) throws -> URL? {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try extract(paths: [path], to: cacheDirectory, password: nil, stripCommonPrefix: true, progress: nil)

        let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        while let item = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return item
            }
        }
        return nil
    }

    /// 目标位置已存在同名项时生成 "name 2.ext" 风格的可用路径。
    public static func uniquedURL(for url: URL, in directory: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(url.lastPathComponent)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for counter in 2...1_000 {
            let name = ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return candidate
    }
}

/// ZIP 整包备注读取（EOCD 尾部注释字段）。
/// WinRAR / 好压 / 360压缩 等工具常把解压密码写在这里——详情面板展示用。
public enum ZipArchiveCommentReader {
    /// 返回 ZIP 的整包备注（UTF-8 优先，Latin1 兜底）；无备注或非 ZIP 文件返回 nil。
    public static func comment(in url: URL) -> String? {
        ZipCentralDirectoryScanner.archiveComment(in: url)
    }
}

/// 扫描 ZIP 中央目录，返回有序条目表（名称 + 加密标志）。
/// ZIP Foundation 未公开加密标志与原始名称字节，这里直接解析 central directory。
/// 顺序与 ZIPFoundation 的归档迭代顺序一致（均按中央目录顺序）。
enum ZipCentralDirectoryScanner {
    struct CentralEntry {
        let name: String
        let isEncrypted: Bool
        /// Unix 权限位（含文件类型高 4 位）。仅 version-made-by 为 Unix 时存在。
        let unixMode: UInt16?
        /// 高精度修改时间：0x000A（NTFS，100ns）优先，其次 0x5455（Unix 秒），
        /// 最后回落到 DOS 时间（2 秒精度）。老工具常只写 DOS 时间。
        let modifiedAt: Date?
    }

    static func scan(in url: URL) -> [CentralEntry] {
        guard let data = centralDirectoryData(in: url) else { return [] }
        let (centralData, entryCount) = data
        var result: [CentralEntry] = []
        var offset = 0
        while offset + 46 <= centralData.count, result.count < entryCount {
            guard centralData[offset] == 0x50, centralData[offset + 1] == 0x4b,
                  centralData[offset + 2] == 0x01, centralData[offset + 3] == 0x02 else { break }

            let flags = le16In(centralData, offset + 8)
            let dosTime = le16In(centralData, offset + 12)
            let dosDate = le16In(centralData, offset + 14)
            let nameLength = le16In(centralData, offset + 28)
            let extraLength = le16In(centralData, offset + 30)
            let commentLength = le16In(centralData, offset + 32)
            let versionMadeBy = le16In(centralData, offset + 4)
            let externalAttributes = UInt32(le32In(centralData, offset + 38))
            defer { offset += 46 + nameLength + extraLength + commentLength }
            guard nameLength > 0, offset + 46 + nameLength <= centralData.count else { continue }

            let nameData = centralData.subdata(in: (offset + 46)..<((offset + 46 + nameLength)))
            let name = ZipPathDecoding.decode(nameData: nameData, utf8Flag: (flags & (1 << 11)) != 0)

            // Unix 宿主写出的包，external attributes 高 16 位是 st_mode（含 S_IFLNK 等类型位）
            let hostOS = UInt8(versionMadeBy >> 8)
            let unixMode: UInt16? = hostOS == 3 ? UInt16(truncatingIfNeeded: externalAttributes >> 16) : nil

            // 扩展字段：0x000A NTFS / 0x5455 扩展时间戳
            let extraStart = offset + 46 + nameLength
            let extraEnd = min(extraStart + extraLength, centralData.count)
            var modifiedAt: Date? = nil
            if extraStart < extraEnd {
                let extra = centralData.subdata(in: extraStart..<extraEnd)
                modifiedAt = extendedTimestamp(in: extra)
            }
            if modifiedAt == nil {
                modifiedAt = dosTimestamp(time: dosTime, date: dosDate)
            }

            result.append(CentralEntry(
                name: name,
                isEncrypted: (flags & 1) != 0,
                unixMode: unixMode,
                modifiedAt: modifiedAt
            ))
        }
        return result
    }

    /// 按路径索引的元数据表（解压时补权限与时间用）。
    static func metadata(in url: URL) -> [String: CentralEntry] {
        var table: [String: CentralEntry] = [:]
        for entry in scan(in: url) {
            table[entry.name.hasSuffix("/") ? String(entry.name.dropLast()) : entry.name] = entry
        }
        return table
    }

    static func encryptedPaths(in url: URL) -> Set<String> {
        Set(scan(in: url).filter(\.isEncrypted).map(\.name))
    }

    // MARK: - 时间与扩展字段

    /// 遍历 extra field 列表，优先取 NTFS 时间（100ns），其次 Unix 扩展时间戳。
    private static func extendedTimestamp(in extra: Data) -> Date? {
        var offset = 0
        var unixDate: Date?
        while offset + 4 <= extra.count {
            let tag = le16In(extra, offset)
            let size = le16In(extra, offset + 2)
            let bodyStart = offset + 4
            guard bodyStart + size <= extra.count else { break }
            switch tag {
            case 0x000A:
                // NTFS：4 字节保留 + 属性标签(2) + 长度(2) + FILETIME(8)
                var cursor = bodyStart
                while cursor + 4 <= bodyStart + size {
                    let attrTag = le16In(extra, cursor)
                    let attrSize = le16In(extra, cursor + 2)
                    let valueStart = cursor + 4
                    guard valueStart + attrSize <= bodyStart + size else { break }
                    if attrTag == 0x0001, attrSize >= 8 {
                        var filetime: UInt64 = 0
                        for i in 0..<8 {
                            filetime |= UInt64(extra[extra.startIndex + valueStart + i]) << (8 * UInt64(i))
                        }
                        // FILETIME：1601-01-01 起的 100ns 计数
                        if filetime > 0 {
                            let seconds = Double(filetime) / 10_000_000.0 - 11_644_473_600.0
                            return Date(timeIntervalSince1970: seconds)
                        }
                    }
                    cursor = valueStart + attrSize
                }
            case 0x5455:
                // 扩展时间戳：flags(1) 后按位跟 mtime/atime/ctime（各 4 字节 Unix 秒）
                if size >= 5 {
                    let flags = extra[extra.startIndex + bodyStart]
                    if flags & 0x01 != 0, size >= 5 {
                        let seconds = le32In(extra, bodyStart + 1)
                        unixDate = Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: UInt32(seconds))))
                    }
                }
            default:
                break
            }
            offset = bodyStart + size
        }
        return unixDate
    }

    /// DOS 日期时间（本地时区，2 秒精度）。
    private static func dosTimestamp(time: Int, date: Int) -> Date? {
        let second = (time & 0x1F) * 2
        let minute = (time >> 5) & 0x3F
        let hour = (time >> 11) & 0x1F
        let day = date & 0x1F
        let month = (date >> 5) & 0x0F
        let year = 1980 + ((date >> 9) & 0x7F)
        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return Calendar(identifier: .gregorian).date(from: components)
    }

    /// 读取 EOCD（End Of Central Directory）末尾的整包备注。
    /// 结构：EOCD 签名(4) + 盘号(2+2) + 条目数(2+2) + 目录大小(4) + 目录偏移(4) + 备注长度(2) + 备注字节。
    static func archiveComment(in url: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }

        let fileSize = (try? fileHandle.seekToEnd()) ?? 0
        guard fileSize >= 22 else { return nil }

        // 与 centralDirectoryData 同款：从尾部向前找 EOCD 签名（最多扫 64KB，容纳前置备注）
        let scanLength = min(Int(fileSize), 65_557)
        try? fileHandle.seek(toOffset: fileSize - UInt64(scanLength))
        guard let tailData = try? fileHandle.read(upToCount: scanLength),
              tailData.count >= 22 else { return nil }

        var index = tailData.count - 22
        while index >= 0 {
            if tailData[index] == 0x50, tailData[index + 1] == 0x4b,
               tailData[index + 2] == 0x05, tailData[index + 3] == 0x06 {
                let commentLength = Int(tailData[index + 20]) | (Int(tailData[index + 21]) << 8)
                guard commentLength > 0 else { return nil }
                let start = index + 22
                guard start + commentLength <= tailData.count else { return nil }
                let data = tailData.subdata(in: start..<(start + commentLength))
                // 备注 coding 不规范：UTF-8 优先（现代工具），Latin1 兜底（老 WinRAR）
                return String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
            }
            index -= 1
        }
        return nil
    }

    /// 定位并读取中央目录：返回（数据, 条目数）。
    private static func centralDirectoryData(in url: URL) -> (Data, Int)? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }

        let fileSize = (try? fileHandle.seekToEnd()) ?? 0
        guard fileSize >= 22 else { return nil }

        // 从文件尾部向前找 EOCD 签名 0x06054b50（注释长度不定，最多扫 64KB）。
        let scanLength = min(Int(fileSize), 65_557)
        try? fileHandle.seek(toOffset: fileSize - UInt64(scanLength))
        guard let tailData = try? fileHandle.read(upToCount: scanLength),
              tailData.count >= 22 else { return nil }

        var eocdOffsetInTail = -1
        var index = tailData.count - 22
        while index >= 0 {
            if tailData[index] == 0x50, tailData[index + 1] == 0x4b,
               tailData[index + 2] == 0x05, tailData[index + 3] == 0x06 {
                eocdOffsetInTail = index
                break
            }
            index -= 1
        }
        guard eocdOffsetInTail >= 0 else { return nil }

        func le16(_ offset: Int) -> Int {
            Int(tailData[offset]) | (Int(tailData[offset + 1]) << 8)
        }
        func le32(_ offset: Int) -> Int {
            le16(offset) | (le16(offset + 2) << 16)
        }

        let centralDirOffset = le32(eocdOffsetInTail + 16)
        let entryCount = le16(eocdOffsetInTail + 10)
        // ZIP64 EOCD：真实值在 ZIP64 EOCD 记录里，这里仅处理非 ZIP64 的常见场景。
        if centralDirOffset == 0xFFFF_FFFF || entryCount == 0xFFFF {
            return nil
        }

        try? fileHandle.seek(toOffset: UInt64(centralDirOffset))
        guard let centralData = try? fileHandle.read(
            upToCount: Int(fileSize - UInt64(centralDirOffset))
        ), centralData.count >= 46 else { return nil }
        return (centralData, entryCount)
    }

    private static func le16In(_ data: Data, _ offset: Int) -> Int {
        Int(data[data.startIndex + offset]) | (Int(data[data.startIndex + offset + 1]) << 8)
    }

    private static func le32In(_ data: Data, _ offset: Int) -> Int {
        le16In(data, offset) | (le16In(data, offset + 2) << 16)
    }
}

/// App 与测试启动时调用一次，把各格式引擎注册进 ArchiveCore 路由表。
public enum FormatZipBootstrap {
    public static func registerEngines() {
        // ZIP 优先（原生 ZIPFoundation 快且稳定）；DMG 单独走 hdiutil；其余格式由 7zz 内核接管。
        if !FormatZipRegistrations.all.contains(where: { $0 is ZipArchiveReader.Type }) {
            FormatZipRegistrations.all.append(ZipArchiveReader.self)
        }
        if !FormatZipRegistrations.all.contains(where: { $0 is DmgArchiveReader.Type }) {
            FormatZipRegistrations.all.append(DmgArchiveReader.self)
        }
        if !FormatZipRegistrations.all.contains(where: { $0 is SevenZipReader.Type }) {
            FormatZipRegistrations.all.append(SevenZipReader.self)
        }
    }
}

// 引擎实例为只读使用（打开后 entries/extract），跨任务传递安全。
extension ZipArchiveReader: @unchecked Sendable {}
