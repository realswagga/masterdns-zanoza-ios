import XCTest
@testable import ZanozaKit

final class ConfigurationImportTests: XCTestCase {
    func testTOMLImportMapsAliasesAndPreservesUnsupportedSettings() throws {
        let source = """
        PROFILE_NAME = "Andron Industries"
        DOMAINS = ["x.false.actor"]
        DATA_ENCRYPTION_METHOD = 5
        ENCRYPTION_KEY = "test-secret"
        LISTEN_PORT = 10886
        HTTP_PROXY_ENABLED = true
        HTTP_PROXY_PORT = 10887
        RESOLVER_BALANCING_STRATEGY = 3
        UPLOAD_PACKET_DUPLICATION_COUNT = 1
        UPLOAD_COMPRESSION_TYPE = 2
        DOWNLOAD_COMPRESSION_TYPE = 2
        MIN_UPLOAD_MTU = 100
        MAX_UPLOAD_MTU = 160
        MTU_TEST_RETRIES_RESOLVERS = 3
        MTU_TEST_TIMEOUT_RESOLVERS = 2.0
        MTU_TEST_PARALLELISM_RESOLVERS = 512
        TX_CHANNEL_SIZE = 4096
        STARTUP_MODE = "resolvers"
        """

        let bundle = try MasterDnsConfigurationCodec.importProfile(from: source)
        let profile = bundle.profile
        XCTAssertEqual(profile.name, "Andron Industries")
        XCTAssertEqual(profile.domain, "x.false.actor")
        XCTAssertEqual(profile.encryptionMethod, .aes256gcm)
        XCTAssertEqual(profile.configuration.listener.listenPort, 10_886)
        XCTAssertEqual(profile.configuration.listener.httpProxyPort, 10_887)
        XCTAssertEqual(profile.configuration.resolver.packetDuplicationCount, 1)
        XCTAssertEqual(profile.configuration.encoding.uploadCompression, .lz4)
        XCTAssertEqual(profile.configuration.mtu.testRetries, 3)
        XCTAssertEqual(profile.configuration.mtu.testParallelism, 512)
        XCTAssertEqual(profile.configuration.preservedUnsupportedSettings["TX_CHANNEL_SIZE"], "4096")
        XCTAssertEqual(profile.configuration.preservedUnsupportedSettings["STARTUP_MODE"], "\"resolvers\"")
        XCTAssertEqual(bundle.warnings.count, 1)

        let exported = MasterDnsConfigurationCodec.exportTOML(profile)
        XCTAssertTrue(exported.contains("LISTEN_PORT = 10886"))
        XCTAssertFalse(exported.contains("TX_CHANNEL_SIZE"), "Unsupported settings must not be falsely activated")
    }

    func testSmartImportAcceptsRawAndBase64JSON() throws {
        var source = ConnectionProfile(name: "JSON", domain: "x.false.actor", encryptionKey: "secret")
        source.configuration.listener.listenPort = 41_234
        let data = try JSONEncoder().encode(source)

        let raw = try ProfileShareCodec.decodeBundle(String(decoding: data, as: UTF8.self)).profile
        XCTAssertEqual(raw.domain, source.domain)
        XCTAssertEqual(raw.configuration.listener.listenPort, 41_234)
        XCTAssertNotEqual(raw.id, source.id)

        let encoded = data.base64EncodedString()
        let base64 = try ProfileShareCodec.decodeBundle(encoded).profile
        XCTAssertEqual(base64.configuration.listener.listenPort, 41_234)
    }

    func testSettingsOnlyImportKeepsServerIdentity() throws {
        let base = ConnectionProfile(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            name: "Private server",
            domain: "x.false.actor",
            encryptionKey: "do-not-replace"
        )
        let imported = try MasterDnsConfigurationCodec.applyConfiguration(from: """
        LISTEN_PORT = 10886
        RESOLVER_BALANCING_STRATEGY = 6
        DATA_ENCRYPTION_METHOD = 1
        """, to: base).profile
        XCTAssertEqual(imported.id, base.id)
        XCTAssertEqual(imported.name, base.name)
        XCTAssertEqual(imported.domain, base.domain)
        XCTAssertEqual(imported.encryptionKey, base.encryptionKey)
        XCTAssertEqual(imported.encryptionMethod, .xor)
        XCTAssertEqual(imported.configuration.listener.listenPort, 10_886)
        XCTAssertEqual(imported.configuration.resolver.balancingStrategy, .lossThenLatency)
        XCTAssertEqual(imported.appliedConfigurationPreset, .custom)
    }

    func testV1ProfileLinkStillImports() throws {
        let json = """
        {
          "version": 1,
          "name": "Legacy share",
          "domain": "X.FALSE.ACTOR.",
          "encryptionKey": "secret",
          "encryptionMethod": 5,
          "uploadCompression": 0,
          "downloadCompression": 0,
          "packetDuplicationCount": 2,
          "setupPacketDuplicationCount": 3,
          "resolverBalancingStrategy": 3,
          "logLevel": "WARN"
        }
        """
        let payload = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let decoded = try ProfileShareCodec.decode("zanoza://profile?data=\(payload)")
        XCTAssertEqual(decoded.domain, "x.false.actor")
        XCTAssertEqual(decoded.encryptionMethod, .aes256gcm)
        XCTAssertEqual(decoded.packetDuplicationCount, 2)
        XCTAssertEqual(decoded.setupPacketDuplicationCount, 3)
    }

    func testV2ShareIncludesResolverPresetAndRegeneratesIDs() throws {
        let endpoint = try XCTUnwrap(ResolverEndpoint(host: "77.88.8.8"))
        let evaluation = ResolverEvaluation(
            endpoint: endpoint,
            status: .tunnelAccepted,
            attempts: 3,
            replies: 3,
            medianLatencyMS: 42,
            lossPercent: 0,
            uploadMTU: 133,
            downloadMTU: 2_048
        )
        let preset = ResolverPreset(name: "RU", endpoints: [endpoint], evaluations: [evaluation])
        var profile = ConnectionProfile(name: "Shared", domain: "x.false.actor", encryptionKey: "secret")
        profile.resolverPresetID = preset.id

        let decoded = try ProfileShareCodec.decodeBundle(ProfileShareCodec.encode(profile, resolverPreset: preset))
        let importedPreset = try XCTUnwrap(decoded.resolverPreset)
        XCTAssertNotEqual(decoded.profile.id, profile.id)
        XCTAssertNotEqual(importedPreset.id, preset.id)
        XCTAssertEqual(decoded.profile.resolverPresetID, importedPreset.id)
        XCTAssertEqual(importedPreset.endpoints, preset.endpoints)
        XCTAssertTrue(importedPreset.evaluations.isEmpty, "Device/path-specific scan telemetry must not be shared")
        XCTAssertEqual(importedPreset.kind, .parent)
    }
}
