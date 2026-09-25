import Foundation
import GRPCCore
import GRPCInProcessTransport
import Pulse
import Testing

let exampleBaseURL = URL(string: "https://example.com")!

/// A fresh on-disk store that writes synchronously, so tests can read right after a call.
func makeStore() throws -> LoggerStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PulseGRPCTests-\(UUID().uuidString)", isDirectory: true)
    return try LoggerStore(storeURL: url, options: [.create, .synchronous])
}

/// A plain copy of the fields the tests check, read in a fresh context.
struct TaskSnapshot {
    let url: String?
    let httpMethod: String?
    let state: NetworkTaskEntity.State
    let statusCode: Int32
    let requestHeaders: [String: String]
    let responseHeaders: [String: String]
    let requestBody: String?
    let responseBody: String?
    let errorDomain: String?
    let errorCode: Int32
    let errorDebugDescription: String?
    let duration: Double
    let label: String?

    init(_ task: NetworkTaskEntity) {
        url = task.url
        httpMethod = task.httpMethod
        state = task.state
        statusCode = task.statusCode
        requestHeaders = task.originalRequest?.headers ?? [:]
        responseHeaders = task.response?.headers ?? [:]
        requestBody = task.requestBody?.data.flatMap { String(data: $0, encoding: .utf8) }
        responseBody = task.responseBody?.data.flatMap { String(data: $0, encoding: .utf8) }
        errorDomain = task.errorDomain
        errorCode = task.errorCode
        errorDebugDescription = task.errorDebugDescription
        duration = task.duration
        label = task.message?.label
    }

    /// Header lookup ignoring case: `URLRequest` capitalizes header names.
    func requestHeader(_ name: String) -> String? {
        requestHeaders.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    func responseHeader(_ name: String) -> String? {
        responseHeaders.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

func snapshots(in store: LoggerStore) throws -> [TaskSnapshot] {
    let context = store.newBackgroundContext()
    return try context.performAndWait {
        try store.tasks(context: context).map(TaskSnapshot.init)
    }
}

/// Polls `condition` until it holds or `timeout` elapses.
func eventually(
    timeout: Duration = .seconds(2),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Condition not met within \(timeout)", sourceLocation: sourceLocation)
}

/// Runs `body` with an Echo client using `interceptors`, talking to `service`
/// over an in-process transport.
func withEchoClient<Result: Sendable>(
    service: EchoService = EchoService(),
    interceptors: [any ClientInterceptor],
    _ body: @Sendable (Echo_Echo.Client<InProcessTransport.Client>) async throws -> Result
) async throws -> Result {
    let inProcess = InProcessTransport()
    return try await withGRPCServer(transport: inProcess.server, services: [service]) { _ in
        try await withGRPCClient(transport: inProcess.client, interceptors: interceptors) { client in
            try await body(Echo_Echo.Client(wrapping: client))
        }
    }
}
