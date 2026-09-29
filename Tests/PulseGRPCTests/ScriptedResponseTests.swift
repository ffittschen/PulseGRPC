import Foundation
import GRPCCore
import Pulse
import PulseGRPC
import Testing

/// Calls whose timing the in-process transport can't produce on demand, e.g. a
/// cancellation between two response parts. The interceptor is called directly, with
/// a scripted response in place of the transport's.
@Suite struct ScriptedResponseTests {
    @Test func trailersReadBeforeCancellationAreLoggedAsOK() async throws {
        let store = try makeStore()
        let parts = ScriptedBodyParts([.success(.message("hi")), .success(.trailingMetadata(["x-trailing": "2"]))])

        try await Task {
            var iterator = try await intercept(returning: parts, store: store).makeAsyncIterator()
            _ = try await iterator.next()
            _ = try await iterator.next()
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(try await iterator.next() == nil)
        }.value

        let task = try #require(try snapshots(in: store).first)
        #expect(task.state == .success)
        #expect(task.responseHeader("grpc-status") == "0")
    }

    @Test func serverErrorReadDuringCancellationKeepsItsStatus() async throws {
        let store = try makeStore()
        let parts = ScriptedBodyParts([
            .success(.message("hi")),
            .failure(RPCError(code: .notFound, message: "nope", metadata: ["x-reason": "missing"])),
        ])

        try await Task {
            var iterator = try await intercept(returning: parts, store: store).makeAsyncIterator()
            _ = try await iterator.next()
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: RPCError.self) { try await iterator.next() }
        }.value

        let task = try #require(try snapshots(in: store).first)
        #expect(task.errorCode == 5)
        #expect(task.errorDebugDescription?.contains("NOT_FOUND (5): nope") == true)
        #expect(task.responseHeader("x-reason") == "missing")
    }

    @Test func cancellationErrorDuringCancellationIsLoggedAsCancelled() async throws {
        let store = try makeStore()
        let parts = ScriptedBodyParts([.success(.message("hi")), .failure(CancellationError())])

        try await Task {
            var iterator = try await intercept(returning: parts, store: store).makeAsyncIterator()
            _ = try await iterator.next()
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { try await iterator.next() }
        }.value

        let task = try #require(try snapshots(in: store).first)
        #expect(task.errorCode == 1)
        #expect(task.errorDebugDescription?.contains("CANCELLED (1): The RPC was cancelled.") == true)
    }

    /// grpc-swift-2 skips the request producer when writing the request metadata throws,
    /// e.g. because the server already closed the stream. The task is logged once
    /// grpc-swift-2 lets go of the request.
    @Test func rejectedCallWhoseProducerNeverRunsIsLogged() async throws {
        let store = try makeStore()
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))

        let response = try await interceptor.intercept(
            request: StreamingClientRequest<String> { try await $0.write("hi") },
            context: context
        ) { _, _ in
            StreamingClientResponse<String>(error: RPCError(code: .unimplemented, message: "nope"))
        }

        #expect(throws: RPCError.self) { try response.accepted.get() }
        let task = try #require(try snapshots(in: store).first)
        #expect(task.state == .failure)
        #expect(task.errorCode == 12)
        #expect(task.requestBody == nil)
    }

    // MARK: Private

    private let context = ClientContext(
        descriptor: MethodDescriptor(service: ServiceDescriptor(fullyQualifiedService: "echo.Echo"), method: "Get"),
        remotePeer: "in-process:1",
        localPeer: "in-process:1"
    )

    /// Calls the interceptor as if the transport accepted the call and returned `parts`,
    /// runs the request producer, and returns the body parts the app would read.
    private func intercept(
        returning parts: ScriptedBodyParts,
        store: LoggerStore
    ) async throws -> RPCAsyncSequence<ScriptedBodyParts.Element, any Error> {
        let interceptor = PulseClientInterceptor(baseURL: exampleBaseURL, logger: NetworkLogger(store: store))
        let response = try await interceptor.intercept(
            request: StreamingClientRequest<String> { try await $0.write("hi") },
            context: context
        ) { request, _ in
            try await request.producer(RPCWriter(wrapping: DiscardingWriter()))
            return StreamingClientResponse(metadata: [:], bodyParts: RPCAsyncSequence(wrapping: parts))
        }
        return try response.accepted.get().bodyParts
    }
}

/// Returns its parts in order and then `nil`, whether or not the task is cancelled.
private struct ScriptedBodyParts: AsyncSequence, Sendable {
    typealias Element = StreamingClientResponse<String>.Contents.BodyPart

    let parts: [Result<Element, any Error>]

    init(_ parts: [Result<Element, any Error>]) {
        self.parts = parts
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(parts: parts[...])
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var parts: ArraySlice<Result<Element, any Error>>

        mutating func next() async throws -> Element? {
            try parts.popFirst()?.get()
        }
    }
}

private struct DiscardingWriter: RPCWriterProtocol {
    func write(_ element: String) async throws {}
    func write(contentsOf elements: some Sequence<String>) async throws {}
}
