import Foundation
import Network

public struct ResolverEndpoint: Codable, Hashable, Identifiable, Sendable {
    public let host: String
    public let port: Int

    public init?(host: String, port: Int = 53) {
        let normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard (1...65_535).contains(port), Self.isIPAddress(normalized) else { return nil }
        self.host = normalized
        self.port = port
    }

    public var id: String { canonicalAddress }

    public var canonicalAddress: String {
        if host.contains(":") {
            return port == 53 ? host : "[\(host)]:\(port)"
        }
        return port == 53 ? host : "\(host):\(port)"
    }

    public var isPrivateOrLocal: Bool {
        if let ipv4 = Self.ipv4Bytes(host) {
            switch (ipv4[0], ipv4[1]) {
            case (10, _), (127, _), (169, 254), (192, 168): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        let lower = host.lowercased()
        return lower == "::1" || lower.hasPrefix("fe8") || lower.hasPrefix("fe9")
            || lower.hasPrefix("fea") || lower.hasPrefix("feb")
            || lower.hasPrefix("fc") || lower.hasPrefix("fd")
    }

    public var isProhibitedForScanning: Bool {
        guard let bytes = Self.ipv4Bytes(host) else { return false }
        // Explicitly excluded by the supplied operational safety notice.
        return bytes[0] == 194 && bytes[1] == 226
    }

    static func isIPAddress(_ value: String) -> Bool {
        IPv4Address(value) != nil || IPv6Address(value) != nil
    }

    static func ipv4Bytes(_ value: String) -> [UInt8]? {
        guard let address = IPv4Address(value) else { return nil }
        return Array(address.rawValue)
    }
}

public enum ResolverPresetKind: String, Codable {
    case parent
    case evaluatedSubset
}

public enum ResolverRankingMode: String, CaseIterable, Codable, Identifiable {
    case balanced
    case latency
    case loss
    case throughput

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .balanced: "Balanced"
        case .latency: "Latency"
        case .loss: "Reliability"
        case .throughput: "Speed"
        }
    }
}

public enum ResolverProbeStatus: String, Codable {
    case pending
    case reachable
    case tunnelAccepted
    case tunnelRejected
    case prohibited
    case cancelled
    case failed
}

public struct ResolverEvaluation: Codable, Equatable, Identifiable {
    public var endpoint: ResolverEndpoint
    public var status: ResolverProbeStatus
    public var attempts: Int
    public var replies: Int
    public var medianLatencyMS: Double?
    public var jitterMS: Double?
    public var lossPercent: Double
    public var uploadMTU: Int?
    public var downloadMTU: Int?
    public var tunnelLatencyMS: Double?
    public var downloadMbps: Double?
    public var uploadMbps: Double?
    public var failureReason: String?
    public var evaluatedAt: Date

    public init(
        endpoint: ResolverEndpoint,
        status: ResolverProbeStatus = .pending,
        attempts: Int = 0,
        replies: Int = 0,
        medianLatencyMS: Double? = nil,
        jitterMS: Double? = nil,
        lossPercent: Double = 100,
        uploadMTU: Int? = nil,
        downloadMTU: Int? = nil,
        tunnelLatencyMS: Double? = nil,
        downloadMbps: Double? = nil,
        uploadMbps: Double? = nil,
        failureReason: String? = nil,
        evaluatedAt: Date = Date()
    ) {
        self.endpoint = endpoint
        self.status = status
        self.attempts = attempts
        self.replies = replies
        self.medianLatencyMS = medianLatencyMS
        self.jitterMS = jitterMS
        self.lossPercent = lossPercent
        self.uploadMTU = uploadMTU
        self.downloadMTU = downloadMTU
        self.tunnelLatencyMS = tunnelLatencyMS
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.failureReason = failureReason
        self.evaluatedAt = evaluatedAt
    }

    public var id: String { endpoint.id }

    public var tunnelViable: Bool {
        status == .tunnelAccepted || (uploadMTU ?? 0) > 0 && (downloadMTU ?? 0) > 0
    }

    /// A result may be used in a generated child preset only when the direct
    /// probe received a reply and, when an encrypted probe ran, MasterDNS
    /// accepted it. This deliberately excludes the finite sentinel score used
    /// for failed and prohibited entries.
    public var isSelectable: Bool {
        guard replies > 0 else { return false }
        switch status {
        case .reachable, .tunnelAccepted:
            return true
        case .pending, .tunnelRejected, .prohibited, .cancelled, .failed:
            return false
        }
    }

    public func isSelectable(for mode: ResolverRankingMode) -> Bool {
        guard isSelectable else { return false }
        if mode == .throughput {
            return downloadMbps != nil || uploadMbps != nil
        }
        return true
    }

    public func rankingScore(for mode: ResolverRankingMode) -> Double {
        guard status != .prohibited, status != .failed, replies > 0 else {
            return -.greatestFiniteMagnitude
        }
        let latency = medianLatencyMS ?? tunnelLatencyMS ?? 10_000
        let jitter = jitterMS ?? latency
        let reliability = max(0, 100 - lossPercent)
        let mtuCapacity = Double(min(uploadMTU ?? 0, 160)) / 160 * 35
            + Double(min(downloadMTU ?? 0, 2_048)) / 2_048 * 35
        let measuredSpeed = log2(max(1, (downloadMbps ?? 0) + (uploadMbps ?? 0))) * 12
        switch mode {
        case .latency:
            return -latency - jitter * 0.15 + (tunnelViable ? 1_000 : 0)
        case .loss:
            return reliability * 10 - latency * 0.02 + (tunnelViable ? 1_000 : 0)
        case .throughput:
            return measuredSpeed + mtuCapacity - lossPercent * 2 - latency * 0.01
                + (tunnelViable ? 1_000 : 0)
        case .balanced:
            return reliability * 4 + mtuCapacity + measuredSpeed - latency * 0.04
                - jitter * 0.04 + (tunnelViable ? 1_000 : 0)
        }
    }
}

public struct ResolverPreset: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ResolverPresetKind
    public var parentID: UUID?
    public var endpoints: [ResolverEndpoint]
    public var evaluations: [ResolverEvaluation]
    public var sourceDescription: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ResolverPresetKind = .parent,
        parentID: UUID? = nil,
        endpoints: [ResolverEndpoint],
        evaluations: [ResolverEvaluation] = [],
        sourceDescription: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.parentID = kind == .parent ? nil : parentID
        self.endpoints = Self.deduplicate(endpoints)
        self.evaluations = evaluations
        self.sourceDescription = sourceDescription
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var resolverText: String {
        endpoints.map(\.canonicalAddress).joined(separator: "\n") + (endpoints.isEmpty ? "" : "\n")
    }

    public func ranked(_ mode: ResolverRankingMode) -> [ResolverEvaluation] {
        evaluations.sorted {
            let left = $0.rankingScore(for: mode)
            let right = $1.rankingScore(for: mode)
            if left == right { return $0.endpoint.canonicalAddress < $1.endpoint.canonicalAddress }
            return left > right
        }
    }

    public func topSubset(count: Int, mode: ResolverRankingMode, name: String? = nil) -> ResolverPreset {
        let rankedResults = ranked(mode).filter { $0.isSelectable(for: mode) }
        let selected = Array(rankedResults.prefix(max(1, count)))
        return ResolverPreset(
            name: name ?? "Top \(count) · \(mode.title)",
            kind: .evaluatedSubset,
            parentID: kind == .parent ? id : parentID,
            endpoints: selected.map(\.endpoint),
            evaluations: selected,
            sourceDescription: "Evaluated from \(self.name)"
        )
    }

    private static func deduplicate(_ values: [ResolverEndpoint]) -> [ResolverEndpoint] {
        var seen = Set<String>()
        // The embedded MasterDNS resolver map is keyed by IP address, so two
        // ports for one host cannot be active simultaneously.
        return values.filter { seen.insert($0.host).inserted }
    }
}

public struct ResolverEvaluationSummary: Codable, Equatable {
    public let total: Int
    public let reachable: Int
    public let tunnelViable: Int
    public let measuredSpeed: Int

    public init(evaluations: [ResolverEvaluation]) {
        total = evaluations.count
        reachable = evaluations.filter { $0.replies > 0 }.count
        tunnelViable = evaluations.filter(\.tunnelViable).count
        measuredSpeed = evaluations.filter { $0.downloadMbps != nil || $0.uploadMbps != nil }.count
    }
}
