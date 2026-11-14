import Testing
import Foundation
import ZIPFoundation
@testable import ArchiveCore
@testable import FormatZip

/// 2026-11-06 安全修复回归（自包含，不依赖外部素材）：
/// 1. zip-slip：含 ../ 条目的压缩包在列目录阶段被整体拒绝（既有防护）+ 解压期闸门（纵深防御）
/// 2. DMG 解压：目标目录已有同名文件时不删除不覆盖，以唯一名落盘
/// 3. 打包：先压到临时目标再替换——压缩失败不碰用户原有压缩包，成功才替换
@Suite("安全修复回归")
struct SafetyFixTests {

    /// 造一个含目录穿越条目的恶意 zip。
    private func makeEvilZip(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: "ok.txt", type: .file, uncompressedSize: Int64(4),
                             provider: { _, _ in Data("fine".utf8) })
        // 直接写入越界条目名（ZIPFoundation 允许任意 entry 名）
        try archive.addEntry(with: "../../../../afz-slip-ESCAPED.txt", type: .file, uncompressedSize: Int64(4),
                             provider: { _, _ in Data("evil".utf8) })
    }

    /// 用 hdiutil 造一个小 DMG（含 note.txt）。
    /// 不用 -srcfolder（部分系统状态下会"资源忙"）：建空盘 → 挂载写入 → 卸载 → 转 UDZO。
    private func makeSampleDMG(at url: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("afz-dmgbuild-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        func runHDIUtil(_ args: [String]) throws {
            let run = Process()
            run.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            run.arguments = args
            try run.run()
            run.waitUntilExit()
            guard run.terminationStatus == 0 else {
                throw ArchiveEngineError.unreadable("hdiutil \(args.first ?? "") 失败")
            }
        }

        let blank = work.appendingPathComponent("blank.dmg")
        try runHDIUtil(["create", "-size", "1m", "-fs", "HFS+", "-volname", "VOL", blank.path])
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try runHDIUtil(["attach", blank.path, "-mountpoint", mount.path, "-quiet"])
        defer { try? runHDIUtil(["detach", mount.path, "-quiet"]) }
        try "DMG-CONTENT".write(to: mount.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try? runHDIUtil(["detach", mount.path, "-quiet"])
        try runHDIUtil(["convert", blank.path, "-format", "UDZO", "-o", url.path, "-quiet"])
    }

    @Test("zip-slip：../ 条目被拒绝且不逃逸")
    func zipSlip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("afz-slip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let evil = root.appendingPathComponent("evil.zip")
        try makeEvilZip(at: evil)
        // 列目录阶段即拒绝整个包（既有防护：条目名含 ../ 直接 unreadable）
        #expect(throws: Error.self) {
            _ = try ZipArchiveReader(url: evil)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("afz-slip-ESCAPED.txt").path))
    }

    @Test("DMG 解压：目标同名文件不删除，唯一名落盘")
    func dmgNoOverwrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("afz-dmg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dmg = root.appendingPathComponent("sample.dmg")
        try makeSampleDMG(at: dmg)

        let dest = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try "USER-ORIGINAL".write(to: dest.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let reader = try DmgArchiveReader(url: dmg, verifyProgress: nil, skipRequested: { true })
        try reader.extract(paths: ["note.txt"], to: dest, password: nil, stripCommonPrefix: false, progress: nil)
        let content = (try? String(contentsOf: dest.appendingPathComponent("note.txt"), encoding: .utf8)) ?? ""
        #expect(content == "USER-ORIGINAL")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []
        #expect(names.contains("note 2.txt"))
    }

    /// 用系统 zip 造一个带整包备注的 zip（备注常被用来放解压密码）。
    @Test("ZIP 备注：EOCD 注释可读取；无备注包返回 nil")
    func zipComment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("afz-comment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("note.txt")
        try "hello".write(to: src, atomically: true, encoding: .utf8)

        func runZip(_ args: [String], stdin: String?) throws {
            let run = Process()
            run.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            run.arguments = args
            run.currentDirectoryURL = root
            if let stdin {
                let pipe = Pipe()
                run.standardInput = pipe
                try pipe.fileHandleForWriting.write(Data(stdin.utf8))
                try pipe.fileHandleForWriting.close()
            }
            try run.run()
            run.waitUntilExit()
            guard run.terminationStatus == 0 else {
                throw ArchiveEngineError.unreadable("zip \(args.first ?? "") 失败")
            }
        }

        // 带备注包
        let noted = root.appendingPathComponent("noted.zip")
        try runZip(["-q", "noted.zip", "note.txt"], stdin: nil)
        try runZip(["-z", "noted.zip"], stdin: "解压密码: p@ss123\n备用密码: 0000\n")
        let comment = ZipArchiveCommentReader.comment(in: noted)
        #expect(comment?.contains("p@ss123") == true)
        #expect(comment?.contains("备用密码: 0000") == true)

        // 无备注包 → nil
        let plain = root.appendingPathComponent("plain.zip")
        try runZip(["-q", "plain.zip", "note.txt"], stdin: nil)
        #expect(ZipArchiveCommentReader.comment(in: plain) == nil)
    }

    @Test("打包：失败不碰旧包 / 成功替换目标")
    func packReplace() throws {        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("afz-pack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("out.zip")
        try "PREVIOUS-ARCHIVE".write(to: out, atomically: true, encoding: .utf8)

        // 失败场景：源不存在 → 抛错且旧包原样
        #expect(throws: Error.self) {
            try SevenZipWriter.create(
                items: [root.appendingPathComponent("not-exist")],
                to: out, options: CreationOptions(format: .zip)
            )
        }
        #expect((try? String(contentsOf: out, encoding: .utf8)) == "PREVIOUS-ARCHIVE")

        // 成功场景：目标已存在 → 被新包替换
        let src = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "hello".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try SevenZipWriter.create(items: [src], to: out, options: CreationOptions(format: .zip))
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size]) as? Int64 ?? 0
        #expect(size > 100)
        #expect((try? String(contentsOf: out, encoding: .utf8)) != "PREVIOUS-ARCHIVE")
    }

    @Test("归档级备注：RAR/7z -slt 的 Comment 解析（单行/多行/无备注）")
    func archiveCommentParsing() {
        let block = [
            "Path = /tmp/x.rar",
            "Type = Rar5",
            "Characteristics = Locator QuickOpen:5 Comment",
            "Comment = 解压密码：123456",
            "第二行备注",
            "Blocks = 8"
        ]
        #expect(SevenZipReader.parseArchiveComment(from: block) == "解压密码：123456\n第二行备注")
        #expect(SevenZipReader.parseArchiveComment(from: ["Path = /x.zip", "Type = zip"]) == nil)
        #expect(SevenZipReader.parseArchiveComment(from: ["Type = 7z", "Comment = "]) == nil)
    }

    @Test("7z 列表：去掉 -ba 后归档级块不污染条目，且条目数正确")
    func sevenZipListingWithInfoBlock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("afz-7zlist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("a.txt")
        try "hello".write(to: src, atomically: true, encoding: .utf8)
        let out = root.appendingPathComponent("t.7z")
        try SevenZipWriter.create(items: [src], to: out, options: CreationOptions(format: .sevenZip))

        let reader = try SevenZipReader(url: out)
        #expect(reader.entries.filter { !$0.isDirectory }.map(\.path) == ["a.txt"])
        #expect(reader.summary.fileCount == 1)
        #expect(reader.summary.comment == nil)
    }
}
