import Foundation
import GRPCCore
@testable import PulseGRPC
import SwiftProtobuf
import Testing

@Suite struct GRPCTaskMappingTests {
    private let descriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "echo.Echo"),
        method: "Get"
    )

    @Test(arguments: [
        ("ipv4:127.0.0.1:31415", "127.0.0.1:31415"),
        ("ipv6:[::1]:443", "[::1]:443"),
        ("in-process:27182", "in-process"),
        ("unix:/tmp/socket", "unix"),
        ("", "unknown"),
    ])
    func authorityFromRemotePeer(remotePeer: String, expected: String) {
        #expect(GRPCTaskMapping.authority(fromRemotePeer: remotePeer) == expected)
    }

    @Test(arguments: [
        ("https://example.com", "grpcs://example.com/echo.Echo/Get"),
        ("https://example.com:8443/", "grpcs://example.com:8443/echo.Echo/Get"),
        ("grpcs://example.com", "grpcs://example.com/echo.Echo/Get"),
        ("http://localhost:9000", "grpc://localhost:9000/echo.Echo/Get"),
        ("https://example.com/api?x=1", "grpcs://example.com/api/echo.Echo/Get"),
    ])
    func urlFromBaseURL(baseURL: String, expected: String) throws {
        let url = GRPCTaskMapping.url(baseURL: URL(string: baseURL), remotePeer: "ipv4:10.0.0.1:443", descriptor: descriptor)
        #expect(url.absoluteString == expected)
    }

    @Test func urlFallsBackToRemotePeer() {
        let url = GRPCTaskMapping.url(baseURL: nil, remotePeer: "ipv4:10.0.0.1:443", descriptor: descriptor)
        #expect(url.absoluteString == "grpc://10.0.0.1:443/echo.Echo/Get")
    }

    @Test func headersJoinRepeatedKeysAndEncodeBinaryValues() {
        var metadata: Metadata = ["x-id": "1"]
        metadata.addString("2", forKey: "x-id")
        metadata.addBinary([0x01, 0x02], forKey: "x-token-bin")

        let headers = GRPCTaskMapping.headers(from: metadata)

        #expect(headers["x-id"] == "1, 2")
        #expect(headers["x-token-bin"] == "AQI=")
    }

    @Test func encodesProtobufMessagesAsJSON() {
        let json = GRPCTaskMapping.encode(Google_Protobuf_StringValue("hello"), options: .init())
        #expect(json == "\"hello\"")
    }

    @Test func encodesOtherMessagesAsJSONStrings() {
        struct Custom: Sendable, CustomStringConvertible {
            var description: String { "custom \"value\"" }
        }
        let json = GRPCTaskMapping.encode(Custom(), options: .init())
        #expect(json == #""custom \"value\"""#)
    }

    @Test func bodyShapeDependsOnMessageCount() {
        #expect(GRPCTaskMapping.body(fromJSONMessages: []) == nil)
        #expect(GRPCTaskMapping.body(fromJSONMessages: [#"{"a":1}"#]) == Data(#"{"a":1}"#.utf8))
        #expect(GRPCTaskMapping.body(fromJSONMessages: ["1", "2"]) == Data("[1,2]".utf8))
    }

    @Test func errorUsesCanonicalStatusName() {
        let error = GRPCTaskMapping.error(for: RPCError(code: .notFound, message: "user not found"))
        #expect(error.domain == "gRPC")
        #expect(error.code == 5)
        #expect(error.localizedDescription == "NOT_FOUND (5): user not found")
    }

    @Test(arguments: [
        ("50m", Duration.milliseconds(50)),
        ("2S", .seconds(2)),
        ("1M", .seconds(60)),
        ("1H", .seconds(3600)),
        ("7u", .microseconds(7)),
        ("9n", .nanoseconds(9)),
    ])
    func parsesGRPCTimeout(value: String, expected: Duration) {
        #expect(GRPCTaskMapping.timeout(fromHeaderValue: value) == expected)
    }

    @Test(arguments: ["", "m", "12", "12x"])
    func rejectsInvalidGRPCTimeout(value: String) {
        #expect(GRPCTaskMapping.timeout(fromHeaderValue: value) == nil)
    }

    @Test func cancellationMapsToCancelled() {
        #expect(GRPCTaskMapping.rpcError(from: CancellationError()).code == .cancelled)
    }
}
