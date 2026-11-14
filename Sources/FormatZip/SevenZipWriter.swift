import Foundation
import Darwin
import ArchiveCore

/// 创建进度（fraction 0~1；processed/total 为按比例的估算值，用于进度卡显示「139 MB / 478 MB」）。
public struct CreationProgress: Sendable {
    public var fraction: Double
    public var processedBytes: Int64?
    public var totalBytes: Int64?

    public init(fraction: Double, processedBytes: Int64? = nil, totalBytes: Int64? = nil) {
        self.fraction = fraction
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
    }
}

/// 基于 7zz 内核的创建引擎。
/// - ZIP（deflate / AES-256）
/// - 7Z（LZMA2 / 加密头部）
/// - TAR 系：TAR / TAR.GZ / TAR.XZ / TAR.ZST（先打 tar，再单文件压缩，两步）
/// 压缩包内路径以「所有条目的公共祖先目录」为基准取相对路径（与访达压缩行为一致）。
/// 注：RAR 压缩算法专有（7zz 只解不压），创建格式不含 RAR。
public enum SevenZipWriter {
    /// 打包本地文件/目录到目标压缩包。progress 在后台线程回传 0.0~1.0。
    /// splitSize 非 nil 时分卷压缩（如 "100m"，仅对单步格式生效）。
    ///
    /// 【安全修复 2026-11-06】先压到临时目标，全部成功后才替换用户的目标文件。
    /// 以前是"先删旧包再压缩"——压缩中途失败（磁盘满/取消/崩溃）会连用户原有
    /// 压缩包一起销毁。现在任何失败都不会碰已有文件。
    public static func create(
        items: [URL],
        to destination: URL,
        options: CreationOptions,
        splitSize: String? = nil,
        nameOverrides: [String: String] = [:],
        progress: (@Sendable (CreationProgress) -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        let stagingRoot = fm.temporaryDirectory
            .appendingPathComponent("afz-pack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }
        let tmpDest = stagingRoot.appendingPathComponent(destination.lastPathComponent)

        try packDirect(
            items: items, to: tmpDest, options: options,
            splitSize: splitSize, nameOverrides: nameOverrides, progress: progress
        )

        // 打包成功，安全落位
        if splitSize != nil {
            // 分卷：成功后才清旧卷并按目标名落位（x.7z.001…）
            for i in 1...999 {
                let old = URL(fileURLWithPath: destination.path + String(format: ".%03d", i))
                if fm.fileExists(atPath: old.path) { try? fm.removeItem(at: old) }
            }
            for i in 1...999 {
                let part = URL(fileURLWithPath: tmpDest.path + String(format: ".%03d", i))
                guard fm.fileExists(atPath: part.path) else { break }
                try fm.moveItem(at: part, to: URL(fileURLWithPath: destination.path + String(format: ".%03d", i)))
            }
        } else if fm.fileExists(atPath: destination.path) {
            do {
                try fm.replaceItemAt(destination, withItemAt: tmpDest)
            } catch {
                // 跨卷 replaceItemAt 可能失败：旧包先移到暂存区备份，再移入新包；失败可回滚
                let backup = stagingRoot.appendingPathComponent("old-\(destination.lastPathComponent)")
                try fm.moveItem(at: destination, to: backup)
                do {
                    try fm.moveItem(at: tmpDest, to: destination)
                } catch {
                    try? fm.moveItem(at: backup, to: destination)
                    throw error
                }
            }
        } else {
            try fm.moveItem(at: tmpDest, to: destination)
        }
    }

    /// 实际打包（直接写到 destination，可能中途失败，仅供 create 的临时目标使用）。
    private static func packDirect(
        items: [URL],
        to destination: URL,
        options: CreationOptions,
        splitSize: String?,
        nameOverrides: [String: String],
        progress: (@Sendable (CreationProgress) -> Void)?
    ) throws {
        let fm = FileManager.default
        guard !items.isEmpty else {
            throw ArchiveEngineError.creationFailed("没有可压缩的文件")
        }
        guard let binary = SevenZipReader.locateBinary() else {
            throw ArchiveEngineError.creationFailed("未找到 7zz 内核")
        }

        let workDir = commonAncestor(of: items)
        let names = items.map { item -> String in
            let prefix = workDir.standardizedFileURL.path.hasSuffix("/")
                ? workDir.standardizedFileURL.path
                : workDir.standardizedFileURL.path + "/"
            let std = item.standardizedFileURL.path
            return std.hasPrefix(prefix) ? String(std.dropFirst(prefix.count)) : item.lastPathComponent
        }
        let totalBytes = totalSize(of: items)

        // 相对路径写入清单文件（避免命令行长度与转义问题）
        var processDir = workDir
        var archiveNames = names
        var tempDirs: [URL] = []
        defer { for dir in tempDirs { try? fm.removeItem(at: dir) } }

        // 元数据承载方式（遵循 macOS 自身的归档规律）：
        // · 纯 TAR：一律走系统 bsdtar——默认保留 Unix 权限/属主（「保留目录结构与
        //            Unix 文件属性」）；保留辅助文件时再开 --xattrs 写 pax 扩展头，
        //            清理模式则排除 __MACOSX/.DS_Store/._*。
        // · ZIP / 7Z：容器没有 xattr 字段 → AppleDouble（__MACOSX/._*，访达压缩的标准做法）
        // · 包内改名（Windows 文件名修正）：影子目录符号链接按新名字落盘
        // 注：只有真正携带扩展属性/资源叉的条目才会产生 ._ 文件。
        if options.format == .tar {
            try createTarWithMetadata(
                names: names, workDir: workDir, destination: destination,
                options: options, binary: binary, splitSize: splitSize,
                preserveXattrs: options.preserveMetadata,
                excludeAuxiliary: !options.preserveMetadata,
                progress: progress
            )
            return
        }
        if options.preserveMetadata, isTarFamily(options.format) {
            try createTarWithMetadata(
                names: names, workDir: workDir, destination: destination,
                options: options, binary: binary, splitSize: splitSize, progress: progress
            )
            return
        }

        let overrides = nameOverrides.filter { !$0.value.isEmpty }
        var appleDouble: URL?
        if options.preserveMetadata,
           let tree = buildAppleDoubleTree(
               names: names, workDir: workDir, binary: binary, tempDirs: &tempDirs
           ) {
            appleDouble = tree
        }
        if appleDouble != nil || !overrides.isEmpty,
           let shadow = makeShadowDirectory(
               names: names, workDir: workDir, appleDouble: appleDouble,
               tempDirs: &tempDirs, nameOverrides: overrides
           ) {
            processDir = shadow
            // 包内条目名 = 原相对路径逐组件应用改名映射（与影子链接名一致）
            archiveNames = names.map { applyingComponentOverrides($0, overrides) }
            if appleDouble != nil { archiveNames.append("__MACOSX") }
        }

        let listFile = fm.temporaryDirectory
            .appendingPathComponent("afz-create-\(UUID().uuidString).lst")
        try archiveNames.joined(separator: "\n").write(to: listFile, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: listFile) }

        func typeSwitch() -> [String] { Self.typeSwitch(options.format) }

        func baseArgs(typeOverride: [String]? = nil) -> [String] {
            Self.baseArguments(
                format: options.format, options: options,
                splitSize: splitSize, typeOverride: typeOverride
            )
        }

        // 两步格式：先 tar 到临时目录（进度 0~0.7），再压缩为最终格式（0.7~1.0）
        let tarFirst = options.format == .tgz || options.format == .txz || options.format == .tzst
        let stepBase: Double = tarFirst ? 0.7 : 0.0
        let stepScale: Double = tarFirst ? 0.3 : 1.0
        var finalTarURL: URL?
        defer {
            if let tarURL = finalTarURL { try? fm.removeItem(at: tarURL) }
        }

        var args = baseArgs()
        let result: (status: Int32, stderr: String)
        if tarFirst {
            // 内层 tar 用确定性命名："x.tar.gz" 去掉 .gz 得 "x.tar"（gzip/xz 单文件容器按此名记录条目）
            let base = destination.deletingPathExtension().lastPathComponent
            let innerName = base.hasSuffix(".tar") ? base : base + ".tar"
            let tarURL = fm.temporaryDirectory.appendingPathComponent(innerName)
            finalTarURL = tarURL
            var tarArgs = baseArgs(typeOverride: ["-ttar"])
            tarArgs.append(tarURL.path)
            tarArgs.append("@\(listFile.path)")
            try runStep(binary, tarArgs, workDir: processDir, totalBytes: totalBytes, progress: progress)

            // 第二步：压缩上一步的 tar 单文件（输入为绝对路径，无需 @list）
            args.append(destination.path)
            args.append(tarURL.path)
            result = runProcess(binary, args, currentDirectory: processDir) { line in
                guard let progress, let fraction = lastPercent(in: line) else { return !Task.isCancelled }
                progress(makeProgress(fraction: 0.7 + fraction * 0.3, totalBytes: totalBytes))
                return !Task.isCancelled
            }
        } else {
            args.append(destination.path)
            args.append("@\(listFile.path)")
            result = runProcess(binary, args, currentDirectory: processDir) { line in
                guard let progress, let fraction = lastPercent(in: line) else { return !Task.isCancelled }
                progress(makeProgress(fraction: fraction, totalBytes: totalBytes))
                return !Task.isCancelled
            }
        }
        if result.status == -2 {
            throw ArchiveEngineError.cancelled
        }
        guard result.status == 0 else {
            throw ArchiveEngineError.creationFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        progress?(CreationProgress(fraction: 1.0, processedBytes: totalBytes, totalBytes: totalBytes))
    }

    /// 按比例换算的进度（字节用于进度卡「139.5 MB / 478.4 MB」显示）。
    private static func makeProgress(fraction: Double, totalBytes: Int64) -> CreationProgress {
        let f = min(1, max(0, fraction))
        return CreationProgress(
            fraction: f,
            processedBytes: Int64(Double(totalBytes) * f),
            totalBytes: totalBytes
        )
    }

    /// 待打包内容总字节（目录递归）。
    static func totalSize(of items: [URL]) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for item in items {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue, let enumerator = fm.enumerator(at: item, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in enumerator {
                    total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            } else if let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - TAR 系原生元数据（pax 扩展头）

    /// TAR / TAR.GZ / TAR.XZ / TAR.ZST：pax 扩展头可直接承载扩展属性，无需 __MACOSX。
    static func isTarFamily(_ format: ArchiveFormat) -> Bool {
        format == .tar || format == .tgz || format == .txz || format == .tzst
    }

    private static func typeSwitch(_ format: ArchiveFormat) -> [String] {
        switch format {
        case .zip: return ["-tzip"]
        case .sevenZip: return ["-t7z"]
        case .tar: return ["-ttar"]
        case .tgz: return ["-tgzip"]
        case .txz: return ["-txz"]
        case .tzst: return ["-tzst"]
        default: return ["-tzip"]
        }
    }

    private static func baseArguments(
        format: ArchiveFormat,
        options: CreationOptions,
        splitSize: String?,
        typeOverride: [String]? = nil
    ) -> [String] {
        var args = ["a", "-y", "-bso0", "-bsp1"]
        args += typeOverride ?? typeSwitch(format)
        args.append("-mx=\(max(0, min(9, options.level)))")
        // 处理器使用（设置里「最大可用核心数」）：限定 7zz 的多线程数；
        // nil = 不传，走 7zz 默认（全部可用）
        if let limit = options.threadLimit, limit > 0 {
            args.append("-mmt=\(limit)")
        }
        if format == .sevenZip {
            // 强度语义：快速=不固实；均衡=128 MB 固实块；
            // 更小=1 GB；极限=4 GB。-mqs 开启固实扩展模式。
            switch options.level {
            case 1...3: args.append("-ms=off")
            case 4...6: args += ["-ms=128m", "-mqs=on"]
            case 7...8: args += ["-ms=1g", "-mqs=on"]
            case 9: args += ["-ms=4g", "-mqs=on"]
            default: break
            }
        }
        if !options.preserveMetadata {
            args += ["-xr!__MACOSX", "-xr!.DS_Store", "-xr!._*"]
        }
        if let splitSize {
            args.append("-v\(splitSize)")
        }
        if let password = options.password, !password.isEmpty {
            args.append("-p\(password)")
            if format == .zip {
                args.append("-mem=AES256")
            } else if format == .sevenZip {
                args.append("-mhe=on")  // 7z：加密文件名列表（头部）
            }
        }
        // 注意：不能加 "--" 分隔符——7zz 25.01 会把后续 @listfile 当普通文件名（实测）
        return args
    }

    /// 用系统 tar（bsdtar）打包：
    /// · preserveXattrs（macOS 辅助文件方案）：写 pax 扩展属性（LIBARCHIVE.xattr /
    ///   SCHILY.xattr），macOS 解压自动合并——与「系统 tar 压缩」产物一致；
    /// · excludeAuxiliary（清理模式，如 Linux 与服务器方案）：排除 __MACOSX /
    ///   .DS_Store / ._ *；无论哪种模式 bsdtar 都保留 Unix 权限与属主。
    private static func createTarWithMetadata(
        names: [String],
        workDir: URL,
        destination: URL,
        options: CreationOptions,
        binary: URL,
        splitSize: String?,
        preserveXattrs: Bool = true,
        excludeAuxiliary: Bool = false,
        progress: (@Sendable (CreationProgress) -> Void)?
    ) throws {
        let fm = FileManager.default
        let tarBinary = URL(fileURLWithPath: "/usr/bin/tar")
        guard fm.isExecutableFile(atPath: tarBinary.path) else {
            throw ArchiveEngineError.creationFailed("未找到系统 tar（/usr/bin/tar）")
        }
        let totalBytes = totalSize(of: names.map { workDir.appendingPathComponent($0) })

        let compresses = options.format != .tar
        let chunk = splitSize.flatMap(byteCount)
        // 需要二次处理（压缩 / 分卷）时先写临时 tar，避免在目标路径留下中间产物
        let needsStaging = compresses || chunk != nil
        let base = destination.deletingPathExtension().lastPathComponent
        let tarURL = needsStaging
            ? fm.temporaryDirectory.appendingPathComponent("afz-metatar-\(UUID().uuidString)-\(base).tar")
            : destination
        defer { if needsStaging { try? fm.removeItem(at: tarURL) } }

        let total = max(1, countEntries(names: names, workDir: workDir))
        let tarSpan = compresses ? 0.7 : 0.98
        var seen = 0
        var tarArgs = ["-c", "-v"]
        if preserveXattrs { tarArgs.append("--xattrs") }
        if excludeAuxiliary {
            tarArgs += [
                "--exclude", "__MACOSX",
                "--exclude", "*.DS_Store",
                "--exclude", "._*",
            ]
        }
        tarArgs += ["-f", tarURL.path, "-C", workDir.path] + names
        let tarResult = runProcess(
            tarBinary,
            tarArgs,
            currentDirectory: workDir,
            mergeStderr: true
        ) { line in
            // bsdtar 的 -v 文件清单输出到 stderr，格式为 "a <path>"
            if line.hasPrefix("a ") {
                seen += 1
                let fraction = min(tarSpan, Double(seen) / Double(total) * tarSpan)
                progress?(makeProgress(fraction: fraction, totalBytes: totalBytes))
            }
            return !Task.isCancelled
        }
        if tarResult.status == -2 { throw ArchiveEngineError.cancelled }
        guard tarResult.status == 0 else {
            throw ArchiveEngineError.creationFailed(
                tarResult.stderr.isEmpty ? "系统 tar 打包失败" : tarResult.stderr
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        guard compresses else {
            if let chunk { try splitFile(tarURL, chunkSize: chunk, destination: destination) }
            progress?(CreationProgress(fraction: 1.0, processedBytes: totalBytes, totalBytes: totalBytes))
            return
        }

        var args = baseArguments(format: options.format, options: options, splitSize: splitSize)
        args.append(destination.path)
        args.append(tarURL.path)
        let result = runProcess(binary, args, currentDirectory: workDir) { line in
            guard let progress, let fraction = lastPercent(in: line) else { return !Task.isCancelled }
            progress(makeProgress(fraction: 0.7 + fraction * 0.3, totalBytes: totalBytes))
            return !Task.isCancelled
        }
        if result.status == -2 { throw ArchiveEngineError.cancelled }
        guard result.status == 0 else {
            throw ArchiveEngineError.creationFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        progress?(CreationProgress(fraction: 1.0, processedBytes: totalBytes, totalBytes: totalBytes))
    }

    /// 从 7zz 的进度行里取最后一个百分比（如 " 45%"）。
    private static func lastPercent(in line: String) -> Double? {
        var fraction: Double?
        var searchEnd = line.endIndex
        while let r = line.range(
            of: #"[0-9]{1,3}%"#, options: .regularExpression, range: line.startIndex..<searchEnd
        ) {
            fraction = Double(String(line[r]).dropLast()).map { $0 / 100 }
            searchEnd = r.lowerBound
        }
        return fraction
    }

    /// 打包条目总数（含目录自身），仅用于把 bsdtar 的逐条输出换算成进度。
    private static func countEntries(names: [String], workDir: URL) -> Int {
        let fm = FileManager.default
        var count = 0
        for name in names {
            let url = workDir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            count += 1
            guard isDir.boolValue,
                  let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
            for case let _ as URL in enumerator { count += 1 }
        }
        return count
    }

    /// 解析 7z 风格的分卷尺寸（"100m" / "1g" / "4400m"）。
    public static func byteCount(_ size: String) -> Int64? {
        let text = size.trimmingCharacters(in: .whitespaces).lowercased()
        guard let last = text.last else { return nil }
        var multiplier: Int64 = 1
        var digits = text
        switch last {
        case "k": multiplier = 1024; digits = String(text.dropLast())
        case "m": multiplier = 1024 * 1024; digits = String(text.dropLast())
        case "g": multiplier = 1024 * 1024 * 1024; digits = String(text.dropLast())
        default: break
        }
        guard let value = Int64(digits), value > 0 else { return nil }
        return value * multiplier
    }

    /// 按固定大小切分（沿用 7z 分卷命名 x.tar.001 / .002 …）。
    private static func splitFile(_ url: URL, chunkSize: Int64, destination: URL) throws {
        let fm = FileManager.default
        guard chunkSize > 0, let input = try? FileHandle(forReadingFrom: url) else {
            throw ArchiveEngineError.creationFailed("分卷失败：无法读取中间 tar")
        }
        defer { try? input.close() }
        let bufferSize: Int64 = 1 << 20
        var index = 1
        while true {
            let partURL = URL(fileURLWithPath: destination.path + String(format: ".%03d", index))
            guard fm.createFile(atPath: partURL.path, contents: nil),
                  let output = try? FileHandle(forWritingTo: partURL) else {
                throw ArchiveEngineError.creationFailed("分卷失败：无法写入 \(partURL.lastPathComponent)")
            }
            var written: Int64 = 0
            while written < chunkSize {
                let want = Int(min(bufferSize, chunkSize - written))
                let data = input.readData(ofLength: want)
                if data.isEmpty { break }
                output.write(data)
                written += Int64(data.count)
            }
            try? output.close()
            if written == 0 {
                try? fm.removeItem(at: partURL)
                break
            }
            index += 1
            if written < chunkSize { break }
        }
    }

    // MARK: - macOS 辅助文件（AppleDouble / __MACOSX）

    /// 条目是否携带扩展属性或资源叉（只 stat xattr，不解压内容，避免无谓的全量双读）。
    static func hasExtendedMetadata(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if hasXattr(url.path) { return true }
        guard isDir.boolValue,
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        else { return false }
        for case let child as URL in enumerator where hasXattr(child.path) { return true }
        return false
    }

    private static func hasXattr(_ path: String) -> Bool {
        listxattr(path, nil, 0, XATTR_NOFOLLOW) > 0
    }

    /// 用系统 `ditto --sequesterRsrc` 生成标准 AppleDouble 树（与访达压缩同一实现），
    /// 返回 `__MACOSX` 目录；无任何元数据时返回 nil（此时不写入 __MACOSX）。
    static func buildAppleDoubleTree(
        names: [String], workDir: URL, binary: URL, tempDirs: inout [URL]
    ) -> URL? {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("afz-meta-\(UUID().uuidString)", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        guard (try? fm.createDirectory(at: out, withIntermediateDirectories: true)) != nil else { return nil }
        tempDirs.append(root)

        for name in names {
            let item = workDir.appendingPathComponent(name)
            guard hasExtendedMetadata(item) else { continue }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &isDir)
            let zipURL = root.appendingPathComponent("m-\(UUID().uuidString).zip")
            var args = ["-c", "-k", "--sequesterRsrc"]
            // keepParent：目录或带子路径的条目需要保留层级，顶层单文件则取 basename
            if isDir.boolValue || name.contains("/") { args.append("--keepParent") }
            args += [name, zipURL.path]
            runTool(URL(fileURLWithPath: "/usr/bin/ditto"), args, currentDirectory: workDir)
            // 只取 __MACOSX 树，正文由 7zz 正常打包（不重复写入）
            runTool(
                binary,
                ["x", "-y", "-bso0", zipURL.path, "__MACOSX/*", "-o\(out.path)"],
                currentDirectory: workDir
            )
            try? fm.removeItem(at: zipURL)
        }
        let macosx = out.appendingPathComponent("__MACOSX")
        guard fm.fileExists(atPath: macosx.path) else { return nil }
        return macosx
    }

    /// 影子目录：条目以符号链接指向真实位置（7zz 默认跟随链接），
    /// 这样元数据与正文能在**同一遍**打包中写入，分卷/加密/二次格式无需特殊处理。
    /// nameOverrides 非空时（Windows 文件名修正）：**目录必须是真实目录**、仅文件
    /// 做符号链接——若目录也用链接，7zz 会递归真实目录、内部条目名无法应用改名映射。
    private static func makeShadowDirectory(
        names: [String], workDir: URL, appleDouble: URL?, tempDirs: inout [URL],
        nameOverrides: [String: String] = [:]
    ) -> URL? {
        let fm = FileManager.default
        let shadow = fm.temporaryDirectory.appendingPathComponent("afz-shadow-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: shadow, withIntermediateDirectories: true)) != nil else { return nil }
        tempDirs.append(shadow)

        for name in names {
            let source = workDir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { continue }
            let mappedName = applyingComponentOverrides(name, nameOverrides)
            let linkURL = shadow.appendingPathComponent(mappedName)
            if isDir.boolValue {
                // 目录：真实目录 + 内部逐文件镜像（应用逐组件改名）
                try? fm.createDirectory(at: linkURL, withIntermediateDirectories: true)
                guard mirrorTree(source: source, into: linkURL, overrides: nameOverrides) else { return nil }
            } else {
                try? fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try fm.createSymbolicLink(at: linkURL, withDestinationURL: source)
                } catch {
                    return nil
                }
            }
        }
        if let appleDouble {
            do {
                try fm.createSymbolicLink(
                    at: shadow.appendingPathComponent("__MACOSX"), withDestinationURL: appleDouble
                )
            } catch {
                return nil
            }
        }
        return shadow
    }

    /// 把目录内容镜像为「真实目录 + 文件符号链接」树，相对路径逐组件应用改名映射。
    private static func mirrorTree(source: URL, into target: URL, overrides: [String: String]) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return false
        }
        let base = source.standardizedFileURL.path
        for case let child as URL in enumerator {
            let childPath = child.standardizedFileURL.path
            guard childPath.hasPrefix(base + "/") else { continue }
            let relative = String(childPath.dropFirst(base.count + 1))
            let mapped = applyingComponentOverrides(relative, overrides)
            let dest = target.appendingPathComponent(mapped)
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            } else {
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try fm.createSymbolicLink(at: dest, withDestinationURL: child)
                } catch {
                    return false
                }
            }
        }
        return true
    }

    /// 相对路径逐组件应用改名映射（"a/CON.txt" + [CON: CON_] → "a/CON_.txt"）。
    static func applyingComponentOverrides(_ name: String, _ overrides: [String: String]) -> String {
        guard !overrides.isEmpty else { return name }
        return name.split(separator: "/", omittingEmptySubsequences: true)
            .map { overrides[String($0)] ?? String($0) }
            .joined(separator: "/")
    }

    /// 同步执行外部工具（无输出回传，用于 ditto / 元数据提取）。
    private static func runTool(_ tool: URL, _ arguments: [String], currentDirectory: URL) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // 元数据是尽力而为：失败不影响正文打包
        }
    }

    /// 所有条目的公共祖先目录（含单条目时取其父目录）。
    public static func commonAncestor(of items: [URL]) -> URL {        let paths = items.map { $0.standardizedFileURL.deletingLastPathComponent().path }
        guard let first = paths.first else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        var common = first.split(separator: "/").map(String.init)
        for path in paths.dropFirst() {
            let parts = path.split(separator: "/").map(String.init)
            var i = 0
            while i < common.count, i < parts.count, common[i] == parts[i] { i += 1 }
            common = Array(common.prefix(i))
        }
        return URL(fileURLWithPath: "/" + common.joined(separator: "/"), isDirectory: true)
    }

    private static func runStep(
        _ binary: URL, _ arguments: [String], workDir: URL,
        totalBytes: Int64 = 0, progress: (@Sendable (CreationProgress) -> Void)? = nil
    ) throws {
        let result = runProcess(binary, arguments, currentDirectory: workDir) { line in
            if let progress, let fraction = lastPercent(in: line) {
                progress(makeProgress(fraction: fraction * 0.7, totalBytes: totalBytes))
            }
            return !Task.isCancelled
        }
        if result.status == -2 { throw ArchiveEngineError.cancelled }
        guard result.status == 0 else {
            throw ArchiveEngineError.creationFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 与 SevenZipReader.run 同构的进程执行（额外支持工作目录）。
    /// mergeStderr：把 stderr 并入 stdout 一起逐行回传（bsdtar 的 -v 清单输出在 stderr），
    /// 此时非 "a " 前缀的行会被收集进返回值的 stderr。
    @discardableResult
    private static func runProcess(
        _ binary: URL,
        _ arguments: [String],
        currentDirectory: URL,
        mergeStderr: Bool = false,
        onStdoutLine: @escaping (String) -> Bool
    ) -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = mergeStderr ? stdoutPipe : stderrPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }

        var cancelled = false
        var mergedStderr: [String] = []
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
            while let sep = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D || $0 == 0x08 }) {
                let lineData = buffer[buffer.startIndex..<sep]
                buffer.removeSubrange(buffer.startIndex...sep)
                let line = String(decoding: lineData, as: UTF8.self)
                if mergeStderr, !line.isEmpty, !line.hasPrefix("a ") {
                    mergedStderr.append(line)
                }
                if !onStdoutLine(line) {
                    cancelled = true
                    process.terminate()
                    break
                }
            }
            if cancelled { break }
        }
        let stderr = mergeStderr
            ? mergedStderr.joined(separator: "\n")
            : String(
                decoding: (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data(),
                as: UTF8.self
            )
        if !cancelled { process.waitUntilExit() }
        return (cancelled ? -2 : process.terminationStatus, stderr)
    }
}
