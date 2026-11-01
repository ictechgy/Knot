import Foundation
import Darwin
import Security
import KnotNativeCore

protocol EnrollmentDiscovering: AnyObject, Sendable {
    func discover(address: String?) async throws -> [EnrollmentCandidate]
    func close()
}

/// A user-started, one-shot UDP query. It never advertises a code or invitation.
final class DiscoveryClient: EnrollmentDiscovering, @unchecked Sendable {
    private let queue = DispatchQueue(label: "KnotNativePreview.discovery")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[EnrollmentCandidate], any Error>?
    private var closed = false
    private var started = false
    // Socket and dispatch sources are owned exclusively by queue.
    private var reader: (any DispatchSourceRead)?
    private var timer: (any DispatchSourceTimer)?
    private var candidates: [String: EnrollmentCandidate] = [:]
    func discover(address: String?) async throws -> [EnrollmentCandidate] {
        if let address, !Invitation.isPrivateIPv4(address) { throw EnrollmentFailure.invalidTarget }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { value in
                lock.lock()
                guard !closed, !started else { lock.unlock(); value.resume(throwing: EnrollmentFailure.cancelled); return }
                started = true; continuation = value; lock.unlock()
                queue.async { self.begin(address: address) }
            }
        } onCancel: { self.close() }
    }
    private var pending: Bool {
        lock.lock(); defer { lock.unlock() }; return !closed && continuation != nil
    }
    private func begin(address: String?) {
        guard pending else { return }
        var nonce = Data(count: 16)
        let randomStatus = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard randomStatus == errSecSuccess, let query = try? EnrollmentWire.discoveryQuery(nonce: nonce) else {
            finish(.failure(EnrollmentFailure.transport)); return
        }
        let queryNonce = nonce
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { finish(.failure(EnrollmentFailure.transport)); return }
        var broadcast: Int32 = 1
        guard fcntl(fd, F_SETFL, O_NONBLOCK) >= 0,
              setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(fd); finish(.failure(EnrollmentFailure.transport)); return
        }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = EnrollmentWire.discoveryPort.bigEndian
        guard (address ?? "255.255.255.255").withCString({ inet_pton(AF_INET, $0, &destination.sin_addr) }) == 1 else {
            Darwin.close(fd); finish(.failure(EnrollmentFailure.invalidTarget)); return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader = source
        source.setCancelHandler { _ = Darwin.close(fd) }
        source.setEventHandler { [weak self] in self?.receive(fd: fd, nonce: queryNonce, target: address) }
        let timeout = DispatchSource.makeTimerSource(queue: queue)
        timer = timeout
        timeout.schedule(deadline: .now() + 3)
        timeout.setEventHandler { [weak self] in
            guard let self else { return }
            self.finish(.success(self.candidates.values.sorted { ($0.name, $0.address) < ($1.name, $1.address) }))
        }
        source.resume(); timeout.resume()
        guard pending else { finish(.failure(EnrollmentFailure.cancelled)); return }
        let sent = query.withUnsafeBytes { raw in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, query.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent != query.count { finish(.failure(EnrollmentFailure.transport)) }
    }
    private func receive(fd: Int32, nonce: Data, target: String?) {
        // Limit each callback as well as storage, so malformed LAN floods cannot
        // starve queued cancellation or the three-second completion timer.
        for _ in 0..<64 {
            guard pending else { return }
            var bytes = [UInt8](repeating: 0, count: 1025)
            var endpoint = sockaddr_in(), size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = bytes.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &endpoint) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &size)
                    }
                }
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                finish(.failure(EnrollmentFailure.transport)); return
            }
            guard (1...1024).contains(count), endpoint.sin_family == sa_family_t(AF_INET),
                  size >= MemoryLayout<sockaddr_in>.size else { continue }
            var rawAddress = endpoint.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &rawAddress, &text, socklen_t(text.count)) != nil else { continue }
            let address = String(decoding: text.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard target == nil || address == target,
                  let candidate = try? EnrollmentWire.discoveryReply(Data(bytes.prefix(count)), nonce: nonce, sourceIPv4: address),
                  candidates[candidate.id] == nil, candidates.count < EnrollmentWire.candidateLimit else { continue }
            candidates[candidate.id] = candidate
        }
    }
    private func finish(_ result: Result<[EnrollmentCandidate], any Error>) {
        lock.lock(); let pending = continuation; continuation = nil; closed = true; lock.unlock()
        queue.async {
            self.timer?.cancel(); self.timer = nil
            self.reader?.cancel(); self.reader = nil
            self.candidates.removeAll()
        }
        pending?.resume(with: result)
    }
    func close() { finish(.failure(EnrollmentFailure.cancelled)) }
}
