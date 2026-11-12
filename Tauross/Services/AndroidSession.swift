import Foundation
import Darwin

final class StreamSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(port: UInt16) throws {
        fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TaurossError.message("Unable to create the video socket.") }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); fd = -1; throw TaurossError.message("Unable to connect to the Android stream.") }
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    // shutdown unblocks recv; descriptor stays owned until deinit to avoid descriptor-reuse races.
    func cancel() { lock.lock(); defer { lock.unlock() }; if fd >= 0 { shutdown(fd, SHUT_RDWR) } }
    func read(_ count: Int, idleAllowed: Bool = false, cancelled: () -> Bool = { false }) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var received = 0
            while received < count {
                if cancelled() { throw CancellationError() }
                let n = recv(fd, bytes.baseAddress!.advanced(by: received), count - received, 0)
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && idleAllowed { continue }
                guard n > 0 else { throw TaurossError.message("Android stream disconnected. Check the cable, device lock screen, or Wi-Fi connection.") }
                received += n
            }
        }
        return result
    }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let n = send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw TaurossError.message("Unable to send input to Android.") }
                sent += n
            }
        }
    }
}

final class AndroidSession: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var video: StreamSocket?
    private var control: StreamSocket?
    private let inputQueue = DispatchQueue(label: "com.tauross.input")
    private var log = ""
    private let surface: VideoSurface
    private let onFailure: @Sendable (String) -> Void

    init(surface: VideoSurface, onFailure: @escaping @Sendable (String) -> Void) {
        self.surface = surface; self.onFailure = onFailure
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func check() throws { if isStopped { throw CancellationError() } }
    func start(device: MirrorDevice, options: StreamOptions) {
        DispatchQueue(label: "com.tauross.android", qos: .userInteractive).async { [self] in
            do { try stream(device: device, options: options) }
            catch {
                if !isStopped {
                    lock.lock(); let details = log; lock.unlock()
                    onFailure(error.localizedDescription + (details.isEmpty ? "" : "\n\n" + details))
                }
            }
            stop()
        }
    }
    func stop() {
        lock.lock(); stopped = true; let sockets = [video, control]; lock.unlock()
        sockets.forEach { $0?.cancel() }
    }
    func send(_ data: Data) {
        inputQueue.async { [self] in
            lock.lock(); let socket = stopped ? nil : control; lock.unlock()
            do { try socket?.write(data) }
            catch { if !isStopped { onFailure(error.localizedDescription); stop() } }
        }
    }
    func key(_ code: UInt32) { send(ScrcpyControl.key(code, down: true)); send(ScrcpyControl.key(code, down: false)) }

    private func install(_ socket: StreamSocket, isControl: Bool) throws {
        lock.lock()
        if stopped { lock.unlock(); socket.cancel(); throw CancellationError() }
        if isControl { control = socket } else { video = socket }
        lock.unlock()
    }

    private func stream(device: MirrorDevice, options: StreamOptions) throws {
        let prefix = ["-s", device.id]
        let scid = String(format: "%08x", UInt32.random(in: 1...0x7fffffff))
        let remote = "/data/local/tmp/tauross-\(scid).jar"
        let server = try BundledTools.url("scrcpy-server")
        var port: String?
        var process: Process?
        var pipe: Pipe?
        defer {
            lock.lock(); let sockets = [video, control]; lock.unlock()
            sockets.forEach { $0?.cancel() }
            pipe?.fileHandleForReading.readabilityHandler = nil
            if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
            if let port { _ = try? ADBService.runSync(prefix + ["forward", "--remove", "tcp:\(port)"]) }
            _ = try? ADBService.runSync(prefix + ["shell", "rm", "-f", remote], timeout: 5)
        }
        try check()
        _ = try ADBService.runSync(prefix + ["push", server.path, remote])
        try check()
        port = try ADBService.runSync(prefix + ["forward", "tcp:0", "localabstract:scrcpy_\(scid)"])
        guard let port, let number = UInt16(port) else { throw TaurossError.message("ADB could not allocate a streaming port.") }
        try check()
        let runner = try ADBService.process(prefix + ["shell", "CLASSPATH=\(remote)", "app_process", "/", "com.genymobile.scrcpy.Server", "3.3.4", "scid=\(scid)"] + options.serverArguments)
        let output = Pipe(); pipe = output
        runner.standardOutput = output; runner.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.lock(); self.log = String((self.log + String(decoding: data, as: UTF8.self)).suffix(3000)); self.lock.unlock()
        }
        try runner.run(); process = runner
        var connected: StreamSocket?
        // ADB accepts a TCP connection before the device's abstract socket exists; the dummy byte proves readiness.
        for _ in 0..<60 {
            try check()
            guard runner.isRunning else { break }
            do {
                let candidate = try StreamSocket(port: number)
                try install(candidate, isControl: false)
                _ = try candidate.read(1, cancelled: { self.isStopped })
                connected = candidate; break
            } catch {
                try check()
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        guard let connected else { throw TaurossError.message("Unable to start scrcpy-server on the device.") }
        if options.control { try install(StreamSocket(port: number), isControl: true) }
        _ = try connected.read(64) // Device name.
        let header = try connected.read(12)
        guard header.unsignedBE(at: 0, count: 4) == 0x68323634 else { throw TaurossError.message("The device did not provide an H.264 stream.") }
        let decoder = H264Decoder(surface: surface)
        while !isStopped {
            let header = try connected.read(12, idleAllowed: true, cancelled: { self.isStopped })
            let flagsAndPTS = header.unsignedBE(at: 0, count: 8)
            let size = Int(header.unsignedBE(at: 8, count: 4))
            guard size > 0 && size <= 32 * 1024 * 1024 else { throw TaurossError.message("Invalid video packet size.") }
            let data = try connected.read(size, cancelled: { self.isStopped })
            surface.addBytes(size + 12)
            try decoder.consume(data, pts: flagsAndPTS & 0x3fffffffffffffff, config: flagsAndPTS & 0x8000000000000000 != 0)
        }
    }
}
