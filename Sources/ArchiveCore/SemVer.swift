import Foundation

/// 语义化版本解析与比较（更新检查、发布号对齐都用它）。
/// 接受 "v1.2.0" / "1.2" / "1.2.0-beta.1" 这类常见写法；缺失段补 0，
/// 预发布/构建后缀在比较时忽略（发布纪律：主版本号向前走，不带后缀发正式版）。
public enum SemVer {
    /// 解析失败返回 nil。
    public static func parse(_ raw: String) -> [Int]? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // 去掉预发布与构建元数据后缀（1.2.0-beta.1 / 1.2.0+build42 → 1.2.0）
        s = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? s
        let parts = s.split(separator: ".")
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        return numbers
    }

    /// 逐段比较（补齐到 3 段）；任一侧无法解析按相等处理（不弹假更新）。
    public static func compare(_ a: String, to b: String) -> ComparisonResult {
        guard let va = parse(a), let vb = parse(b) else { return .orderedSame }
        for i in 0..<3 {
            if va[i] < vb[i] { return .orderedAscending }
            if va[i] > vb[i] { return .orderedDescending }
        }
        return .orderedSame
    }

    /// 规范化展示文案（"v1.2" → "1.2.0"）；解析失败原样返回。
    public static func normalized(_ raw: String) -> String {
        guard let numbers = parse(raw) else { return raw }
        return numbers.prefix(3).map(String.init).joined(separator: ".")
    }
}
