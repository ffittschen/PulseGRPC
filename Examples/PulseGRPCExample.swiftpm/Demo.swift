import Foundation
import GRPCCore
import GRPCInProcessTransport
import PulseGRPC

/// One button's worth of work: makes a call and describes the outcome.
struct DemoCall: Sendable {
    let title: String
    let action: @Sendable () async -> String
}

enum Demo {
    static let interceptor = PulseClientInterceptor(baseURL: URL(string: "https://echo.example.com")!)

    static let grpcCalls: [DemoCall] = [
        DemoCall(title: "Unary OK") {
            await echo("Get") { try await $0.get(.with { $0.text = "hello" }).text }
        },
        DemoCall(title: "Unary NOT_FOUND") {
            let service = EchoService(failure: RPCError(code: .notFound, message: "No echo named 'ghost'"))
            return await echo("Get", service: service) { try await $0.get(.with { $0.text = "ghost" }).text }
        },
        DemoCall(title: "Server stream") {
            await echo("Expand") { client in
                try await client.expand(.with { $0.text = "a b c" }) { try await words(in: $0.messages) }
            }
        },
        DemoCall(title: "Client stream") {
            await echo("Collect") { client in
                try await client.collect { writer in
                    try await writer.write(contentsOf: ["a", "b", "c"].map { word in .with { $0.text = word } })
                }.text
            }
        },
        DemoCall(title: "Bidi") {
            await echo("Update") { client in
                try await client.update { writer in
                    for word in ["x", "y", "z"] {
                        try await writer.write(.with { $0.text = word })
                    }
                } onResponse: { try await words(in: $0.messages) }
            }
        },
        DemoCall(title: "Deadline exceeded") {
            let gate = Gate()
            return await echo("Get", service: EchoService(gate: gate)) { client in
                var options = CallOptions.defaults
                options.timeout = .milliseconds(50)
                do {
                    return try await client.get(.with { $0.text = "slow" }, options: options).text
                } catch {
                    await gate.open() // Lets the handler finish, so the server can shut down.
                    throw error
                }
            }
        },
    ]

    static let rest = DemoCall(title: "GET api.github.com") {
        do {
            let url = URL(string: "https://api.github.com/repos/kean/Pulse")!
            let (data, response) = try await URLSession.shared.data(from: url)
            return "REST: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0), \(data.count) bytes"
        } catch {
            return "REST: \(error.localizedDescription)"
        }
    }

    /// Runs `body` against a fresh in-process Echo server, with `interceptor` on the client.
    private static func echo(
        _ method: String,
        service: EchoService = EchoService(),
        _ body: @Sendable (Echo_Echo.Client<InProcessTransport.Client>) async throws -> String
    ) async -> String {
        let inProcess = InProcessTransport()
        do {
            let reply = try await withGRPCServer(transport: inProcess.server, services: [service]) { _ in
                try await withGRPCClient(transport: inProcess.client, interceptors: [interceptor]) { client in
                    try await body(Echo_Echo.Client(wrapping: client))
                }
            }
            return "\(method): \(reply)"
        } catch let error as RPCError {
            return "\(method): \(error.code) \(error.message)"
        } catch {
            return "\(method): \(error)"
        }
    }

    private static func words(in messages: RPCAsyncSequence<Echo_EchoResponse, any Error>) async throws -> String {
        var words: [String] = []
        for try await message in messages {
            words.append(message.text)
        }
        return words.joined(separator: " ")
    }
}
