import XCTest
@testable import ZanozaKit

final class ConfigBuilderTests: XCTestCase {
    func testBuildsTOMLWithDomainAndPort() {
        let profile = ConnectionProfile(
            name: "Test",
            domain: "v.example.com",
            encryptionKey: "abc123"
        )
        let settings = AppSettings(socksPort: 41080)
        let toml = ConfigBuilder.buildTOML(for: profile, settings: settings)
        XCTAssertTrue(toml.contains("DOMAINS = [\"v.example.com\"]"))
        XCTAssertTrue(toml.contains("LISTEN_PORT = 41080"))
        XCTAssertTrue(toml.contains("ENCRYPTION_KEY = \"abc123\""))
        XCTAssertTrue(toml.contains("LISTEN_IP = \"127.0.0.1\""))
    }

    func testEscapesQuotesInKey() {
        let profile = ConnectionProfile(
            name: "Test",
            domain: "v.example.com",
            encryptionKey: "ab\"cd"
        )
        let toml = ConfigBuilder.buildTOML(for: profile, settings: AppSettings())
        XCTAssertTrue(toml.contains("ENCRYPTION_KEY = \"ab\\\"cd\""))
    }

    func testFallsBackToBundledResolversWhenCustomIsEmpty() {
        let text = ConfigBuilder.resolversText(settings: AppSettings())
        // Bundled list is curated to the high-MTU Yandex set.
        XCTAssertTrue(text.contains("77.88.8.8"))
        XCTAssertTrue(text.contains("77.88.8.88"))
    }

    func testGlobalResolverOverrideAppliesToEveryProfile() {
        let custom = "10.0.0.1\n10.0.0.2"
        let settings = AppSettings(customResolvers: custom)
        XCTAssertEqual(ConfigBuilder.resolversText(settings: settings), custom)
    }

    func testProfileListenerFlowsIntoTOML() {
        var profile = ConnectionProfile(name: "T", domain: "v.example.com", encryptionKey: "k")
        profile.configuration.listener.listenPort = 9999
        profile.configuration.listener.socksUser = "alice"
        profile.configuration.listener.socksPass = "p@ss"
        profile.configuration.listener.socksAuth = true
        let toml = ConfigBuilder.buildTOML(for: profile, settings: AppSettings())
        XCTAssertTrue(toml.contains("LISTEN_PORT = 9999"))
        XCTAssertTrue(toml.contains("SOCKS5_AUTH = true"))
        XCTAssertTrue(toml.contains("SOCKS5_USER = \"alice\""))
        XCTAssertTrue(toml.contains("SOCKS5_PASS = \"p@ss\""))
    }

    func testBuildsCompleteAndronConfiguration() {
        let profile = ConnectionProfile(name: "Andron", domain: "x.false.actor", encryptionKey: "secret")
        let toml = ConfigBuilder.buildTOML(for: profile, settings: AppSettings())
        let required = [
            "DATA_ENCRYPTION_METHOD = 5",
            "BASE_ENCODE_DATA = true",
            "UPLOAD_COMPRESSION_TYPE = 0",
            "DOWNLOAD_COMPRESSION_TYPE = 0",
            "RESOLVER_BALANCING_STRATEGY = 3",
            "PACKET_DUPLICATION_COUNT = 2",
            "SETUP_PACKET_DUPLICATION_COUNT = 3",
            "MIN_UPLOAD_MTU = 40",
            "MAX_UPLOAD_MTU = 133",
            "MIN_DOWNLOAD_MTU = 200",
            "MAX_DOWNLOAD_MTU = 2048",
            "HTTP_PROXY_ENABLED = true",
            "SOCKS_OPTIMISTIC_CONNECT = true",
            "LOCAL_DNS_ENABLED = false",
            "RX_TX_WORKERS = 8",
            "TUNNEL_PROCESS_WORKERS = 8",
        ]
        for setting in required {
            XCTAssertTrue(toml.contains(setting), "Missing \(setting)")
        }
    }
}

final class ConnectionProfileTests: XCTestCase {
    func testDefaultSettingsSocksPortIs41080() {
        XCTAssertEqual(AppSettings().socksPort, 41080)
    }

    func testDefaultProfileUsesRequestedMasterDnsKnobs() {
        let profile = ConnectionProfile()
        XCTAssertEqual(profile.encryptionMethod, .aes256gcm)
        XCTAssertEqual(profile.resolverBalancingStrategy, .leastLoss)
        XCTAssertEqual(profile.packetDuplicationCount, 2)
        XCTAssertEqual(profile.setupPacketDuplicationCount, 3)
        XCTAssertEqual(profile.uploadCompression, .off)
        XCTAssertEqual(profile.downloadCompression, .off)
        XCTAssertEqual(profile.configuration.mtu.maxUpload, 133)
        XCTAssertEqual(profile.configuration.mtu.maxDownload, 2_048)
        XCTAssertEqual(profile.configuration.logLevel, .info)
    }

    func testProvidedFullConfigurationIsNotOverwrittenByInitializerDefaults() {
        var configuration = MasterDnsClientConfiguration.preset(.performance)
        configuration.listener.listenPort = 42_222
        configuration.arq.windowSize = 777
        let profile = ConnectionProfile(
            name: "Full",
            domain: "x.false.actor",
            encryptionKey: "secret",
            configuration: configuration,
            appliedConfigurationPreset: .custom
        )
        XCTAssertEqual(profile.configuration, configuration)
        XCTAssertEqual(profile.configuration.listener.listenPort, 42_222)
        XCTAssertEqual(profile.configuration.resolver.packetDuplicationCount, 1)
        XCTAssertEqual(profile.configuration.encoding.uploadCompression, .lz4)
    }

    func testLegacyProfileDecodesWithOriginalValues() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Legacy",
          "domain": "x.false.actor",
          "encryptionKey": "secret",
          "encryptionMethod": 1,
          "uploadCompression": 3,
          "downloadCompression": 3,
          "packetDuplicationCount": 5,
          "setupPacketDuplicationCount": 6,
          "resolverBalancingStrategy": 5,
          "logLevel": "INFO"
        }
        """
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.encryptionMethod, .xor)
        XCTAssertEqual(decoded.uploadCompression, .zlib)
        XCTAssertEqual(decoded.packetDuplicationCount, 5)
        XCTAssertEqual(decoded.setupPacketDuplicationCount, 6)
        XCTAssertEqual(decoded.resolverBalancingStrategy, .hybridScore)
        XCTAssertEqual(decoded.appliedConfigurationPreset, .custom)
    }

    func testSettingsNormalizesOutOfRangePort() {
        XCTAssertEqual(AppSettings.normalizedSocksPort(0), 41080)
        XCTAssertEqual(AppSettings.normalizedSocksPort(100_000), 41080)
        XCTAssertEqual(AppSettings.normalizedSocksPort(5050), 5050)
    }

    func testProfileRoundTripsThroughJSON() throws {
        let profile = ConnectionProfile(
            name: "Round trip",
            domain: "v.example.com",
            encryptionKey: "shared-secret",
            encryptionMethod: .aes256gcm,
            uploadCompression: .zstd,
            downloadCompression: .lz4,
            packetDuplicationCount: 5,
            setupPacketDuplicationCount: 6,
            resolverBalancingStrategy: .hybridScore,
            logLevel: .debug
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testSettingsRoundTripsThroughJSON() throws {
        let settings = AppSettings(
            socksPort: 18000,
            socksUser: "u",
            socksPass: "p",
            socksAuthEnabled: true,
            customResolvers: "1.1.1.1\n8.8.8.8",
            resolverProviderID: "megafon",
            useFastResolvers: true
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testLegacySettingsRequestOneTimeProfileListenerMigration() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.didMigrateProfileListeners)
        XCTAssertTrue(AppSettings().didMigrateProfileListeners)
    }

    func testInvalidResolverProviderFallsBackToNone() {
        XCTAssertEqual(AppSettings(resolverProviderID: "unknown").resolverProviderID, AppSettings.noResolverProviderID)
    }
}

final class ProfileShareCodecTests: XCTestCase {
    func testSharedProfileLinkPreservesServerSettings() throws {
        let profile = ConnectionProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Shared",
            domain: "v.example.com",
            encryptionKey: "secret",
            encryptionMethod: .aes256gcm,
            uploadCompression: .zstd,
            downloadCompression: .lz4,
            packetDuplicationCount: 7,
            setupPacketDuplicationCount: 8,
            resolverBalancingStrategy: .lossThenLatency,
            logLevel: .debug
        )

        let link = try ProfileShareCodec.encode(profile)
        XCTAssertTrue(link.hasPrefix("zanoza://profile?data="))

        let decoded = try ProfileShareCodec.decode(link)
        XCTAssertNotEqual(decoded.id, profile.id)
        XCTAssertEqual(decoded.name, profile.name)
        XCTAssertEqual(decoded.domain, profile.domain)
        XCTAssertEqual(decoded.encryptionKey, profile.encryptionKey)
        XCTAssertEqual(decoded.encryptionMethod, profile.encryptionMethod)
        XCTAssertEqual(decoded.uploadCompression, profile.uploadCompression)
        XCTAssertEqual(decoded.downloadCompression, profile.downloadCompression)
        XCTAssertEqual(decoded.packetDuplicationCount, profile.packetDuplicationCount)
        XCTAssertEqual(decoded.setupPacketDuplicationCount, profile.setupPacketDuplicationCount)
        XCTAssertEqual(decoded.resolverBalancingStrategy, profile.resolverBalancingStrategy)
        XCTAssertEqual(decoded.logLevel, profile.logLevel)
    }

    func testInvalidSharedProfileLinkThrows() {
        XCTAssertThrowsError(try ProfileShareCodec.decode("https://example.com/profile"))
    }
}

final class ResolverListServiceTests: XCTestCase {
    func testProviderResolverCombinesProviderWithYandex() throws {
        let settings = AppSettings(resolverProviderID: "megafon")
        let text = try ResolverListService.resolve(settings: settings, fetch: { url in
            switch url.lastPathComponent {
            case "megafon.txt":
                return "1.1.1.1\n2.2.2.2\n"
            case "yandex.txt":
                return "2.2.2.2\n3.3.3.3\n"
            default:
                XCTFail("Unexpected resolver URL \(url)")
                return ""
            }
        })
        XCTAssertEqual(text, "1.1.1.1\n2.2.2.2\n3.3.3.3\n")
    }

    func testFastResolverDoesNotCombineYandex() throws {
        let settings = AppSettings(resolverProviderID: "megafon", useFastResolvers: true)
        let text = try ResolverListService.resolve(settings: settings, fetch: { url in
            XCTAssertEqual(url.lastPathComponent, "fast.txt")
            return "4.4.4.4\n"
        })
        XCTAssertEqual(text, "4.4.4.4\n")
    }

    func testManualResolversSkipRemoteFetch() throws {
        let manual = "10.0.0.1\n10.0.0.2"
        let settings = AppSettings(
            customResolvers: manual,
            resolverProviderID: "mts",
            useFastResolvers: true
        )
        let text = try ResolverListService.resolve(settings: settings, fetch: { url in
            XCTFail("Manual resolver override should not fetch \(url)")
            return ""
        })
        XCTAssertEqual(text, manual)
    }
}

final class ProfilePingerTests: XCTestCase {
    func testDnsQueryPacketShape() {
        let data = ProfilePinger.makeDnsQuery(for: "v.example.com")
        // 12-byte header + (1 + 1 + 1 + 7 + 1 + 3 + 1) labels + 4-byte trailer
        XCTAssertEqual(data.count, 12 + 1 + 1 + 1 + 7 + 1 + 3 + 1 + 4)
        XCTAssertEqual(data[2], 0x01) // RD flag high byte
        XCTAssertEqual(data[5], 0x01) // QDCOUNT low byte
        XCTAssertEqual(data[data.count - 4], 0x00) // QTYPE high
        XCTAssertEqual(data[data.count - 3], 0x01) // QTYPE=A
        XCTAssertEqual(data[data.count - 1], 0x01) // QCLASS=IN
    }
}
