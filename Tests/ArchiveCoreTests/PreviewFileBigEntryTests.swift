import XCTest
import ArchiveCore
import FormatZip

/// 临时复现：Movies.zip 中 1.37GB 视频条目 previewFile 管线截断问题（本地大文件调试用）。
final class PreviewFileBigEntryTests: XCTestCase {
    private let movieZip = URL(fileURLWithPath: "/Users/btwise/Movies/Movies.zip")
    private let entryPath = "网络测试工具箱.mp4"

    func testPreviewFileBigVideo() throws {
        guard FileManager.default.fileExists(atPath: movieZip.path) else {
            throw XCTSkip("本地调试样本不存在，跳过")
        }
        let reader = try ZipArchiveReader.open(url: movieZip, password: nil)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("afz-repro-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try reader.previewFile(path: entryPath, cacheDirectory: dir)
        XCTAssertNotNil(url, "previewFile 返回 nil")
        let size = (try? FileManager.default.attributesOfItem(atPath: url!.path)[.size] as? Int64) ?? -1
        print("== previewFile artifact size = \(size)")
        XCTAssertEqual(size, 1_369_698_950, "解压产物应为完整 1.37GB")
    }

    func testExtractBigVideoDirectly() throws {
        guard FileManager.default.fileExists(atPath: movieZip.path) else {
            throw XCTSkip("本地调试样本不存在，跳过")
        }
        let reader = try ZipArchiveReader.open(url: movieZip, password: nil)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("afz-repro2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try reader.extract(paths: [entryPath], to: dir, password: nil, stripCommonPrefix: true, progress: nil)
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [URLResourceKey.fileSizeKey])
        while let item = enumerator?.nextObject() as? URL {
            let size = (try? item.resourceValues(forKeys: [URLResourceKey.fileSizeKey]).fileSize) ?? -1
            print("== extract produced: \(item.lastPathComponent) size=\(size)")
        }
    }
}
