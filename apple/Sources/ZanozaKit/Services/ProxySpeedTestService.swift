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
        uploadBytes: Int = 32 * 1_024,
        timeoutSeconds: Double = 30
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
    /// The actual measurement window used for the download.  It can be
    /// shorter than the configured timeout when the advertised response size
    /// has been received, and can equal the timeout for a streaming/partial
    /// response.
    public var downloadElapsedSeconds: Double = 0
    /// SOCKS/MasterDNS handshake round-trip observed immediately before the
    /// download.  This is the useful "ping" to show alongside live bytes.
    public var downloadPingMS: Double = 0
    public var uploadElapsedSeconds: Double = 0
    public var uploadPingMS: Double = 0
    /// A timeout after non-zero download bytes is a completed partial sample,
    /// not a failed resolver.  Expose that fact so the UI and evaluator can
    /// be transparent about the measurement.
    public var downloadTimedOut: Bool = false
    public var uploadTimedOut: Bool = false
    public var uploadFailureReason: String? = nil
    public var completedAt: Date
}

public enum ProxySpeedTestStage: String, Equatable, Sendable {
    case proxyHandshake
    case egressVerification
    case download
    case upload
}

public struct ProxySpeedTestProgress: Equatable, Sendable {
    public let stage: ProxySpeedTestStage
    /// Bytes received/sent for the active transfer when known.
    public let completedBytes: Int
    public let totalBytes: Int?
    public let fraction: Double
    public let latencyMS: Double?
    public let bytesPerSecond: Double?
    public let elapsedSeconds: Double?
    public let detail: String

    public init(
        stage: ProxySpeedTestStage,
        completedBytes: Int = 0,
        totalBytes: Int? = nil,
        fraction: Double = 0,
        latencyMS: Double? = nil,
        bytesPerSecond: Double? = nil,
        elapsedSeconds: Double? = nil,
        detail: String = ""
    ) {
        self.stage = stage
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = totalBytes
        self.fraction = min(max(fraction, 0), 1)
        self.latencyMS = latencyMS
        self.bytesPerSecond = bytesPerSecond
        self.elapsedSeconds = elapsedSeconds
        self.detail = detail
    }
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
        try await runDetailed(options: options) { update in
            progress(update.stage)
        }
    }

    public func runDetailed(
        options: ProxySpeedTestOptions,
        progress: @escaping @Sendable (ProxySpeedTestProgress) -> Void = { _ in }
    ) async throws -> ProxySpeedTestResult {
        try await withTaskCancellationHandler(operation: {
            guard (1...65_535).contains(options.proxyPort), !options.proxyHost.isEmpty else {
                throw ProxySpeedTestError.invalidProxy
            }
            try Task.checkCancellation()

            progress(ProxySpeedTestProgress(stage: .proxyHandshake, detail: "Opening local SOCKS connection"))
            let egress = try await request(
                url: options.egressURL,
                method: "GET",
                body: Data(),
                options: options,
                stage: .egressVerification,
                allowPartialOnTimeout: true,
                progress: progress
            )
            try Task.checkCancellation()
            progress(ProxySpeedTestProgress(stage: .egressVerification, fraction: 1, detail: "Remote egress verified"))
            let egressText = String(data: egress.body, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard ResolverEndpoint.isIPAddress(egressText) else {
                throw ProxySpeedTestError.egressVerificationFailed
            }

            progress(ProxySpeedTestProgress(stage: .download, detail: "Downloading through proxy"))
            let download = try await request(
                url: options.downloadURL,
                method: "GET",
                body: Data(),
                options: options,
                stage: .download,
                allowPartialOnTimeout: true,
                progress: progress
            )
            let downloadMbps = Self.megabitsPerSecond(bytes: download.body.count, seconds: download.elapsedSeconds)

            try Task.checkCancellation()
            progress(ProxySpeedTestProgress(stage: .upload, detail: "Uploading incompressible payload"))
            let uploadBody = Self.makeIncompressiblePayload(byteCount: options.uploadBytes)
            let upload: HTTPResult?
            let uploadFailureReason: String?
            do {
                upload = try await request(
                    url: options.uploadURL,
                    method: "POST",
                    body: uploadBody,
                    options: options,
                    stage: .upload,
                    allowPartialOnTimeout: true,
                    progress: progress
                )
                uploadFailureReason = nil
            } catch {
                // Upload response endpoints frequently buffer or keep the
                // connection open.  Keep the valid download sample instead
                // of throwing away the whole resolver when that response is
                // unavailable.  The reason remains visible in the result.
                upload = nil
                uploadFailureReason = error.localizedDescription
                progress(ProxySpeedTestProgress(
                    stage: .upload,
                    latencyMS: nil,
                    detail: "Upload unavailable; download retained · " + error.localizedDescription
                ))
            }
            let uploadMbps = upload.map {
                Self.megabitsPerSecond(bytes: uploadBody.count, seconds: $0.elapsedSeconds)
            } ?? 0

            return ProxySpeedTestResult(
                proxyHandshakeMS: max(egress.handshakeMS, max(download.handshakeMS, upload?.handshakeMS ?? 0)),
                egressIP: egressText,
                downloadMbps: downloadMbps,
                uploadMbps: uploadMbps,
                downloadedBytes: download.body.count,
                uploadedBytes: uploadBody.count,
                downloadElapsedSeconds: download.elapsedSeconds,
                downloadPingMS: download.handshakeMS,
                uploadElapsedSeconds: upload?.elapsedSeconds ?? 0,
                uploadPingMS: upload?.handshakeMS ?? 0,
                downloadTimedOut: download.timedOut,
                uploadTimedOut: upload?.timedOut ?? (uploadFailureReason != nil),
                uploadFailureReason: uploadFailureReason,
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
        let timedOut: Bool
    }

    private struct ParsedHTTPTransfer {
        let body: Data
        let headers: [String: String]
        let statusCode: Int
        let bodyComplete: Bool
    }

    private func request(
        url: URL,
        method: String,
        body: Data,
        options: ProxySpeedTestOptions,
        stage: ProxySpeedTestStage,
        allowPartialOnTimeout: Bool = false,
        progress: @escaping @Sendable (ProxySpeedTestProgress) -> Void
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
            if !body.isEmpty {
                progress(ProxySpeedTestProgress(
                    stage: stage,
                    completedBytes: body.count,
                    totalBytes: body.count,
                    fraction: 1,
                    latencyMS: handshakeMS,
                    elapsedSeconds: max(0.001, Double(DispatchTime.now().uptimeNanoseconds - transferStart) / 1_000_000_000),
                    detail: "upload payload sent; waiting for remote response · ping " + Self.formatMilliseconds(handshakeMS)
                ))
            } else if stage == .download {
                progress(ProxySpeedTestProgress(
                    stage: stage,
                    latencyMS: handshakeMS,
                    elapsedSeconds: max(0.001, Double(DispatchTime.now().uptimeNanoseconds - transferStart) / 1_000_000_000),
                    detail: "download request sent; waiting for bytes · ping " + Self.formatMilliseconds(handshakeMS)
                ))
            }
            let expectedHint = method == "GET" ? expectedContentLength(from: url) : nil
            let response = try await socket.receiveUntilClose(
                maximumBytes: max(8 * 1_024 * 1_024, body.count + 1_024 * 1_024),
                timeout: options.timeoutSeconds,
                stage: stage,
                stopWhen: { data in
                    guard allowPartialOnTimeout, method == "GET" else { return false }
                    guard let expected = Self.expectedBodyLength(in: data, fallback: expectedHint) else {
                        return false
                    }
                    return Self.bodyByteCount(in: data) >= expected
                },
                progress: { bytes in
                    let bodyBytes = Self.bodyByteCount(in: bytes)
                    let total = method == "POST"
                        ? nil
                        : Self.expectedBodyLength(in: bytes, fallback: expectedHint)
                    let fraction = total.map { min(1, Double(bodyBytes) / Double(max(1, $0))) } ?? 0
                    let elapsed = max(0.001, Double(DispatchTime.now().uptimeNanoseconds - transferStart) / 1_000_000_000)
                    let rate = Double(bodyBytes) / elapsed
                    progress(ProxySpeedTestProgress(
                        stage: stage,
                        completedBytes: bodyBytes,
                        totalBytes: total,
                        fraction: fraction,
                        latencyMS: handshakeMS,
                        bytesPerSecond: rate,
                        elapsedSeconds: elapsed,
                        detail: stage.rawValue + ": "
                            + ByteCountFormatter.string(fromByteCount: Int64(bodyBytes), countStyle: .file)
                            + " · " + Self.formatRate(rate)
                            + " · ping " + Self.formatMilliseconds(handshakeMS)
                    ))
                }
            )
            let elapsed = max(0.001, Double(DispatchTime.now().uptimeNanoseconds - transferStart) / 1_000_000_000)
            socket.cancel()
            let parsed: ParsedHTTPTransfer
            do {
                parsed = try Self.parseHTTPTransfer(
                    response.data,
                    allowPartial: allowPartialOnTimeout || response.stoppedEarly
                )
            } catch {
                // A timeout with no response bytes is the only case that is
                // considered a throughput timeout.  Preserve normal HTTP and
                // SOCKS errors so they remain actionable in the log.
                if response.timedOut && Self.bodyByteCount(in: response.data) == 0 {
                    throw ProxySpeedTestError.timeout(stage)
                }
                if stage == .download,
                   Self.bodyByteCount(in: response.data) == 0,
                   !Self.isHTTPStatusError(error) {
                    throw ProxySpeedTestError.timeout(stage)
                }
                throw error
            }
            if response.timedOut && !allowPartialOnTimeout {
                throw ProxySpeedTestError.timeout(stage)
            }
            if stage == .download && parsed.body.isEmpty {
                // Headers alone do not demonstrate a working resolver.  A
                // non-zero body is the explicit success boundary for the
                // bounded download measurement.
                throw ProxySpeedTestError.timeout(stage)
            }
            if stage == .download {
                let finalRate = Double(parsed.body.count) / elapsed
                let sampleTimedOut = (response.timedOut || response.stoppedEarly) && !parsed.bodyComplete
                let windowLabel = sampleTimedOut ? "measurement window ended" : "download complete"
                progress(ProxySpeedTestProgress(
                    stage: stage,
                    completedBytes: parsed.body.count,
                    totalBytes: Self.expectedBodyLength(in: response.data, fallback: expectedHint),
                    fraction: Self.expectedBodyLength(in: response.data, fallback: expectedHint)
                        .map { min(1, Double(parsed.body.count) / Double(max(1, $0))) } ?? 0,
                    latencyMS: handshakeMS,
                    bytesPerSecond: finalRate,
                    elapsedSeconds: elapsed,
                    detail: windowLabel + ": "
                        + ByteCountFormatter.string(fromByteCount: Int64(parsed.body.count), countStyle: .file)
                        + " · " + Self.formatRate(finalRate)
                        + " · ping " + Self.formatMilliseconds(handshakeMS)
                ))
            }
            return HTTPResult(
                body: parsed.body,
                elapsedSeconds: elapsed,
                handshakeMS: handshakeMS,
                timedOut: (response.timedOut || response.stoppedEarly) && !parsed.bodyComplete
            )
        } catch {
            socket.cancel()
            throw error
        }
    }

    // The standard speed-test URL has a stable 1 MiB object, but the response
    // header is not available until after the stream starts. This hint keeps
    // progress useful without making correctness depend on a content length.
    private func expectedContentLength(from url: URL) -> Int? {
        if url.path.lowercased().contains("1mb") { return 1 * 1_024 * 1_024 }
        return nil
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
        try parseHTTPTransfer(data, allowPartial: false).body
    }

    /// Test/diagnostic hook used by the evaluator to verify that a response
    /// snapshot can be ranked before its origin closes the connection.
    static func parseHTTPResponseSnapshot(_ data: Data) throws -> (bytes: Int, complete: Bool) {
        let parsed = try parseHTTPTransfer(data, allowPartial: true)
        return (parsed.body.count, parsed.bodyComplete)
    }

    /// Parses a response incrementally.  `allowPartial` is used only by the
    /// bounded throughput window: a valid 2xx response with a non-zero body
    /// is useful even when the origin has not closed the stream yet.
    private static func parseHTTPTransfer(
        _ data: Data,
        allowPartial: Bool
    ) throws -> ParsedHTTPTransfer {
        let separator = Data([13, 10, 13, 10])
        guard let range = data.range(of: separator),
              let header = String(data: data[..<range.lowerBound], encoding: .isoLatin1),
              let statusLine = header.components(separatedBy: "\r\n").first else {
            throw ProxySpeedTestError.invalidHTTPResponse
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw ProxySpeedTestError.invalidHTTPResponse
        }
        guard (200..<300).contains(status) else { throw ProxySpeedTestError.httpStatus(status) }
        let headers = parseHeaders(header.components(separatedBy: "\r\n").dropFirst())
        let rawBody = Data(data[range.upperBound...])

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            let decoded = try decodeChunkedBodyPartial(rawBody, allowPartial: allowPartial)
            return ParsedHTTPTransfer(
                body: decoded.body,
                headers: headers,
                statusCode: status,
                bodyComplete: decoded.complete
            )
        }

        if let lengthText = headers["content-length"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let contentLength = Int(lengthText), contentLength >= 0 {
            guard rawBody.count >= contentLength || allowPartial else {
                throw ProxySpeedTestError.invalidHTTPResponse
            }
            return ParsedHTTPTransfer(
                body: Data(rawBody.prefix(min(contentLength, rawBody.count))),
                headers: headers,
                statusCode: status,
                bodyComplete: rawBody.count >= contentLength
            )
        }

        return ParsedHTTPTransfer(
            body: rawBody,
            headers: headers,
            statusCode: status,
            // With no framing metadata, EOF is the only completion signal.
            bodyComplete: !allowPartial
        )
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

    private static func decodeChunkedBodyPartial(
        _ body: Data,
        allowPartial: Bool
    ) throws -> (body: Data, complete: Bool) {
        let crlf = Data([13, 10])
        var cursor = body.startIndex
        var decoded = Data()
        while cursor < body.endIndex {
            guard let lineRange = body[cursor...].range(of: crlf),
                  let line = String(data: body[cursor..<lineRange.lowerBound], encoding: .ascii) else {
                if allowPartial { return (decoded, false) }
                throw ProxySpeedTestError.invalidHTTPResponse
            }
            let sizeText = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? line
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else {
                throw ProxySpeedTestError.invalidHTTPResponse
            }
            cursor = lineRange.upperBound
            if size == 0 { return (decoded, true) }
            let available = body.distance(from: cursor, to: body.endIndex)
            guard available >= size + 2 else {
                if allowPartial {
                    // Count payload bytes already received even when the
                    // final CRLF (or the rest of this chunk) is missing.
                    let payloadCount = min(size, available)
                    if payloadCount > 0 {
                        let end = body.index(cursor, offsetBy: payloadCount)
                        decoded.append(body[cursor..<end])
                    }
                    return (decoded, false)
                }
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
        if allowPartial { return (decoded, false) }
        throw ProxySpeedTestError.invalidHTTPResponse
    }

    /// Returns decoded payload bytes, excluding HTTP headers and chunk framing,
    /// for a response snapshot received so far.  This is deliberately
    /// best-effort because it runs for every socket read while the body is
    /// still being assembled.
    private static func bodyByteCount(in data: Data) -> Int {
        let separator = Data([13, 10, 13, 10])
        guard let range = data.range(of: separator),
              let header = String(data: data[..<range.lowerBound], encoding: .isoLatin1) else {
            return 0
        }
        let headers = parseHeaders(header.components(separatedBy: "\r\n").dropFirst())
        let rawBodyCount = data.distance(from: range.upperBound, to: data.endIndex)
        if headers["transfer-encoding"]?.lowercased().contains("chunked") != true {
            if let contentLength = headers["content-length"].flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), contentLength >= 0 {
                return min(rawBodyCount, contentLength)
            }
            return rawBodyCount
        }
        do {
            return try parseHTTPTransfer(data, allowPartial: true).body.count
        } catch {
            return rawBodyCount
        }
    }

    private static func expectedBodyLength(in data: Data, fallback: Int?) -> Int? {
        let separator = Data([13, 10, 13, 10])
        guard let range = data.range(of: separator),
              let header = String(data: data[..<range.lowerBound], encoding: .isoLatin1) else {
            return fallback
        }
        let headers = parseHeaders(header.components(separatedBy: "\r\n").dropFirst())
        if let value = headers["content-length"].flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), value >= 0 {
            return value
        }
        return fallback
    }

    private static func formatRate(_ bytesPerSecond: Double) -> String {
        String(format: "%.2f Mbit/s", bytesPerSecond * 8 / 1_000_000)
    }

    private static func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.0f ms", max(0, value))
    }

    private static func isHTTPStatusError(_ error: Error) -> Bool {
        guard let value = error as? ProxySpeedTestError else { return false }
        if case .httpStatus = value { return true }
        return false
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
    struct ReceiveResult: Sendable {
        let data: Data
        let timedOut: Bool
        let stoppedEarly: Bool
    }

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

    func receiveUntilClose(
        maximumBytes: Int,
        timeout: Double,
        stage: ProxySpeedTestStage,
        stopWhen: @escaping @Sendable (Data) -> Bool = { _ in false },
        progress: @escaping @Sendable (Data) -> Void = { _ in }
    ) async throws -> ReceiveResult {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ThrowingContinuationGate<ReceiveResult>(continuation)
            let buffer = ReceiveBuffer()
            queue.asyncAfter(deadline: .now() + timeout) {
                gate.succeed(
                    ReceiveResult(data: buffer.snapshot(), timedOut: true, stoppedEarly: false),
                    cancel: self.connection
                )
            }
            func next() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { data, _, complete, error in
                    if let data { buffer.append(data) }
                    let snapshot = buffer.snapshot()
                    progress(snapshot)
                    if snapshot.count > maximumBytes {
                        gate.succeed(
                            ReceiveResult(data: snapshot, timedOut: false, stoppedEarly: true),
                            cancel: self.connection
                        )
                    } else if let error {
                        // A reset after payload bytes is still a useful
                        // bounded sample.  Only an empty response is allowed
                        // to become a hard connection failure.
                        if snapshot.isEmpty {
                            gate.fail(ProxySpeedTestError.connection(error.localizedDescription), cancel: self.connection)
                        } else {
                            gate.succeed(
                                ReceiveResult(data: snapshot, timedOut: false, stoppedEarly: true),
                                cancel: self.connection
                            )
                        }
                    } else if stopWhen(snapshot) {
                        gate.succeed(
                            ReceiveResult(data: snapshot, timedOut: false, stoppedEarly: true),
                            cancel: self.connection
                        )
                    } else if complete {
                        gate.succeed(
                            ReceiveResult(data: snapshot, timedOut: false, stoppedEarly: false),
                            cancel: nil
                        )
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

private final class ReceiveBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func append(_ data: Data) {
        lock.lock()
        value.append(data)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
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
