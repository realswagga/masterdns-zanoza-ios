import XCTest
@testable import ZanozaKit

final class ResolverImportParserTests: XCTestCase {
    func testParsesTextJSONPortsAndDeduplicatesByHost() throws {
        let report = ResolverImportParser.parse("""
        77.88.8.8
        udp://77.88.8.8:5353
        {"resolvers":["1.2.3.4:5353","[2001:db8::1]:53"]}
        """)
        // JSON extraction is intentionally whole-document only, so exercise it
        // separately from free-form text.
        XCTAssertTrue(report.endpoints.contains(try XCTUnwrap(ResolverEndpoint(host: "77.88.8.8"))))
        XCTAssertEqual(report.endpoints.filter { $0.host == "77.88.8.8" }.count, 1)
        XCTAssertEqual(report.duplicateCount, 1)

        let json = ResolverImportParser.parse("{\"resolvers\":[\"1.2.3.4:5353\",\"[2001:db8::1]:53\"]}")
        XCTAssertEqual(json.endpoints.count, 2)
        XCTAssertEqual(json.endpoints.first { $0.host == "1.2.3.4" }?.port, 5_353)
    }

    func testCIDRExpansionCapAndProhibitedRange() {
        let report = ResolverImportParser.parse("""
        192.0.2.0/30
        10.0.0.0/19
        194.226.80.1
        """)
        XCTAssertEqual(report.endpoints.count, 4)
        XCTAssertEqual(report.prohibitedCount, 1)
        XCTAssertTrue(report.issues.contains { $0.message.contains("safe per-CIDR limit") })
    }
}

final class ResolverRankingTests: XCTestCase {
    func testTopSubsetNeverIncludesFailedOrProhibitedResolvers() throws {
        let good = try XCTUnwrap(ResolverEndpoint(host: "77.88.8.8"))
        let failed = try XCTUnwrap(ResolverEndpoint(host: "77.88.8.1"))
        let prohibited = try XCTUnwrap(ResolverEndpoint(host: "194.226.80.1"))
        let evaluations = [
            ResolverEvaluation(
                endpoint: good,
                status: .tunnelAccepted,
                attempts: 5,
                replies: 5,
                medianLatencyMS: 20,
                lossPercent: 0,
                uploadMTU: 120,
                downloadMTU: 2_048
            ),
            ResolverEvaluation(endpoint: failed, status: .failed, attempts: 5, replies: 0),
            ResolverEvaluation(endpoint: prohibited, status: .prohibited, attempts: 0, replies: 0),
        ]
        let parent = ResolverPreset(name: "Parent", endpoints: [good, failed, prohibited], evaluations: evaluations)
        let top = parent.topSubset(count: 100, mode: .balanced)
        XCTAssertEqual(top.endpoints, [good])
        XCTAssertEqual(top.parentID, parent.id)
    }

    func testThroughputSubsetRequiresMeasuredSpeed() throws {
        let measured = try XCTUnwrap(ResolverEndpoint(host: "77.88.8.8"))
        let mtuOnly = try XCTUnwrap(ResolverEndpoint(host: "77.88.8.1"))
        let evaluations = [
            ResolverEvaluation(
                endpoint: measured,
                status: .tunnelAccepted,
                attempts: 3,
                replies: 3,
                lossPercent: 0,
                uploadMTU: 120,
                downloadMTU: 2_048,
                downloadMbps: 5,
                uploadMbps: 0.2
            ),
            ResolverEvaluation(
                endpoint: mtuOnly,
                status: .tunnelAccepted,
                attempts: 3,
                replies: 3,
                lossPercent: 0,
                uploadMTU: 133,
                downloadMTU: 2_048
            ),
        ]
        let parent = ResolverPreset(name: "Parent", endpoints: [measured, mtuOnly], evaluations: evaluations)
        XCTAssertEqual(parent.topSubset(count: 5, mode: .throughput).endpoints, [measured])
    }

    func testPresetStorePersistsParentAndChildAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("presets.json")
        let endpoint = try XCTUnwrap(ResolverEndpoint(host: "77.88.8.8"))
        let store = ResolverPresetStore(fileURL: file)
        let parent = store.createParent(name: "Parent", endpoints: [endpoint])
        let child = store.createChild(parentID: parent.id, name: "Top", endpoints: [endpoint])

        let reloaded = ResolverPresetStore(fileURL: file)
        XCTAssertEqual(reloaded.preset(id: parent.id)?.endpoints, [endpoint])
        XCTAssertEqual(reloaded.children(of: parent.id).map(\.id), [child.id])
    }

    func testPresetStoreEditKeepsIdentityAndDropsRemovedMeasurements() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let endpointA = try XCTUnwrap(ResolverEndpoint(host: "77.88.8.8"))
        let endpointB = try XCTUnwrap(ResolverEndpoint(host: "77.88.8.1"))
        let evaluation = ResolverEvaluation(
            endpoint: endpointA,
            status: .tunnelAccepted,
            attempts: 1,
            replies: 1,
            lossPercent: 0,
            uploadMTU: 120,
            downloadMTU: 2_048
        )
        let store = ResolverPresetStore(fileURL: file)
        let parent = store.createParent(name: "Original", endpoints: [endpointA, endpointB], source: "scan")
        var withEvaluation = parent
        withEvaluation.evaluations = [evaluation]
        store.save(withEvaluation)

        let edited = try XCTUnwrap(store.update(parent.id, name: "Edited", endpoints: [endpointA]))
        XCTAssertEqual(edited.id, parent.id)
        XCTAssertEqual(edited.name, "Edited")
        XCTAssertEqual(edited.endpoints, [endpointA])
        XCTAssertEqual(edited.evaluations.map(\.endpoint), [endpointA])
    }
}

final class LogFormatterTests: XCTestCase {
    func testCompactLogRemovesColourTagsAndTablePadding() {
        let lines = [
            "[01:02:03] 2026/09/18 01:02:03 [MasterDnsVPN Client] [INFO] <green>✅ Accepted (1/2): x.false.actor via 10.140.1.254:53 | upload=100 | download=500 | totals: valid=1, rejected=0</green>",
            "--------------------------------------------------------------------------------"
        ]
        let compact = LogFormatter.compact(lines)
        XCTAssertEqual(compact[0], "[I] ✅ (1/2) : x.false.actor - 10.140.1.254 | U=100 | D=500 | v:1, r:0")
        XCTAssertFalse(compact[0].contains("<green>"))
        XCTAssertEqual(compact[1], "────────")
    }

    func testCompactRejectedAndMtuSummaryUseShortTokens() {
        let lines = [
            "[MasterDnsVPN Client] [WARN] ❌ Rejected (2/5): x.false.actor via 10.140.1.2:53 | reason=UPLOAD_MTU | value=0 | totals: valid=1, rejected=1",
            "[MasterDnsVPN Client] [INFO] Total valid resolvers after MTU testing: 3 of 5",
            "[MasterDnsVPN Client] [INFO] Global MTU Configuration -> Upload: 111, Download: 1149",
            "[22:40:13] 2026/09/17 19:40:13 [MasterDnsVPN Client] [INFO] 10.140.1.254:53    111    1149    114ms    x.false.actor",
        ]
        let compact = LogFormatter.compact(lines)
        XCTAssertEqual(compact[0], "[W] ❌ (2/5) : x.false.actor - 10.140.1.2 | UPLOAD_MTU | v:1, r:1")
        XCTAssertEqual(compact[1], "[I] MTU 3/5 valid")
        XCTAssertEqual(compact[2], "[I] MTU U=111 D=1149")
        XCTAssertEqual(compact[3], "[I] 10.140.1.254 U=111 D=1149 114ms")
    }
}

final class RegionalResolverDiscoveryTests: XCTestCase {
    func testCarrierSeedReportRetainsProvenanceAndProducesSafeDiagnostics() throws {
        let endpoint = try XCTUnwrap(ResolverEndpoint(host: "10.140.1.254"))
        let report = CarrierResolverSeedReport(
            endpoints: [endpoint],
            issues: ["API fallback"],
            queriedDomains: ["google.com", "max.ru"],
            provenance: [endpoint.id: "dhcp:Apple resolver configuration"],
            discoveryMethods: ["dhcp:Apple resolver configuration"]
        )

        XCTAssertEqual(report.source(for: endpoint), "dhcp:Apple resolver configuration")
        XCTAssertEqual(report.sourceSummary, "dhcp:Apple resolver configuration: 1")
        XCTAssertTrue(report.diagnosticText.contains("10.140.1.254 ← dhcp:Apple resolver configuration"))
        XCTAssertTrue(report.diagnosticText.contains("google.com,max.ru"))
        XCTAssertTrue(report.diagnosticText.contains("API fallback"))
        XCTAssertFalse(report.diagnosticText.contains("encryptionKey"))
    }

    func testCarrierSeedReportDefaultsUnknownProvenanceWithoutBreakingOldInitializer() throws {
        let endpoint = try XCTUnwrap(ResolverEndpoint(host: "10.140.1.254"))
        let report = CarrierResolverSeedReport(endpoints: [endpoint])

        XCTAssertEqual(report.source(for: endpoint), "unknown source")
        XCTAssertEqual(report.discoveryMethods, [])
        XCTAssertTrue(report.diagnosticText.contains("methods=unavailable"))
    }

    func testCarrierSeedsArePrioritizedAndRetainProvenance() throws {
        let carrier = try XCTUnwrap(ResolverEndpoint(host: "10.140.1.254"))
        let pasted = try XCTUnwrap(ResolverEndpoint(host: "10.140.1.1"))
        let report = RegionalResolverDiscoveryService.discover(
            options: RegionalResolverDiscoveryOptions(
                seedText: pasted.canonicalAddress,
                carrierSeedEndpoints: [carrier],
                expandNearby: false
            )
        )
        XCTAssertEqual(report.candidates.map(\.endpoint), [carrier, pasted])
        XCTAssertEqual(report.candidates.first?.source, "carrier DHCP")
    }

    func testAutonomousDomainSetContainsCarrierAndNeutralControls() {
        XCTAssertTrue(AutonomousResolverDefaults.domains.contains("google.com"))
        XCTAssertTrue(AutonomousResolverDefaults.domains.contains("max.ru"))
        XCTAssertTrue(AutonomousResolverDefaults.domains.contains("vk.ru"))
        XCTAssertTrue(AutonomousResolverDefaults.domains.contains("megafon.ru"))
        XCTAssertTrue(AutonomousResolverDefaults.domains.contains("example.com"))
        XCTAssertEqual(AutonomousResolverDefaults.recordTypes, [1, 28])
    }

    func testDiscoveryExpandsOnlyBoundedPrivateNeighbourhood() throws {
        let report = RegionalResolverDiscoveryService.discover(
            options: RegionalResolverDiscoveryOptions(
                seedText: "10.140.1.254\n10.140.1.254:53\n194.226.80.1",
                localIPv4: "10.140.1.100",
                expandNearby: true,
                nearbyRadius: 2,
                maximumCandidates: 64
            )
        )
        XCTAssertTrue(report.candidates.contains { $0.endpoint.host == "10.140.1.254" })
        XCTAssertTrue(report.candidates.contains { $0.endpoint.host == "10.140.1.252" })
        XCTAssertTrue(report.candidates.contains { $0.endpoint.host == "10.140.1.100" })
        XCTAssertFalse(report.candidates.contains { $0.endpoint.host == "194.226.80.1" })
        XCTAssertTrue(report.issues.contains { $0.contains("prohibited") })
        XCTAssertLessThanOrEqual(report.candidates.count, 64)
    }

    func testPublicLocalAddressDoesNotTriggerImplicitSweep() {
        let report = RegionalResolverDiscoveryService.discover(
            options: RegionalResolverDiscoveryOptions(
                seedText: "",
                localIPv4: "62.60.236.225",
                expandNearby: true,
                nearbyRadius: 16,
                maximumCandidates: 512
            )
        )
        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertTrue(report.issues.contains { $0.contains("No seed") })
    }
}

final class ProxySpeedTestParsingTests: XCTestCase {
    func testThroughputDefaultsUseTwoMtuAttemptsAndFiveCandidates() {
        let options = ResolverScanOptions()
        XCTAssertEqual(options.attempts, 2)
        XCTAssertEqual(options.throughputCandidateLimit, 5)
        XCTAssertEqual(
            ResolverScanOptions(throughputCandidateLimit: 500).throughputCandidateLimit,
            50
        )
    }

    func testSelectiveThroughputDoesNotProbeProhibitedResolver() async throws {
        let endpoint = try XCTUnwrap(ResolverEndpoint(host: "194.226.80.1"))
        do {
            _ = try await ResolverScannerService().testThroughput(
                for: endpoint,
                profile: .empty,
                settings: AppSettings(),
                options: ResolverScanOptions(),
                runtimeDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            )
            XCTFail("A prohibited resolver must be rejected before starting a session")
        } catch let error as ResolverScannerError {
            XCTAssertEqual(error.errorDescription, "This resolver is in a prohibited scan range.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAutonomousScanOptionsNormalizeDomainsAndRecordTypes() {
        let options = ResolverScanOptions(
            reconciliationDomains: [" google.com. ", "", "max.ru", "invalid"],
            reconciliationRecordTypes: [1, 28, 15, 1]
        )
        XCTAssertEqual(options.reconciliationDomains, ["google.com", "max.ru"])
        XCTAssertEqual(options.reconciliationRecordTypes, [1, 28, 1])
    }

    func testUploadPayloadIsNotTriviallyCompressible() {
        let payload = ProxySpeedTestService.makeIncompressiblePayload(byteCount: 4_096)
        XCTAssertEqual(payload.count, 4_096)
        XCTAssertGreaterThan(Set(payload).count, 200)
        XCTAssertEqual(payload, ProxySpeedTestService.makeIncompressiblePayload(byteCount: 4_096))
    }

    func testDecodesChunkedHTTPBody() throws {
        let response = Data((
            "HTTP/1.1 200 OK\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "Connection: close\r\n"
            + "\r\n"
            + "4\r\ntest\r\n"
            + "3\r\n123\r\n"
            + "0\r\n\r\n"
        ).utf8)
        XCTAssertEqual(try ProxySpeedTestService.parseHTTPResponse(response), Data("test123".utf8))
    }

    func testHonorsContentLengthAndRejectsFailureStatus() throws {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ntestignored".utf8)
        XCTAssertEqual(try ProxySpeedTestService.parseHTTPResponse(response), Data("test".utf8))
        let failure = Data("HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertThrowsError(try ProxySpeedTestService.parseHTTPResponse(failure))
    }

    func testPartialContentLengthResponseKeepsDownloadedBytes() throws {
        let response = Data((
            "HTTP/1.1 200 OK\r\n"
            + "Content-Length: 1000000\r\n"
            + "Connection: keep-alive\r\n"
            + "\r\n"
            + "partial-body"
        ).utf8)
        let snapshot = try ProxySpeedTestService.parseHTTPResponseSnapshot(response)
        XCTAssertEqual(snapshot.bytes, 12)
        XCTAssertFalse(snapshot.complete)
    }

    func testPartialChunkedResponseCountsPayloadBeforeTimeout() throws {
        let response = Data((
            "HTTP/1.1 200 OK\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "\r\n"
            + "8\r\npartial!"
        ).utf8)
        let snapshot = try ProxySpeedTestService.parseHTTPResponseSnapshot(response)
        XCTAssertEqual(snapshot.bytes, 8)
        XCTAssertFalse(snapshot.complete)
    }
}
