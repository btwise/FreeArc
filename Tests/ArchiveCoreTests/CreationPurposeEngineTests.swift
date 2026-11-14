import Testing
import Foundation
@testable import ArchiveCore
@testable import FormatZip

/// 五用途方案端到端引擎测试（方案语义）：
/// · 通用分享：ZIP + 均衡 + 清理辅助文件
/// · Windows 用户：ZIP + 包内文件名修正（影子目录改名）
/// · Mac 之间传递：ZIP + 保留 macOS 辅助文件（AppleDouble __MACOSX）
/// · Linux 与服务器：TAR + 仅打包 + 清理辅助文件 + 保留 Unix 权限
/// · 尽可能小：7Z + 极限 + 4 GB 固实块参数
struct CreationPurposeEngineTests {
    /// 构造统一测试素材：报告.txt / .DS_Store / __MACOSX/._x / CON.txt / sub/nested.txt
    private static func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("afz-engine-tests-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("项目", isDirectory: true)
        let sub = project.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("中文内容 hello".utf8).write(to: project.appendingPathComponent("报告.txt"))
        try Data("junk".utf8).write(to: project.appendingPathComponent(".DS_Store"))
        let macosx = project.appendingPathComponent("__MACOSX", isDirectory: true)
        try FileManager.default.createDirectory(at: macosx, withIntermediateDirectories: true)
        try Data("ad".utf8).write(to: macosx.appendingPathComponent("._报告.txt"))
        try Data("con".utf8).write(to: project.appendingPathComponent("CON.txt"))
        try Data("nested".utf8).write(to: sub.appendingPathComponent("nested.txt"))
        return project
    }

    private static func entryPaths(_ url: URL) throws -> Set<String> {
        let archive = try SevenZipReader.open(url: url, password: nil)
        return Set(archive.entries.filter { !$0.isDirectory }.map(\.path))
    }

    // MARK: 通用分享

    @Test func generalShareZipClean() throws {
        let project = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        let out = project.deletingLastPathComponent().appendingPathComponent("general.zip")
        try SevenZipWriter.create(
            items: [project], to: out,
            options: CreationOptions(level: 5, format: .zip, password: nil, preserveMetadata: false)
        )
        let paths = try Self.entryPaths(out)
        #expect(paths.contains("项目/报告.txt"))
        #expect(paths.contains("项目/sub/nested.txt"))
        // 清理辅助文件：__MACOSX / .DS_Store 不得进包
        #expect(!paths.contains { $0.contains("__MACOSX") })
        #expect(!paths.contains { $0.hasSuffix(".DS_Store") })
        #expect(!paths.contains { $0.contains("._") })
    }

    // MARK: Windows 用户（包内改名）

    @Test func windowsFilenameRepairRenamesInsideArchiveOnly() throws {
        let project = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        let out = project.deletingLastPathComponent().appendingPathComponent("windows.zip")
        try SevenZipWriter.create(
            items: [project], to: out,
            options: CreationOptions(level: 5, format: .zip, password: nil, preserveMetadata: false),
            nameOverrides: ["CON.txt": "CON_.txt"]
        )
        let paths = try Self.entryPaths(out)
        #expect(paths.contains("项目/CON_.txt"))
        #expect(!paths.contains { $0.hasSuffix("CON.txt") })
        // 源文件不受影响
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("CON.txt").path))
        // 改名后内容仍可读出（经解压验证）
        let archive = try SevenZipReader.open(url: out, password: nil)
        let dest = project.deletingLastPathComponent().appendingPathComponent("x-out", isDirectory: true)
        try archive.extract(
            paths: ["项目/CON_.txt"], to: dest, password: nil,
            stripCommonPrefix: false, progress: nil
        )
        let renamed = try Data(contentsOf: dest.appendingPathComponent("项目/CON_.txt"))
        #expect(String(decoding: renamed, as: UTF8.self) == "con")
    }

    // MARK: Mac 之间传递（保留辅助文件）

    @Test func macPurposePreservesAuxiliaries() throws {
        let project = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        let out = project.deletingLastPathComponent().appendingPathComponent("mac.zip")
        try SevenZipWriter.create(
            items: [project], to: out,
            options: CreationOptions(level: 5, format: .zip, password: nil, preserveMetadata: true)
        )
        let paths = try Self.entryPaths(out)
        // 保留 macOS 辅助文件：__MACOSX AppleDouble 必须进包
        #expect(paths.contains { $0.contains("__MACOSX") })
        #expect(paths.contains("项目/报告.txt"))
    }

    // MARK: Linux 与服务器（TAR 仅打包 + 清理 + Unix 属性）

    @Test func linuxPurposeTarPackOnlyAndClean() throws {
        let project = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        let out = project.deletingLastPathComponent().appendingPathComponent("linux.tar")
        try SevenZipWriter.create(
            items: [project], to: out,
            options: CreationOptions(level: 0, format: .tar, password: nil, preserveMetadata: false)
        )
        // 产物必须是合法 tar（bsdtar 能列出）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tf", out.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(listing.contains("项目/报告.txt"))
        #expect(listing.contains("项目/sub/nested.txt"))
        // 清理辅助文件
        #expect(!listing.contains("__MACOSX"))
        #expect(!listing.contains(".DS_Store"))
        // Unix 权限保留（bsdtar 默认记录 mode；644 文件可查）
        let stat = Process()
        stat.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
        let extractDir = project.deletingLastPathComponent().appendingPathComponent("t-out", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        stat.arguments = ["-f", "%Lp", extractDir.appendingPathComponent("项目/报告.txt").path]
        let tar2 = Process()
        tar2.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar2.arguments = ["-xf", out.path, "-C", extractDir.path]
        tar2.standardError = FileHandle.nullDevice
        try tar2.run(); tar2.waitUntilExit()
        let pipe2 = Pipe()
        stat.standardOutput = pipe2
        stat.standardError = FileHandle.nullDevice
        try stat.run(); stat.waitUntilExit()
        let mode = String(decoding: pipe2.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // %Lp 输出权限位（源文件由 Data.write 创建，默认 644）；bsdtar 归档后原样还原
        #expect(mode == "644")
    }

    // MARK: 尽可能小（7Z 极限 + 固实块）

    @Test func smallestPurposeSevenZipMaximal() throws {
        let project = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        let out = project.deletingLastPathComponent().appendingPathComponent("small.7z")
        // 极限档 = -mx=9 -ms=4g -mqs=on（参数由引擎装配，此处验证可执行且产物合法）
        try SevenZipWriter.create(
            items: [project], to: out,
            options: CreationOptions(level: 9, format: .sevenZip, password: nil, preserveMetadata: false)
        )
        let paths = try Self.entryPaths(out)
        #expect(paths.contains("项目/报告.txt"))
        #expect(!paths.contains { $0.contains("__MACOSX") })
        // 极限 7Z 应比不压缩 ZIP 明显更小（文本素材重复度高）
        let zipOut = project.deletingLastPathComponent().appendingPathComponent("store.zip")
        try SevenZipWriter.create(
            items: [project], to: zipOut,
            options: CreationOptions(level: 0, format: .zip, password: nil, preserveMetadata: false)
        )
        let small = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
        let store = (try FileManager.default.attributesOfItem(atPath: zipOut.path)[.size] as? Int64) ?? 0
        #expect(small > 0 && small < store)
    }

    // MARK: 方案默认值与 7zz 参数装配的一致性

    @Test func purposeDefaultsMatchOriginalSemantics() {
        // 强度档位 → 7zz 级别映射
        #expect(CreationStrength.store.mxLevel == 0)
        #expect(CreationStrength.fast.mxLevel == 1)
        #expect(CreationStrength.balanced.mxLevel == 5)
        #expect(CreationStrength.small.mxLevel == 7)
        #expect(CreationStrength.max.mxLevel == 9)
        // 档位词（字符串表）
        #expect(CreationStrength.store.word == "仅打包")
        #expect(CreationStrength.fast.word == "更快")
        #expect(CreationStrength.balanced.word == "均衡")
        #expect(CreationStrength.small.word == "更小")
        #expect(CreationStrength.max.word == "极限")
        // 7Z 固实参数（文案 128MB / 1GB / 4GB）
        #expect(CreationStrength.fast.sevenZipSolidArgs == ["-ms=off"])
        #expect(CreationStrength.balanced.sevenZipSolidArgs == ["-ms=128m", "-mqs=on"])
        #expect(CreationStrength.small.sevenZipSolidArgs == ["-ms=1g", "-mqs=on"])
        #expect(CreationStrength.max.sevenZipSolidArgs == ["-ms=4g", "-mqs=on"])
        // 格式能力：仅 ZIP/7Z 可创建、可分卷；TAR 不可分卷、不可加密
        #expect(CreationFormat.creatableFormats == [.zip, .sevenZip, .tar])
        #expect(CreationFormat.tar.supportsSplit == false)
        #expect(CreationFormat.tar.supportsEncryption == false)
        #expect(CreationFormat.zip.supportsSplit && CreationFormat.sevenZip.supportsSplit)
    }

    // MARK: Windows 文件名检测规则

    @Test func windowsSuggestedNameRules() {
        #expect(windowsSuggestedName("ok.txt") == nil)
        #expect(windowsSuggestedName("a:b.txt") == "a_b.txt")
        #expect(windowsSuggestedName("name?.txt") == "name_.txt")
        #expect(windowsSuggestedName("trailing. ") == "trailing")
        #expect(windowsSuggestedName("CON") == "CON_")
        #expect(windowsSuggestedName("con.txt") == "con_.txt")
        #expect(windowsSuggestedName("NUL") == "NUL_")
        #expect(windowsSuggestedName("COM1.log") == "COM1_.log")
        #expect(windowsSuggestedName("正常文件.txt") == nil)
    }
}
