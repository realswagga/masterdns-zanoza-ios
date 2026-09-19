import Foundation

/// Presentation-only log formatting. The raw log remains available for copy
/// and troubleshooting; compact mode is intended for a phone-sized screen.
public enum LogFormatter {
    public static func compact(_ lines: [String]) -> [String] {
        lines.map { compactLine($0) }
    }

    public static func compactText(_ lines: [String]) -> String {
        compact(lines).joined(separator: "\n")
    }

    private static func compactLine(_ input: String) -> String {
        var line = input
            .replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<red>", with: "")
            .replacingOccurrences(of: "</red>", with: "")
            .replacingOccurrences(of: "<green>", with: "")
            .replacingOccurrences(of: "</green>", with: "")
            .replacingOccurrences(of: "<yellow>", with: "")
            .replacingOccurrences(of: "</yellow>", with: "")
            .replacingOccurrences(of: "<cyan>", with: "")
            .replacingOccurrences(of: "</cyan>", with: "")
            .replacingOccurrences(of: "<blue>", with: "")
            .replacingOccurrences(of: "</blue>", with: "")
            .replacingOccurrences(of: "<magenta>", with: "")
            .replacingOccurrences(of: "</magenta>", with: "")

        // MasterDNS' native logger is written for a terminal.  Its long
        // prefix and aligned table columns make the same information almost
        // unreadable in a phone-sized log view.  Accepted/rejected probe
        // records get a stable, deliberately compact representation first.
        if let probe = compactProbeLine(line) {
            return probe
        }
        if let table = compactMTUTableRow(line) {
            return table
        }
        if let summary = compactMTUSummary(line) {
            return summary
        }

        line = line.replacingOccurrences(of: "[MasterDnsVPN Client]", with: "[Client]")
        line = line.replacingOccurrences(of: "[MasterDNS Client]", with: "[Client]")
        line = line.replacingOccurrences(of: "[INFO]", with: "[I]")
        line = line.replacingOccurrences(of: "[WARN]", with: "[W]")
        line = line.replacingOccurrences(of: "[ERROR]", with: "[E]")

        // Tables and separator banners from the native MTU logger consume a
        // lot of vertical space and do not add information once a resolver
        // line has been emitted.
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && Set(trimmed).count == 1,
           trimmed.first == "=",
           trimmed.count >= 8 {
            return "────────"
        }
        if !trimmed.isEmpty && Set(trimmed).count == 1,
           trimmed.first == "-",
           trimmed.count >= 8 {
            return "────────"
        }

        // Collapse runs of alignment whitespace while retaining the timestamp
        // and the meaningful key/value separators.
        line = line.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        line = line.replacingOccurrences(of: " | ", with: " · ")
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts lines such as:
    ///
    /// ``[...][INFO] ✅ Accepted (3/7): x.example via 1.2.3.4:53 |
    /// upload=111 | download=3386 | totals: valid=3, rejected=0``
    ///
    /// into the format used by the evaluator's compact log:
    /// ``[I] ✅ (3/7) : x.example - 1.2.3.4 | U=111 | D=3386 | v:3, r:0``.
    private static func compactProbeLine(_ input: String) -> String? {
        let isAccepted = input.range(of: "Accepted (", options: .caseInsensitive) != nil
        let isRejected = input.range(of: "Rejected (", options: .caseInsensitive) != nil
        guard isAccepted || isRejected else { return nil }

        let level: String
        if input.range(of: "[ERROR]", options: .caseInsensitive) != nil { level = "E" }
        else if input.range(of: "[WARN]", options: .caseInsensitive) != nil { level = "W" }
        else { level = "I" }

        guard let marker = input.range(of: isAccepted ? "Accepted (" : "Rejected (", options: .caseInsensitive),
              let close = input[marker.upperBound...].firstIndex(of: ")"),
              let colon = input[close...].firstIndex(of: ":") else {
            return nil
        }
        let counter = input[marker.upperBound..<close].trimmingCharacters(in: .whitespaces)
        let remainder = input[input.index(after: colon)...]
        let fields = remainder.components(separatedBy: "|")
        let head = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url: String
        let address: String
        if let via = head.range(of: " via ", options: .caseInsensitive) {
            url = String(head[..<via.lowerBound]).trimmingCharacters(in: .whitespaces)
            address = compactAddress(String(head[via.upperBound...]))
        } else {
            // Some MasterDNS versions use `URL - IP` already.
            let split = head.components(separatedBy: " - ")
            url = split.first?.trimmingCharacters(in: .whitespaces) ?? head
            address = split.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        }
        let valid = number(after: "valid=", in: input) ?? number(after: "v:", in: input) ?? 0
        let rejected = number(after: "rejected=", in: input) ?? number(after: "r:", in: input) ?? 0
        let icon = isAccepted ? "✅" : "❌"
        if isAccepted {
            let upload = number(after: "upload=", in: input) ?? number(after: "U=", in: input) ?? 0
            let download = number(after: "download=", in: input) ?? number(after: "D=", in: input) ?? 0
            return "[\(level)] \(icon) (\(counter)) : \(url) - \(address) | U=\(upload) | D=\(download) | v:\(valid), r:\(rejected)"
        }
        let reason = value(after: "reason=", in: input) ?? "rejected"
        return "[\(level)] \(icon) (\(counter)) : \(url) - \(address) | \(reason) | v:\(valid), r:\(rejected)"
    }

    /// The post-probe table is useful for debugging, but its padded header
    /// and domain column regularly exceed a 50-character phone log width.
    private static func compactMTUTableRow(_ input: String) -> String? {
        let cleaned = stripMetadata(input)
        let parts = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 3,
              parts[0].contains(":"),
              parts[1].allSatisfy(\.isNumber),
              parts[2].allSatisfy(\.isNumber) else { return nil }
        let ip = compactAddress(parts[0])
        let latency = parts.dropFirst(3).first(where: { $0.lowercased().hasSuffix("ms") })
        var output = "[I] \(ip) U=\(parts[1]) D=\(parts[2])"
        if let latency { output += " \(latency)" }
        return output
    }

    private static func compactMTUSummary(_ input: String) -> String? {
        let lower = input.lowercased()
        let level: String
        if lower.contains("[error]") { level = "E" }
        else if lower.contains("[warn]") { level = "W" }
        else { level = "I" }

        if lower.contains("total valid resolvers after mtu testing") {
            let marker = "total valid resolvers after mtu testing"
            let start = input.range(of: marker, options: .caseInsensitive).map(\.upperBound) ?? input.startIndex
            let tail = input[start...]
            let numbers = tail.matches(of: /\d+/).map(\.output)
            if numbers.count >= 2 { return "[\(level)] MTU \(numbers[0])/\(numbers[1]) valid" }
        }
        if lower.contains("global mtu configuration") || lower.contains("selected synced upload mtu") {
            let upload = number(after: "upload", in: input)
            let download = number(after: "download", in: input)
            if let upload, let download { return "[\(level)] MTU U=\(upload) D=\(download)" }
        }
        if lower.contains("max upload mtu found") {
            let upload = number(after: "upload mtu found:", in: input)
            let download = number(after: "download mtu found:", in: input)
            if let upload, let download { return "[\(level)] MTU max U=\(upload) D=\(download)" }
        }
        if lower.contains("valid connections after mtu testing") {
            return "[\(level)] MTU valid connections"
        }
        if lower.contains("testing mtu sizes") {
            return "[\(level)] MTU testing"
        }
        if lower.contains("mtu testing completed") {
            return "[\(level)] MTU complete"
        }
        if lower.contains("session policy adjusted max_download_mtu") {
            let requested = number(after: "requested:", in: input)
            let effective = number(after: "effective:", in: input)
            if let requested, let effective { return "[\(level)] MTU D \(requested)→\(effective)" }
        }
        return nil
    }

    private static func stripMetadata(_ input: String) -> String {
        var line = input
        // Remove timestamp and logger/level metadata, leaving the table row.
        line = line.replacingOccurrences(
            of: #"^\s*.*\]\s*"#,
            with: "",
            options: .regularExpression
        )
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compactAddress(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #":53$"#, with: "", options: .regularExpression)
    }

    private static func number(after marker: String, in input: String) -> Int? {
        guard let range = input.range(of: marker, options: .caseInsensitive) else { return nil }
        let tail = input[range.upperBound...]
        guard let start = tail.firstIndex(where: { $0.isNumber }) else { return nil }
        let digits = tail[start...].prefix { $0.isNumber }
        return Int(digits)
    }

    private static func value(after marker: String, in input: String) -> String? {
        guard let range = input.range(of: marker, options: .caseInsensitive) else { return nil }
        let tail = input[range.upperBound...]
        let value = tail.split(separator: "|", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}
