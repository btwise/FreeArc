import Foundation
import ZIPFoundation

/// ZIP 改写支持（M2：包内删除 / 保存修改）。
public enum ZipArchiveWriter {
    /// 把目录内容打包为 zip：目录内相对路径作为条目路径，deflate 压缩。
    /// 空目录以目录条目写入；中央目录由 ZIPFoundation 在每次 addEntry 时落盘。
    public static func packDirectory(_ directory: URL, to output: URL) throws {
        let archive = try Archive(url: output, accessMode: .create)
        // /tmp 等符号链接目录会导致枚举路径与基准路径前缀不一致，先标准化
        let base = directory.standardizedFileURL
        let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var urls: [URL] = []
        while let next = enumerator?.nextObject() as? URL {
            urls.append(next)
        }
        // 字典序保证父目录条目先于其内容写入
        for fileURL in urls.sorted(by: { $0.path < $1.path }) {
            let relative = String(fileURL.standardizedFileURL.path.dropFirst(base.path.count + 1))
            try archive.addEntry(with: relative, relativeTo: base, compressionMethod: .deflate)
        }
    }
}
