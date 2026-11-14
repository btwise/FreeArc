import Foundation

/// 统一的错误呈现模型：**标题 + 具体原因 + 可操作建议**。
///
/// 目的（用户明确要求）：任何流程出错都要给用户一个「说得清、指得出下一步」的交代，
/// 而不是甩一个白版、或者一条只说"失败"的干巴巴文字。
/// 所有失败入口（打开 / 创建 / 解压 / 其它操作）都必须经由这里的工厂方法产生文案。
struct AppFailure: Equatable {
    /// 一句话标题（弹窗标题 / 错误页大标题）
    var title: String
    /// 具体原因（来自内核或系统 error 的原始描述）
    var detail: String
    /// 可操作建议，逐条展示
    var hints: [String]
    /// SF Symbol
    var symbol: String

    /// 弹窗正文：原因 + 建议清单
    var alertText: String {
        guard !hints.isEmpty else { return detail }
        return detail + "\n\n" + hints.map { "• " + $0 }.joined(separator: "\n")
    }

    // MARK: - 工厂

    static func open(_ detail: String) -> AppFailure {
        AppFailure(
            title: "无法打开压缩包",
            detail: detail,
            hints: [
                "文件可能已被移动、重命名或删除",
                "压缩包可能下载不完整或已损坏",
                "加密压缩包需要输入正确密码",
                "分卷压缩包请选择第一卷（.001）"
            ],
            symbol: "exclamationmark.triangle"
        )
    }

    static func create(_ detail: String) -> AppFailure {
        AppFailure(
            title: "创建压缩包失败",
            detail: detail,
            hints: [
                "检查目标文件夹是否有写入权限、磁盘空间是否充足",
                "源文件可能正在被其它程序占用",
                "文件名不能包含特殊字符"
            ],
            symbol: "exclamationmark.triangle"
        )
    }

    static func extract(_ detail: String) -> AppFailure {
        AppFailure(
            title: "解压失败",
            detail: detail,
            hints: [
                "目标位置可能没有写入权限或磁盘空间不足",
                "压缩包可能已损坏，或与当前内核不兼容",
                "加密压缩包密码错误时会解压失败"
            ],
            symbol: "exclamationmark.triangle"
        )
    }

    /// 其它操作（重命名、保存改写、安装等）：沿用同一套呈现，只换标题。
    static func operation(_ title: String, _ detail: String, hints: [String] = []) -> AppFailure {
        AppFailure(
            title: title,
            detail: detail,
            hints: hints.isEmpty ? ["可稍后重试；若持续失败，请检查文件权限与磁盘空间"] : hints,
            symbol: "exclamationmark.triangle"
        )
    }
}
