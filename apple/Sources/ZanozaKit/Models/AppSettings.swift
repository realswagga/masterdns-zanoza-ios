import Foundation

// Global resolver-provider configuration plus retained 0.1.x listener fields.
// Listener settings are migrated into each profile once; current builds edit
// them in the profile's full MasterDNS configuration.
public struct AppSettings: Codable, Equatable {
    public static let defaultSocksPort = 41080
    public static let noResolverProviderID = ""
    public static let minimumSocksPort = 1024
    public static let maximumSocksPort = 65535
    public static var socksPortRange: ClosedRange<Int> { minimumSocksPort...maximumSocksPort }

    public var socksPort: Int
    public var socksUser: String
    public var socksPass: String
    public var socksAuthEnabled: Bool
    public var customResolvers: String
    public var resolverProviderID: String
    public var useFastResolvers: Bool
    public var systemVPNEnabled: Bool
    public var didMigrateProfileListeners: Bool

    public init(
        socksPort: Int = Self.defaultSocksPort,
        socksUser: String = "zanoza",
        socksPass: String = "zanoza",
        socksAuthEnabled: Bool = false,
        customResolvers: String = "",
        resolverProviderID: String = Self.noResolverProviderID,
        useFastResolvers: Bool = false,
        systemVPNEnabled: Bool = false,
        didMigrateProfileListeners: Bool = true
    ) {
        self.socksPort = Self.normalizedSocksPort(socksPort)
        self.socksUser = socksUser
        self.socksPass = socksPass
        self.socksAuthEnabled = socksAuthEnabled
        self.customResolvers = customResolvers
        self.resolverProviderID = Self.normalizedResolverProviderID(resolverProviderID)
        self.useFastResolvers = useFastResolvers
        self.systemVPNEnabled = systemVPNEnabled
        self.didMigrateProfileListeners = didMigrateProfileListeners
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let port = try container.decodeIfPresent(Int.self, forKey: .socksPort) ?? Self.defaultSocksPort
        socksPort = Self.normalizedSocksPort(port)
        socksUser = try container.decodeIfPresent(String.self, forKey: .socksUser) ?? "zanoza"
        socksPass = try container.decodeIfPresent(String.self, forKey: .socksPass) ?? "zanoza"
        socksAuthEnabled = try container.decodeIfPresent(Bool.self, forKey: .socksAuthEnabled) ?? false
        customResolvers = try container.decodeIfPresent(String.self, forKey: .customResolvers) ?? ""
        let providerID = try container.decodeIfPresent(String.self, forKey: .resolverProviderID) ?? Self.noResolverProviderID
        resolverProviderID = Self.normalizedResolverProviderID(providerID)
        useFastResolvers = try container.decodeIfPresent(Bool.self, forKey: .useFastResolvers) ?? false
        systemVPNEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemVPNEnabled) ?? false
        // A missing key identifies settings written by Zanoza 0.1.x.
        didMigrateProfileListeners = try container.decodeIfPresent(Bool.self, forKey: .didMigrateProfileListeners) ?? false
    }

    public static func normalizedSocksPort(_ port: Int) -> Int {
        socksPortRange.contains(port) ? port : defaultSocksPort
    }

    public static func clampedSocksPort(_ port: Int) -> Int {
        min(max(port, minimumSocksPort), maximumSocksPort)
    }

    public static func normalizedResolverProviderID(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return noResolverProviderID }
        return ResolverCatalog.provider(id: trimmed) == nil ? noResolverProviderID : trimmed
    }
}
