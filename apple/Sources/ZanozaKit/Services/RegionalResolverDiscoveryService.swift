import Foundation

#if canImport(Darwin)
import Darwin
#endif
#if canImport(SystemConfiguration) && os(macOS)
import SystemConfiguration
#endif

/// Shared bounded domain set for automatic carrier resolver reconciliation.
/// It deliberately mixes Russian/carrier names with neutral global controls.
public enum AutonomousResolverDefaults {
    public static let domains = [
        "google.com", "max.ru", "vk.ru", "megafon.ru", "yandex.ru", "cloudflare.com", "citylink.pro", "example.com"
    ]
    public static let recordTypes: [UInt16] = [1, 28] // A, AAAA
}

/// A candidate assembled by the carrier/regional resolver discovery screen.
/// The source is kept next to the address so a saved preset can explain where
/// an endpoint came from (DHCP seed, an explicitly pasted list, or a bounded
/// nearby-address expansion).
public struct RegionalResolverCandidate: Codable, Equatable, Identifiable, Sendable {
    public let endpoint: ResolverEndpoint
    public let source: String

    public var id: String { endpoint.id }

    public init(endpoint: ResolverEndpoint, source: String) {
        self.endpoint = endpoint
        self.source = source
    }
}

public struct RegionalResolverDiscoveryOptions: Equatable, Sendable {
    public var seedText: String
    public var localIPv4: String
    /// Resolver addresses learned from the active carrier/DHCP path.  These
    /// are intentionally separate from pasted/provider text so provenance is
    /// retained in the generated parent preset.
    public var carrierSeedEndpoints: [ResolverEndpoint]
    public var expandNearby: Bool
    public var nearbyRadius: Int
    public var maximumCandidates: Int

    public init(
        seedText: String = "",
        localIPv4: String = "",
        carrierSeedEndpoints: [ResolverEndpoint] = [],
        expandNearby: Bool = true,
        nearbyRadius: Int = 16,
        maximumCandidates: Int = 512
    ) {
        self.seedText = seedText
        self.localIPv4 = localIPv4
        self.carrierSeedEndpoints = carrierSeedEndpoints
        self.expandNearby = expandNearby
        self.nearbyRadius = min(max(nearbyRadius, 1), 64)
        self.maximumCandidates = min(max(maximumCandidates, 1), 2_048)
    }
}

public struct RegionalResolverDiscoveryReport: Equatable, Sendable {
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
/// The automatic path reads the active carrier/DHCP DNS list through the
/// platform resolver configuration when available. It still accepts pasted
/// DHCP/router output and can optionally probe a small /24 neighbourhood around
/// a private seed. This is intentional: a blind sweep of 10/8 is both unsafe
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

        // Carrier/DHCP seeds are added before nearby expansion and before any
        // pasted/provider entries when the caller supplies both.  This keeps
        // the automatic path anchored to the serving network while retaining
        // explicit input as an auditable supplement.
        for endpoint in options.carrierSeedEndpoints {
            add(endpoint, source: "carrier DHCP")
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
            if options.carrierSeedEndpoints.isEmpty {
                issues.append("No seed/carrier DHCP resolver was exposed; enter DHCP/router DNS addresses or select a provider list.")
            }
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

/// A bounded, read-only lookup of the DNS servers selected by the host's
/// carrier configuration.  On Apple platforms the public DNS access layer can
/// return the address that answered a normal query; this is preferable to
/// guessing public resolvers or sweeping private address space.  If the
/// access layer is unavailable, the traditional resolver files are used as a
/// clearly-labelled fallback.
public struct CarrierResolverSeedReport: Equatable, Sendable {
    public let endpoints: [ResolverEndpoint]
    public let issues: [String]
    public let queriedDomains: [String]

    public init(endpoints: [ResolverEndpoint], issues: [String] = [], queriedDomains: [String] = []) {
        self.endpoints = endpoints
        self.issues = issues
        self.queriedDomains = queriedDomains
    }
}

public enum CarrierResolverSeedService {
    public static let defaultDomains = [
        "google.com", "max.ru", "vk.ru", "megafon.ru", "yandex.ru", "cloudflare.com", "citylink.pro"
    ]
    public static let defaultMaximum = 32

    public static func discover(
        domains: [String] = defaultDomains,
        maximum: Int = defaultMaximum
    ) -> CarrierResolverSeedReport {
        let names = Array(domains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty && $0.contains(".") }
            .prefix(12))
        let cap = min(max(maximum, 1), 128)
        var endpoints: [ResolverEndpoint] = []
        var stubs: [ResolverEndpoint] = []
        var seen = Set<String>()
        var issues: [String] = []

        func add(_ host: String, source: String) {
            guard let endpoint = ResolverEndpoint(host: host), !endpoint.isProhibitedForScanning else {
                if !host.isEmpty { issues.append("Skipped prohibited/invalid carrier resolver: \(host)") }
                return
            }
            if endpoint.host.hasPrefix("127.") || endpoint.host == "0.0.0.0" {
                if !stubs.contains(endpoint) { stubs.append(endpoint) }
                return
            }
            guard !seen.contains(endpoint.id) else { return }
            guard endpoints.count < cap else {
                if !issues.contains("Carrier resolver cap reached (\(cap)).") {
                    issues.append("Carrier resolver cap reached (\(cap)).")
                }
                return
            }
            seen.insert(endpoint.id)
            endpoints.append(endpoint)
            _ = source // provenance is attached by RegionalResolverDiscoveryService
        }

        // Querying the system's super-client returns the actual responder used
        // for each normal lookup. It follows DHCP/search-domain routing and
        // does not introduce an external Quad9/Cloudflare dependency.
        // The dynamic lookup keeps this package buildable on SDKs where Apple's
        // resolver header is not exposed to Swift.
        #if canImport(SystemConfiguration) && os(macOS)
        // SystemConfiguration is the authoritative public Apple API for the
        // active DHCP/service DNS list. It is checked before a query-response
        // inference so a local forwarding stub cannot hide the carrier pair.
        for value in systemConfigurationServers() {
            add(value, source: "dhcp:SystemConfiguration")
        }
        #endif
        #if canImport(Darwin)
        let configured = configuredSystemResolvers()
        for value in configured { add(value, source: "dhcp:Apple resolver configuration") }
        let queried = configured.isEmpty ? querySystemResponders(names) : []
        for value in queried { add(value, source: "carrier responder") }
        if configured.isEmpty && queried.isEmpty && !names.isEmpty {
            issues.append("System DNS responder API returned no carrier address; trying resolver configuration files.")
        }
        #endif

        if endpoints.isEmpty {
            for path in ["/etc/resolv.conf", "/private/etc/resolv.conf"] {
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                for line in text.components(separatedBy: .newlines) {
                    let pieces = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    guard pieces.count >= 2, pieces[0].lowercased() == "nameserver" else { continue }
                    let host = String(pieces[1]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    if host.hasPrefix("127.") || host == "0.0.0.0" {
                        issues.append("Only local resolver stub found in \(path): \(host)")
                        if let endpoint = ResolverEndpoint(host: host), !stubs.contains(endpoint) {
                            stubs.append(endpoint)
                        }
                    } else {
                        add(host, source: "carrier DHCP configuration")
                    }
                }
                if !endpoints.isEmpty { break }
            }
        }
        if endpoints.isEmpty, let stub = stubs.first {
            endpoints.append(stub)
            issues.append("Only a local resolver stub was available; carrier DHCP address was not exposed")
        }
        if endpoints.isEmpty {
            issues.append("Carrier DHCP DNS servers are unavailable to this process.")
        }
        return CarrierResolverSeedReport(endpoints: endpoints, issues: issues, queriedDomains: names)
    }

    #if canImport(SystemConfiguration) && os(macOS)
    private static func systemConfigurationServers() -> [String] {
        guard let store = SCDynamicStoreCreate(
            nil,
            "io.zanoza.carrier-resolver-scan" as CFString,
            nil,
            nil
        ),
        let value = SCDynamicStoreCopyValue(
            store,
            "State:/Network/Global/DNS" as CFString
        ) else { return [] }

        var output: [String] = []
        var seen = Set<String>()

        func collect(_ value: Any, key: String? = nil) {
            if let addresses = value as? [String], key == "ServerAddresses" {
                for address in addresses {
                    guard IPv4Octets(address) != nil, seen.insert(address).inserted else { continue }
                    output.append(address)
                }
                return
            }
            if let dictionary = value as? [String: Any] {
                for (childKey, childValue) in dictionary {
                    collect(childValue, key: childKey)
                }
                return
            }
            if let dictionary = value as? NSDictionary {
                for key in dictionary.allKeys {
                    guard let childKey = key as? String,
                          let childValue = dictionary[childKey] else { continue }
                    collect(childValue, key: childKey)
                }
            }
        }
        collect(value)
        return output
    }
    #endif

    #if canImport(Darwin)
    private typealias DNSOpen = @convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?
    private typealias DNSFree = @convention(c) (OpaquePointer?) -> Void
    private typealias DNSQuery = @convention(c) (
        OpaquePointer?, UnsafePointer<CChar>?, UInt32, UInt32,
        UnsafeMutablePointer<CChar>?, UInt32,
        UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<UInt32>?
    ) -> Int32
    // Use raw pointers for the private C triple-pointer signature so this
    // remains source-compatible across Darwin SDKs whose imported nested
    // pointer spelling differs. The ABI is `struct sockaddr ***`.
    private typealias DNSAllServerAddrs = @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?
    ) -> Void

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        let address = name.withCString { symbolName in
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbolName)
        }
        guard let address else { return nil }
        return unsafeBitCast(address, to: type)
    }

    private static func configuredSystemResolvers() -> [String] {
        guard let open = symbol("dns_open", as: DNSOpen.self),
              let all = symbol("dns_all_server_addrs", as: DNSAllServerAddrs.self),
              let close = symbol("dns_free", as: DNSFree.self),
              let handle = open(nil) else { return [] }
        defer { close(handle) }

        var list: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        withUnsafeMutablePointer(to: &list) { pointer in
            all(handle, UnsafeMutableRawPointer(pointer), &count)
        }
        guard let list, count > 0 else { return [] }
        defer { free(list) }

        let entries = list.assumingMemoryBound(to: UnsafeMutablePointer<sockaddr>?.self)
        var values: [String] = []
        var seen = Set<String>()
        for index in 0..<Int(count) {
            guard let address = entries[index] else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length: socklen_t = {
                switch Int32(address.pointee.sa_family) {
                case AF_INET: return socklen_t(MemoryLayout<sockaddr_in>.size)
                case AF_INET6: return socklen_t(MemoryLayout<sockaddr_in6>.size)
                default: return socklen_t(MemoryLayout<sockaddr>.size)
                }
            }()
            let status = getnameinfo(
                address,
                length,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            free(UnsafeMutableRawPointer(address))
            guard status == 0 else { continue }
            let value = String(cString: host)
            // MasterDNS resolver presets in this workflow are IPv4-oriented;
            // retain IPv6 for future display only when the endpoint model can
            // represent it, and never add a malformed address.
            guard ResolverEndpoint(host: value) != nil, seen.insert(value).inserted else { continue }
            values.append(value)
        }
        return values
    }

    private static func querySystemResponders(_ domains: [String]) -> [String] {
        guard let open = symbol("dns_open", as: DNSOpen.self),
              let query = symbol("dns_query", as: DNSQuery.self),
              let close = symbol("dns_free", as: DNSFree.self),
              let handle = open(nil) else { return [] }
        defer { close(handle) }

        var values: [String] = []
        var seen = Set<String>()
        for domain in domains {
            var response = [CChar](repeating: 0, count: 4_096)
            var storage = sockaddr_storage()
            var length = UInt32(MemoryLayout<sockaddr_storage>.size)
            let result: Int32 = withUnsafeMutablePointer(to: &storage) { storagePointer in
                storagePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { from in
                    domain.withCString { name in
                        response.withUnsafeMutableBufferPointer { buffer in
                            query(handle, name, 1, 1, buffer.baseAddress, UInt32(buffer.count), from, &length)
                        }
                    }
                }
            }
            guard result > 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = withUnsafePointer(to: &storage) { storagePointer in
                storagePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    getnameinfo(address, socklen_t(length), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                }
            }
            guard status == 0 else { continue }
            let value = String(cString: host)
            if IPv4Octets(value) != nil && seen.insert(value).inserted {
                values.append(value)
            }
        }
        return values
    }
    #endif
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
