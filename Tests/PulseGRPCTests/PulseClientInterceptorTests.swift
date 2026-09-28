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

    /// A server that rejects a call before reading it replies trailers-only, which
    /// often reaches the client before the request message has been written.
    @Test func rejectedCallKeepsRequestBody() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))

        try await withEchoClient(services: [], interceptors: [interceptor]) { client in
            for index in 0..<10 {
                await #expect(throws: RPCError.self) {
                    try await client.get(.with { $0.text = "call-\(index)" })
                }
            }
        }

        try await eventually { try snapshots(in: store).filter { $0.state == .failure }.count == 10 }
        let tasks = try snapshots(in: store)
        #expect(tasks.allSatisfy { $0.errorCode == 12 })
        #expect(Set(tasks.compactMap(\.requestBody)).count == 10)
    }

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

    @Test func requestMetadataKeysDifferingInCaseKeepAllValues() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))
        var metadata: Metadata = ["X-Id": "1"]
        metadata.addString("2", forKey: "x-id")

        _ = try await withEchoClient(interceptors: [interceptor]) { [metadata] client in
            try await client.get(.with { $0.text = "hi" }, metadata: metadata)
        }

        let task = try #require(try snapshots(in: store).first)
        #expect(task.requestHeader("x-id") == "1, 2")
    }

    // MARK: Streaming

    @Test func serverStreamResponseIsLoggedAsJSONArray() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))

        let words = try await withEchoClient(interceptors: [interceptor]) { client in
            try await client.expand(.with { $0.text = "a b c" }) { response in
                var words: [String] = []
                for try await message in response.messages {
                    words.append(message.text)
                }
                return words
            }
        }

        #expect(words == ["a", "b", "c"])
        let task = try #require(try snapshots(in: store).first)
        #expect(task.url == "grpcs://example.com/echo.Echo/Expand")
        #expect(task.state == .success)
        #expect(task.responseBody == #"[{"text":"a"},{"text":"b"},{"text":"c"}]"#)
    }

    @Test func clientStreamRequestIsLoggedAsJSONArray() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))

        let reply = try await withEchoClient(interceptors: [interceptor]) { client in
            try await client.collect { writer in
                try await writer.write(.with { $0.text = "a" })
                try await writer.write(contentsOf: [.with { $0.text = "b" }, .with { $0.text = "c" }])
            }
        }

        #expect(reply.text == "a b c")
        let task = try #require(try snapshots(in: store).first)
        #expect(task.state == .success)
        #expect(task.requestBody == #"[{"text":"a"},{"text":"b"},{"text":"c"}]"#)
        #expect(task.responseBody == #"{"text":"a b c"}"#)
    }

    @Test func bidirectionalStreamIsLoggedWithBothBodies() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))

        let count = try await withEchoClient(interceptors: [interceptor]) { client in
            try await client.update { writer in
                try await writer.write(.with { $0.text = "x" })
                try await writer.write(.with { $0.text = "y" })
            } onResponse: { response in
                var count = 0
                for try await _ in response.messages {
                    count += 1
                }
                return count
            }
        }

        #expect(count == 2)
        let task = try #require(try snapshots(in: store).first)
        #expect(task.state == .success)
        #expect(task.requestBody == #"[{"text":"x"},{"text":"y"}]"#)
        #expect(task.responseBody == #"[{"text":"x"},{"text":"y"}]"#)
    }

    @Test func serverStreamFailingMidwayKeepsReceivedMessages() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))
        let service = EchoService(failure: RPCError(code: .dataLoss, message: "stream broke"))

        await #expect(throws: RPCError.self) {
            try await withEchoClient(service: service, interceptors: [interceptor]) { client in
                try await client.expand(.with { $0.text = "a b" }) { response in
                    for try await _ in response.messages {}
                }
            }
        }

        let task = try #require(try snapshots(in: store).first)
        #expect(task.state == .failure)
        #expect(task.errorCode == 15)
        #expect(task.responseHeader("grpc-status") == "15")
        #expect(task.responseHeader("grpc-message") == "stream broke")
        #expect(task.responseBody == #"[{"text":"a"},{"text":"b"}]"#)
    }

    @Test func concurrentCallsAreLoggedAsSeparateTasks() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))

        try await withEchoClient(interceptors: [interceptor]) { client in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<10 {
                    group.addTask { _ = try await client.get(.with { $0.text = "call-\(index)" }) }
                }
                try await group.waitForAll()
            }
        }

        let tasks = try snapshots(in: store)
        #expect(tasks.count == 10)
        #expect(tasks.allSatisfy { $0.state == .success && $0.requestBody == $0.responseBody })
        #expect(Set(tasks.compactMap(\.requestBody)).count == 10)
    }

    // MARK: Lifecycle

    @Test func taskIsPendingUntilServerResponds() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))
        let gate = Gate()

        try await withEchoClient(service: EchoService(gate: gate), interceptors: [interceptor]) { client in
            async let reply = client.get(.with { $0.text = "hi" })
            try await eventually { try snapshots(in: store).first?.state == .pending }
            await gate.open()
            _ = try await reply
        }

        let task = try #require(try snapshots(in: store).first)
        #expect(task.state == .success)
    }

    @Test func abandonedStreamIsLoggedAsCancelled() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))

        let first = try await withEchoClient(interceptors: [interceptor]) { client in
            try await client.expand(.with { $0.text = "a b c" }) { response -> String? in
                for try await message in response.messages {
                    return message.text
                }
                return nil
            }
        }

        #expect(first == "a")
        try await eventually { try snapshots(in: store).first?.state == .failure }
        let task = try #require(try snapshots(in: store).first)
        #expect(task.errorDomain == "gRPC")
        #expect(task.errorCode == 1)
    }

    @Test func cancelledStreamIsLoggedAsCancelled() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))
        let gate = Gate()
        let firstMessageReceived = Gate()

        try await withEchoClient(service: EchoService(gate: gate), interceptors: [interceptor]) { client in
            let call = Task {
                try await client.expand(.with { $0.text = "a b" }) { response in
                    for try await _ in response.messages {
                        await firstMessageReceived.open()
                    }
                }
            }
            // The server now waits at `gate` after sending "a".
            await firstMessageReceived.wait()
            call.cancel()
            _ = await call.result
            await gate.open() // Lets the server handler finish so the server can shut down.
        }

        try await eventually { try snapshots(in: store).first?.state == .failure }
        let task = try #require(try snapshots(in: store).first)
        #expect(task.errorDomain == "gRPC")
        #expect(task.errorCode == 1)
        #expect(task.responseBody == #"{"text":"a"}"#)
    }

    @Test func cancelledCallWithTimeoutReportsTimeoutAndElapsedTime() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))
        let gate = Gate()

        try await withEchoClient(service: EchoService(gate: gate), interceptors: [interceptor]) { client in
            var options = CallOptions.defaults
            options.timeout = .seconds(30) // Sent as an 8-digit `grpc-timeout`, e.g. `29999986u`.
            let call = Task { try await client.get(.with { $0.text = "slow" }, options: options) }
            try await eventually { try snapshots(in: store).first?.state == .pending }
            try await Task.sleep(for: .milliseconds(50))
            call.cancel()
            _ = await call.result
            await gate.open()
        }

        try await eventually { try snapshots(in: store).first?.state == .failure }
        let task = try #require(try snapshots(in: store).first)
        #expect(task.errorCode == 1)
        #expect(task.errorDebugDescription?.contains("CANCELLED (1): The RPC was cancelled (grpc-timeout 30s, ") == true)
        #expect(task.errorDebugDescription?.contains("ms elapsed).") == true)
    }

    @Test func cancelledCallWithoutTimeoutKeepsPlainMessage() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))
        let gate = Gate()

        try await withEchoClient(service: EchoService(gate: gate), interceptors: [interceptor]) { client in
            let call = Task { try await client.get(.with { $0.text = "slow" }) }
            try await eventually { try snapshots(in: store).first?.state == .pending }
            call.cancel()
            _ = await call.result
            await gate.open()
        }

        try await eventually { try snapshots(in: store).first?.state == .failure }
        let task = try #require(try snapshots(in: store).first)
        #expect(task.errorDebugDescription?.contains("CANCELLED (1): The RPC was cancelled.") == true)
    }

    @Test func deadlineExceededIsLoggedAsFailure() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))
        let gate = Gate()

        try await withEchoClient(service: EchoService(gate: gate), interceptors: [interceptor]) { client in
            // Connect first: grpc-swift computes `grpc-timeout` before it waits for the
            // connection, while the interceptor's clock only starts once the stream exists.
            _ = try await client.collect { try await $0.write(.with { $0.text = "warm-up" }) }
            var options = CallOptions.defaults
            options.timeout = .milliseconds(300)
            await #expect(throws: RPCError.self) {
                try await client.get(.with { $0.text = "slow" }, options: options)
            }
            await gate.open()
        }

        try await eventually { try snapshots(in: store).contains { $0.state == .failure } }
        let task = try #require(try snapshots(in: store).first { $0.url?.hasSuffix("/Get") == true })
        #expect(task.errorDomain == "gRPC")
        #expect(task.errorCode == 4)
        #expect(task.responseHeader("grpc-status") == "4")
        #expect(task.requestHeader("grpc-timeout") != nil)
        #expect(task.errorDebugDescription?.contains("(grpc-timeout 300ms, ") == true)
    }

    // MARK: Logger configuration

    @Test func sensitiveHeadersAreRedacted() async throws {
        let store = try makeStore()
        let logger = NetworkLogger(store: store) { $0.sensitiveHeaders = ["authorization"] }
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: logger)

        _ = try await withEchoClient(interceptors: [interceptor]) { client in
            try await client.get(.with { $0.text = "hi" }, metadata: ["authorization": "Bearer secret"])
        }

        let task = try #require(try snapshots(in: store).first)
        #expect(task.requestHeader("authorization") == "<private>")
    }

    @Test func nilLabelFallsBackToLoggerLabel() async throws {
        let store = try makeStore()
        let logger = NetworkLogger(store: store) { $0.label = "custom" }
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: logger, label: nil)

        _ = try await withEchoClient(interceptors: [interceptor]) { client in
            try await client.get(.with { $0.text = "hi" })
        }

        let task = try #require(try snapshots(in: store).first)
        #expect(task.label == "custom")
    }
}
