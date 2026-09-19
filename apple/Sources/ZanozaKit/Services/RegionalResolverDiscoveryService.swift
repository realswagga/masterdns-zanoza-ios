import Foundation

/// A candidate assembled by the carrier/regional resolver discovery screen.
/// The source is kept next to the address so a saved preset can explain where
/// an endpoint came from (DHCP seed, an explicitly pasted list, or a bounded
/// nearby-address expansion).
public struct RegionalResolverCandidate: Codable, Equatable, Identifiable {
    public let endpoint: ResolverEndpoint
    public let source: String

    public var id: String { endpoint.id }

    public init(endpoint: ResolverEndpoint, source: String) {
        self.endpoint = endpoint
        self.source = source
    }
}

public struct RegionalResolverDiscoveryOptions: Equatable {
    public var seedText: String
    public var localIPv4: String
    public var expandNearby: Bool
    public var nearbyRadius: Int
    public var maximumCandidates: Int

    public init(
        seedText: String = "",
        localIPv4: String = "",
        expandNearby: Bool = true,
        nearbyRadius: Int = 16,
        maximumCandidates: Int = 512
    ) {
        self.seedText = seedText
        self.localIPv4 = localIPv4
        self.expandNearby = expandNearby
        self.nearbyRadius = min(max(nearbyRadius, 1), 64)
        self.maximumCandidates = min(max(maximumCandidates, 1), 2_048)
    }
}

public struct RegionalResolverDiscoveryReport: Equatable {
    public let candidates: [RegionalResolverCandidate]
    public let issues: [String]

    public var endpoints: [ResolverEndpoint] { candidates.map(\.endpoint) }
    public var sourceSummary: String {
        let grouped = Dictionary(grouping: candidates, by: \.source)
            .map { "\($0.key): \($0.value.count)" }
            .sorted()
        return grouped.joined(separator: " · ")
    }
}

/// Builds a bounded candidate pool for the in-app ISP/carrier scan.
///
/// iOS does not expose the DHCP DNS server list to an ordinary app.  The
/// screen therefore accepts pasted DHCP/router output and can additionally
/// probe a small /24 neighbourhood around a private seed or the active local
/// IPv4 address.  This is intentional: a blind sweep of 10/8 is both unsafe
/// and incapable of distinguishing the user's carrier from unrelated hosts.
public enum RegionalResolverDiscoveryService {
    public static let defaultNearbyRadius = 16
    public static let defaultMaximumCandidates = 512

    public static func discover(
        options: RegionalResolverDiscoveryOptions
    ) -> RegionalResolverDiscoveryReport {
        var issues: [String] = []
        var candidates: [RegionalResolverCandidate] = []
        var indexByAddress: [String: Int] = [:]

        func add(_ endpoint: ResolverEndpoint, source: String) {
            guard !endpoint.isProhibitedForScanning else {
                issues.append("Skipped prohibited resolver range: \(endpoint.canonicalAddress)")
                return
            }
            if let index = indexByAddress[endpoint.id] {
                // Preserve the most specific provenance when a DHCP seed is
                // also found through local-subnet expansion.
                if candidates[index].source.hasPrefix("nearby") && !source.hasPrefix("nearby") {
                    candidates[index] = RegionalResolverCandidate(endpoint: endpoint, source: source)
                }
                return
            }
            guard candidates.count < options.maximumCandidates else {
                if !issues.contains("Candidate cap reached (\(options.maximumCandidates)).") {
                    issues.append("Candidate cap reached (\(options.maximumCandidates)).")
                }
                return
            }
            indexByAddress[endpoint.id] = candidates.count
            candidates.append(RegionalResolverCandidate(endpoint: endpoint, source: source))
        }

        let parsed = ResolverImportParser.parse(options.seedText)
        for endpoint in parsed.endpoints {
            add(endpoint, source: "pasted/seed")
        }
        issues.append(contentsOf: parsed.issues.map(\.message))
        if parsed.prohibitedCount > 0 {
            issues.append("Skipped \(parsed.prohibitedCount) prohibited resolver(s).")
        }
        if parsed.endpoints.isEmpty && options.seedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("No seed resolvers supplied; enter DHCP/router DNS addresses or select a provider list.")
        }

        if options.expandNearby {
            let seeds = candidates.map(\.endpoint)
            for endpoint in seeds {
                guard let ipv4 = IPv4Octets(endpoint.host), ipv4.isPrivate else { continue }
                for host in nearbyHosts(ipv4, radius: options.nearbyRadius) {
                    guard let nearby = ResolverEndpoint(host: host, port: endpoint.port) else { continue }
                    add(nearby, source: "nearby /24 of \(endpoint.host)")
                }
            }

            if let local = IPv4Octets(options.localIPv4), local.isPrivate {
                for host in nearbyHosts(local, radius: options.nearbyRadius) {
                    guard let nearby = ResolverEndpoint(host: host) else { continue }
                    add(nearby, source: "nearby /24 of local \(options.localIPv4)")
                }
            }
        }

        return RegionalResolverDiscoveryReport(candidates: candidates, issues: issues)
    }

    public static func nearbyHosts(_ octets: IPv4Octets, radius: Int) -> [String] {
        let lower = max(1, Int(octets.last) - min(max(radius, 1), 64))
        let upper = min(254, Int(octets.last) + min(max(radius, 1), 64))
        var values = Set<Int>([1, 254, Int(octets.last)])
        values.formUnion(lower...upper)
        return values.sorted().map { "\(octets.first).\(octets.second).\(octets.third).\($0)" }
    }
}

public struct IPv4Octets: Equatable {
    public let first: UInt8
    public let second: UInt8
    public let third: UInt8
    public let last: UInt8

    public init?(_ value: String) {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4,
              let first = UInt8(pieces[0]),
              let second = UInt8(pieces[1]),
              let third = UInt8(pieces[2]),
              let last = UInt8(pieces[3]) else { return nil }
        self.first = first
        self.second = second
        self.third = third
        self.last = last
    }

    public var isPrivate: Bool {
        switch (first, second) {
        case (10, _), (192, 168), (172, 16...31), (100, 64...127): return true
        default: return false
        }
    }
}
