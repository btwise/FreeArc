import Foundation

/// Flow 智能推荐（Flow："根据压缩包内容，推荐此刻最合适的操作"）。
/// 纯判定引擎：输入条目树与当前选中，输出「主推荐 + 备选」动作列表，不依赖 UI。
/// 执行统一由 ArchiveBrowser.runFlowAction 完成。
enum FlowAction: Equatable {
    /// 包内有 .pkg/.mpkg 安装包 → 交给 macOS 安装器
    case installPackages([String])
    /// 包内有 .app → 安装到 /Applications
    case installApps([String])
    /// 包内有 .ttf/.otf → 交给系统字体册
    case installFonts([String])
    /// 整包只有一个常规文件（白名单格式）→ 用系统默认应用打开
    case openFile(path: String, name: String)
    /// 有选中条目 → 只解压所选
    case extractSelection

    var label: String {
        switch self {
        case .installPackages(let pkgs):
            pkgs.count > 1 ? "安装 \(pkgs.count) 个软件包" : "安装软件包"
        case .installApps(let apps):
            apps.count > 1 ? "安装 \(apps.count) 个应用" : "安装应用"
        case .installFonts(let fonts):
            fonts.count > 1 ? "安装 \(fonts.count) 个字体" : "安装字体"
        case .openFile(_, let name):
            "打开「\(name)」"
        case .extractSelection:
            "解压所选"
        }
    }

    var symbolName: String {
        switch self {
        case .installPackages: "shippingbox.fill"
        case .installApps: "arrow.down.app"
        case .installFonts: "textformat"
        case .openFile: "arrow.up.forward.app"
        case .extractSelection: "square.and.arrow.down"
        }
    }

    var helpText: String {
        switch self {
        case .installPackages:
            "将软件包交给 macOS 安装器"
        case .installApps(let apps):
            apps.count > 1 ? "将 \(apps.count) 个应用安装到「应用程序」文件夹" : "将应用安装到「应用程序」文件夹"
        case .installFonts:
            "将字体交给字体册安装"
        case .openFile:
            "用系统默认应用打开"
        case .extractSelection:
            "只解压选中的条目"
        }
    }
}

enum FlowEngine {
    /// "打开文件" Flow 允许的扩展名白名单（五分类：文档/图像/音频/视频/数据交换；
    /// 后续设置窗口的「Flow → 打开文件」分区绑定此清单）。
    static let openFileWhitelist: Set<String> = [
        // 文档
        "pdf", "txt", "md", "rtf", "csv", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "epub",
        // 图像
        "png", "jpg", "jpeg", "gif", "webp", "heif", "heic", "tiff", "bmp", "svg", "psd",
        // 音频
        "mp3", "m4a", "aac", "wav", "flac", "ogg",
        // 视频
        "mp4", "m4v", "mov", "mkv", "webm", "avi",
        // 数据交换
        "json", "xml", "yaml", "yml", "html", "css",
    ]

    /// 计算推荐动作：返回有序列表，第一个为主推荐，其余为备选；空数组 = 不展示推荐条。
    /// - selectedFiles: 当前选中且可解压的文件节点（浏览器侧已过滤删除/拖入项）
    static func recommendations(root: ArchiveNode, selectedFiles: [ArchiveNode]) -> [FlowAction] {
        var apps: [String] = []
        var fonts: [String] = []
        var pkgs: [String] = []
        collectFeatures(in: root, apps: &apps, fonts: &fonts, pkgs: &pkgs)

        var actions: [FlowAction] = []
        // 优先级：安装包 > 应用 > 字体 > 打开文件 > 解压所选
        // （安装类动作目的性最强；DMG + .app 是最常见的"下载即装"场景）
        if !pkgs.isEmpty { actions.append(.installPackages(pkgs)) }
        if !apps.isEmpty { actions.append(.installApps(apps)) }
        if !fonts.isEmpty { actions.append(.installFonts(fonts)) }
        if let single = singleOpenableFile(at: root) {
            actions.append(.openFile(path: single.path, name: single.name))
        }
        if !selectedFiles.isEmpty {
            actions.append(.extractSelection)
        }
        return actions
    }

    /// 递归收集特征条目；跳过隐藏项（.DS_Store/__MACOSX）、拖入未保存项，
    /// 命中 .app 后不再深入（避免把 bundle 内部文件误当内容）。
    private static func collectFeatures(
        in node: ArchiveNode,
        apps: inout [String],
        fonts: inout [String],
        pkgs: inout [String]
    ) {
        for child in node.children where !FlowEngine.isHiddenName(child.name) && !child.isPendingAdd {
            let ext = (child.name as NSString).pathExtension.lowercased()
            if child.isDirectory {
                if ext == "app" {
                    apps.append(child.path)
                    continue
                }
            } else {
                switch ext {
                case "pkg", "mpkg": pkgs.append(child.path)
                case "ttf", "otf": fonts.append(child.path)
                default: break
                }
            }
            collectFeatures(in: child, apps: &apps, fonts: &fonts, pkgs: &pkgs)
        }
    }

    /// 整包内容（顶层非隐藏项）恰好只有一个常规文件且格式在白名单内 → 推荐"打开文件"。
    private static func singleOpenableFile(at root: ArchiveNode) -> ArchiveNode? {
        let top = root.sortedChildren.filter { !FlowEngine.isHiddenName($0.name) && !$0.isPendingAdd }
        guard top.count == 1, let only = top.first, !only.isDirectory else { return nil }
        let ext = (only.name as NSString).pathExtension.lowercased()
        guard openFileWhitelist.contains(ext) else { return nil }
        return only
    }
}

extension FlowEngine {
    /// 与 ArchiveBrowser.isHiddenName 同口径（macOS 特有隐藏项；此处独立实现避免主线程隔离耦合）
    static func isHiddenName(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "__MACOSX"
    }
}
