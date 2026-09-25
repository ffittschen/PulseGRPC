import Foundation
import GRPCCore
import Pulse
import SwiftProtobuf

/// A grpc-swift v2 client interceptor that logs every RPC attempt to Pulse as
/// a network task.
///
/// Add it **last** in the client's interceptor list, so it sees the final
/// request metadata and the raw `RPCError` before other interceptors change them.
///
/// ```swift
/// let client = GRPCClient(
///     transport: transport,
///     interceptors: [AuthInterceptor(), PulseClientInterceptor(baseURL: URL(string: "https://api.example.com")!)]
/// )
/// ```
public struct PulseClientInterceptor: ClientInterceptor {
    private let baseURL: URL?
    private let logger: NetworkLogger?
    private let label: String?
    private let jsonEncodingOptions: JSONEncodingOptions

    /// - parameters:
    ///   - baseURL: The server's URL, e.g. `https://api.example.com:443`. Used for the
    ///     logged URL (`grpcs://…` for `https`, `grpc://…` otherwise). If `nil`, the
    ///     address of the remote peer is used.
    ///   - logger: The network logger. If `nil`, uses `NetworkLogger.shared` at the time of each call.
    ///   - label: The label of the logged tasks. If `nil`, uses the logger's configured label.
    ///   - jsonEncodingOptions: Options for encoding protobuf messages as JSON.
    public init(
        baseURL: URL? = nil,
        logger: NetworkLogger? = nil,
        label: String? = "grpc",
        jsonEncodingOptions: JSONEncodingOptions = .init()
    ) {
        self.baseURL = baseURL
        self.logger = logger
        self.label = label
        self.jsonEncodingOptions = jsonEncodingOptions
    }

    public func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (
            _ request: StreamingClientRequest<Input>,
            _ context: ClientContext
        ) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        let recorder = RPCRecorder(
            request: GRPCTaskMapping.makeRequest(baseURL: baseURL, context: context, metadata: request.metadata),
            requestMetadata: request.metadata,
            logger: logger ?? .shared,
            label: label,
            jsonEncodingOptions: jsonEncodingOptions
        )
        recorder.start()

        var request = request
        let producer = request.producer
        request.producer = { writer in
            defer { recorder.requestDidFinish() }
            try await producer(RPCWriter(wrapping: RecordingWriter(base: writer, recorder: recorder)))
        }

        let response: StreamingClientResponse<Output>
        do {
            response = try await next(request, context)
        } catch {
            recorder.finish(.threw(error, isCancelled: Task.isCancelled))
            throw error
        }

        switch response.accepted {
        case .success(var contents):
            recorder.recordInitialMetadata(contents.metadata)
            contents.bodyParts = RPCAsyncSequence(wrapping: RecordingBodyParts(base: contents.bodyParts, recorder: recorder))
            return StreamingClientResponse(accepted: .success(contents))
        case .failure(let error):
            recorder.finishAfterRequest(.failed(error, isCancelled: Task.isCancelled))
            return response
        }
    }
}
