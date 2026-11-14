import SwiftUI

// MARK: - 开源组件目录与许可窗口（关于页「查看开源许可」）

/// 单个开源组件条目：名称 / 版本 / 项目地址 / 许可证 / 用途 / 许可全文。
struct OSSComponent: Identifiable, Hashable {
    let name: String
    let version: String
    let projectURL: String?
    let licenseName: String
    let usage: String
    let licenseFullText: String

    var id: String { name }
}

@MainActor
enum OpenSourceCatalog {

    /// 7-Zip 许可全文随应用分发（7zz-License.txt），运行时读取。
    private static func sevenZipLicenseText() -> String {
        if let url = Bundle.main.url(forResource: "7zz-License", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            return text
        }
        return "许可全文随应用分发（应用资源 7zz-License.txt）。"
    }

    static let components: [OSSComponent] = [
        OSSComponent(
            name: "ZIPFoundation",
            version: "本地内置",
            projectURL: "https://github.com/weichsel/ZIPFoundation",
            licenseName: "MIT",
            usage: "原生 ZIP 压缩包读取与写入引擎，负责 ZIP 格式的浏览、解压与打包。以本地 vendoring 方式随源码分发，保证构建离线可复现。",
            licenseFullText: """
            MIT License

            Copyright (c) 2017-2024 Thomas Zoechling (https://www.peakstep.com)

            Permission is hereby granted, free of charge, to any person obtaining a copy
            of this software and associated documentation files (the "Software"), to deal
            in the Software without restriction, including without limitation the rights
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
            copies of the Software, and to permit persons to whom the Software is
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all
            copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
            AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
            LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
            OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
            SOFTWARE.
            """
        ),
        OSSComponent(
            name: "7-Zip（7zz）",
            version: "25.01",
            projectURL: "https://www.7-zip.org",
            licenseName: "GNU LGPL 2.1 及其后版本（含 unRAR 限制）",
            usage: "7z / RAR / ISO / CAB 等格式的解压与压缩内核，以独立命令行进程 7zz 随应用分发。许可全文随附于应用资源（7zz-License.txt）。",
            licenseFullText: sevenZipLicenseText()
        ),
        OSSComponent(
            name: "libarchive / bsdtar",
            version: "macOS 系统自带",
            projectURL: "https://www.libarchive.org",
            licenseName: "BSD 2-Clause",
            usage: "TAR 及压缩 TAR 变体的解压内核（调用 macOS 系统自带的 bsdtar 命令行工具，不随应用额外分发）。",
            licenseFullText: """
            Copyright (c) 2003-2024 The libarchive project contributors.
            All rights reserved.

            Redistribution and use in source and binary forms, with or without
            modification, are permitted provided that the following conditions
            are met:

            1. Redistributions of source code must retain the above copyright
               notice, this list of conditions and the following disclaimer.
            2. Redistributions in binary form must reproduce the above copyright
               notice, this list of conditions and the following disclaimer in
               the documentation and/or other materials provided with the
               distribution.

            THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS
            OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
            WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
            ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY
            DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
            DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
            GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
            INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
            IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
            OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN
            IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
            """
        ),
        OSSComponent(
            name: "macOS 系统组件",
            version: "macOS 15",
            projectURL: nil,
            licenseName: "Apple 系统软件许可协议",
            usage: "hdiutil（DMG / ISO 挂载与转换）、QuickLook（文件预览）、AppKit / SwiftUI 等系统框架与命令行工具，随 macOS 分发，受 Apple 系统软件许可约束。",
            licenseFullText: "本应用使用了随 macOS 分发的系统组件（hdiutil、QuickLook、AppKit、SwiftUI 等），这些组件的著作权归 Apple Inc. 所有，受 Apple 系统软件许可协议约束。本应用未对这些组件进行再分发。"
        ),
    ]

    // MARK: 许可窗口（单例复用，与设置窗口同一模式）

    private static var licenseWindow: NSWindow?

    static func showWindow() {
        if let window = licenseWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "开源许可"
        window.minSize = NSSize(width: 580, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: OpenSourceLicensesView())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        licenseWindow = window
    }

    static func closeWindow() {
        licenseWindow?.close()
    }
}

// MARK: - 许可窗口视图（左列表 / 右详情，跟随应用主题）

private struct OpenSourceLicensesView: View {
    @State private var selection = OpenSourceCatalog.components.first?.id

    private var selected: OSSComponent? {
        OpenSourceCatalog.components.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 页头
            VStack(alignment: .leading, spacing: 3) {
                Text("开源许可")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("感谢这些开源项目。以下保留原始版权声明和许可全文。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            HStack(spacing: 0) {
                // 左侧组件列表
                componentList
                    .frame(width: 210)
                Divider()
                // 右侧详情
                if let component = selected {
                    componentDetail(component)
                } else {
                    Text("选择一个组件查看详情")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()

            // 底部：关闭按钮（右下）
            HStack {
                Spacer()
                Button("关闭") { OpenSourceCatalog.closeWindow() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Theme.canvasBackground)
    }

    // 左侧列表（设置侧栏同款选中样式）
    private var componentList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(OpenSourceCatalog.components) { component in
                    Button {
                        selection = component.id
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(component.name)
                                .font(.system(size: 13, weight: selection == component.id ? .medium : .regular))
                                .foregroundStyle(selection == component.id ? Theme.textPrimary : Theme.textSecondary)
                            Text(component.version)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            selection == component.id
                                ? Theme.chipBackground
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .background(Theme.panelBackground)
    }

    // 右侧详情（信息卡 + 许可全文滚动）
    private func componentDetail(_ component: OSSComponent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Text(component.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let url = component.projectURL, let link = URL(string: url) {
                        Link(destination: link) {
                            HStack(spacing: 4) {
                                Image(systemName: "safari")
                                    .font(.system(size: 11))
                                Text("项目主页")
                                    .font(.system(size: 12))
                            }
                        }
                        .buttonStyle(.link)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let url = component.projectURL {
                        detailLine("Project", value: url, monospaced: true)
                    }
                    detailLine("License", value: component.licenseName)
                    detailLine("版本", value: component.version)
                }

                Text(component.usage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text(component.licenseFullText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.cardBackground)
        .id(component.id)  // 切换组件时滚动位置归顶
    }

    private func detailLine(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 64, alignment: .trailing)
            Text(value)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
