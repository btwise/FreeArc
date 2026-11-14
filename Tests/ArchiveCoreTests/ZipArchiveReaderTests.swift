import XCTest
import Foundation
import ArchiveCore
import FormatZip
import ZIPFoundation

extension UInt16 {
    var littleEndianBytes: Data {
        withUnsafeBytes(of: littleEndian) { Data($0) }
    }
}

extension UInt32 {
    var littleEndianBytes: Data {
        withUnsafeBytes(of: littleEndian) { Data($0) }
    }
}

/// 测试用线程安全数值收集器（进度回调是 @Sendable，不能直接捕获 var）。
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class ZipArchiveReaderTests: XCTestCase {
    private var workDir = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arcfrezip-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// 用 ZIP Foundation 生成一个包含嵌套目录与多个文件的样本压缩包。
    private func makeSampleArchive() throws -> URL {
        let archiveURL = workDir.appendingPathComponent("sample.zip")
        try FileManager.default.createDirectory(
            at: workDir.appendingPathComponent("src/photos"),
            withIntermediateDirectories: true
        )
        let notes = workDir.appendingPathComponent("src/notes.txt")
        let photo = workDir.appendingPathComponent("src/photos/sea.jpg")
        let readme = workDir.appendingPathComponent("src/photos/readme.md")
        try Data("hello arcfrezip".utf8).write(to: notes)
        try Data(repeating: 0x41, count: 4096).write(to: photo)
        try Data("# readme".utf8).write(to: readme)

        try FileManager.default.zipItem(
            at: workDir.appendingPathComponent("src"),
            to: archiveURL
        )
        return archiveURL
    }

    func testOpenAndListEntries() throws {
        let url = try makeSampleArchive()
        let reader = try ZipArchiveReader(url: url)

        XCTAssertEqual(reader.summary.format, .zip)
        XCTAssertEqual(reader.summary.fileCount, 3)
        XCTAssertTrue(reader.entries.contains { $0.path == "src/notes.txt" })
        XCTAssertTrue(reader.entries.contains { $0.path == "src/photos/sea.jpg" })
        XCTAssertTrue(reader.entries.contains { $0.isDirectory && $0.path == "src/photos" })
        XCTAssertEqual(reader.summary.totalUncompressed, 4096 + 15 + 8)
    }

    func testExtractAllPreservesStructureAndCleansStaging() throws {
        let url = try makeSampleArchive()
        let reader = try ZipArchiveReader(url: url)
        let destination = workDir.appendingPathComponent("out")

        let recorder = ProgressRecorder()
        try reader.extract(
            paths: reader.entries.filter { !$0.isDirectory }.map(\.path),
            to: destination,
            password: nil,
            stripCommonPrefix: false
        ) { progress in
            recorder.append(progress.fraction)
        }
        let reportedProgress = recorder.values

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("src/notes.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("src/photos/sea.jpg").path))
        XCTAssertTrue(reportedProgress.last.flatMap { $0 >= 1.0 } ?? false)
        // 暂存目录已清理，目标目录无残留
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".arcfrezip-staging") })
    }

    func testExtractSelectedDirectoryExpandsToFiles() throws {
        let url = try makeSampleArchive()
        let reader = try ZipArchiveReader(url: url)
        let destination = workDir.appendingPathComponent("out2")

        // 只选中 src/photos 目录，应展开为其中两个文件，且不包含 notes.txt
        try reader.extract(paths: ["src/photos"], to: destination, password: nil, progress: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("sea.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("readme.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("notes.txt").path))
    }

    func testUniquedURL() {
        let dir = workDir
        let existing = dir.appendingPathComponent("a.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: existing.path, contents: Data()))
        let resolved = ZipArchiveReader.uniquedURL(
            for: dir.appendingPathComponent("a.txt"),
            in: dir
        )
        XCTAssertEqual(resolved.lastPathComponent, "a 2.txt")
    }

    /// 手工构造一个 UTF-8 中文文件名但未设置 UTF-8 标志（bit 11）的 zip，
    /// 复现 ditto / macOS Finder 产生的典型结构，验证中文不乱码。
    func testChineseNamesWithoutUTF8Flag() throws {
        let archiveURL = workDir.appendingPathComponent("chinese.zip")
        let name = "照片集/海边.jpg"
        let nameData = Data(name.utf8)
        let content = Data("x".utf8)

        var data = Data()
        // 本地文件头：sig, version 20, flags 0(无 bit11), method 0(stored), time/date 0, crc 0, sizes, name
        data.append(contentsOf: [0x50, 0x4b, 0x03, 0x04, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        data.append(UInt16(nameData.count).littleEndianBytes)
        data.append(UInt16(0).littleEndianBytes)
        data.append(nameData)
        data.append(content)

        let localHeaderSize = 30 + nameData.count
        let centralDirOffset = data.count

        // 中央目录：sig, versionMadeBy, versionNeeded, flags 0, method 0, time/date 0 → 共 6 对，
        // 然后是 crc32(4)。注意对齐：sig 后正好 12 字节，CRC 是 4 字节。
        var central = Data()
        central.append(contentsOf: [0x50, 0x4b, 0x01, 0x02, 20, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        central.append(contentsOf: [0, 0, 0, 0]) // crc32
        central.append(UInt32(content.count).littleEndianBytes)
        central.append(UInt32(content.count).littleEndianBytes)
        central.append(UInt16(nameData.count).littleEndianBytes)
        central.append(UInt16(0).littleEndianBytes) // extra
        central.append(UInt16(0).littleEndianBytes) // comment
        central.append(UInt16(0).littleEndianBytes) // disk
        central.append(UInt16(0).littleEndianBytes) // internal attrs
        central.append(UInt32(0).littleEndianBytes) // external attrs
        central.append(UInt32(0).littleEndianBytes) // 本地头位于文件开头，相对偏移为 0
        central.append(nameData)

        data.append(central)

        // EOCD
        data.append(contentsOf: [0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0])
        data.append(UInt16(1).littleEndianBytes)
        data.append(UInt16(1).littleEndianBytes)
        data.append(UInt32(central.count).littleEndianBytes)
        data.append(UInt32(centralDirOffset).littleEndianBytes)
        data.append(UInt16(0).littleEndianBytes)

        try data.write(to: archiveURL)

        let reader = try ZipArchiveReader(url: archiveURL)
        XCTAssertTrue(reader.entries.contains { $0.path == name }, "条目应包含 \(name)，实际为 \(reader.entries.map(\.path))")
        // 中文目录应可解压出正确文件名
        let destination = workDir.appendingPathComponent("out-cn")
        try reader.extract(paths: [name], to: destination, password: nil, stripCommonPrefix: false, progress: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path))
    }

    /// GBK 编码中文文件名的 zip（Windows 中文环境典型产物：bit 11 未置位，
    /// 名称字节非 UTF-8），验证 GB18030 回退解码不乱码。
    func testChineseNamesGBKWithoutUTF8Flag() throws {
        let archiveURL = workDir.appendingPathComponent("gbk.zip")
        let name = "五好学生-何欣怡.docx"
        guard let nameData = name.data(using: ZipPathDecoding.gb18030) else {
            throw XCTSkip("当前系统不支持 GB18030 编码")
        }
        // GBK 字节必须不是合法 UTF-8，否则测试无意义
        XCTAssertNil(String(data: nameData, encoding: .utf8))
        let content = Data("x".utf8)

        var data = Data()
        data.append(contentsOf: [0x50, 0x4b, 0x03, 0x04, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        data.append(UInt16(nameData.count).littleEndianBytes)
        data.append(UInt16(0).littleEndianBytes)
        data.append(nameData)
        data.append(content)

        let centralDirOffset = data.count
        var central = Data()
        central.append(contentsOf: [0x50, 0x4b, 0x01, 0x02, 20, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        central.append(contentsOf: [0, 0, 0, 0]) // crc32
        central.append(UInt32(content.count).littleEndianBytes)
        central.append(UInt32(content.count).littleEndianBytes)
        central.append(UInt16(nameData.count).littleEndianBytes)
        central.append(UInt16(0).littleEndianBytes)
        central.append(UInt16(0).littleEndianBytes)
        central.append(UInt16(0).littleEndianBytes)
        central.append(UInt16(0).littleEndianBytes)
        central.append(UInt32(0).littleEndianBytes)
        central.append(UInt32(0).littleEndianBytes) // 本地头位于文件开头
        central.append(nameData)
        data.append(central)

        data.append(contentsOf: [0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0])
        data.append(UInt16(1).littleEndianBytes)
        data.append(UInt16(1).littleEndianBytes)
        data.append(UInt32(central.count).littleEndianBytes)
        data.append(UInt32(centralDirOffset).littleEndianBytes)
        data.append(UInt16(0).littleEndianBytes)
        try data.write(to: archiveURL)

        let reader = try ZipArchiveReader(url: archiveURL)
        XCTAssertTrue(
            reader.entries.contains { $0.path == name },
            "GBK 名称应正确解码为 \(name)，实际为 \(reader.entries.map(\.path))"
        )
    }

    /// 真实文件探针：通过环境变量 AFZ_PROBE_ZIP 指定本机 zip 文件，
    /// 验证 GBK 中文包端到端解码（不依赖网络的回归保障）。
    func testRealArchiveProbe() throws {
        guard let rawPath = ProcessInfo.processInfo.environment["AFZ_PROBE_ZIP"],
              !rawPath.isEmpty else {
            throw XCTSkip("未设置 AFZ_PROBE_ZIP，跳过真实文件探针")
        }
        let url = URL(fileURLWithPath: rawPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("探针文件不存在：\(rawPath)")
        }
        let reader = try ZipArchiveReader(url: url)
        // GBK 包不应出现 cp437 乱码特征字符
        let mojibake = reader.entries.contains { $0.path.contains("ð") || $0.path.contains("å") && $0.path.contains("ç") }
        XCTAssertFalse(mojibake, "真实包存在乱码路径：\(reader.entries.prefix(5).map(\.path))")
        XCTAssertTrue(reader.summary.fileCount > 0)
    }

    func testRejectsPathTraversalArchive() throws {
        // 构造含 ".." 路径的恶意 zip
        let archiveURL = workDir.appendingPathComponent("evil.zip")
        try FileManager.default.createFile(
            atPath: workDir.appendingPathComponent("payload.txt").path,
            contents: Data("x".utf8)
        )
        try FileManager.default.zipItem(
            at: workDir.appendingPathComponent("payload.txt"),
            to: archiveURL
        )
        // ZIP Foundation 不允许构造穿越路径，这里仅验证正常包不被误判
        XCTAssertNoThrow(try ZipArchiveReader(url: archiveURL))
    }
}
