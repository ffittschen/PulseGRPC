import Foundation
import GRPCCore
import Pulse
import PulseGRPC
import Testing

@Suite struct PulseClientInterceptorTests {
    @Test func unaryCallIsLoggedAsSuccessfulTask() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))

        let reply = try await withEchoClient(interceptors: [interceptor]) { client in
            try await client.get(.with { $0.text = "hello" }, metadata: ["x-request": "abc"])
        }

        #expect(reply.text == "hello")
        let task = try #require(try snapshots(in: store).first)
        #expect(task.url == "grpcs://example.com/echo.Echo/Get")
        #expect(task.httpMethod == "POST")
        #expect(task.state == .success)
        #expect(task.statusCode == 200)
        #expect(task.label == "grpc")
        #expect(task.requestBody == #"{"text":"hello"}"#)
        #expect(task.responseBody == #"{"text":"hello"}"#)
        #expect(task.requestHeader("x-request") == "abc")
        #expect(task.requestHeader("Content-Type") == "application/json")
        #expect(task.responseHeader("grpc-status") == "0")
        #expect(task.responseHeader("x-initial") == "1")
        #expect(task.responseHeader("x-trailing") == "2")
        #expect(task.responseHeader("Content-Type") == "application/json")
        #expect(task.duration > 0)
    }

    @Test func failedUnaryCallIsLoggedWithGRPCStatus() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))
        let service = EchoService(failure: RPCError(code: .notFound, message: "nope", metadata: ["x-reason": "missing"]))

        await #expect(throws: RPCError.self) {
            try await withEchoClient(service: service, interceptors: [interceptor]) { client in
                try await client.get(.with { $0.text = "hello" })
            }
        }

        let task = try #require(try snapshots(in: store).first)
        #expect(task.state == .failure)
        #expect(task.errorDomain == "gRPC")
        #expect(task.errorCode == 5)
        #expect(task.errorDebugDescription?.contains("NOT_FOUND (5): nope") == true)
        #expect(task.responseHeader("grpc-status") == "5")
        #expect(task.responseHeader("grpc-message") == "nope")
        #expect(task.responseHeader("x-reason") == "missing")
        #expect(task.requestBody == #"{"text":"hello"}"#)
        #expect(task.responseBody == nil)
    }

    /// Review focus 5.
    @Test func requestMetadataIsStoredAsHeaders() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))
        var metadata: Metadata = ["content-type": "application/grpc", "x-id": "1"]
        metadata.addString("2", forKey: "x-id")
        metadata.addBinary([0x01, 0x02], forKey: "x-token-bin")

        _ = try await withEchoClient(interceptors: [interceptor]) { [metadata] client in
            try await client.get(.with { $0.text = "hi" }, metadata: metadata)
        }

        let task = try #require(try snapshots(in: store).first)
        #expect(task.requestHeader("x-id") == "1, 2")
        #expect(task.requestHeader("x-token-bin") == "AQI=")
        #expect(task.requestHeader("Content-Type") == "application/json")
        #expect(task.requestHeaders.keys.filter { $0.lowercased() == "content-type" }.count == 1)
    }
}
