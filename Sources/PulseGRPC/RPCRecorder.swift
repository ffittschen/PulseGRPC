import Foundation
import GRPCCore
import Pulse
import SwiftProtobuf
import Synchronization

/// Collects everything about one RPC attempt and logs it to Pulse exactly once.
final class RPCRecorder: Sendable {
    enum Outcome: Sendable {
        /// The response stream ended. This is only a success if trailers arrived:
        /// grpc-swift also ends the stream quietly when the calling task is cancelled.
        case endOfStream(isCancelled: Bool)
        /// The RPC ended with an error. The error's metadata are the trailers.
        case failed(RPCError, isCancelled: Bool)
        /// `next` threw before a response existed.
        case threw(any Error, isCancelled: Bool)
    }

    private struct State: Sendable {
        var requestMessages: [String] = []
        var responseMessages: [String] = []
        var initialMetadata: Metadata = [:]
        var trailingMetadata: Metadata?
        var isFinished = false
    }

    let taskId = UUID()
    private let startDate = Date()
    private let startInstant = ContinuousClock.now
    private let timeout: Duration?
    private let request: URLRequest
    private let logger: NetworkLogger
    private let label: String?
    private let jsonEncodingOptions: JSONEncodingOptions
    private let state = Mutex(State())

    init(
        request: URLRequest,
        requestMetadata: Metadata,
        logger: NetworkLogger,
        label: String?,
        jsonEncodingOptions: JSONEncodingOptions
    ) {
        self.request = request
        self.timeout = Array(requestMetadata[stringValues: "grpc-timeout"]).first
            .flatMap(GRPCTaskMapping.timeout(fromHeaderValue:))
        self.logger = logger
        self.label = label
        self.jsonEncodingOptions = jsonEncodingOptions
    }

    deinit {
        // Safety net: the app stopped reading the response before it ended.
        if let state = takeUnfinishedState() {
            log(state, withResponse: true, rpcError: RPCError(code: .cancelled, message: "Response stream not fully consumed."))
        }
    }

    // MARK: Recording

    func start() {
        logger.logTaskCreated(taskId: taskId, request: request, label: label)
    }

    func recordRequestMessage(_ message: some Sendable) {
        let json = GRPCTaskMapping.encode(message, options: jsonEncodingOptions)
        state.withLock { state in
            if !state.isFinished { state.requestMessages.append(json) }
        }
    }

    func recordResponseMessage(_ message: some Sendable) {
        let json = GRPCTaskMapping.encode(message, options: jsonEncodingOptions)
        state.withLock { state in
            if !state.isFinished { state.responseMessages.append(json) }
        }
    }

    func recordInitialMetadata(_ metadata: Metadata) {
        state.withLock { $0.initialMetadata = metadata }
    }

    func recordTrailingMetadata(_ metadata: Metadata) {
        state.withLock { $0.trailingMetadata = metadata }
    }

    /// Logs the completed task. Only the first call has an effect.
    func finish(_ outcome: Outcome) {
        guard let state = takeUnfinishedState() else { return }
        switch outcome {
        case .endOfStream(let isCancelled):
            let isComplete = state.trailingMetadata != nil && !isCancelled
            log(state, withResponse: true, rpcError: isComplete ? nil : cancellationError())
        case .failed(let error, let isCancelled):
            log(state, withResponse: true, rpcError: isCancelled ? cancellationError() : error)
        case .threw(let error, let isCancelled):
            if isCancelled {
                log(state, withResponse: false, rpcError: cancellationError())
            } else if error is RPCError || error is any RPCErrorConvertible {
                log(state, withResponse: false, rpcError: GRPCTaskMapping.rpcError(from: error))
            } else {
                log(state, response: nil, error: error)
            }
        }
    }

    // MARK: Private

    private func takeUnfinishedState() -> State? {
        state.withLock { state in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            return state
        }
    }

    /// `DEADLINE_EXCEEDED` if the request's `grpc-timeout` has run out, `CANCELLED` otherwise.
    ///
    /// grpc-swift computes `grpc-timeout` just before the interceptors run, so the
    /// recorder's clock starts slightly later. The tolerance absorbs that gap.
    private func cancellationError() -> RPCError {
        if let timeout, ContinuousClock.now - startInstant + .milliseconds(20) >= timeout {
            return RPCError(code: .deadlineExceeded, message: "RPC timed out before completing")
        }
        return RPCError(code: .cancelled, message: "The RPC was cancelled.")
    }

    private func log(_ state: State, withResponse: Bool, rpcError: RPCError?) {
        log(
            state,
            response: withResponse ? makeResponse(state, rpcError: rpcError) : nil,
            error: rpcError.map(GRPCTaskMapping.error(for:))
        )
    }

    private func log(_ state: State, response: HTTPURLResponse?, error: (any Error)?) {
        logger.logTaskCompleted(
            taskId: taskId,
            request: request,
            response: response,
            error: error,
            requestBody: GRPCTaskMapping.body(fromJSONMessages: state.requestMessages),
            responseBody: GRPCTaskMapping.body(fromJSONMessages: state.responseMessages),
            metrics: NetworkLogger.Metrics(
                taskInterval: DateInterval(start: startDate, end: max(Date(), startDate)),
                redirectCount: 0,
                transactions: []
            ),
            label: label
        )
    }

    private func makeResponse(_ state: State, rpcError: RPCError?) -> HTTPURLResponse? {
        guard let url = request.url else { return nil }
        var headers = GRPCTaskMapping.merging(
            GRPCTaskMapping.headers(from: state.initialMetadata),
            GRPCTaskMapping.headers(from: state.trailingMetadata ?? [:])
        )
        if let rpcError {
            headers = GRPCTaskMapping.merging(headers, GRPCTaskMapping.headers(from: rpcError.metadata))
        }
        headers = GRPCTaskMapping.removingContentType(from: headers)
        headers["grpc-status"] = String(rpcError?.code.rawValue ?? 0)
        if let message = rpcError?.message, !message.isEmpty {
            headers["grpc-message"] = message
        }
        headers["Content-Type"] = GRPCTaskMapping.contentType
        return HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/2", headerFields: headers)
    }
}
