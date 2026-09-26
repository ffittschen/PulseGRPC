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
        var isRequestFinished = false
        /// An outcome waiting for the request side to finish, see `finishAfterRequest(_:)`.
        var pendingCompletion: Completion?
        var isFinished = false
    }

    /// What gets logged, fixed when the outcome is known.
    private struct Completion: Sendable {
        enum Result: Sendable {
            /// A gRPC status; `nil` means OK.
            case rpc(RPCError?, withResponse: Bool)
            /// A non-gRPC error thrown by `next`, logged unchanged.
            case other(any Error)
        }

        var result: Result
        var endDate: Date
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
        // Safety net: the app stopped reading the response before it ended, or a
        // pending outcome never saw the request side finish.
        if let state = takeUnfinishedState() {
            log(state, state.pendingCompletion ?? Completion(
                result: .rpc(RPCError(code: .cancelled, message: "Response stream not fully consumed."), withResponse: true),
                endDate: Date()
            ))
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

    /// Logs the completed task. Only the first call to `finish(_:)` or
    /// `finishAfterRequest(_:)` has an effect.
    func finish(_ outcome: Outcome) {
        complete(outcome, waitsForRequest: false)
    }

    /// Like `finish(_:)`, but logs only once the request side is done.
    ///
    /// A server that rejects a call before reading it replies trailers-only, often
    /// before the request message has been written. The outcome and end date are
    /// fixed now; waiting only keeps the request body.
    func finishAfterRequest(_ outcome: Outcome) {
        complete(outcome, waitsForRequest: true)
    }

    /// Called when the request producer returns or throws.
    func requestDidFinish() {
        let finished: (State, Completion)? = state.withLock { state in
            state.isRequestFinished = true
            guard !state.isFinished, let completion = state.pendingCompletion else { return nil }
            state.isFinished = true
            return (state, completion)
        }
        if let finished {
            log(finished.0, finished.1)
        }
    }

    // MARK: Private

    private func complete(_ outcome: Outcome, waitsForRequest: Bool) {
        let endDate = Date()
        let finished: (State, Completion)? = state.withLock { state in
            guard !state.isFinished, state.pendingCompletion == nil else { return nil }
            let completion = Completion(result: result(for: outcome, trailingMetadata: state.trailingMetadata), endDate: endDate)
            guard !waitsForRequest || state.isRequestFinished else {
                state.pendingCompletion = completion
                return nil
            }
            state.isFinished = true
            return (state, completion)
        }
        if let finished {
            log(finished.0, finished.1)
        }
    }

    private func result(for outcome: Outcome, trailingMetadata: Metadata?) -> Completion.Result {
        switch outcome {
        case .endOfStream(let isCancelled):
            let isComplete = trailingMetadata != nil && !isCancelled
            return .rpc(isComplete ? nil : cancellationError(), withResponse: true)
        case .failed(let error, let isCancelled):
            return .rpc(isCancelled ? cancellationError() : error, withResponse: true)
        case .threw(let error, let isCancelled):
            if isCancelled {
                return .rpc(cancellationError(), withResponse: false)
            }
            if error is RPCError || error is any RPCErrorConvertible {
                return .rpc(GRPCTaskMapping.rpcError(from: error), withResponse: false)
            }
            return .other(error)
        }
    }

    private func takeUnfinishedState() -> State? {
        state.withLock { state in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            return state
        }
    }

    /// `DEADLINE_EXCEEDED` if the request's `grpc-timeout` has run out, `CANCELLED` otherwise.
    ///
    /// grpc-swift computes `grpc-timeout` before it waits for a connection, while this clock
    /// starts once the stream exists. The 20 ms tolerance absorbs the usual gap; on a slow
    /// first connection a deadline can still read as `CANCELLED`, so the message says how
    /// much time was allowed and how much had passed.
    private func cancellationError() -> RPCError {
        guard let timeout else {
            return RPCError(code: .cancelled, message: "The RPC was cancelled.")
        }
        let elapsed = ContinuousClock.now - startInstant
        let details = "grpc-timeout \(GRPCTaskMapping.format(timeout)), \(GRPCTaskMapping.format(elapsed)) elapsed"
        if elapsed + .milliseconds(20) >= timeout {
            return RPCError(code: .deadlineExceeded, message: "RPC timed out before completing (\(details)).")
        }
        return RPCError(code: .cancelled, message: "The RPC was cancelled (\(details)).")
    }

    private func log(_ state: State, _ completion: Completion) {
        switch completion.result {
        case .rpc(let rpcError, let withResponse):
            log(
                state,
                response: withResponse ? makeResponse(state, rpcError: rpcError) : nil,
                error: rpcError.map(GRPCTaskMapping.error(for:)),
                endDate: completion.endDate
            )
        case .other(let error):
            log(state, response: nil, error: error, endDate: completion.endDate)
        }
    }

    private func log(_ state: State, response: HTTPURLResponse?, error: (any Error)?, endDate: Date) {
        logger.logTaskCompleted(
            taskId: taskId,
            request: request,
            response: response,
            error: error,
            requestBody: GRPCTaskMapping.body(fromJSONMessages: state.requestMessages),
            responseBody: GRPCTaskMapping.body(fromJSONMessages: state.responseMessages),
            metrics: NetworkLogger.Metrics(
                taskInterval: DateInterval(start: startDate, end: max(endDate, startDate)),
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
