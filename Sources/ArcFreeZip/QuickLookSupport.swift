import SwiftUI
import AppKit
import AVKit
import QuickLookUI
import QuickLookThumbnailing
import ArchiveCore

// MARK: - 空格键：系统 Quick Look 面板

/// 系统 Quick Look 面板的数据源与开关。
/// 系统面板（QLPreviewPanel）自带缩放、全屏、分享、标记等能力，
/// 这里只负责把「包内解压出来的临时文件」交给它显示。
final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated(unsafe) static let shared = QuickLookPresenter()

    nonisolated(unsafe) private var item: NSURL?

    private override init() { super.init() }

    var isVisible: Bool { QLPreviewPanel.shared()?.isVisible ?? false }

    /// 同一个文件再次触发时关闭面板（空格是开关，与访达一致）。
    func toggle(url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, (item as URL?) == url {
            panel.orderOut(nil)
            item = nil
            return
        }
        item = url as NSURL
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    /// 双击文件：始终把面板显示出来（不因「同一文件再次触发」而收起）。
    /// 面板已可见时只换内容、保持位置；未显示时才居中。
    func show(url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        let wasVisible = panel.isVisible
        item = url as NSURL
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if !wasVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        QLPreviewPanel.shared()?.orderOut(nil)
        item = nil
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        item == nil ? 0 : 1
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        item
    }
}

// MARK: - 悬停悬浮预览

struct HoverPreviewModel {
    let name: String
    let typeText: String
    let sizeText: String
    /// 缩略图/大图（音频试听时置 nil）
    var image: NSImage?
    /// 视频文件（设置开启「在悬浮预览中播放视频」且体积在上限内）自动播放。
    var videoURL: URL?
    /// 视频原始宽高比（按原比例出画面，不裁不黑边）
    var videoAspect: CGFloat?
    /// 音频文件（设置开启「自动播放音频」）悬停试听。
    var audioURL: URL?

    /// 读视频轨道的原始宽高比（考虑旋转矩阵；竖拍视频也正确）。
    static func videoAspectRatio(for url: URL) async -> CGFloat? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let transformed = size.applying(transform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        return height > 0 ? width / height : nil
    }
}

/// 悬停预览的视频播放层：静音跟随设置、悬浮出控制条（可播放/暂停/拖进度）、循环播放。
struct HoverVideoView: NSViewRepresentable {
    let url: URL
    var muted: Bool = AppSettings.hoverVideoMuted

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        // .floating：控制条平时隐藏，鼠标移到画面上才浮出（与访达预览一致）
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        let player = AVPlayer(url: url)
        player.isMuted = muted
        player.actionAtItemEnd = .none
        view.player = player
        context.coordinator.player = player
        context.coordinator.observeLoop()
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            let player = AVPlayer(url: url)
            player.isMuted = muted
            player.actionAtItemEnd = .none
            view.player = player
            context.coordinator.player = player
            context.coordinator.observeLoop()
            player.play()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.stop()
        view.player?.pause()
        view.player = nil
    }

    final class Coordinator {
        var player: AVPlayer?
        private var observer: NSObjectProtocol?

        func observeLoop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let item = player?.currentItem else { return }
            observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                self?.player?.seek(to: .zero)
                self?.player?.play()
            }
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}

/// 悬停预览的音频试听层：AVPlayer 驱动 + 随播放起伏的声浪条（原生 SwiftUI 动画）。
struct HoverAudioView: View {
    let url: URL

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    /// 声浪条相位（0...1 循环），播放中随时间推进。
    @State private var phase: Double = 0
    @State private var isPlaying = false

    private let barCount = 5

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cornerS)
                .fill(Theme.zebraRow)
            HStack(spacing: 5) {
                ForEach(0..<barCount, id: \.self) { index in
                    // 各条相位错开，形成波浪；暂停时回到最小高度
                    let offset = Double(index) * 0.35
                    let level = isPlaying ? abs(sin((phase + offset) * .pi)) : 0.12
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 26 + 58 * level)
                        .animation(.linear(duration: 0.12), value: level)
                }
            }
            Image(systemName: "music.note")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(10)
                .background(Theme.cardBackground, in: Circle())
                .overlay(
                    Circle().strokeBorder(Theme.groupBorderColor, lineWidth: 1)
                )
        }
        .frame(width: 224, height: 268)
        .onAppear(perform: startPlayback)
        .onDisappear(perform: stopPlayback)
    }

    private func startPlayback() {
        let player = AVPlayer(url: url)
        self.player = player
        // 0.1s 轮询推进声浪相位；播放结束后 seek 回起点循环
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { _ in
            guard player.rate > 0 else { return }
            isPlaying = true
            phase += 0.18
            if phase > 1 { phase -= 1 }
        }
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }
        player.play()
    }

    private func stopPlayback() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }
}

/// 悬浮预览（对齐原版交互）：浮层里只有媒体本身——大图/视频/声浪直接撑满，
/// 不叠加文件名、类型、大小等文字（那些信息详情面板里有）。
struct HoverPreviewCard: View {
    let model: HoverPreviewModel

    var body: some View {
        ZStack {
            if let videoURL = model.videoURL {
                // 按视频原始比例给画幅（上限 480×420，避免竖拍视频占满整屏）
                let aspect = model.videoAspect ?? 16.0 / 9.0
                let videoWidth: CGFloat = 480
                let videoHeight = min(max(videoWidth / aspect, 160), 420)
                HoverVideoView(url: videoURL)
                    .frame(width: videoWidth, height: videoHeight)
            } else if let audioURL = model.audioURL {
                HoverAudioView(url: audioURL)
            } else if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: 400, maxHeight: 400)
            } else {
                // 没有缩略图的类型：只显示类型图标，同样不带文字
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.zebraRow)
                    .frame(width: 132, height: 132)
                    .overlay(
                        Image(systemName: EntryIcon.symbol(for: model.name, isDirectory: false))
                            .font(.system(size: 56))
                            .foregroundStyle(Theme.accent)
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomTrailing) {
            // 仅视频显示静音状态角标（跟随「视频默认静音」设置）
            if model.videoURL != nil {
                Image(systemName: AppSettings.hoverVideoMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .padding(8)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
    }
}

/// 无边框浮层窗口承载悬浮预览：不抢焦点、不吃鼠标事件、跟随光标弹出，
/// 显示期间还贴着光标移动（对齐原版：水平/垂直移动预览都跟着走、不消失）。
@MainActor
final class HoverPreviewPanel {
    /// 所有访问点都在主线程（SwiftUI 修饰符/面板自身），static let 随类隔离即可
    static let shared = HoverPreviewPanel()

    private var panel: NSPanel?
    /// 当前展示的模型与尺寸（跟随移动时免重算 fittingSize；可选避免隐式 init 隔离问题）
    private var currentModel: HoverPreviewModel?
    private var currentSize: CGSize?
    private var moveMonitor: Any?
    /// 视频预览可交互：光标能移进画面点播放控制，此时浮层不再跟随、也不自动隐藏
    private var isInteractive = false
    private var cursorInside = false
    private var pendingHide: DispatchWorkItem?

    /// 浮层是否正在显示（跨文件滑动时用短延迟直接换内容）
    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ model: HoverPreviewModel, at mouse: CGPoint) {
        let host = NSHostingView(rootView: HoverPreviewCard(model: model))
        let size = host.fittingSize
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = host
        // 只有视频需要鼠标进入（播放控制）；图片/音频保持穿透，不挡选区与拖拽
        isInteractive = model.videoURL != nil
        cursorInside = false
        pendingHide?.cancel()
        pendingHide = nil
        panel.ignoresMouseEvents = !isInteractive

        panel.setFrame(CGRect(origin: anchor(for: mouse, size: size), size: size), display: true)
        if panel.isVisible {
            panel.alphaValue = 1
        } else {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        currentModel = model
        currentSize = size
        startFollowing()
    }

    /// 锚点：光标右下方（对齐原版：预览从悬停行下方展开），右缘溢出翻到左侧，
    /// 底缘溢出翻到上方，并收进屏幕可见区。
    private func anchor(for mouse: CGPoint, size: CGSize) -> CGPoint {
        var origin = CGPoint(x: mouse.x + 16, y: mouse.y + 20)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.x + size.width > visible.maxX - 8 {
                origin.x = mouse.x - 16 - size.width
            }
            if origin.y + size.height > visible.maxY - 8 {
                origin.y = mouse.y - 10 - size.height
            }
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
            origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
        }
        return origin
    }

    /// 跟随光标：监听鼠标移动，实时把浮层重新锚到光标旁。
    /// 本地监听器只在自家窗口收得到 mouseMoved，需要窗口开启 acceptsMouseMovedEvents；
    /// 结束时必须还原原值——SwiftUI 的 onHover 跟踪依赖它，强设 false 会永久杀死悬停。
    private func startFollowing() {
        guard moveMonitor == nil else { return }
        savedMouseMovedFlags.removeAll()
        for window in NSApp.windows where window.isVisible {
            savedMouseMovedFlags[ObjectIdentifier(window)] = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
        }
        moveMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.followCursor()
            }
            return event
        }
    }

    /// 显示浮层期间各窗口 acceptsMouseMovedEvents 的原值（按窗口对象标识记录）
    private var savedMouseMovedFlags: [ObjectIdentifier: Bool] = [:]

    private func stopFollowing() {
        if let monitor = moveMonitor {
            NSEvent.removeMonitor(monitor)
            moveMonitor = nil
        }
        for (id, flag) in savedMouseMovedFlags {
            if let window = NSApp.windows.first(where: { ObjectIdentifier($0) == id }) {
                window.acceptsMouseMovedEvents = flag
            }
        }
        savedMouseMovedFlags.removeAll()
    }

    /// 把浮层重新锚到当前光标旁（跟随移动只挪位置，不重建内容）。
    /// 视频模式下光标一旦进入画面就停止跟随——否则永远追不上、点不到控制条。
    private func followCursor() {
        guard panel?.isVisible == true, currentModel != nil, let panel else { return }
        let size = currentSize ?? .zero
        let mouse = NSEvent.mouseLocation
        let inside = panel.frame.contains(mouse)
        if inside {
            cursorInside = true
            pendingHide?.cancel()
            pendingHide = nil
            return
        }
        if cursorInside {
            // 从画面移出：视频预览随之收起（与「移开文件就消失」一致）
            cursorInside = false
            hide()
            return
        }
        panel.setFrame(CGRect(origin: anchor(for: mouse, size: size), size: size), display: true)
    }

    /// 光标离开文件后调用：给 0.3 秒宽限，允许光标斜着移进视频画面；
    /// 期间若已进入画面则不隐藏。
    func scheduleHideUnlessHovered() {
        guard isVisible else { return }
        pendingHide?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if panel.frame.insetBy(dx: 8, dy: 8).contains(NSEvent.mouseLocation) { return }
            self.hide()
        }
        pendingHide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func hide() {
        pendingHide?.cancel()
        pendingHide = nil
        cursorInside = false
        currentModel = nil
        stopFollowing()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            // 释放视频播放器，避免悬停离开后继续解码
            panel.contentView = nil
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

/// 在文件名上停留后弹出悬浮预览；移出即消失。
private struct ArchiveHoverPreviewModifier: ViewModifier {
    let browser: ArchiveBrowser
    let node: ArchiveNode
    var delay: UInt64 = 480_000_000

    @State private var hoverTask: Task<Void, Never>?
    @State private var shown = false

    /// 探针调试：AFZ_PROBE=1 时把悬停事件流写到 /tmp/afz-hover.log
    private func probe(_ text: String) {
        guard ProcessInfo.processInfo.environment["AFZ_PROBE"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/afz-hover-probe") else { return }
        let line = "\(Date())  \(text)\n"
        if let handle = FileHandle(forWritingAtPath: "/tmp/afz-hover.log") {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)!.write(to: URL(fileURLWithPath: "/tmp/afz-hover.log"))
        }
    }

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                probe("onHover(\(hovering)) \(node.name)")
                hoverTask?.cancel()
                if hovering {
                    guard !node.isDirectory else { return }
                    // 悬浮预览总开关（设置「通用 → 悬浮预览」）
                    guard AppSettings.hoverPreviewEnabled else { return }
                    // 浮层已开着（正在文件间滑动）：换内容只等 120ms，不闪没
                    let wait = HoverPreviewPanel.shared.isVisible ? 120_000_000 : delay
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: wait)
                        guard !Task.isCancelled, !node.isDirectory, let entry = node.entry else { return }
                        var videoURL: URL?
                        var videoAspect: CGFloat?
                        var audioURL: URL?
                        if ArchiveBrowser.isHoverVideo(name: entry.name, size: entry.size) {
                            videoURL = await browser.previewArtifact(for: entry)
                            if let videoURL { videoAspect = await HoverPreviewModel.videoAspectRatio(for: videoURL) }
                        } else if ArchiveBrowser.isHoverAudio(name: entry.name),
                                  AppSettings.hoverAudioAutoplay, !browser.isBrowseLocked {
                            // 音频自动试听：解出临时文件交给播放层
                            audioURL = await browser.previewArtifact(for: entry)
                        }
                        let image: NSImage? = videoURL == nil && audioURL == nil
                            ? await browser.hoverPreviewImage(for: entry)
                            : nil
                        guard !Task.isCancelled else { return }
                        probe("show \(entry.name)")
                        HoverPreviewPanel.shared.show(
                            HoverPreviewModel(
                                name: entry.name,
                                typeText: FileTypeDescription.describe(name: entry.name),
                                sizeText: ByteFormatter.string(from: entry.size),
                                image: image,
                                videoURL: videoURL,
                                videoAspect: videoAspect,
                                audioURL: audioURL
                            ),
                            at: NSEvent.mouseLocation
                        )
                        shown = true
                    }
                } else if shown {
                    shown = false
                    // 不立即收起：留 0.3s 宽限，方便光标移进视频画面点控制条
                    HoverPreviewPanel.shared.scheduleHideUnlessHovered()
                }
            }
            .onDisappear {
                hoverTask?.cancel()
                if shown {
                    shown = false
                    HoverPreviewPanel.shared.hide()
                }
            }
    }
}

// MARK: - 创建工作台：真实文件预览（悬停卡片 + 空格 Quick Look）

/// 磁盘真实文件的预览支持：无需解压，直接取系统缩略图 / 原文件 URL。
@MainActor
enum CreationPreviewSupport {
    /// 悬停预览卡片模型（图片/文档走系统缩略图，小视频直接播放原文件）。
    static func hoverModel(for item: CreationItem) async -> HoverPreviewModel {
        var videoURL: URL?
        var videoAspect: CGFloat?
        if ArchiveBrowser.isHoverVideo(name: item.name, size: item.size) {
            videoURL = item.url
            videoAspect = await HoverPreviewModel.videoAspectRatio(for: item.url)
        }
        let image: NSImage? = videoURL == nil ? await thumbnail(for: item.url) : nil
        return HoverPreviewModel(
            name: item.name,
            typeText: FileTypeDescription.describe(name: item.name),
            sizeText: ByteFormatter.string(from: item.size),
            image: image,
            videoURL: videoURL,
            videoAspect: videoAspect
        )
    }

    /// 系统缩略图（Quick Look 缩略图服务，覆盖图片/文档/表格等常见类型）。
    /// 800px：悬浮预览最大 400pt，视网膜屏 2x 下正好够锐。
    static func thumbnail(for url: URL, maxPixel: CGFloat = 800) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: maxPixel, height: maxPixel),
                scale: NSScreen.main?.backingScaleFactor ?? 1,
                representationTypes: .all
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
    }
}

/// 创建工作台的悬停预览（与包内条目悬停同一浮层，480ms 延迟）。
private struct CreationHoverPreviewModifier: ViewModifier {
    let item: CreationItem
    var delay: UInt64 = 480_000_000

    @State private var hoverTask: Task<Void, Never>?
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering {
                    guard !item.isDirectory else { return }
                    // 悬浮预览总开关（设置「通用 → 悬浮预览」）
                    guard AppSettings.hoverPreviewEnabled else { return }
                    // 浮层已开着（正在文件间滑动）：换内容只等 120ms，不闪没
                    let wait = HoverPreviewPanel.shared.isVisible ? 120_000_000 : delay
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: wait)
                        guard !Task.isCancelled else { return }
                        var model = await CreationPreviewSupport.hoverModel(for: item)
                        // 真实文件：音频自动试听直接用原文件（优先于缩略图）
                        if model.videoURL == nil,
                           ArchiveBrowser.isHoverAudio(name: item.name), AppSettings.hoverAudioAutoplay {
                            model.audioURL = item.url
                            model.image = nil
                        }
                        guard !Task.isCancelled else { return }
                        HoverPreviewPanel.shared.show(model, at: NSEvent.mouseLocation)
                        shown = true
                    }
                } else if shown {
                    shown = false
                    // 不立即收起：留 0.3s 宽限，方便光标移进视频画面点控制条
                    HoverPreviewPanel.shared.scheduleHideUnlessHovered()
                }
            }
            .onDisappear {
                hoverTask?.cancel()
                if shown {
                    shown = false
                    HoverPreviewPanel.shared.hide()
                }
            }
    }
}

// MARK: - 空格键监听

private struct SpaceQuickLookModifier: ViewModifier {
    let action: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: install)
            .onDisappear(perform: remove)
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 49 = 空格键；带修饰键时交给系统
            guard event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                return event
            }
            // Quick Look 面板可见时，空格交给系统自己关闭
            if QLPreviewPanel.shared()?.isVisible == true { return event }
            // 对话框（保存/打开/警告）里空格是正常输入，不拦截
            if let keyWindow = NSApp.keyWindow, keyWindow is NSPanel { return event }
            // 搜索框等文本输入聚焦时不拦截
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSText || responder is NSTextView {
                return event
            }
            MainActor.assumeIsolated { action() }
            return nil
        }
    }

    private func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

extension View {
    /// 文件名悬停 → 悬浮预览卡片。
    func archiveHoverPreview(browser: ArchiveBrowser, node: ArchiveNode) -> some View {
        modifier(ArchiveHoverPreviewModifier(browser: browser, node: node))
    }

    /// 创建工作台：待打包文件悬停 → 悬浮预览卡片（真实文件缩略图）。
    func creationHoverPreview(item: CreationItem) -> some View {
        modifier(CreationHoverPreviewModifier(item: item))
    }

    /// 空格键 → 系统 Quick Look 预览选中文件。
    func spaceQuickLook(action: @escaping () -> Void) -> some View {
        modifier(SpaceQuickLookModifier(action: action))
    }
}
