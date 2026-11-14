import Foundation
import Security
import Testing
@testable import ArchiveCore
@testable import FormatZip

/// 分卷收尾归一：按大小分卷时只切出一卷 → 产物改名为普通压缩包名（不带 .001）；
/// 真正切出多卷 → 保留编号。目标地址被占用时不动。
struct VolumeCollapseTests {

    private func tempRoot(_ tag: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("afz-volume-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("单卷：分卷开启但只生成 .001 → 改名为普通压缩包名")
    func singleVolumeCollapsesToPlainName() throws {
        let root = tempRoot("single")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("a.txt")
        try "hello".write(to: src, atomically: true, encoding: .utf8)
        let dest = root.appendingPathComponent("out.zip")

        // 1m 分卷 + 极小内容 → 只会有一卷
        try SevenZipWriter.create(
            items: [src], to: dest,
            options: CreationOptions(format: .zip), splitSize: "1m"
        )
        // 前置确认：7zz 确实以分卷形态落盘（out.zip.001 存在、本体不存在）
        #expect(FileManager.default.fileExists(atPath: dest.path + ".001"))
        #expect(!FileManager.default.fileExists(atPath: dest.path))

        let product = ArchiveVolume.collapseSingleVolume(for: dest)
        #expect(product == dest)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(!FileManager.default.fileExists(atPath: dest.path + ".001"))
    }

    @Test("多卷：存在 .002 → 保留编号，不改名")
    func multiVolumeKeepsNumbering() throws {
        let root = tempRoot("multi")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("blob.bin")
        // 2.5 MB 真随机数据（不可压）+ 1m 分卷 → 必然多卷
        var data = Data(count: 2_500_000)
        data.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, buf.count, buf.baseAddress!)
        }
        try data.write(to: src)
        let dest = root.appendingPathComponent("out.zip")

        try SevenZipWriter.create(
            items: [src], to: dest,
            options: CreationOptions(format: .zip), splitSize: "1m"
        )
        #expect(FileManager.default.fileExists(atPath: dest.path + ".001"))
        #expect(FileManager.default.fileExists(atPath: dest.path + ".002"))

        let product = ArchiveVolume.collapseSingleVolume(for: dest)
        #expect(product == URL(fileURLWithPath: dest.path + ".001"))
        #expect(FileManager.default.fileExists(atPath: dest.path + ".001"))
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("目标被占用：destination 已存在 → 不覆盖，保持首卷原样")
    func occupiedDestinationIsLeftAlone() throws {
        let root = tempRoot("occupied")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("out.zip.001")
        try "volume-data".write(to: first, atomically: true, encoding: .utf8)
        let dest = root.appendingPathComponent("out.zip")
        try "OLD-ARCHIVE".write(to: dest, atomically: true, encoding: .utf8)

        let product = ArchiveVolume.collapseSingleVolume(for: dest)
        #expect(product == first)
        #expect((try? String(contentsOf: dest, encoding: .utf8)) == "OLD-ARCHIVE")
    }
}
