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
            "[01:02:03] <green>✅ Accepted (1/2): resolver | upload=100 | download=500</green>",
            "--------------------------------------------------------------------------------"
        ]
        let compact = LogFormatter.compact(lines)
        XCTAssertTrue(compact[0].contains("Accepted (1/2)"))
        XCTAssertFalse(compact[0].contains("<green>"))
        XCTAssertEqual(compact[1], "────────")
    }
}

final class ProxySpeedTestParsingTests: XCTestCase {
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
}
