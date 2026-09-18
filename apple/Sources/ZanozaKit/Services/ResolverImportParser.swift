import Foundation

public struct ResolverImportIssue: Equatable, Identifiable {
    public let id = UUID()
    public let line: Int?
    public let message: String
}

public struct ResolverImportReport: Equatable {
    public let endpoints: [ResolverEndpoint]
    public let issues: [ResolverImportIssue]
    public let duplicateCount: Int
    public let prohibitedCount: Int

    public var summary: String {
        "\(endpoints.count) unique · \(duplicateCount) duplicates · \(prohibitedCount) prohibited skipped"
    }
}

public enum ResolverImportParser {
    public static let maximumExpandedCIDRHosts = 4_096
    public static let maximumImportedEndpoints = 65_536

    private static let candidateRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:udp://)?(\[[0-9a-f:]+\]|(?:\d{1,3}\.){3}\d{1,3})(?:/(\d{1,3}))?(?::(\d{1,5}))?"#
    )

    public static func parse(_ raw: String) -> ResolverImportReport {
        let normalized = extractTextFromJSONIfPossible(raw) ?? raw
        var endpoints: [ResolverEndpoint] = []
        var issues: [ResolverImportIssue] = []
        var seen = Set<String>()
        var duplicates = 0
        var prohibited = 0

        for (lineOffset, sourceLine) in normalized.components(separatedBy: .newlines).enumerated() {
            let lineNumber = lineOffset + 1
            let line = stripComments(sourceLine)
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = candidateRegex.matches(in: line, range: range)
            for match in matches {
                guard let hostRange = Range(match.range(at: 1), in: line) else { continue }
                let host = String(line[hostRange]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let prefix: Int? = {
                    guard match.range(at: 2).location != NSNotFound,
                          let r = Range(match.range(at: 2), in: line) else { return nil }
                    return Int(line[r])
                }()
                let port: Int = {
                    guard match.range(at: 3).location != NSNotFound,
                          let r = Range(match.range(at: 3), in: line) else { return 53 }
                    return Int(line[r]) ?? 53
                }()

                let parsed: [ResolverEndpoint]
                if let prefix {
                    parsed = expandIPv4CIDR(host: host, prefix: prefix, port: port, line: lineNumber, issues: &issues)
                } else if let endpoint = ResolverEndpoint(host: host, port: port) {
                    parsed = [endpoint]
                } else {
                    issues.append(ResolverImportIssue(line: lineNumber, message: "Invalid resolver: \(host):\(port)"))
                    continue
                }

                for endpoint in parsed {
                    if endpoint.isProhibitedForScanning {
                        prohibited += 1
                        continue
                    }
                    // MasterDNS itself deduplicates by IP even when ports differ.
                    guard seen.insert(endpoint.host).inserted else {
                        duplicates += 1
                        continue
                    }
                    endpoints.append(endpoint)
                    if endpoints.count >= maximumImportedEndpoints {
                        issues.append(ResolverImportIssue(line: lineNumber, message: "Import stopped at \(maximumImportedEndpoints) endpoints."))
                        return ResolverImportReport(
                            endpoints: endpoints,
                            issues: issues,
                            duplicateCount: duplicates,
                            prohibitedCount: prohibited
                        )
                    }
                }
            }
        }

        return ResolverImportReport(
            endpoints: endpoints,
            issues: issues,
            duplicateCount: duplicates,
            prohibitedCount: prohibited
        )
    }

    private static func stripComments(_ line: String) -> String {
        var value = line.replacingOccurrences(of: "\u{feff}", with: "")
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        // Keep the `//` in a URI scheme, but trim ordinary trailing comments.
        if let slash = value.range(of: " //") { value = String(value[..<slash.lowerBound]) }
        return value
    }

    private static func extractTextFromJSONIfPossible(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var strings: [String] = []
        func walk(_ value: Any, key: String? = nil) {
            switch value {
            case let string as String:
                if key == nil || ["host", "ip", "address", "resolver", "resolvers", "endpoint", "endpoints"].contains(key!.lowercased()) {
                    strings.append(string)
                }
            case let array as [Any]:
                array.forEach { walk($0, key: key) }
            case let dictionary as [String: Any]:
                dictionary.forEach { walk($0.value, key: $0.key) }
            default:
                break
            }
        }
        walk(object)
        return strings.isEmpty ? nil : strings.joined(separator: "\n")
    }

    private static func expandIPv4CIDR(
        host: String,
        prefix: Int,
        port: Int,
        line: Int,
        issues: inout [ResolverImportIssue]
    ) -> [ResolverEndpoint] {
        guard (0...32).contains(prefix), let bytes = ResolverEndpoint.ipv4Bytes(host) else {
            issues.append(ResolverImportIssue(line: line, message: "Only valid IPv4 CIDRs can be expanded: \(host)/\(prefix)"))
            return []
        }
        let hostBits = 32 - prefix
        guard hostBits < 63 else { return [] }
        let count = 1 << hostBits
        guard count <= maximumExpandedCIDRHosts else {
            issues.append(ResolverImportIssue(
                line: line,
                message: "CIDR \(host)/\(prefix) contains \(count) addresses; the safe per-CIDR limit is \(maximumExpandedCIDRHosts)."
            ))
            return []
        }
        let address = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(hostBits)
        let network = address & mask
        return (0..<count).compactMap { offset in
            let value = network &+ UInt32(offset)
            let text = "\((value >> 24) & 255).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
            return ResolverEndpoint(host: text, port: port)
        }
    }
}
