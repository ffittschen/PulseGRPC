import Foundation
import GRPCCore
@testable import PulseGRPC
import SwiftProtobuf
import Testing

@Suite struct MappingTests {
    private let descriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "echo.Echo"),
        method: "Get"
    )

    @Test(arguments: [
        ("ipv4:127.0.0.1:31415", "grpc://127.0.0.1:31415/echo.Echo/Get"),
        ("ipv6:[::1]:443", "grpc://[::1]:443/echo.Echo/Get"),
        ("in-process:27182", "grpc://in-process/echo.Echo/Get"),
        ("unix:/tmp/socket", "grpc://unix/echo.Echo/Get"),
        ("", "grpc://unknown/echo.Echo/Get"),
    ])
    func urlFallsBackToRemotePeer(remotePeer: String, expected: String) {
        #expect(URL(baseURL: nil, remotePeer: remotePeer, descriptor: descriptor).absoluteString == expected)
    }

    @Test(arguments: [
        ("https://example.com", "grpcs://example.com/echo.Echo/Get"),
        ("https://example.com:8443/", "grpcs://example.com:8443/echo.Echo/Get"),
        ("grpcs://example.com", "grpcs://example.com/echo.Echo/Get"),
        ("http://localhost:9000", "grpc://localhost:9000/echo.Echo/Get"),
        ("https://example.com/api?x=1", "grpcs://example.com/api/echo.Echo/Get"),
    ])
    func urlFromBaseURL(baseURL: String, expected: String) throws {
        let url = URL(baseURL: URL(string: baseURL), remotePeer: "ipv4:10.0.0.1:443", descriptor: descriptor)
        #expect(url.absoluteString == expected)
    }

    @Test func headersJoinRepeatedKeysAndEncodeBinaryValues() {
        var metadata: Metadata = ["x-id": "1"]
        metadata.addString("2", forKey: "x-id")
        metadata.addBinary([0x01, 0x02], forKey: "x-token-bin")

        let headers = [String: String](metadata)

        #expect(headers["x-id"] == "1, 2")
        #expect(headers["x-token-bin"] == "AQI=")
    }

    /// The HTTP/2 transport passes pseudo-headers such as `:status` through as metadata.
    @Test func headersDropHTTP2PseudoHeaders() {
        let metadata: Metadata = [":status": "200", "x-id": "1"]
        #expect([String: String](metadata) == ["x-id": "1"])
    }

    @Test func headersLowercaseKeys() {
        var metadata: Metadata = ["X-Id": "1"]
        metadata.addString("2", forKey: "x-id")
        #expect([String: String](metadata) == ["x-id": "1, 2"])
    }

    @Test func responseMergesInitialAndTrailingMetadata() throws {
        let url = try #require(URL(string: "grpcs://example.com/echo.Echo/Get"))
        let response = try #require(HTTPURLResponse(
            url: url,
            initialMetadata: ["x-id": "1", "content-type": "application/grpc"],
            trailingMetadata: ["X-Id": "2"],
            rpcError: RPCError(code: .notFound, message: "gone", metadata: ["x-id": "3"])
        ))
        #expect(response.value(forHTTPHeaderField: "x-id") == "1, 2, 3")
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(response.value(forHTTPHeaderField: "grpc-status") == "5")
        #expect(response.value(forHTTPHeaderField: "grpc-message") == "gone")
    }

    @Test func encodesProtobufMessagesAsJSON() {
        let json = String(json: Google_Protobuf_StringValue("hello"), options: .init())
        #expect(json == "\"hello\"")
    }

    @Test func encodesOtherMessagesAsJSONStrings() {
        struct Custom: Sendable, CustomStringConvertible {
            var description: String { "custom \"value\"" }
        }
        let json = String(json: Custom(), options: .init())
        #expect(json == #""custom \"value\"""#)
    }

    @Test func bodyShapeDependsOnMessageCount() {
        #expect(Data(jsonMessages: []) == nil)
        #expect(Data(jsonMessages: [#"{"a":1}"#]) == Data(#"{"a":1}"#.utf8))
        #expect(Data(jsonMessages: ["1", "2"]) == Data("[1,2]".utf8))
    }

    @Test func errorUsesCanonicalStatusName() {
        let error = NSError(RPCError(code: .notFound, message: "user not found"))
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
        #expect(Duration(grpcTimeout: value) == expected)
    }

    @Test(arguments: ["", "m", "12", "12x"])
    func rejectsInvalidGRPCTimeout(value: String) {
        #expect(Duration(grpcTimeout: value) == nil)
    }

    @Test(arguments: [
        (Duration.milliseconds(160), "160ms"),
        (.microseconds(299_985), "300ms"),
        (.milliseconds(2_500), "2.5s"),
        (.microseconds(9_999_980), "10s"),
    ])
    func formatsDurations(duration: Duration, expected: String) {
        #expect(duration.statusMessageDescription == expected)
    }

    @Test func cancellationMapsToCancelled() {
        #expect(RPCError(mapping: CancellationError()).code == .cancelled)
    }
}
