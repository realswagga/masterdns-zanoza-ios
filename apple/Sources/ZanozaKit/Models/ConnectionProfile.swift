import Foundation

public enum EncryptionMethod: Int, CaseIterable, Codable, Identifiable {
    case none = 0
    case xor = 1
    case chacha20 = 2
    case aes128gcm = 3
    case aes192gcm = 4
    case aes256gcm = 5

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .none: "None"
        case .xor: "XOR"
        case .chacha20: "ChaCha20"
        case .aes128gcm: "AES-128-GCM"
        case .aes192gcm: "AES-192-GCM"
        case .aes256gcm: "AES-256-GCM"
        }
    }
}

public enum CompressionType: Int, CaseIterable, Codable, Identifiable {
    case off = 0
    case zstd = 1
    case lz4 = 2
    case zlib = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .zstd: "Zstd"
        case .lz4: "LZ4"
        case .zlib: "Zlib"
        }
    }
}

public enum BalancingStrategy: Int, CaseIterable, Codable, Identifiable {
    case random = 1
    case roundRobin = 2
    case leastLoss = 3
    case lowestLatency = 4
    case hybridScore = 5
    case lossThenLatency = 6
    case leastLossTopRandom = 7
    case leastLossTopRoundRobin = 8

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .random: "Random"
        case .roundRobin: "Round Robin"
        case .leastLoss: "Least Loss"
        case .lowestLatency: "Lowest Latency"
        case .hybridScore: "Hybrid Score"
        case .lossThenLatency: "Loss → Latency"
        case .leastLossTopRandom: "Least Loss Top (Random)"
        case .leastLossTopRoundRobin: "Least Loss Top (Round Robin)"
        }
    }
}

public enum LogLevel: String, CaseIterable, Codable, Identifiable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct ConnectionProfile: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var domain: String
    public var encryptionKey: String
    public var encryptionMethod: EncryptionMethod
    public var configuration: MasterDnsClientConfiguration
    public var appliedConfigurationPreset: MasterDnsConfigurationPreset
    public var resolverPresetID: UUID?

    public var uploadCompression: CompressionType {
        get { configuration.encoding.uploadCompression }
        set { configuration.encoding.uploadCompression = newValue }
    }

    public var downloadCompression: CompressionType {
        get { configuration.encoding.downloadCompression }
        set { configuration.encoding.downloadCompression = newValue }
    }

    public var packetDuplicationCount: Int {
        get { configuration.resolver.packetDuplicationCount }
        set { configuration.resolver.packetDuplicationCount = newValue }
    }

    public var setupPacketDuplicationCount: Int {
        get { configuration.resolver.setupPacketDuplicationCount }
        set { configuration.resolver.setupPacketDuplicationCount = newValue }
    }

    public var resolverBalancingStrategy: BalancingStrategy {
        get { configuration.resolver.balancingStrategy }
        set { configuration.resolver.balancingStrategy = newValue }
    }

    public var logLevel: LogLevel {
        get { configuration.logLevel }
        set { configuration.logLevel = newValue }
    }

    public init(
        id: UUID = UUID(),
        name: String = "",
        domain: String = "",
        encryptionKey: String = "",
        encryptionMethod: EncryptionMethod = .aes256gcm,
        uploadCompression: CompressionType? = nil,
        downloadCompression: CompressionType? = nil,
        packetDuplicationCount: Int? = nil,
        setupPacketDuplicationCount: Int? = nil,
        resolverBalancingStrategy: BalancingStrategy? = nil,
        logLevel: LogLevel? = nil,
        configuration: MasterDnsClientConfiguration? = nil,
        appliedConfigurationPreset: MasterDnsConfigurationPreset = .andronReliability,
        resolverPresetID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.domain = domain
        self.encryptionKey = encryptionKey
        self.encryptionMethod = encryptionMethod
        var effectiveConfiguration = configuration ?? .preset(appliedConfigurationPreset)
        if let uploadCompression {
            effectiveConfiguration.encoding.uploadCompression = uploadCompression
        }
        if let downloadCompression {
            effectiveConfiguration.encoding.downloadCompression = downloadCompression
        }
        if let packetDuplicationCount {
            effectiveConfiguration.resolver.packetDuplicationCount = max(1, min(10, packetDuplicationCount))
        }
        if let setupPacketDuplicationCount {
            effectiveConfiguration.resolver.setupPacketDuplicationCount = max(
                effectiveConfiguration.resolver.packetDuplicationCount,
                min(12, setupPacketDuplicationCount)
            )
        }
        if let resolverBalancingStrategy {
            effectiveConfiguration.resolver.balancingStrategy = resolverBalancingStrategy
        }
        if let logLevel {
            effectiveConfiguration.logLevel = logLevel
        }
        effectiveConfiguration.normalize()
        self.configuration = effectiveConfiguration
        self.appliedConfigurationPreset = appliedConfigurationPreset
        self.resolverPresetID = resolverPresetID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, domain, encryptionKey, encryptionMethod
        case uploadCompression, downloadCompression
        case packetDuplicationCount, setupPacketDuplicationCount
        case resolverBalancingStrategy, logLevel
        case configuration, appliedConfigurationPreset, resolverPresetID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
        encryptionKey = try c.decodeIfPresent(String.self, forKey: .encryptionKey) ?? ""
        encryptionMethod = try c.decodeIfPresent(EncryptionMethod.self, forKey: .encryptionMethod) ?? .xor
        resolverPresetID = try c.decodeIfPresent(UUID.self, forKey: .resolverPresetID)

        if var decoded = try c.decodeIfPresent(MasterDnsClientConfiguration.self, forKey: .configuration) {
            decoded.normalize()
            configuration = decoded
            appliedConfigurationPreset = try c.decodeIfPresent(
                MasterDnsConfigurationPreset.self,
                forKey: .appliedConfigurationPreset
            ) ?? .custom
        } else {
            // Backward-compatible migration for profiles saved by Zanoza 0.1.x.
            var migrated = MasterDnsClientConfiguration.preset(.compatibility)
            migrated.encoding.uploadCompression = try c.decodeIfPresent(CompressionType.self, forKey: .uploadCompression) ?? .zlib
            migrated.encoding.downloadCompression = try c.decodeIfPresent(CompressionType.self, forKey: .downloadCompression) ?? .zlib
            migrated.resolver.packetDuplicationCount = try c.decodeIfPresent(Int.self, forKey: .packetDuplicationCount) ?? 5
            migrated.resolver.setupPacketDuplicationCount = try c.decodeIfPresent(Int.self, forKey: .setupPacketDuplicationCount) ?? 6
            migrated.resolver.balancingStrategy = try c.decodeIfPresent(BalancingStrategy.self, forKey: .resolverBalancingStrategy) ?? .hybridScore
            migrated.logLevel = try c.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
            migrated.normalize()
            configuration = migrated
            appliedConfigurationPreset = .custom
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(domain, forKey: .domain)
        try c.encode(encryptionKey, forKey: .encryptionKey)
        try c.encode(encryptionMethod, forKey: .encryptionMethod)
        try c.encode(configuration, forKey: .configuration)
        try c.encode(appliedConfigurationPreset, forKey: .appliedConfigurationPreset)
        try c.encodeIfPresent(resolverPresetID, forKey: .resolverPresetID)
    }

    public static var empty: ConnectionProfile {
        return ConnectionProfile(
            name: AppLocalization.string("New profile"),
            encryptionMethod: .aes256gcm,
            appliedConfigurationPreset: .andronReliability
        )
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if !domain.isEmpty { return domain }
        return AppLocalization.string("Untitled")
    }

    public var listDetail: String {
        var parts: [String] = []
        if !domain.isEmpty { parts.append(domain) }
        parts.append(encryptionMethod.title)
        return parts.joined(separator: " · ")
    }
}
