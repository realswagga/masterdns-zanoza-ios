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
}
