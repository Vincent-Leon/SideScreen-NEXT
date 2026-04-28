/*
 * StreamingServer (BSD socket variant)
 *
 * 改动原因（macOS 26 / Tahoe）：上游用 Network.framework (NWListener/NWConnection) 时，
 * 来自外部局域网的连接 NWConnection 状态会卡在 .preparing，永远不进 .ready —
 * sendDisplaySize / sendFrame 永远不会被触发，应用层数据也就发不出去。这是 macOS 在
 * Local Network 隐私机制下对 ad-hoc 签名 App 的隐性收紧（即便 Info.plist 加了
 * NSLocalNetworkUsageDescription 也仍未触发授权弹框）。
 *
 * 修法：替换为标准 POSIX BSD socket。BSD socket 走 kernel 层，不经过 Network.framework，
 * 不受 Local Network 隐私的拦截。loopback 与外部 LAN 一视同仁。
 *
 * 公共接口与上游 100% 兼容（init / start / stop / setDisplaySize / updateRotation /
 * sendDisplaySize / sendFrame / 各 callback），AppDelegate 等其他文件零改动。
 */

import Foundation
import Darwin

class StreamingServer {
    private let port: UInt16

    // POSIX 文件描述符
    private var listenFd: Int32 = -1
    private var clientFd: Int32 = -1
    private let clientLock = NSLock()
    /// 序列化所有写到 clientFd 的逻辑消息，避免视频帧的 (header,data) 两个 send 之间被
    /// pong / displayConfig 插入造成字节交错（"stream misaligned" bug 的根因）。
    private let sendLock = NSLock()

    // 上游接口对齐
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?
    var onTouchEvent: ((Float, Float, Int, Int, Float, Float) -> Void)?
    var onStats: ((Double, Double) -> Void)?

    private let frameQueue = DispatchQueue(label: "frameQueue", qos: .userInteractive)
    private let acceptQueue = DispatchQueue(label: "acceptQueue", qos: .userInteractive)
    private let receiveQueue = DispatchQueue(label: "receiveQueue", qos: .userInteractive)

    private var bytesSent: UInt64 = 0
    private var frameCount: UInt64 = 0
    private var droppedFrames: UInt64 = 0
    private var lastStatsTime = DispatchTime.now()
    private var displayWidth = 1920
    private var displayHeight = 1080
    private var rotation = 0
    private var isStopped = false
    private var connectionReady = false

    private var totalFrameAgeNs: UInt64 = 0
    private var profiledFrameCount: UInt64 = 0

    init(port: UInt16) {
        self.port = port
    }

    // MARK: - Lifecycle

    func start() {
        isStopped = false

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            debugLog("socket() failed: errno=\(errno) \(String(cString: strerror(errno)))")
            return
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // bind to 0.0.0.0:port
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0)) // INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult < 0 {
            debugLog("bind() failed: errno=\(errno) \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            return
        }

        if Darwin.listen(fd, 16) < 0 {
            debugLog("listen() failed: errno=\(errno) \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            return
        }

        listenFd = fd
        debugLog("BSD TCP Server listening on port \(port)")

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        isStopped = true

        // 让正在排队的 sendFrame 完成
        frameQueue.sync {}

        clientLock.lock()
        if clientFd >= 0 {
            shutdown(clientFd, Int32(SHUT_RDWR))
            Darwin.close(clientFd)
            clientFd = -1
            connectionReady = false
        }
        clientLock.unlock()

        if listenFd >= 0 {
            shutdown(listenFd, Int32(SHUT_RDWR))
            Darwin.close(listenFd)
            listenFd = -1
        }
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while !isStopped, listenFd >= 0 {
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)

            let cfd = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(listenFd, sockPtr, &len)
                }
            }

            if cfd < 0 {
                if isStopped { break }
                if errno == EINTR { continue }
                debugLog("accept() failed: errno=\(errno) \(String(cString: strerror(errno)))")
                continue
            }

            // TCP_NODELAY 低延迟
            var nodelay: Int32 = 1
            setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))

            // 替换旧连接（一次只服务一个 client，跟上游一致）
            clientLock.lock()
            let old = clientFd
            clientFd = cfd
            connectionReady = false
            droppedFrames = 0
            clientLock.unlock()
            if old >= 0 {
                shutdown(old, Int32(SHUT_RDWR))
                Darwin.close(old)
            }

            let ip = Self.ipString(from: clientAddr)
            debugLog("BSD client connected from \(ip):\(UInt16(bigEndian: clientAddr.sin_port)) fd=\(cfd) — sending display config")

            sendDisplaySize()

            clientLock.lock()
            connectionReady = true
            clientLock.unlock()

            debugLog("Connection ready for frames")
            onClientConnected?()

            receiveQueue.async { [weak self] in
                self?.receiveLoop(fd: cfd)
            }
        }
    }

    private static func ipString(from addr: sockaddr_in) -> String {
        var addr = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        _ = withUnsafePointer(to: &addr.sin_addr) { p in
            inet_ntop(AF_INET, p, &buf, socklen_t(INET_ADDRSTRLEN))
        }
        return String(cString: buf)
    }

    // MARK: - Receive loop (touch + ping)

    private func receiveLoop(fd: Int32) {
        recvLoop: while !isStopped {
            var typeByte: UInt8 = 0
            let n = recv(fd, &typeByte, 1, Int32(MSG_WAITALL))
            if n <= 0 { break }

            switch typeByte {
            case 2:
                // 触控：1 byte n + n×(4 byte x + 4 byte y) + 4 byte action（小端）
                var pointerCount: UInt8 = 0
                if recv(fd, &pointerCount, 1, Int32(MSG_WAITALL)) <= 0 { break recvLoop }
                let pc = max(1, min(2, Int(pointerCount)))

                var x1: Float = 0, y1: Float = 0, x2: Float = 0, y2: Float = 0
                if recv(fd, &x1, 4, Int32(MSG_WAITALL)) <= 0 { break recvLoop }
                if recv(fd, &y1, 4, Int32(MSG_WAITALL)) <= 0 { break recvLoop }
                if pc == 2 {
                    if recv(fd, &x2, 4, Int32(MSG_WAITALL)) <= 0 { break recvLoop }
                    if recv(fd, &y2, 4, Int32(MSG_WAITALL)) <= 0 { break recvLoop }
                }
                var action: Int32 = 0
                if recv(fd, &action, 4, Int32(MSG_WAITALL)) <= 0 { break recvLoop }

                DispatchQueue.main.async { [weak self] in
                    self?.onTouchEvent?(x1, y1, Int(action), pc, x2, y2)
                }

            case 4:
                // ping：8 byte 时间戳，原样回 type=5 pong
                var ts = [UInt8](repeating: 0, count: 8)
                if recv(fd, &ts, 8, Int32(MSG_WAITALL)) <= 0 { break recvLoop }
                var pong = [UInt8](repeating: 0, count: 9)
                pong[0] = 5
                for i in 0..<8 { pong[i + 1] = ts[i] }
                _ = pong.withUnsafeBufferPointer {
                    sendAll(fd: fd, bytes: UnsafeRawPointer($0.baseAddress!), length: 9)
                }

            default:
                debugLog("Unknown msg type \(typeByte) from client — disconnecting")
                break recvLoop
            }
        }
        cleanupClient(fd: fd)
    }

    private func cleanupClient(fd: Int32) {
        clientLock.lock()
        if clientFd == fd {
            clientFd = -1
            connectionReady = false
        }
        clientLock.unlock()
        Darwin.close(fd)
        onClientDisconnected?()
    }

    // MARK: - Public API

    func setDisplaySize(width: Int, height: Int, rotation: Int = 0) {
        displayWidth = width
        displayHeight = height
        self.rotation = rotation
    }

    func updateRotation(_ rotation: Int) {
        self.rotation = rotation
        sendDisplaySize()
    }

    func sendDisplaySize() {
        clientLock.lock()
        let fd = clientFd
        clientLock.unlock()
        guard fd >= 0 else { return }

        var bytes = [UInt8]()
        bytes.append(1) // type=0x01
        let w = Int32(displayWidth).bigEndian
        let h = Int32(displayHeight).bigEndian
        let r = Int32(rotation).bigEndian
        withUnsafeBytes(of: w) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: h) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: r) { bytes.append(contentsOf: $0) }

        _ = bytes.withUnsafeBufferPointer {
            sendAll(fd: fd, bytes: UnsafeRawPointer($0.baseAddress!), length: bytes.count)
        }
        debugLog("Sent display config: \(displayWidth)x\(displayHeight) @ \(rotation)°")
    }

    func sendFrame(_ data: Data, timestamp: UInt64, isKeyframe: Bool = false) {
        clientLock.lock()
        let fd = clientFd
        let ready = connectionReady
        clientLock.unlock()
        guard fd >= 0, !isStopped, ready else { return }

        frameQueue.async { [weak self] in
            guard let self = self else { return }

            // 拼成单个 packet（1 byte type + 4 byte BE size + N bytes payload），用一次 sendAll
            // 发出。原来的 header/data 分两次 send 会与 pong/displayConfig 交错，造成
            // 客户端 stream misaligned。多一次 ~50 KB 的 memcpy 不算瓶颈。
            var packet = Data(capacity: 5 + data.count)
            packet.append(0)
            var size = Int32(data.count).bigEndian
            withUnsafeBytes(of: &size) { ptr in
                packet.append(contentsOf: ptr)
            }
            packet.append(data)

            let ok = packet.withUnsafeBytes { buf in
                self.sendAll(fd: fd, bytes: buf.baseAddress!, length: packet.count)
            }
            if !ok {
                self.droppedFrames += 1
                return
            }

            let sendAge = DispatchTime.now().uptimeNanoseconds - timestamp
            self.updateStats(bytes: data.count, frameAgeNs: sendAge)
        }
    }

    // MARK: - Helpers

    /// 持锁版本 — 单条逻辑消息内多次 send 的中间态期间持续持锁，
    /// 阻止其他线程插入字节流（避免 stream misaligned）。
    private func sendAll(fd: Int32, bytes: UnsafeRawPointer, length: Int) -> Bool {
        sendLock.lock()
        defer { sendLock.unlock() }
        var offset = 0
        while offset < length && !isStopped {
            // MSG_NOSIGNAL 防止 SIGPIPE 杀进程（macOS 上是 SO_NOSIGPIPE 或 MSG_NOSIGNAL）
            let n = send(fd, bytes.advanced(by: offset), length - offset, Int32(MSG_NOSIGNAL))
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            offset += n
        }
        return offset == length
    }

    // MARK: - Stats

    private func updateStats(bytes: Int, frameAgeNs: UInt64 = 0) {
        bytesSent += UInt64(bytes)
        frameCount += 1
        if frameAgeNs > 0 {
            totalFrameAgeNs += frameAgeNs
            profiledFrameCount += 1
        }

        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - lastStatsTime.uptimeNanoseconds) / 1_000_000_000

        if elapsed >= 1.0 {
            let mbps = Double(bytesSent * 8) / elapsed / 1_000_000
            let fps = Double(frameCount) / elapsed
            onStats?(fps, mbps)

            if profiledFrameCount > 0 {
                let avgAgeMs = Double(totalFrameAgeNs) / Double(profiledFrameCount) / 1_000_000.0
                debugLog("Pipeline: \(String(format: "%.1f", fps))fps, \(String(format: "%.1f", mbps))Mbps, avg frame age: \(String(format: "%.1f", avgAgeMs))ms, dropped: \(droppedFrames)")
            }

            bytesSent = 0
            frameCount = 0
            droppedFrames = 0
            totalFrameAgeNs = 0
            profiledFrameCount = 0
            lastStatsTime = now
        }
    }
}
