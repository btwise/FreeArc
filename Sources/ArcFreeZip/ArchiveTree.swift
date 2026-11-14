import Foundation
import ArchiveCore

/// 归档内目录树节点（由扁平条目列表构建，用于面包屑导航）。
/// 纯值类型：嵌套浏览的层快照需要跨并发域传递，显式声明 Sendable。
struct ArchiveNode: Identifiable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    var entry: ArchiveEntry?
    var children: [ArchiveNode] = []
    /// 拖入添加的外部文件/目录（数据不在压缩包 reader 里，保存时从磁盘源复制）。
    var isPendingAdd: Bool = false

    var id: String { path.isEmpty ? "/" : path }

    /// 插入一个扁平路径。
    mutating func insert(path: String, entry: ArchiveEntry) {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        insert(components: components, entry: entry)
    }

    private mutating func insert(components: [String], entry: ArchiveEntry) {
        guard let first = components.first else { return }
        let childPath = path.isEmpty ? first : path + "/" + first
        if components.count == 1 {
            if let idx = children.firstIndex(where: { $0.path == childPath }) {
                children[idx].entry = entry
            } else {
                children.append(
                    ArchiveNode(name: first, path: childPath, isDirectory: entry.isDirectory, entry: entry)
                )
            }
            return
        }
        // 中间目录：若压缩包没有显式的目录条目也照常生成。
        if let idx = children.firstIndex(where: { $0.path == childPath }) {
            children[idx].insert(components: Array(components.dropFirst()), entry: entry)
        } else {
            var dir = ArchiveNode(name: first, path: childPath, isDirectory: true, entry: nil)
            dir.insert(components: Array(components.dropFirst()), entry: entry)
            children.append(dir)
        }
    }

    /// 目录在前、按名称排序。
    var sortedChildren: [ArchiveNode] {
        children.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func node(atPath path: String) -> ArchiveNode? {
        if path == self.path || (path.isEmpty && self.path.isEmpty) { return self }
        for child in children {
            if path == child.path || path.hasPrefix(child.path + "/") {
                return child.node(atPath: path)
            }
        }
        return nil
    }

    // MARK: 包内编辑（显示层改名 / 外部添加节点维护）

    /// 显示层重命名：只替换目标节点的 name，path 保持原值——
    /// 预览/解压/保存按原路径取数，改名在保存落盘时才真正应用。
    func withRenamedNode(at path: String, name newName: String) -> ArchiveNode {
        guard path != self.path else {
            return ArchiveNode(
                name: newName, path: path, isDirectory: isDirectory,
                entry: entry, children: children, isPendingAdd: isPendingAdd
            )
        }
        var copy = self
        for i in copy.children.indices
        where path == copy.children[i].path || path.hasPrefix(copy.children[i].path + "/") {
            copy.children[i] = copy.children[i].withRenamedNode(at: path, name: newName)
        }
        return copy
    }

    /// 移除节点（撤销拖入添加用）。
    func removingNode(at path: String) -> ArchiveNode {
        var copy = self
        copy.children.removeAll { $0.path == path }
        for i in copy.children.indices
        where path.hasPrefix(copy.children[i].path + "/") {
            copy.children[i] = copy.children[i].removingNode(at: path)
        }
        return copy
    }

    /// 给指定路径的节点打上 isPendingAdd 标记（含其全部子节点）。
    func markingPendingAdd(from path: String) -> ArchiveNode {
        var copy = self
        if let idx = copy.children.firstIndex(where: { $0.path == path }) {
            copy.children[idx].markSubtreePendingAdd()
            return copy
        }
        for i in copy.children.indices
        where path.hasPrefix(copy.children[i].path + "/") {
            copy.children[i] = copy.children[i].markingPendingAdd(from: path)
        }
        return copy
    }

    private mutating func markSubtreePendingAdd() {
        isPendingAdd = true
        for i in children.indices { children[i].markSubtreePendingAdd() }
    }

    /// 收集子树内全部 isPendingAdd 节点路径。
    func collectPendingAddPaths(into result: inout Set<String>) {
        for child in children {
            if child.isPendingAdd { result.insert(child.path) }
            child.collectPendingAddPaths(into: &result)
        }
    }
}
