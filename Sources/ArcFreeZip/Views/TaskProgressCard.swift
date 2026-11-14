import AppKit
import SwiftUI

/// 独占进度卡（「正在压缩」浮窗）：
/// 应用图标（右下角小角标标出任务类型）+ 标题/文件名 + 红色取消按钮 /
/// 主题色进度条 + 百分比 + 已处理字节。
/// 创建与解压共用同一套外观，只换标题与细节文案。
struct TaskProgressCard: View {
    var symbol: String
    var title: String
    var name: String
    var fraction: Double
    var detail: String?
    var onCancel: () -> Void

    private var percent: Int { min(100, max(0, Int((fraction * 100).rounded()))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                // 应用图标 + 任务类型角标（解压/压缩）
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 14, height: 14)
                        .background(Theme.accent, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.cardBackground, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button(action: onCancel) {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("取消")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.78, green: 0.20, blue: 0.20), in: Capsule())
                }
                .buttonStyle(.plain)
                .afzHelp("中止当前任务")
            }

            HStack(spacing: 12) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.dividerColor)
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
                    }
                }
                .frame(height: 8)

                Text("\(percent)%")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, alignment: .trailing)
            }

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 480)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.dividerColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

/// 字节文案（「139.5 MB」）。
func afzByteText(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    return formatter.string(fromByteCount: bytes)
}

/// 保存修改进度卡：重写压缩包分两段（解出原有条目 / 重新打包 / 写入原文件），
/// 阶段之间耗时差异大，用旋转指示器 + 阶段文案，而不是一条永远走不满的进度条。
struct SaveProgressCard: View {
    var phase: String
    var name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 14, height: 14)
                        .background(Theme.accent, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.cardBackground, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("正在保存修改")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                Text(phase)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 420)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.dividerColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}
