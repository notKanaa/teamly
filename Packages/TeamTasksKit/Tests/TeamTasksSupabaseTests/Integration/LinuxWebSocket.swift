#if os(Linux)
import Foundation
import Glibc
@testable import RealtimeV2

/// Minimal RFC 6455 WebSocket client over a plain TCP socket (`ws://` only), for the Linux integration tests.
///
/// supabase-swift's Realtime uses `URLSessionWebSocketTask`, which on Linux needs a libcurl built with WebSocket
/// support; the one of the `swift:*-noble` images is not ("WebSockets not supported by libcurl"). This transport
/// is plugged into `RealtimeClientV2` through its internal initializer (`@testable import RealtimeV2`), so the
/// adapters' Realtime code (channels, bindings, `system` status, token updates) runs unchanged against the
/// local stack. Only the socket differs from the app, which uses `URLSessionWebSocketTask` on iOS.
final class LinuxWebSocket: WebSocket, @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let events: AsyncStream<WebSocketEvent>
    let `protocol`: String = ""

    private let fd: Int32
    private let continuation: AsyncStream<WebSocketEvent>.Continuation
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closed = false
    private var code: Int?
    private var reason: String?

    private init(fd: Int32, leftover: [UInt8]) {
        self.fd = fd
        (events, continuation) = AsyncStream.makeStream(of: WebSocketEvent.self, bufferingPolicy: .unbounded)
        let thread = Thread { [self] in
            readLoop(buffer: leftover)
        }
        thread.stackSize = 1 << 20
        thread.start()
    }

    // MARK: - Connection

    /// The `RealtimeClientV2` WebSocket transport.
    static func connect(url: URL, headers: [String: String]) async throws -> any WebSocket {
        try await withCheckedThrowingContinuation { continuation in
            Thread {
                do {
                    continuation.resume(returning: try LinuxWebSocket.open(url: url, headers: headers))
                } catch {
                    continuation.resume(throwing: error)
                }
            }.start()
        }
    }

    private static func open(url: URL, headers: [String: String]) throws -> LinuxWebSocket {
        guard url.scheme == "ws", let host = url.host else {
            throw Failure(description: "only ws:// URLs are supported: \(url)")
        }
        let port = url.port ?? 80
        let fd = try tcpConnect(host: host, port: port)
        do {
            var target = url.path.isEmpty ? "/" : url.path
            if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery {
                target += "?" + query
            }
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            var request = "GET \(target) HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\n"
            request += "Connection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
            let reserved: Set<String> = ["host", "upgrade", "connection", "sec-websocket-key", "sec-websocket-version"]
            for (name, value) in headers where !reserved.contains(name.lowercased()) {
                request += "\(name): \(value)\r\n"
            }
            request += "\r\n"
            try writeAll(fd: fd, Array(request.utf8))

            // Response headers, then possibly the first frames.
            var buffer: [UInt8] = []
            let separator: [UInt8] = [13, 10, 13, 10]
            var headerEnd: Int?
            while headerEnd == nil {
                let chunk = try readSome(fd: fd)
                guard !chunk.isEmpty else { throw Failure(description: "connection closed during the handshake") }
                buffer += chunk
                if buffer.count >= 4 {
                    headerEnd = (0...(buffer.count - 4)).first { Array(buffer[$0..<($0 + 4)]) == separator }
                }
            }
            let end = headerEnd ?? 0
            let head = String(decoding: buffer[..<end], as: UTF8.self)
            guard let status = head.split(separator: "\r\n").first, status.contains(" 101") else {
                throw Failure(description: "WebSocket upgrade refused: \(head)")
            }
            return LinuxWebSocket(fd: fd, leftover: Array(buffer[(end + 4)...]))
        } catch {
            Glibc.close(fd)
            throw error
        }
    }

    private static func tcpConnect(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        var results: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &results)
        guard status == 0, let first = results else {
            throw Failure(description: "cannot resolve \(host) (\(status))")
        }
        defer { freeaddrinfo(results) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                if Glibc.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    var one: Int32 = 1
                    let tcpNoDelay: Int32 = 1 // TCP_NODELAY (netinet/tcp.h is not part of the Glibc module)
                    _ = setsockopt(fd, Int32(IPPROTO_TCP), tcpNoDelay, &one, socklen_t(MemoryLayout<Int32>.size))
                    return fd
                }
                Glibc.close(fd)
            }
            current = info.pointee.ai_next
        }
        throw Failure(description: "cannot connect to \(host):\(port) (errno \(errno))")
    }

    private static func writeAll(fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                Glibc.send(fd, raw.baseAddress! + offset, bytes.count - offset, Int32(MSG_NOSIGNAL))
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw Failure(description: "send failed (errno \(errno))")
            }
            offset += written
        }
    }

    private static func readSome(fd: Int32) throws -> [UInt8] {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = chunk.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, raw.count, 0)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure(description: "recv failed (errno \(errno))")
            }
            return Array(chunk[..<count])
        }
    }

    // MARK: - WebSocket

    var closeCode: Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return code
    }

    var closeReason: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return reason
    }

    var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    func send(_ text: String) {
        sendFrame(opcode: 0x1, payload: Array(text.utf8))
    }

    func send(_ binary: Data) {
        sendFrame(opcode: 0x2, payload: Array(binary))
    }

    func close(code: Int?, reason: String?) {
        guard !isClosed else { return }
        var payload: [UInt8] = []
        let closeCode = code ?? 1000
        payload.append(UInt8((closeCode >> 8) & 0xFF))
        payload.append(UInt8(closeCode & 0xFF))
        payload += Array((reason ?? "").utf8)
        sendFrame(opcode: 0x8, payload: payload)
        finish(code: closeCode, reason: reason ?? "")
    }

    /// Drops the TCP connection without a close frame, like a network loss (the peer sees an abnormal close).
    func simulateNetworkLoss() {
        shutdown(fd, Int32(SHUT_RDWR))
    }

    // MARK: - Frames

    private func sendFrame(opcode: UInt8, payload: [UInt8]) {
        guard !isClosed else { return }
        var frame: [UInt8] = [0x80 | opcode]
        let length = payload.count
        if length < 126 {
            frame.append(0x80 | UInt8(length))
        } else if length <= 0xFFFF {
            frame.append(0x80 | 126)
            frame += [UInt8(length >> 8), UInt8(length & 0xFF)]
        } else {
            frame.append(0x80 | 127)
            frame += (0..<8).reversed().map { UInt8((UInt64(length) >> (UInt64($0) * 8)) & 0xFF) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try LinuxWebSocket.writeAll(fd: fd, frame)
        } catch {
            finish(code: 1006, reason: "\(error)")
        }
    }

    /// Marks the connection closed (once), reports the close event and wakes the reader up.
    private func finish(code: Int, reason: String) {
        stateLock.lock()
        let wasClosed = closed
        closed = true
        if !wasClosed {
            self.code = code
            self.reason = reason
        }
        stateLock.unlock()
        guard !wasClosed else { return }
        shutdown(fd, Int32(SHUT_RDWR))
        continuation.yield(.close(code: code, reason: reason))
    }

    private func readLoop(buffer initial: [UInt8]) {
        var buffer = initial
        var message: [UInt8] = []
        var messageOpcode: UInt8 = 0

        /// Ensures `count` bytes are buffered; false at the end of the stream.
        func fill(_ count: Int) -> Bool {
            while buffer.count < count {
                guard let chunk = try? LinuxWebSocket.readSome(fd: fd), !chunk.isEmpty else { return false }
                buffer += chunk
            }
            return true
        }

        loop: while !isClosed {
            guard fill(2) else { break }
            let fin = buffer[0] & 0x80 != 0
            let opcode = buffer[0] & 0x0F
            let masked = buffer[1] & 0x80 != 0
            var length = Int(buffer[1] & 0x7F)
            var headerSize = 2
            if length == 126 {
                guard fill(4) else { break }
                length = Int(buffer[2]) << 8 | Int(buffer[3])
                headerSize = 4
            } else if length == 127 {
                guard fill(10) else { break }
                length = (2..<10).reduce(0) { $0 << 8 | Int(buffer[$1]) }
                headerSize = 10
            }
            let maskSize = masked ? 4 : 0
            guard fill(headerSize + maskSize + length) else { break }
            var payload = Array(buffer[(headerSize + maskSize)..<(headerSize + maskSize + length)])
            if masked {
                let mask = Array(buffer[headerSize..<(headerSize + 4)])
                payload = payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
            }
            buffer.removeFirst(headerSize + maskSize + length)

            switch opcode {
            case 0x0, 0x1, 0x2:
                if opcode != 0x0 {
                    messageOpcode = opcode
                    message = []
                }
                message += payload
                if fin {
                    if messageOpcode == 0x1 {
                        continuation.yield(.text(String(decoding: message, as: UTF8.self)))
                    } else {
                        continuation.yield(.binary(Data(message)))
                    }
                    message = []
                }
            case 0x8:
                let code = payload.count >= 2 ? Int(payload[0]) << 8 | Int(payload[1]) : 1005
                let reason = payload.count > 2 ? String(decoding: payload[2...], as: UTF8.self) : ""
                sendFrame(opcode: 0x8, payload: Array(payload.prefix(2)))
                finish(code: code, reason: reason)
                break loop
            case 0x9:
                sendFrame(opcode: 0xA, payload: payload)
            default:
                break
            }
        }
        finish(code: 1006, reason: "abnormal close")
        Glibc.close(fd)
    }
}
#endif
