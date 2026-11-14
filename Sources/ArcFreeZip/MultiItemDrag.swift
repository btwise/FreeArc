import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ArchiveCore

/// 多选拖出交付：每个条目一个文件承诺（file promise）。
///
/// SwiftUI 的 `onDrag` 一次只能交付一个 `NSItemProvider`，多选时只能把内容整体
/// 包成一个「以压缩包命名的文件夹」，落到目标位置就会多出一层子目录。
/// 这里改走 AppKit 拖拽会话：Finder 拿到 N 个文件承诺，直接把每个条目写进
/// 拖放目标文件夹——与单选拖出完全一致的落点语义。
final class MultiItemDrag: NSObject, NSDraggingSource {

    struct Item: Sendable {
        /// 交付到磁盘的文件名（含扩展名；已应用待保存的改名）。
        let name: String
        /// 包内路径（在解压暂存区里的相对位置）。
        let path: String
        let isDirectory: Bool
    }

    private let items: [Item]
    private let extraction: SharedExtraction
    /// 文件承诺的 delegate 必须由我们强引用（NSFilePromiseProvider 只持弱引用）。
    private var promises: [FilePromise] = []
    private var session: NSDraggingSession?

    /// - Parameters:
    ///   - items: 交付条目（名称 + 包内路径）
    ///   - extractionPaths: 需要解压的包内路径（目录已展开成其内部文件）
    ///   - extract: 解压动作（把给定路径解到指定目录，保持归档内的原始相对结构）
    init(
        items: [Item],
        extractionPaths: [String],
        extract: @escaping @Sendable ([String], URL) throws -> Void
    ) {
        self.items = items
        self.extraction = SharedExtraction(paths: extractionPaths, extract: extract)
    }

    /// 在指定视图上发起拖拽会话（frame 用视图坐标）。
    @MainActor
    func start(from view: NSView, at point: NSPoint, event: NSEvent) {
        promises = items.map { FilePromise(item: $0, extraction: extraction) }

        let side: CGFloat = 40
        var draggingItems: [NSDraggingItem] = []
        for (index, promise) in promises.enumerated() {
            let provider = NSFilePromiseProvider(
                fileType: promise.fileTypeIdentifier,
                delegate: promise
            )
            let draggingItem = NSDraggingItem(pasteboardWriter: provider)
            // 多个条目按 6pt 阶梯错开，视觉上一摞文件
            let offset = CGFloat(index) * 6
            draggingItem.setDraggingFrame(
                NSRect(
                    x: point.x - side / 2 + offset,
                    y: point.y - side / 2 + offset,
                    width: side,
                    height: side
                ),
                contents: Self.icon(for: promise.item)
            )
            draggingItems.append(draggingItem)
        }
        session = view.beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        self.session = nil
        // 承诺写入由 Finder 异步发起（可能晚于会话结束），暂存目录交给
        // ArchiveDragExtraction 的两小时定期清理，这里不做删除。
    }

    // MARK: 拖拽预览图标

    private static func icon(for item: Item) -> NSImage {
        let ext = (item.name as NSString).pathExtension.lowercased()
        let type: UTType
        if !ext.isEmpty, let resolved = UTType(filenameExtension: ext) {
            type = resolved
        } else {
            type = item.isDirectory ? .folder : .data
        }
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = NSSize(width: 36, height: 36)
        return icon
    }
}

// MARK: - 单个条目的文件承诺

/// 一个条目一个承诺：Finder 落盘时把解出的内容写到它给出的目标 URL。
private final class FilePromise: NSObject, NSFilePromiseProviderDelegate {
    let item: MultiItemDrag.Item
    private let extraction: SharedExtraction

    init(item: MultiItemDrag.Item, extraction: SharedExtraction) {
        self.item = item
        self.extraction = extraction
    }

    /// 承诺的类型：目录（含 .app）用 public.folder，文件按扩展名推断。
    var fileTypeIdentifier: String {
        if item.isDirectory && !item.name.lowercased().hasSuffix(".app") {
            return UTType.folder.identifier
        }
        let ext = (item.name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type.identifier
        }
        return item.isDirectory ? UTType.folder.identifier : UTType.data.identifier
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        item.name
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let item = self.item
        let extraction = self.extraction
        // completionHandler 由 AppKit 提供、不是 Sendable，包一层带进后台队列
        final class Completion: @unchecked Sendable {
            let handler: (Error?) -> Void
            init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
        }
        let completion = Completion(completionHandler)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let source = try extraction.stagedURL(for: item)
                let fm = FileManager.default
                // 安全红线：绝不删除目标位置已有的任何文件。正常情况下 Finder
                // 给出的 url 是不存在的（同名时它自己会改成「xx 2」）；万一给出
                // 了已存在的路径，改用带序号的新名字，而不是先删再拷。
                var destination = url
                if fm.fileExists(atPath: destination.path) {
                    let base = destination.deletingPathExtension()
                    let ext = destination.pathExtension
                    var n = 2
                    repeat {
                        let candidate = ext.isEmpty
                            ? base.appendingPathExtension("\(n)")
                            : base.appendingPathExtension("\(n)").appendingPathExtension(ext)
                        if !fm.fileExists(atPath: candidate.path) {
                            destination = candidate
                            break
                        }
                        n += 1
                    } while n < 1000
                }
                try fm.copyItem(at: source, to: destination)
                completion.handler(nil)
            } catch {
                completion.handler(error)
            }
        }
    }
}

// MARK: - 共享解压暂存

/// 一次拖拽只解压一次：所有承诺并发写入时等同一份结果。
final class SharedExtraction: @unchecked Sendable {
    private let condition = NSCondition()
    private var isFinished = false
    private var payload: URL?
    private var failure: Error?

    init(
        paths: [String],
        extract: @escaping @Sendable ([String], URL) throws -> Void
    ) {
        let base = ArchiveDragExtraction.stagingRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = base.appendingPathComponent("payload", isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async {
            var outcome: Result<URL, Error>
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try extract(paths, target)
                outcome = .success(target)
            } catch {
                outcome = .failure(error)
            }
            self.condition.lock()
            switch outcome {
            case .success(let url): self.payload = url
            case .failure(let error): self.failure = error
            }
            self.isFinished = true
            self.condition.broadcast()
            self.condition.unlock()
        }
    }

    /// 等待解压完成并返回该条目在暂存区里的真实位置。
    func stagedURL(for item: MultiItemDrag.Item) throws -> URL {
        condition.lock()
        while !isFinished {
            condition.wait()
        }
        let payload = self.payload
        let failure = self.failure
        condition.unlock()

        if let failure { throw failure }
        guard let payload else { throw CocoaError(.fileNoSuchFile) }

        let fm = FileManager.default
        var normalized = item.path
        while normalized.hasPrefix("./") { normalized = String(normalized.dropFirst(2)) }
        let direct = payload.appendingPathComponent(normalized)
        if fm.fileExists(atPath: direct.path) { return direct }

        // 兜底：条目路径与解出结构可能有前缀差异（部分引擎会剥掉公共目录），
        // 按文件名在暂存区里找一次。
        if let found = Self.locate(name: item.name, in: payload) { return found }
        throw CocoaError(.fileNoSuchFile)
    }

    static func locate(name: String, in root: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }
}

// MARK: - 多选拖拽总闸

/// 拖拽起点登记 + 鼠标事件拦截。
///
/// SwiftUI 没有「一次拖多个条目」的入口：`.onDrag` 只能返回一个 provider，
/// 多选时只能把内容整体包成一个文件夹。这里在鼠标事件上拦一刀：
/// 当按下位置属于多选集时，抢在 SwiftUI 之前发起 AppKit 拖拽会话；
/// 其余情况（单选、非条目区域）原样放行，`.onDrag` 行为完全不变。
@MainActor
final class MultiDragRelay {
    static let shared = MultiDragRelay()

    private weak var browser: ArchiveBrowser?
    private var hoveredNode: ArchiveNode?
    private var isArmed = false
    private var downPoint: NSPoint = .zero
    private var monitor: Any?

    private init() {}

    /// 由条目视图的 onHover 调用，登记「鼠标当前停在哪个条目上」。
    func setHover(_ browser: ArchiveBrowser, node: ArchiveNode, hovering: Bool) {
        if hovering {
            self.browser = browser
            hoveredNode = node
            installMonitorIfNeeded()
        } else if hoveredNode?.path == node.path, self.browser === browser {
            hoveredNode = nil
            self.browser = nil
        }
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        // 本地监视器回调一定在主线程，但闭包签名是 @Sendable，
        // NSEvent 本身不是 Sendable —— 用轻量盒子带过去。
        struct EventBox: @unchecked Sendable { let event: NSEvent }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { event in
            let box = EventBox(event: event)
            let consumed = MainActor.assumeIsolated { () -> Bool in
                MultiDragRelay.shared.handle(box.event) == nil
            }
            return consumed ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            isArmed = false
            guard let browser, let node = hoveredNode,
                  browser.selectedPaths.count > 1,
                  browser.selectedPaths.contains(node.path) else { return event }
            isArmed = true
            downPoint = NSEvent.mouseLocation
            return event
        case .leftMouseDragged:
            guard isArmed, let browser, let node = hoveredNode else { return event }
            let point = NSEvent.mouseLocation
            guard hypot(point.x - downPoint.x, point.y - downPoint.y) > 4 else { return event }
            isArmed = false
            // 交给 AppKit 拖拽会话后吞掉本事件：否则 SwiftUI 的 onDrag 会同时
            // 发起一个「打包成文件夹」的单条目会话，两个会话互相打架。
            if browser.startNativeDrag(from: node, event: event) {
                return nil
            }
            return event
        case .leftMouseUp:
            isArmed = false
            return event
        default:
            return event
        }
    }
}

extension View {
    /// 登记拖拽起点（多选拖拽总闸用）。
    func multiDragHover(browser: ArchiveBrowser, node: ArchiveNode) -> some View {
        onHover { hovering in
            MultiDragRelay.shared.setHover(browser, node: node, hovering: hovering)
        }
    }
}
