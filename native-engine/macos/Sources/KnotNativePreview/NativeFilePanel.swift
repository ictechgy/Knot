import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KnotNativeCore

/// Reads only the pasteboard delivered by an explicit OS drag, never the clipboard.
@MainActor
enum NativeFileDrop {
    static let tooManyItems = "한 번에 파일 32개까지 보낼 수 있어요."
    static func exceedsLimit(_ pasteboard: NSPasteboard) -> Bool {
        (pasteboard.pasteboardItems?.count ?? 0) > 32
    }
    /// Both OS drop destinations use this admission boundary. Rejections reveal
    /// their authored status without invoking a transfer or reading item URLs.
    static func perform(from pasteboard: NSPasteboard, files: FileTransferModel,
                        beforeSend: () -> Void, showStatus: () -> Void = {}) -> Bool {
        guard !files.isBusy else { return false }
        if exceedsLimit(pasteboard) {
            files.rejectExcessDrop(); showStatus(); return false
        }
        guard let urls = urls(from: pasteboard) else { return false }
        beforeSend(); files.send(urls: urls); showStatus(); return true
    }
    static func urls(from pasteboard: NSPasteboard) -> [URL]? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty, items.count <= 32 else { return nil }
        var urls: [URL] = []
        for item in items {
            guard let text = item.string(forType: .fileURL), text.utf8.count <= 16_384,
                  let url = URL(string: text), url.isFileURL else { return nil }
            urls.append(url)
        }
        return urls
    }
}

/// The window retains pending providers because AppKit's provider delegate is weak.
/// Delegates hold the revocable file model weakly; closing a session cannot retain its capability.
@MainActor
final class NativeFilePromiseOwner: ObservableObject {
    private var providers: [UUID: NSFilePromiseProvider] = [:]
    func provider(entry: NativeFileEntry, files: FileTransferModel) -> (UUID, NSFilePromiseProvider)? {
        guard providers.count < 32, !files.isBusy else { return nil }
        let id = UUID()
        let delegate = NativeFilePromiseDelegate(id: id, entry: entry, files: files, owner: self)
        let type = UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
        let promisedType = entry.isFolder ? UTType.folder.identifier : type.conforms(to: .data) ? type.identifier : UTType.data.identifier
        let provider = NSFilePromiseProvider(fileType: promisedType, delegate: delegate)
        provider.userInfo = delegate
        providers[id] = provider
        return (id, provider)
    }
    func finish(_ id: UUID) { providers[id] = nil }
}

private final class NativeFilePromiseReply: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Error?) -> Void)?
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
    func finish(_ error: Error?) {
        lock.lock(); let callback = handler; handler = nil; lock.unlock()
        callback?(error)
    }
}

@MainActor
private final class NativeFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let id: UUID
    let entry: NativeFileEntry
    weak var files: FileTransferModel?
    weak var owner: NativeFilePromiseOwner?
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "Knot native file promises"; queue.maxConcurrentOperationCount = 1; return queue
    }()
    init(id: UUID, entry: NativeFileEntry, files: FileTransferModel, owner: NativeFilePromiseOwner) {
        self.id = id; self.entry = entry; self.files = files; self.owner = owner
    }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { entry.name }
    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let reply = NativeFilePromiseReply(completionHandler)
        Task { @MainActor [self, reply] in
            defer { owner?.finish(id) }
            guard let files else {
                reply.finish(NSError(domain: "Knot.NativeFiles", code: 1, userInfo: [NSLocalizedDescriptionKey: "연결이 종료되어 파일을 받을 수 없어요."]))
                return
            }
            do {
                // AppKit requires the supplied URL; the engine exclusively publishes
                // exactly here or fails, with no collision rename/overwrite.
                _ = try await files.receive(entry, destination: url)
                reply.finish(nil)
            } catch {
                reply.finish(NSError(domain: "Knot.NativeFiles", code: 2, userInfo: [NSLocalizedDescriptionKey: "파일을 받지 못했어요. 연결과 저장 위치를 확인하고 다시 시도하세요."]))
            }
        }
    }
}

private struct NativeRemoteFileDrag: NSViewRepresentable {
    let entry: NativeFileEntry
    let files: FileTransferModel
    let owner: NativeFilePromiseOwner
    let beforeAction: () -> Void
    func makeNSView(context: Context) -> NativeRemoteFileDragView { NativeRemoteFileDragView() }
    func updateNSView(_ view: NativeRemoteFileDragView, context: Context) {
        view.entry = entry; view.files = files; view.owner = owner; view.beforeAction = beforeAction
        view.toolTip = "Finder로 끌어 파일 받기 · " + entry.name
        view.setAccessibilityLabel(entry.name + " 파일을 Finder로 끌어 받기")
        view.setAccessibilityHelp("키보드로는 옆의 받기 버튼을 사용하세요.")
    }
}

@MainActor
final class NativeRemoteFileDragView: NSView, NSDraggingSource {
    var entry: NativeFileEntry?
    weak var files: FileTransferModel?
    weak var owner: NativeFilePromiseOwner?
    var beforeAction: (() -> Void)?
    private var down: NSEvent?
    private var promise: UUID?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setAccessibilityRole(.image) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSImage(systemSymbolName: entry?.isFolder == true ? "folder" : "arrow.down.doc", accessibilityDescription: nil)?.draw(in: bounds.insetBy(dx: 7, dy: 7))
    }
    override func mouseDown(with event: NSEvent) { down = event }
    override func mouseDragged(with event: NSEvent) {
        guard let down, let entry, let files, let owner, !files.isBusy,
              hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) > 3,
              let (id, provider) = owner.provider(entry: entry, files: files) else { return }
        self.down = nil; promise = id; beforeAction?()
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: NSImage(systemSymbolName: entry.isFolder ? "folder" : "doc", accessibilityDescription: nil))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.isEmpty, let promise { owner?.finish(promise) }
        promise = nil; down = nil
    }
}

struct NativeFilePanel: NSViewRepresentable {
    let files: FileTransferModel
    let owner: NativeFilePromiseOwner
    let beforeAction: () -> Void
    let close: () -> Void
    func makeNSView(context: Context) -> NativeFilePanelHost { NativeFilePanelHost(rootView: content) }
    func updateNSView(_ view: NativeFilePanelHost, context: Context) { view.rootView = content }
    private var content: NativeFilePanelContent { NativeFilePanelContent(files: files, owner: owner, beforeAction: beforeAction, close: close) }
}

@MainActor
final class NativeFilePanelHost: NSHostingView<NativeFilePanelContent> {
    required init(rootView: NativeFilePanelContent) { super.init(rootView: rootView); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !rootView.files.isBusy, sender.draggingPasteboard.availableType(from: [.fileURL]) != nil else { return [] }
        rootView.beforeAction(); return .copy
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !rootView.files.isBusy }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        NativeFileDrop.perform(from: sender.draggingPasteboard, files: rootView.files, beforeSend: rootView.beforeAction)
    }
}

struct NativeFilePanelContent: View {
    @ObservedObject var files: FileTransferModel
    let owner: NativeFilePromiseOwner
    let beforeAction: () -> Void
    let close: () -> Void
    @State private var localNotice: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("파일·폴더 주고받기", systemImage: "folder").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.accessibilityLabel("파일 패널 닫기")
            }
            Text("Windows 공유 폴더 · " + files.rootName).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
            Text("Mac 파일·폴더를 여기에 놓으면 이 공유 폴더로 복사돼요. Windows 탐색기 항목은 화면 밖 Finder로 끌어오거나 아래 목록에서 받으세요.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { beforeAction(); localNotice = nil; files.refresh() } label: { Label("새로고침", systemImage: "arrow.clockwise") }
                Spacer()
                Button(action: chooseFiles) { Label("보내기", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent)
            }.disabled(files.isBusy)
            Divider()
            if files.completedItems > 0 || files.canRetryUploads || files.lastReceivedURL != nil {
                HStack {
                    Label("완료 \(files.completedItems)개", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    Spacer()
                    if files.canRetryUploads { Button("미완료 항목 재시도") { beforeAction(); files.retryUnfinishedUploads() } }
                    if files.lastReceivedURL != nil { Button("Finder에서 보기") { beforeAction(); files.revealLastReceived() } }
                }.font(.system(size: 12))
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if files.entries.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray").font(.system(size: 30, weight: .light))
                            Text(files.isBusy ? "파일 작업 중이에요" : "공유 폴더의 파일이 여기 보여요").font(.system(size: 13, weight: .medium))
                            Text("Windows 파일을 공유 폴더에 넣고 새로고침하세요.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 28)
                    }
                    ForEach(files.entries, id: \.id) { entry in
                        HStack(spacing: 10) {
                            NativeRemoteFileDrag(entry: entry, files: files, owner: owner, beforeAction: beforeAction)
                                .frame(width: 34, height: 34).opacity(files.isBusy ? 0.4 : 1)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1).help(entry.name)
                                Text(entry.isFolder ? "폴더 · 하위 항목 포함" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("받기") { chooseDestination(entry) }.disabled(files.isBusy)
                                .accessibilityLabel(entry.name + " 파일 받기")
                        }.padding(.vertical, 8)
                        Divider()
                    }
                }
            }.frame(maxHeight: .infinity)
            if files.truncated { Text("목록은 최대 256개예요. 필요한 파일만 공유 폴더에 두세요.").font(.system(size: 11)).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 8) {
                if let progress = files.progress { ProgressView(value: progress).accessibilityLabel("파일 전송 진행률") }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let name = files.currentName { Text(verbatim: name).font(.system(size: 12, weight: .medium)).lineLimit(1) }
                        Text(localNotice ?? files.status).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if files.isBusy { Button("전송 취소") { files.cancel() }.buttonStyle(.bordered) }
                }
            }.padding(12).background(NativeStyle.canvas, in: RoundedRectangle(cornerRadius: 8))
            Text("파일·폴더 · 최대 8GiB · 원본 유지 · 기존 항목 덮어쓰기 없음")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 360, minHeight: 360).nativePanel()
    }
    private func chooseFiles() {
        guard !files.isBusy else { return }
        beforeAction()
        let picker = NSOpenPanel(); picker.title = "Windows로 보낼 파일·폴더"; picker.prompt = "보내기"
        picker.canChooseFiles = true; picker.canChooseDirectories = true; picker.treatsFilePackagesAsDirectories = false; picker.allowsMultipleSelection = true
        picker.begin { result in
            guard result == .OK else { return }
            files.send(urls: picker.urls)
        }
    }
    private func chooseDestination(_ entry: NativeFileEntry) {
        guard !files.isBusy else { return }
        beforeAction()
        let picker = NSSavePanel(); picker.title = entry.isFolder ? "Windows 폴더 받기" : "Windows 파일 받기"; picker.prompt = "받기"; picker.nameFieldStringValue = entry.name
        picker.message = "원본은 유지해요. 같은 이름의 파일이 있으면 다른 이름을 선택해주세요."
        picker.begin { result in
            guard result == .OK, let destination = picker.url else { return }
            Task { @MainActor in
                do { _ = try await files.receive(entry, destination: destination); localNotice = nil }
                catch { localNotice = files.status }
            }
        }
    }
}
