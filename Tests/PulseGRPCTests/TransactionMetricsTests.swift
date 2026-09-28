import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Pulse
@testable import PulseGRPC
import Testing

@Suite struct TransactionMetricsTests {
    @Test func unaryCallHasOneSyntheticTransaction() async throws {
        let store = try makeStore()
        let logger = NetworkLogger(store: store) { $0.sensitiveHeaders = ["authorization"] }
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: logger)

        _ = try await withEchoClient(interceptors: [interceptor]) { client in
            try await client.get(.with { $0.text = "hello" }, metadata: ["authorization": "Bearer secret"])
        }

        let transaction = try #require(try transactionSnapshots(in: store).first)
        #expect(transaction.transactionCount == 1)
        #expect(transaction.fetchType == .networkLoad)
        #expect(transaction.size.requestBodyBytesSent == 16) // {"text":"hello"}
        #expect(transaction.size.responseBodyBytesReceived == 16)
        #expect(transaction.size.requestHeaderBytesSent > 0)
        #expect(transaction.taskRequestBodySize == 16)
        #expect(transaction.taskResponseBodySize == 16)
        #expect(transaction.requestHeaders.first { $0.key.lowercased() == "authorization" }?.value == "<private>")
        #expect(transaction.responseHeaders["grpc-status"] == "0")
        #expect(transaction.isFromCache == false)
        #expect(transaction.timing.responseStartDate != nil)
        #expect(abs((transaction.timing.duration ?? 0) - transaction.taskDuration) < 0.001)
    }

    @Test func serverStreamTransactionCountsAllMessages() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))

        _ = try await withEchoClient(interceptors: [interceptor]) { client in
            try await client.expand(.with { $0.text = "a b c" }) { response in
                for try await _ in response.messages {}
            }
        }

        let transaction = try #require(try transactionSnapshots(in: store).first)
        #expect(transaction.size.responseBodyBytesReceived == 40) // [{"text":"a"},{"text":"b"},{"text":"c"}]
    }

    @Test func bidiTransactionOmitsRequestEndThatOverlapsTheResponse() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))

        _ = try await withEchoClient(interceptors: [interceptor]) { client in
            try await client.update { writer in
                try await writer.write(.with { $0.text = "x" })
                try await Task.sleep(for: .milliseconds(30))
                try await writer.write(.with { $0.text = "y" })
            } onResponse: { response in
                for try await _ in response.messages {}
            }
        }

        let transaction = try #require(try transactionSnapshots(in: store).first)
        #expect(transaction.timing.requestEndDate == nil)
        #expect(transaction.timing.responseStartDate != nil)
    }

    @Test func rejectedCallTransactionStartsItsResponseBeforeTheEnd() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))

        _ = try await withEchoClient(services: [], interceptors: [interceptor]) { client in
            await #expect(throws: RPCError.self) {
                try await client.get(.with { $0.text = "x" })
            }
        }

        try await eventually { try snapshots(in: store).first?.state == .failure }
        let transaction = try #require(try transactionSnapshots(in: store).first)
        let start = try #require(transaction.timing.responseStartDate)
        let end = try #require(transaction.timing.responseEndDate)
        #expect(start <= end)
    }

    @Test(arguments: [
        ("ipv4:127.0.0.1:31415", "127.0.0.1", 31415),
        ("ipv6:[::1]:443", "::1", 443),
    ])
    func addressFromPeer(peer: String, address: String, port: Int) {
        let result = PeerAddress(peer: peer)
        #expect(result?.host == address)
        #expect(result?.port == port)
    }

    @Test(arguments: ["in-process:27182", "unix:/tmp/socket", "", "ipv4:", "ipv4:1.2.3.4"])
    func addressFromNonIPPeerIsNil(peer: String) {
        #expect(PeerAddress(peer: peer) == nil)
    }

    @Test func nonIPPeerIsShownAsItIs() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))

        _ = try await withEchoClient(interceptors: [interceptor]) { client in
            try await client.get(.with { $0.text = "hello" })
        }

        let transaction = try #require(try transactionSnapshots(in: store).first)
        #expect(transaction.remoteAddress?.hasPrefix("in-process:") == true)
        #expect(transaction.networkProtocol == nil)
    }

    /// The in-process transport doesn't pass HTTP/2 pseudo-headers, so this runs over the real one.
    @Test func http2TransportRecordsPeerWithoutPseudoHeaders() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: URL(string: "http://127.0.0.1"), logger: NetworkLogger(store: store))
        let serverTransport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: "127.0.0.1", port: 0),
            transportSecurity: .plaintext
        )

        try await withGRPCServer(transport: serverTransport, services: [EchoService()]) { _ in
            let port = try #require(try await serverTransport.listeningAddress.ipv4?.port)
            let clientTransport = try HTTP2ClientTransport.Posix(
                target: .ipv4(address: "127.0.0.1", port: port),
                transportSecurity: .plaintext
            )
            try await withGRPCClient(transport: clientTransport, interceptors: [interceptor]) { client in
                _ = try await Echo_Echo.Client(wrapping: client).get(.with { $0.text = "hello" })
            }
        }

        let task = try #require(try snapshots(in: store).first)
        #expect(task.state == .success)
        #expect(task.responseHeader("grpc-status") == "0")
        // Pulse stores headers as `name: value` lines, so a leaked `:status` reads back
        // under an empty key rather than one starting with ":".
        #expect(task.responseHeaders.keys.allSatisfy { !$0.isEmpty && !$0.hasPrefix(":") })
        let transaction = try #require(try transactionSnapshots(in: store).first)
        #expect(transaction.remoteAddress == "127.0.0.1")
        #expect(transaction.networkProtocol == "h2")
    }

    /// A failed call maps the same way over the real HTTP/2 transport as it does in-process.
    @Test func http2TransportMapsFailedCallStatus() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: URL(string: "http://127.0.0.1"), logger: NetworkLogger(store: store))
        let service = EchoService(failure: RPCError(code: .notFound, message: "No echo named 'ghost'"))
        let serverTransport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: "127.0.0.1", port: 0),
            transportSecurity: .plaintext
        )

        try await withGRPCServer(transport: serverTransport, services: [service]) { _ in
            let port = try #require(try await serverTransport.listeningAddress.ipv4?.port)
            let clientTransport = try HTTP2ClientTransport.Posix(
                target: .ipv4(address: "127.0.0.1", port: port),
                transportSecurity: .plaintext
            )
            _ = try await withGRPCClient(transport: clientTransport, interceptors: [interceptor]) { client in
                await #expect(throws: RPCError.self) {
                    _ = try await Echo_Echo.Client(wrapping: client).get(.with { $0.text = "ghost" })
                }
            }
        }

        let task = try #require(try snapshots(in: store).first)
        #expect(task.state == .failure)
        #expect(task.errorDomain == "gRPC")
        #expect(task.errorCode == 5)
        #expect(task.responseHeader("grpc-status") == "5")
        // Pulse stores headers as `name: value` lines, so a leaked `:status` reads back
        // under an empty key rather than one starting with ":".
        #expect(task.responseHeaders.keys.allSatisfy { !$0.isEmpty && !$0.hasPrefix(":") })
    }
}
