import Foundation
import Network

#if canImport(Mobile)
import Mobile
#endif

public struct ResolverScanOptions: Equatable {
    public var attempts: Int
    public var timeoutSeconds: Double
    public var maximumConcurrency: Int
    public var runMasterDnsMTUProbe: Bool
    public var nativeScanTimeoutSeconds: Double
    public var allowPrivateResolvers: Bool
    public var runThroughputProbe: Bool
    public var throughputCandidateLimit: Int
    public var throughputProxyPort: Int
    public var throughputReadinessTimeoutSeconds: Double
    public var throughputTestTimeoutSeconds: Double
    public var throughputUploadBytes: Int
    public var throughputEgressURL: URL
    public var throughputDownloadURL: URL
    public var throughputUploadURL: URL
    /// Domains used for the carrier/DHCP reconciliation stage.  An empty
    /// value preserves the historical single delegated-domain probe.
    public var reconciliationDomains: [String]
    /// DNS record types represented by the wire query (1=A, 28=AAAA).
    public var reconciliationRecordTypes: [UInt16]

    public init(
        attempts: Int = 5,
        timeoutSeconds: Double = 2,
        maximumConcurrency: Int = 32,
        runMasterDnsMTUProbe: Bool = true,
        nativeScanTimeoutSeconds: Double = 300,
        allowPrivateResolvers: Bool = true,
        runThroughputProbe: Bool = false,
        throughputCandidateLimit: Int = 5,
        throughputProxyPort: Int = 41_180,
        throughputReadinessTimeoutSeconds: Double = 30,
        throughputTestTimeoutSeconds: Double = 15,
        throughputUploadBytes: Int = 32 * 1_024,
        throughputEgressURL: URL = URL(string: "http://checkip.amazonaws.com/")!,
        throughputDownloadURL: URL = URL(string: "http://speedtest.tele2.net/1MB.zip")!,
        throughputUploadURL: URL = URL(string: "http://httpbin.org/post")!,
        reconciliationDomains: [String] = [],
        reconciliationRecordTypes: [UInt16] = [1, 28]
    ) {
        self.attempts = min(max(attempts, 1), 20)
        self.timeoutSeconds = min(max(timeoutSeconds, 0.25), 10)
        self.maximumConcurrency = min(max(maximumConcurrency, 1), 64)
        self.runMasterDnsMTUProbe = runMasterDnsMTUProbe
        self.nativeScanTimeoutSeconds = min(max(nativeScanTimeoutSeconds, 5), 3_600)
        self.allowPrivateResolvers = allowPrivateResolvers
        self.runThroughputProbe = runThroughputProbe
        self.throughputCandidateLimit = min(max(throughputCandidateLimit, 1), 20)
        self.throughputProxyPort = min(max(throughputProxyPort, 1_024), 65_535)
        self.throughputReadinessTimeoutSeconds = min(max(throughputReadinessTimeoutSeconds, 10), 180)
        self.throughputTestTimeoutSeconds = min(max(throughputTestTimeoutSeconds, 5), 120)
        self.throughputUploadBytes = min(max(throughputUploadBytes, 16 * 1_024), 2 * 1_024 * 1_024)
        self.throughputEgressURL = throughputEgressURL
        self.throughputDownloadURL = throughputDownloadURL
        self.throughputUploadURL = throughputUploadURL
        self.reconciliationDomains = Array(reconciliationDomains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty && $0.contains(".") }
            .prefix(12))
        let supported = reconciliationRecordTypes.filter { $0 == 1 || $0 == 28 }
        self.reconciliationRecordTypes = supported.isEmpty ? [1] : Array(supported.prefix(4))
    }
}

public struct ResolverScanProgress: Equatable {
    public enum Stage: String {
        case reachability
        case masterDnsMTU
        case throughput
        case complete
    }

    public let stage: Stage
    public let completed: Int
    public let total: Int
    public let accepted: Int
    public let detail: String
    /// Fractional progress is used while one native probe or throughput
    /// request is in flight. `completed` remains the count of finished items,
    /// preserving the old API semantics for callers that do not need it.
    public let fraction: Double
    /// Partial measurements, emitted periodically so the evaluator can sort
    /// and display rows while a large pool is still being tested.
    public let snapshot: [ResolverEvaluation]

    public init(
        stage: Stage,
        completed: Int,
        total: Int,
        accepted: Int,
        detail: String,
        fraction: Double = 1,
        snapshot: [ResolverEvaluation] = []
    ) {
        self.stage = stage
        self.completed = completed
        self.total = total
        self.accepted = accepted
        self.detail = detail
        self.fraction = min(max(fraction, 0), 1)
        self.snapshot = snapshot
    }
}

public enum ResolverScannerError: LocalizedError {
    case emptyPreset
    case tunnelMustBeStopped
    case nativeScannerUnavailable
    case nativeScanFailed(String)
    case invalidNativeResponse

    public var errorDescription: String? {
        switch self {
        case .emptyPreset: "The resolver preset is empty."
        case .tunnelMustBeStopped: "Disconnect Zanoza before scanning resolvers."
        case .nativeScannerUnavailable: "The MasterDNS scanner is unavailable in this build."
        case .nativeScanFailed(let reason): "MasterDNS scan failed: \(reason)"
        case .invalidNativeResponse: "MasterDNS returned an invalid scan result."
        }
    }
}

public final class ResolverScannerService: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (ResolverScanProgress) -> Void

    public init() {}

    public func evaluate(
        preset: ResolverPreset,
        profile: ConnectionProfile,
        settings: AppSettings,
        options: ResolverScanOptions = ResolverScanOptions(),
        runtimeDirectory: URL,
        boundInterface: String = "",
        boundIPv4: String = "",
        boundIPv6: String = "",
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> [ResolverEvaluation] {
        guard !preset.endpoints.isEmpty else { throw ResolverScannerError.emptyPreset }

        let directResults = await probeReachability(
            preset.endpoints,
            domain: profile.domain,
            domains: options.reconciliationDomains,
            recordTypes: options.reconciliationRecordTypes,
            options: options,
            progress: progress
        )
        var merged = directResults
        var completionDetail = "Reachability evaluation complete"
        if options.runMasterDnsMTUProbe {
            let nativeCandidates = preset.endpoints.filter {
                !$0.isProhibitedForScanning && (options.allowPrivateResolvers || !$0.isPrivateOrLocal)
            }
            progress(ResolverScanProgress(
                stage: .masterDnsMTU,
                completed: 0,
                total: nativeCandidates.count,
                accepted: 0,
                detail: "Running encrypted MasterDNS MTU probes",
                fraction: 0
            ))

            if !nativeCandidates.isEmpty {
                let native = try await runNativeScan(
                    endpoints: nativeCandidates,
                    profile: profile,
                    settings: settings,
                    runtimeDirectory: runtimeDirectory,
                    timeoutSeconds: options.nativeScanTimeoutSeconds,
                    boundInterface: boundInterface,
                    boundIPv4: boundIPv4,
                    boundIPv6: boundIPv6,
                    progress: progress,
                    total: nativeCandidates.count
                )
                let nativeByEndpoint = Dictionary(uniqueKeysWithValues: native.results.map {
                    (ResolverEndpoint(host: $0.resolver, port: $0.port)?.id ?? "\($0.resolver):\($0.port)", $0)
                })
                merged = directResults.map { direct -> ResolverEvaluation in
                    guard let result = nativeByEndpoint[direct.endpoint.id] else { return direct }
                    var value = direct
                    value.uploadMTU = result.uploadMTU > 0 ? result.uploadMTU : nil
                    value.downloadMTU = result.downloadMTU > 0 ? result.downloadMTU : nil
                    value.tunnelLatencyMS = result.tunnelLatencyMS > 0 ? result.tunnelLatencyMS : nil
                    value.status = result.probeSucceeded ? .tunnelAccepted : .tunnelRejected
                    if !result.accepted { value.failureReason = result.status }
                    return value
                }
                progress(ResolverScanProgress(
                    stage: .masterDnsMTU,
                    completed: nativeCandidates.count,
                    total: nativeCandidates.count,
                    accepted: native.results.filter(\.accepted).count,
                    detail: native.error ?? "MasterDNS MTU evaluation complete",
                    fraction: 1,
                    snapshot: merged
                ))
                completionDetail = native.error ?? "MasterDNS MTU evaluation complete"
            } else {
                completionDetail = "No resolvers were eligible for an encrypted MTU probe"
            }
        }

        if options.runThroughputProbe {
            merged = try await runThroughputEvaluation(
                evaluations: merged,
                requireNativeAcceptance: options.runMasterDnsMTUProbe,
                profile: profile,
                settings: settings,
                options: options,
                runtimeDirectory: runtimeDirectory,
                boundInterface: boundInterface,
                boundIPv4: boundIPv4,
                boundIPv6: boundIPv6,
                progress: progress
            )
            completionDetail = "Bounded single-resolver throughput evaluation complete"
        }

        let accepted = options.runMasterDnsMTUProbe
            ? merged.filter(\.tunnelViable).count
            : merged.filter { $0.replies > 0 }.count
        progress(ResolverScanProgress(
            stage: .complete,
            completed: merged.count,
            total: merged.count,
            accepted: accepted,
            detail: completionDetail,
            fraction: 1,
            snapshot: merged
        ))
        return merged
    }

    public func cancelNativeScan() {
        #if canImport(Mobile)
        MobileCancelScan()
        #endif
    }

    private func probeReachability(
        _ endpoints: [ResolverEndpoint],
        domain: String,
        domains: [String],
        recordTypes: [UInt16],
        options: ResolverScanOptions,
        progress: @escaping ProgressHandler
    ) async -> [ResolverEvaluation] {
        var results: [ResolverEvaluation] = []
        var nextIndex = 0
        let concurrency = min(options.maximumConcurrency, endpoints.count)

        await withTaskGroup(of: ResolverEvaluation.self) { group in
            while nextIndex < concurrency {
                let endpoint = endpoints[nextIndex]
                group.addTask { [self] in
                    await evaluateReachability(
                        endpoint,
                        domain: domain,
                        domains: domains,
                        recordTypes: recordTypes,
                        options: options
                    )
                }
                nextIndex += 1
            }
            while let result = await group.next() {
                results.append(result)
                let accepted = results.filter { $0.replies > 0 }.count
                progress(ResolverScanProgress(
                    stage: .reachability,
                    completed: results.count,
                    total: endpoints.count,
                    accepted: accepted,
                    detail: result.endpoint.canonicalAddress,
                    snapshot: results.count == endpoints.count || results.count.isMultiple(of: 5) ? results : []
                ))
                if nextIndex < endpoints.count {
                    let endpoint = endpoints[nextIndex]
                    group.addTask { [self] in
                        await evaluateReachability(
                            endpoint,
                            domain: domain,
                            domains: domains,
                            recordTypes: recordTypes,
                            options: options
                        )
                    }
                    nextIndex += 1
                }
            }
        }
        let order = Dictionary(uniqueKeysWithValues: endpoints.enumerated().map { ($1.id, $0) })
        return results.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }

    private func evaluateReachability(
        _ endpoint: ResolverEndpoint,
        domain: String,
        domains: [String],
        recordTypes: [UInt16],
        options: ResolverScanOptions
    ) async -> ResolverEvaluation {
        if endpoint.isProhibitedForScanning {
            return ResolverEvaluation(endpoint: endpoint, status: .prohibited, failureReason: "Prohibited scan range")
        }
        if endpoint.isPrivateOrLocal && !options.allowPrivateResolvers {
            return ResolverEvaluation(endpoint: endpoint, status: .failed, failureReason: "Private resolver probing is disabled")
        }

        let probeDomains = domains.isEmpty ? [domain] : domains
        var latencies: [Double] = []
        let totalAttempts = options.attempts * probeDomains.count * max(1, recordTypes.count)
        for name in probeDomains {
            for recordType in recordTypes {
                for _ in 0..<options.attempts {
                    if Task.isCancelled {
                        return ResolverEvaluation(endpoint: endpoint, status: .cancelled, attempts: latencies.count, replies: latencies.count)
                    }
                    // Use a nonce only for the delegated profile domain. For
                    // autonomous reconciliation the fixed public names are
                    // intentionally used to compare cached/carrier behaviour.
                    let queryDomain: String
                    if domains.isEmpty {
                        let nonce = UUID().uuidString.prefix(8).lowercased()
                        queryDomain = "z\(nonce).\(name)"
                    } else {
                        queryDomain = name
                    }
                    if let latency = await probeOnce(
                        endpoint: endpoint,
                        domain: queryDomain,
                        recordType: recordType,
                        timeout: options.timeoutSeconds
                    ) {
                        latencies.append(latency)
                    }
                }
            }
        }
        let replies = latencies.count
        let loss = 100 * (1 - Double(replies) / Double(max(1, totalAttempts)))
        guard replies > 0 else {
            return ResolverEvaluation(
                endpoint: endpoint,
                status: .failed,
                attempts: totalAttempts,
                replies: 0,
                lossPercent: 100,
                failureReason: "No matching DNS response"
            )
        }
        let sorted = latencies.sorted()
        let median = sorted[sorted.count / 2]
        let mean = latencies.reduce(0, +) / Double(latencies.count)
        let jitter = latencies.map { abs($0 - mean) }.reduce(0, +) / Double(latencies.count)
        return ResolverEvaluation(
            endpoint: endpoint,
            status: .reachable,
            attempts: totalAttempts,
            replies: replies,
            medianLatencyMS: median,
            jitterMS: jitter,
            lossPercent: loss
        )
    }

    private func probeOnce(
        endpoint: ResolverEndpoint,
        domain: String,
        recordType: UInt16 = 1,
        timeout: Double
    ) async -> Double? {
        let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) ?? .init(integerLiteral: 53)
        let parameters = NWParameters.udp
        parameters.prohibitedInterfaceTypes = [.other]
        parameters.prohibitExpensivePaths = false
        parameters.prohibitConstrainedPaths = false
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)
        let queue = DispatchQueue(label: "io.zanoza.resolver-probe.\(UUID().uuidString)")
        let query = ProfilePinger.makeDnsQuery(for: domain, recordType: recordType)
        let expectedID = query.prefix(2)

        return await withCheckedContinuation { continuation in
            let state = ResolverProbeContinuation(continuation)
            queue.asyncAfter(deadline: .now() + timeout) {
                state.finish(nil, connection: connection)
            }
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    let started = DispatchTime.now().uptimeNanoseconds
                    connection.send(content: query, completion: .contentProcessed { error in
                        if error != nil { state.finish(nil, connection: connection); return }
                        connection.receiveMessage { data, _, _, error in
                            guard error == nil, let data, data.count >= 12,
                                  data.prefix(2).elementsEqual(expectedID) else {
                                state.finish(nil, connection: connection)
                                return
                            }
                            let elapsed = DispatchTime.now().uptimeNanoseconds - started
                            state.finish(Double(elapsed) / 1_000_000, connection: connection)
                        }
                    })
                case .failed:
                    state.finish(nil, connection: connection)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func runNativeScan(
        endpoints: [ResolverEndpoint],
        profile: ConnectionProfile,
        settings: AppSettings,
        runtimeDirectory: URL,
        timeoutSeconds: Double,
        boundInterface: String,
        boundIPv4: String,
        boundIPv6: String,
        progress: @escaping ProgressHandler,
        total: Int
    ) async throws -> NativeResolverScanPayload {
        #if canImport(Mobile)
        let config = ConfigBuilder.buildTOML(for: profile, settings: settings)
        let resolvers = endpoints.map(\.canonicalAddress).joined(separator: "\n") + "\n"
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                MobileSetBoundInterface(boundInterface)
                MobileSetBoundAddress(boundIPv4, boundIPv6)
                let progressState = ResolverNativeProgressState()
                let relay = ResolverNativeLogRelay { line in
                    Task { @MainActor in AppLogger.shared.append(line) }
                } progress: { completed, accepted, detail in
                    guard progressState.accept(completed) else { return }
                    progress(ResolverScanProgress(
                        stage: .masterDnsMTU,
                        completed: completed,
                        total: total,
                        accepted: accepted,
                        detail: detail,
                        fraction: total > 0 ? Double(completed) / Double(total) : 1
                    ))
                }
                MobileSetLogWriter(relay)
                defer { MobileSetLogWriter(nil) }
                var scanError: NSError?
                let json = MobileScanResolvers(
                    config,
                    resolvers,
                    runtimeDirectory.path,
                    timeoutSeconds,
                    &scanError
                )
                if let scanError {
                    throw ResolverScannerError.nativeScanFailed(scanError.localizedDescription)
                }
                guard let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(NativeResolverScanPayload.self, from: data) else {
                    throw ResolverScannerError.invalidNativeResponse
                }
                return payload
            }.value
        }, onCancel: {
            MobileCancelScan()
        })
        #else
        _ = (endpoints, profile, settings, runtimeDirectory, timeoutSeconds, boundInterface, boundIPv4, boundIPv6, progress, total)
        throw ResolverScannerError.nativeScannerUnavailable
        #endif
    }

    private func runThroughputEvaluation(
        evaluations: [ResolverEvaluation],
        requireNativeAcceptance: Bool,
        profile: ConnectionProfile,
        settings: AppSettings,
        options: ResolverScanOptions,
        runtimeDirectory: URL,
        boundInterface: String,
        boundIPv4: String,
        boundIPv6: String,
        progress: @escaping ProgressHandler
    ) async throws -> [ResolverEvaluation] {
        let eligible = evaluations
            .filter { result in
                if requireNativeAcceptance { return result.tunnelViable }
                return result.replies > 0 && result.status == .reachable
            }
            .sorted { $0.rankingScore(for: .balanced) > $1.rankingScore(for: .balanced) }
        let candidates = Array(eligible.prefix(options.throughputCandidateLimit))
        guard !candidates.isEmpty else { return evaluations }

        var output = evaluations
        for (offset, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            progress(ResolverScanProgress(
                stage: .throughput,
                completed: offset,
                total: candidates.count,
                accepted: output.filter { $0.downloadMbps != nil || $0.uploadMbps != nil }.count,
                detail: "Testing \(candidate.endpoint.canonicalAddress) through its own MasterDNS session",
                snapshot: output
            ))
            let acceptedBefore = output.filter { $0.downloadMbps != nil || $0.uploadMbps != nil }.count
            let candidateLabel = candidate.endpoint.canonicalAddress
            let outputSnapshot = output
            do {
                let measured = try await measureSingleResolver(
                    candidate.endpoint,
                    profile: profile,
                    settings: settings,
                    options: options,
                    runtimeDirectory: runtimeDirectory,
                    boundInterface: boundInterface,
                    boundIPv4: boundIPv4,
                    boundIPv6: boundIPv6,
                    progress: { update in
                        let fraction = max(0, min(0.99, update.fraction))
                        progress(ResolverScanProgress(
                            stage: .throughput,
                            completed: offset,
                            total: candidates.count,
                            accepted: acceptedBefore,
                            detail: candidateLabel + ": " + update.detail,
                            fraction: fraction,
                            snapshot: outputSnapshot
                        ))
                    }
                )
                if let index = output.firstIndex(where: { $0.endpoint.id == candidate.endpoint.id }) {
                    output[index].downloadMbps = measured.downloadMbps
                    output[index].uploadMbps = measured.uploadMbps
                    output[index].tunnelLatencyMS = measured.proxyHandshakeMS
                    output[index].failureReason = nil
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let index = output.firstIndex(where: { $0.endpoint.id == candidate.endpoint.id }) {
                    let message = "Throughput: \(error.localizedDescription)"
                    if let previous = output[index].failureReason, !previous.isEmpty {
                        output[index].failureReason = previous + "; " + message
                    } else {
                        output[index].failureReason = message
                    }
                }
            }
            progress(ResolverScanProgress(
                stage: .throughput,
                completed: offset + 1,
                total: candidates.count,
                accepted: output.filter { $0.downloadMbps != nil || $0.uploadMbps != nil }.count,
                detail: candidate.endpoint.canonicalAddress,
                snapshot: output
            ))
        }
        return output
    }

    private func measureSingleResolver(
        _ endpoint: ResolverEndpoint,
        profile: ConnectionProfile,
        settings: AppSettings,
        options: ResolverScanOptions,
        runtimeDirectory: URL,
        boundInterface: String,
        boundIPv4: String,
        boundIPv6: String,
        progress: @escaping @Sendable (ProxySpeedTestProgress) -> Void
    ) async throws -> ProxySpeedTestResult {
        var testProfile = profile
        testProfile.resolverPresetID = nil
        testProfile.appliedConfigurationPreset = .custom
        testProfile.configuration.listener.protocolType = .socks5
        testProfile.configuration.listener.listenIP = "127.0.0.1"
        testProfile.configuration.listener.listenPort = options.throughputProxyPort
        testProfile.configuration.listener.socksAuth = false
        testProfile.configuration.listener.httpProxyEnabled = false
        testProfile.configuration.listener.optimisticSocksConnect = false
        testProfile.configuration.localDNS.enabled = false
        testProfile.configuration.resolver.packetDuplicationCount = 1
        testProfile.configuration.resolver.setupPacketDuplicationCount = 1
        testProfile.configuration.normalize()

        let engine = MasterDnsEngine()
        let speedTester = ProxySpeedTestService()
        let candidateDirectory = runtimeDirectory
            .appendingPathComponent("throughput", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let speedOptions = ProxySpeedTestOptions(
            proxyHost: "127.0.0.1",
            proxyPort: options.throughputProxyPort,
            egressURL: options.throughputEgressURL,
            downloadURL: options.throughputDownloadURL,
            uploadURL: options.throughputUploadURL,
            uploadBytes: options.throughputUploadBytes,
            timeoutSeconds: options.throughputTestTimeoutSeconds
        )

        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                try engine.start(
                    EngineStartOptions(
                        profile: testProfile,
                        settings: settings,
                        runtimeDirectory: candidateDirectory,
                        boundInterface: boundInterface,
                        boundIPv4: boundIPv4,
                        boundIPv6: boundIPv6,
                        resolversText: endpoint.canonicalAddress + "\n",
                        readinessTimeoutSeconds: options.throughputReadinessTimeoutSeconds
                    ),
                    log: { line in
                        Task { @MainActor in AppLogger.shared.append(line) }
                    }
                )
            }.value
            defer { engine.stop() }
            try Task.checkCancellation()
            return try await speedTester.runDetailed(options: speedOptions, progress: progress)
        }, onCancel: {
            speedTester.cancel()
            engine.stop()
        })
    }
}

private final class ResolverProbeContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Double?, Never>?

    init(_ continuation: CheckedContinuation<Double?, Never>) {
        self.continuation = continuation
    }

    func finish(_ result: Double?, connection: NWConnection) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection.cancel()
        pending.resume(returning: result)
    }
}

private struct NativeResolverScanPayload: Codable {
    let version: Int
    let error: String?
    let results: [NativeResolverScanResult]
}

private struct NativeResolverScanResult: Codable {
    let resolver: String
    let port: Int
    let domain: String
    let accepted: Bool
    let probeSucceeded: Bool
    let status: String
    let uploadMTU: Int
    let uploadCharacters: Int
    let downloadMTU: Int
    let tunnelLatencyMS: Double
}

private final class ResolverNativeProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var lastCompleted = 0

    func accept(_ completed: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard completed > lastCompleted else { return false }
        lastCompleted = completed
        return true
    }
}

#if canImport(Mobile)
private final class ResolverNativeLogRelay: NSObject, MobileLogWriterProtocol {
    private let callback: (String) -> Void
    private let progress: (Int, Int, String) -> Void

    init(
        _ callback: @escaping (String) -> Void,
        progress: @escaping (Int, Int, String) -> Void
    ) {
        self.callback = callback
        self.progress = progress
    }

    func writeLog(_ line: String?) {
        guard let line, !line.isEmpty else { return }
        callback(line)
        // Native MasterDNS emits stable counters in both accepted and
        // rejected MTU lines: "(17/110) ... totals: valid=...". Parsing
        // those counters gives the UI live progress without duplicating the
        // probe implementation or waiting for the final JSON payload.
        let normalized = Self.clean(line)
        guard let open = normalized.firstIndex(of: "("),
              let slash = normalized[normalized.index(after: open)...].firstIndex(of: "/"),
              let close = normalized[slash...].firstIndex(of: ")") else { return }
        let completedText = String(normalized[normalized.index(after: open)..<slash])
        let completed = Int(completedText.trimmingCharacters(in: .whitespaces)) ?? 0
        let totalsPart = normalized[normalized.index(after: close)...]
        let accepted: Int
        if let marker = totalsPart.range(of: "valid=") {
            let value = totalsPart[marker.upperBound...].prefix { $0.isNumber }
            accepted = Int(value) ?? 0
        } else {
            accepted = 0
        }
        guard completed > 0 else { return }
        progress(completed, accepted, normalized)
    }

    private static func clean(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<red>", with: "")
            .replacingOccurrences(of: "</red>", with: "")
            .replacingOccurrences(of: "<green>", with: "")
            .replacingOccurrences(of: "</green>", with: "")
            .replacingOccurrences(of: "<yellow>", with: "")
            .replacingOccurrences(of: "</yellow>", with: "")
            .replacingOccurrences(of: "<cyan>", with: "")
            .replacingOccurrences(of: "</cyan>", with: "")
    }
}
#endif
