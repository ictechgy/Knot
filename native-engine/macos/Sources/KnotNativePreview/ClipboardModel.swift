import AppKit
import Combine
import KnotNativeCore

/// Reads/writes the local pasteboard only in direct response to a user copy/paste.
@MainActor
final class ClipboardModel: ObservableObject {
    @Published private(set) var status = "텍스트 복사·붙여넣기"
    @Published private(set) var busy = false
    private let send: (Packet) -> Bool
    private let readText: () -> String?
    private let writeText: (String) -> Bool
    private var pending: (ClipboardOperation, Data)?
    private var timeout: Task<Void, Never>?
    init(send: @escaping (Packet) -> Bool,
         readText: @escaping () -> String? = { NSPasteboard.general.string(forType: .string) },
         writeText: @escaping (String) -> Bool = { text in
             NSPasteboard.general.clearContents()
             return NSPasteboard.general.setString(text, forType: .string)
         }) {
        self.send = send; self.readText = readText; self.writeText = writeText
    }
    func copyFromRemote() { request(.copy, text: "") }
    func pasteToRemote() {
        guard !busy else { return }
        guard let text = readText() else { status = "Mac 클립보드에 텍스트가 없어요."; return }
        request(.paste, text: text)
    }
    private func request(_ operation: ClipboardOperation, text: String) {
        guard !busy else { return }
        let nonce = withUnsafeBytes(of: UUID().uuid) { Data($0) }
        guard let packet = try? ClipboardProtocol.request(operation, nonce: nonce, text: text) else {
            status = "텍스트는 1MiB 이하이며 NUL 문자를 포함할 수 없어요."; return
        }
        pending = (operation, nonce); busy = true
        guard send(packet) else { finish("연결 중에만 텍스트를 옮길 수 있어요."); return }
        status = operation == .copy ? "Windows에서 복사 중…" : "Windows에 붙여넣는 중…"
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.pending?.1 == nonce else { return }
            self.finish("클립보드 응답을 받지 못했어요. 다시 시도하세요.")
        }
    }
    func accept(_ response: ClipboardResponse) {
        guard let pending, pending.0 == response.operation, pending.1 == response.nonce else { return }
        if response.status == .success {
            if response.operation == .copy {
                finish(writeText(response.text) ? "Windows 텍스트를 Mac에 복사했어요." : "Mac 클립보드에 쓰지 못했어요.")
            } else { finish("Windows에 붙여넣었어요.") }
        } else {
            finish(response.status == .busy ? "클립보드 작업이 진행 중이에요." : "텍스트를 옮기지 못했어요. 선택한 텍스트와 연결을 확인하세요.")
        }
    }
    func cancel() { finish("텍스트 복사·붙여넣기") }
    private func finish(_ message: String) { timeout?.cancel(); timeout = nil; pending = nil; busy = false; status = message }
}
