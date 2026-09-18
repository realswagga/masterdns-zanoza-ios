import Foundation

public struct ImportedProfileBundle {
    public var profile: ConnectionProfile
    public var resolverPreset: ResolverPreset?
    public var warnings: [String]

    public init(profile: ConnectionProfile, resolverPreset: ResolverPreset? = nil, warnings: [String] = []) {
        self.profile = profile
        self.resolverPreset = resolverPreset
        self.warnings = warnings
    }
}

public enum ProfileShareCodec {
    public static func encode(_ profile: ConnectionProfile, resolverPreset: ResolverPreset? = nil) throws -> String {
        let payload = SharedProfilePayloadV2(profile: profile, resolverPreset: resolverPreset)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        return "zanoza://profile?data=\(base64URLEncode(data))"
    }

    public static func decode(_ input: String) throws -> ConnectionProfile {
        try decodeBundle(input).profile
    }

    public static func decodeBundle(_ input: String) throws -> ImportedProfileBundle {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileShareCodecError.invalidLink }

        if trimmed.lowercased().hasPrefix("zanoza://") || (!trimmed.contains("=") && looksLikeBase64(trimmed)) {
            let encodedPayload = try payloadString(from: trimmed)
            let data = try base64URLDecode(encodedPayload)
            return try decodeJSONPayload(data)
        }
        if let data = trimmed.data(using: .utf8), isJSONObject(data) {
            return try decodeJSONPayload(data)
        }
        if let decoded = decodeLooseBase64(trimmed), isJSONObject(decoded) {
            return try decodeJSONPayload(decoded)
        }
        if MasterDnsConfigurationCodec.looksLikeConfiguration(trimmed) {
            return try MasterDnsConfigurationCodec.importProfile(from: trimmed)
        }
        throw ProfileShareCodecError.invalidLink
    }

    private static func decodeJSONPayload(_ data: Data) throws -> ImportedProfileBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = envelope["version"] as? Int {
            switch version {
            case 1:
                guard let payload = try? decoder.decode(SharedProfilePayloadV1.self, from: data) else {
                    throw ProfileShareCodecError.invalidPayload
                }
                return ImportedProfileBundle(profile: payload.profile())
            case 2:
                guard let payload = try? decoder.decode(SharedProfilePayloadV2.self, from: data) else {
                    throw ProfileShareCodecError.invalidPayload
                }
                return payload.importedBundle()
            default:
                throw ProfileShareCodecError.unsupportedVersion
            }
        }
        if var profile = try? decoder.decode(ConnectionProfile.self, from: data) {
            profile.id = UUID()
            return ImportedProfileBundle(profile: profile)
        }
        throw ProfileShareCodecError.invalidPayload
    }

    private static func payloadString(from input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "zanoza" {
            guard components.host == "profile",
                  let payload = components.queryItems?.first(where: { $0.name == "data" })?.value,
                  !payload.isEmpty else { throw ProfileShareCodecError.invalidLink }
            return payload
        }
        if trimmed.contains("://") { throw ProfileShareCodecError.invalidLink }
        return trimmed
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func base64URLDecode(_ value: String) throws -> Data {
        guard let data = decodeLooseBase64(value) else { throw ProfileShareCodecError.invalidPayload }
        return data
    }

    private static func decodeLooseBase64(_ value: String) -> Data? {
        var base64 = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }

    private static func looksLikeBase64(_ value: String) -> Bool {
        value.count >= 16 && value.range(of: #"^[A-Za-z0-9_+\-/=\r\n]+$"#, options: .regularExpression) != nil
    }

    private static func isJSONObject(_ data: Data) -> Bool {
        guard let first = data.first(where: { ![9, 10, 13, 32].contains($0) }) else { return false }
        return first == 123 || first == 91
    }
}

public enum ProfileShareCodecError: LocalizedError {
    case invalidLink
    case invalidPayload
    case unsupportedVersion
    case missingDomain
    case missingEncryptionKey

    public var errorDescription: String? {
        switch self {
        case .invalidLink: AppLocalization.string("Invalid profile sharing link or configuration.")
        case .invalidPayload: AppLocalization.string("Profile payload is invalid.")
        case .unsupportedVersion: AppLocalization.string("Profile sharing version is not supported.")
        case .missingDomain: AppLocalization.string("DOMAINS must contain a tunnel domain.")
        case .missingEncryptionKey: AppLocalization.string("ENCRYPTION_KEY is required.")
        }
    }
}

private struct SharedProfilePayloadV2: Codable {
    let version: Int
    let profile: ConnectionProfile
    let resolverPreset: ResolverPreset?

    init(profile: ConnectionProfile, resolverPreset: ResolverPreset?) {
        version = 2
        self.profile = profile
        self.resolverPreset = resolverPreset
    }

    func importedBundle() -> ImportedProfileBundle {
        var importedProfile = profile
        importedProfile.id = UUID()
        guard var importedPreset = resolverPreset else {
            importedProfile.resolverPresetID = nil
            return ImportedProfileBundle(profile: importedProfile)
        }
        importedPreset.id = UUID()
        importedPreset.parentID = nil
        importedPreset.kind = .parent
        importedProfile.resolverPresetID = importedPreset.id
        return ImportedProfileBundle(profile: importedProfile, resolverPreset: importedPreset)
    }
}

private struct SharedProfilePayloadV1: Codable {
    let version: Int
    let name: String
    let domain: String
    let encryptionKey: String
    let encryptionMethod: EncryptionMethod
    let uploadCompression: CompressionType
    let downloadCompression: CompressionType
    let packetDuplicationCount: Int
    let setupPacketDuplicationCount: Int
    let resolverBalancingStrategy: BalancingStrategy
    let logLevel: LogLevel

    func profile() -> ConnectionProfile {
        ConnectionProfile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: domain.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
            encryptionKey: encryptionKey,
            encryptionMethod: encryptionMethod,
            uploadCompression: uploadCompression,
            downloadCompression: downloadCompression,
            packetDuplicationCount: packetDuplicationCount,
            setupPacketDuplicationCount: setupPacketDuplicationCount,
            resolverBalancingStrategy: resolverBalancingStrategy,
            logLevel: logLevel,
            appliedConfigurationPreset: .custom
        )
    }
}
