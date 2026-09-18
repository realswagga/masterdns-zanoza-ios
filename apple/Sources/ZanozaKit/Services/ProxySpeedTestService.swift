import Foundation
import Network

public struct ProxySpeedTestOptions: Equatable {
    public var proxyHost: String
    public var proxyPort: Int
    public var username: String?
    public var password: String?
    public var egressURL: URL
    public var downloadURL: URL
    public var uploadURL: URL
    public var uploadBytes: Int
    public var timeoutSeconds: Double

    public init(
        proxyHost: String = "127.0.0.1",
        proxyPort: Int = 41080,
        username: String? = nil,
        password: String? = nil,
        egressURL: URL = URL(string: "http://checkip.amazonaws.com/")!,
        downloadURL: URL = URL(string: "http://speedtest.tele2.net/1MB.zip")!,
        uploadURL: URL = URL(string: "http://httpbin.org/post")!,
        uploadBytes: Int = 128 * 1_024,
        timeoutSeconds: Double = 90
    ) {
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.username = username
        self.password = password
        self.egressURL = egressURL
        self.downloadURL = downloadURL
        self.uploadURL = uploadURL
        self.uploadBytes = min(max(uploadBytes, 16 * 1_024), 2 * 1_024 * 1_024)
        self.timeoutSeconds = min(max(timeoutSeconds, 5), 300)
    }
}

public struct ProxySpeedTestResult: Equatable {
    public var proxyHandshakeMS: Double
    public var egressIP: String
    public var downloadMbps: Double
    public var uploadMbps: Double
    public var downloadedBytes: Int
    public var uploadedBytes: Int
    public var completedAt: Date
}

public enum ProxySpeedTestStage: String, Equatable {
    case proxyHandshake
    case egressVerification
    case download
    case upload
}

public enum ProxySpeedTestError: LocalizedError {
    case invalidProxy
    case unsupportedURL(URL)
    case connection(String)
    case timeout(ProxySpeedTestStage)
    case socksProtocol(String)
    case proxyAuthenticationFailed
    case proxyConnectFailed(UInt8)
    case invalidHTTPResponse
    case httpStatus(Int)
    case egressVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidProxy: "The local proxy address is invalid."
        case .unsupportedURL(let url): "Only plain HTTP speed-test endpoints are supported: \(url.absoluteString)"
        case .connection(let reason): "Local proxy connection failed: \(reason)"
        case .timeout(let stage): "Proxy test timed out during \(stage.rawValue)."
        case .socksProtocol(let reason): "SOCKS5 protocol error: \(reason)"
        case .proxyAuthenticationFailed: "SOCKS5 authentication failed."
        case .proxyConnectFailed(let code): "SOCKS5 remote CONNECT failed with code \(code)."
        case .invalidHTTPResponse: "The speed-test endpoint returned an invalid HTTP response."
        case .httpStatus(let status): "The speed-test endpoint returned HTTP \(status)."
        case .egressVerificationFailed: "The request passed the SOCKS handshake but no proxy egress IP was returned."
        }
    }
}

/// Runs every request through an explicit SOCKS5 handshake to Zanoza. It does
/// not use URLSession or the system route, preventing the false-positive speed
/// results previously observed while Hiddify was active.
public final class ProxySpeedTestService: @unchecked Sendable {
    private let activeLock = NSLock()
    private var activeConnections: [UUID: AsyncTCPConnection] = [:]

    public init() {}

    public func run(
        options: ProxySpeedTestOptions,
        progress: @escaping @Sendable (ProxySpeedTestStage) -> Void = { _ in }
    ) async throws -> ProxySpeedTestResult {
        try await withTaskCancellationHandler(operation: {
            guard (1...65_535).contains(options.proxyPort), !options.proxyHost.isEmpty else {
                throw ProxySpeedTestError.invalidProxy
            }
            try Task.checkCancellation()

            progress(.proxyHandshake)
            let egress = try await request(
                url: options.egressURL,
                method: "GET",
                body: Data(),
                options: options,
                stage: .egressVerification
            )
            try Task.checkCancellation()
            progress(.egressVerification)
            let egressText = String(data: egress.body, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard ResolverEndpoint.isIPAddress(egressText) else {
                throw ProxySpeedTestError.egressVerificationFailed
            }

            progress(.download)
            let download = try await request(
                url: options.downloadURL,
                method: "GET",
                body: Data(),
                options: options,
                stage: .download
            )
            let downloadMbps = Self.megabitsPerSecond(bytes: download.body.count, seconds: download.elapsedSeconds)

            try Task.checkCancellation()
            progress(.upload)
            let uploadBody = Self.makeIncompressiblePayload(byteCount: options.uploadBytes)
            let upload = try await request(
                url: options.uploadURL,
                method: "POST",
                body: uploadBody,
                options: options,
                stage: .upload
            )
            let uploadMbps = Self.megabitsPerSecond(bytes: uploadBody.count, seconds: upload.elapsedSeconds)

            return ProxySpeedTestResult(
                proxyHandshakeMS: max(egress.handshakeMS, max(download.handshakeMS, upload.handshakeMS)),
                egressIP: egressText,
                downloadMbps: downloadMbps,
                uploadMbps: uploadMbps,
                downloadedBytes: download.body.count,
                uploadedBytes: uploadBody.count,
                completedAt: Date()
            )
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    /// Cancels all sockets owned by this test service. The service can be used
    /// again after cancellation; connections are registered per request.
    public func cancel() {
        activeLock.lock()
        let connections = Array(activeConnections.values)
        activeConnections.removeAll()
        activeLock.unlock()
        connections.forEach { $0.cancel() }
    }

    private struct HTTPResult {
        let body: Data
        let elapsedSeconds: Double
        let handshakeMS: Double
    }

    private func request(
        url: URL,
        method: String,
        body: Data,
        options: ProxySpeedTestOptions,
        stage: ProxySpeedTestStage
    ) async throws -> HTTPResult {
        guard url.scheme?.lowercased() == "http", let host = url.host else {
            throw ProxySpeedTestError.unsupportedURL(url)
        }
        let targetPort = url.port ?? 80
        let socket = AsyncTCPConnection(host: options.proxyHost, port: options.proxyPort)
        let socketID = UUID()
        register(socket, id: socketID)
        defer { unregister(id: socketID) }
        do {
            try await socket.start(timeout: min(options.timeoutSeconds, 15), stage: .proxyHandshake)
            let handshakeStart = DispatchTime.now().uptimeNanoseconds
            try await performSocksHandshake(
                socket: socket,
                targetHost: host,
                targetPort: targetPort,
                username: options.username,
                password: options.password,
                timeout: min(options.timeoutSeconds, 30)
            )
            let handshakeMS = Double(DispatchTime.now().uptimeNanoseconds - handshakeStart) / 1_000_000

            var target = url.path.isEmpty ? "/" : url.path
            if let query = url.query, !query.isEmpty { target += "?\(query)" }
            var headers = "\(method) \(target) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: Zanoza-SpeedTest/1\r\nAccept: */*\r\nConnection: close\r\n"
            if !body.isEmpty {
                headers += "Content-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\n"
            }
            headers += "\r\n"
            var request = Data(headers.utf8)
            request.append(body)

            let transferStart = DispatchTime.now().uptimeNanoseconds
            try await socket.send(request, timeout: options.timeoutSeconds, stage: stage)
            let response = try await socket.receiveUntilClose(
                maximumBytes: max(8 * 1_024 * 1_024, body.count + 1_024 * 1_024),
                timeout: options.timeoutSeconds,
                stage: stage
            )
            let elapsed = max(0.001, Double(DispatchTime.now().uptimeNanoseconds - transferStart) / 1_000_000_000)
            socket.cancel()
            let parsed = try Self.parseHTTPResponse(response)
            return HTTPResult(body: parsed, elapsedSeconds: elapsed, handshakeMS: handshakeMS)
        } catch {
            socket.cancel()
            throw error
        }
    }

    private func performSocksHandshake(
        socket: AsyncTCPConnection,
        targetHost: String,
        targetPort: Int,
        username: String?,
        password: String?,
        timeout: Double
    ) async throws {
        let hasCredentials = !(username ?? "").isEmpty || !(password ?? "").isEmpty
        try await socket.send(Data(hasCredentials ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]), timeout: timeout, stage: .proxyHandshake)
        let method = try await socket.receiveExact(2, timeout: timeout, stage: .proxyHandshake)
        guard method[0] == 0x05 else { throw ProxySpeedTestError.socksProtocol("invalid greeting version") }
        if method[1] == 0x02 {
            let userBytes = Array((username ?? "").utf8.prefix(255))
            let passBytes = Array((password ?? "").utf8.prefix(255))
            var auth = Data([0x01, UInt8(userBytes.count)])
            auth.append(contentsOf: userBytes)
            auth.append(UInt8(passBytes.count))
            auth.append(contentsOf: passBytes)
            try await socket.send(auth, timeout: timeout, stage: .proxyHandshake)
            let reply = try await socket.receiveExact(2, timeout: timeout, stage: .proxyHandshake)
            guard reply[1] == 0 else { throw ProxySpeedTestError.proxyAuthenticationFailed }
        } else if method[1] != 0x00 {
            throw ProxySpeedTestError.socksProtocol("no supported authentication method")
        }

        let hostBytes = Array(targetHost.utf8)
        guard hostBytes.count <= 255, (1...65_535).contains(targetPort) else {
            throw ProxySpeedTestError.socksProtocol("invalid target")
        }
        var connect = Data([0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)])
        connect.append(contentsOf: hostBytes)
        connect.append(UInt8((targetPort >> 8) & 0xff))
        connect.append(UInt8(targetPort & 0xff))
        try await socket.send(connect, timeout: timeout, stage: .proxyHandshake)
        let header = try await socket.receiveExact(4, timeout: timeout, stage: .proxyHandshake)
        guard header[0] == 0x05 else { throw ProxySpeedTestError.socksProtocol("invalid CONNECT reply") }
        guard header[1] == 0 else { throw ProxySpeedTestError.proxyConnectFailed(header[1]) }
        let addressLength: Int
        switch header[3] {
        case 0x01: addressLength = 4
        case 0x04: addressLength = 16
        case 0x03:
            let size = try await socket.receiveExact(1, timeout: timeout, stage: .proxyHandshake)
            addressLength = Int(size[0])
        default: throw ProxySpeedTestError.socksProtocol("invalid reply address type")
        }
        _ = try await socket.receiveExact(addressLength + 2, timeout: timeout, stage: .proxyHandshake)
    }

    static func parseHTTPResponse(_ data: Data) throws -> Data {
        let separator = Data([13, 10, 13, 10])
        guard let range = data.range(of: separator),
              let header = String(data: data[..<range.lowerBound], encoding: .isoLatin1),
              let statusLine = header.components(separatedBy: "\r\n").first else {
            throw ProxySpeedTestError.invalidHTTPResponse
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { throw ProxySpeedTestError.invalidHTTPResponse }
        guard (200..<300).contains(status) else { throw ProxySpeedTestError.httpStatus(status) }
        let headers = parseHeaders(header.components(separatedBy: "\r\n").dropFirst())
        let body = Data(data[range.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return try decodeChunkedBody(body)
        }
        if let lengthText = headers["content-length"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let contentLength = Int(lengthText) {
            guard body.count >= contentLength else { throw ProxySpeedTestError.invalidHTTPResponse }
            return Data(body.prefix(contentLength))
        }
        return body
    }

    private static func parseHeaders(_ lines: ArraySlice<String>) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return headers
    }

    private static func decodeChunkedBody(_ body: Data) throws -> Data {
        let crlf = Data([13, 10])
        var cursor = body.startIndex
        var decoded = Data()
        while cursor < body.endIndex {
            guard let lineRange = body[cursor...].range(of: crlf),
                  let line = String(data: body[cursor..<lineRange.lowerBound], encoding: .ascii) else {
                throw ProxySpeedTestError.invalidHTTPResponse
            }
            let sizeText = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? line
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else {
                throw ProxySpeedTestError.invalidHTTPResponse
            }
            cursor = lineRange.upperBound
            if size == 0 { return decoded }
            guard body.distance(from: cursor, to: body.endIndex) >= size + 2 else {
                throw ProxySpeedTestError.invalidHTTPResponse
            }
            let chunkEnd = body.index(cursor, offsetBy: size)
            decoded.append(body[cursor..<chunkEnd])
            let terminatorEnd = body.index(chunkEnd, offsetBy: 2)
            guard body[chunkEnd..<terminatorEnd].elementsEqual(crlf) else {
                throw ProxySpeedTestError.invalidHTTPResponse
            }
            cursor = terminatorEnd
        }
        throw ProxySpeedTestError.invalidHTTPResponse
    }

    private static func megabitsPerSecond(bytes: Int, seconds: Double) -> Double {
        Double(bytes) * 8 / max(seconds, 0.001) / 1_000_000
    }

    /// A repeated-byte payload can collapse to almost nothing under Zstd/LZ4
    /// and report a fictitious upload rate. Xorshift64 produces deterministic,
    /// high-entropy bytes without involving the system route or disk.
    static func makeIncompressiblePayload(byteCount: Int) -> Data {
        guard byteCount > 0 else { return Data() }
        var state: UInt64 = 0x9e3779b97f4a7c15
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in bytes.indices {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            bytes[index] = UInt8(truncatingIfNeeded: state)
        }
        return Data(bytes)
    }

    private func register(_ connection: AsyncTCPConnection, id: UUID) {
        activeLock.lock(); defer { activeLock.unlock() }
        activeConnections[id] = connection
    }

    private func unregister(id: UUID) {
        activeLock.lock(); defer { activeLock.unlock() }
        activeConnections.removeValue(forKey: id)
    }
}

private final class AsyncTCPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "io.zanoza.proxy-speed.\(UUID().uuidString)")

    init(host: String, port: Int) {
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? .init(integerLiteral: 41080)
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
    }

    func start(timeout: Double, stage: ProxySpeedTestStage) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ThrowingContinuationGate<Void>(continuation)
            queue.asyncAfter(deadline: .now() + timeout) {
                gate.fail(ProxySpeedTestError.timeout(stage), cancel: self.connection)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.succeed((), cancel: nil)
                case .failed(let error): gate.fail(ProxySpeedTestError.connection(error.localizedDescription), cancel: self.connection)
                case .cancelled: gate.fail(ProxySpeedTestError.connection("cancelled"), cancel: nil)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data, timeout: Double, stage: ProxySpeedTestStage) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ThrowingContinuationGate<Void>(continuation)
            queue.asyncAfter(deadline: .now() + timeout) {
                gate.fail(ProxySpeedTestError.timeout(stage), cancel: self.connection)
            }
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    gate.fail(ProxySpeedTestError.connection(error.localizedDescription), cancel: self.connection)
                } else {
                    gate.succeed((), cancel: nil)
                }
            })
        }
    }

    func receiveExact(_ count: Int, timeout: Double, stage: ProxySpeedTestStage) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ThrowingContinuationGate<Data>(continuation)
            var buffer = Data()
            queue.asyncAfter(deadline: .now() + timeout) {
                gate.fail(ProxySpeedTestError.timeout(stage), cancel: self.connection)
            }
            func next() {
                let needed = count - buffer.count
                guard needed > 0 else { gate.succeed(buffer, cancel: nil); return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: needed) { data, _, complete, error in
                    if let data { buffer.append(data) }
                    if let error {
                        gate.fail(ProxySpeedTestError.connection(error.localizedDescription), cancel: self.connection)
                    } else if buffer.count >= count {
                        gate.succeed(Data(buffer.prefix(count)), cancel: nil)
                    } else if complete {
                        gate.fail(ProxySpeedTestError.connection("unexpected end of stream"), cancel: self.connection)
                    } else {
                        next()
                    }
                }
            }
            next()
        }
    }

    func receiveUntilClose(maximumBytes: Int, timeout: Double, stage: ProxySpeedTestStage) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ThrowingContinuationGate<Data>(continuation)
            var buffer = Data()
            queue.asyncAfter(deadline: .now() + timeout) {
                gate.fail(ProxySpeedTestError.timeout(stage), cancel: self.connection)
            }
            func next() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { data, _, complete, error in
                    if let data { buffer.append(data) }
                    if buffer.count > maximumBytes {
                        gate.fail(ProxySpeedTestError.connection("response exceeded safety limit"), cancel: self.connection)
                    } else if let error {
                        gate.fail(ProxySpeedTestError.connection(error.localizedDescription), cancel: self.connection)
                    } else if complete {
                        gate.succeed(buffer, cancel: nil)
                    } else {
                        next()
                    }
                }
            }
            next()
        }
    }

    func cancel() { connection.cancel() }
}

private final class ThrowingContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func succeed(_ value: Value, cancel connection: NWConnection?) {
        finish(.success(value), cancel: connection)
    }

    func fail(_ error: Error, cancel connection: NWConnection?) {
        finish(.failure(error), cancel: connection)
    }

    private func finish(_ result: Result<Value, Error>, cancel connection: NWConnection?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection?.cancel()
        pending.resume(with: result)
    }
}
