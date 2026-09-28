import GRPCCore

/// Records response messages and trailers as the app reads them, and finishes
/// the recorder when the stream ends or fails.
struct RecordingBodyParts<Output: Sendable>: AsyncSequence, Sendable {
    typealias Element = StreamingClientResponse<Output>.Contents.BodyPart
    typealias Failure = any Error

    let base: RPCAsyncSequence<Element, any Error>
    let recorder: RPCRecorder

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), recorder: recorder)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: RPCAsyncSequence<Element, any Error>.AsyncIterator
        let recorder: RPCRecorder

        mutating func next() async throws -> Element? {
            do {
                guard let part = try await base.next() else {
                    recorder.finish(.endOfStream(isCancelled: Task.isCancelled))
                    return nil
                }
                switch part {
                case .message(let message):
                    recorder.recordResponseMessage(message)
                case .trailingMetadata(let metadata):
                    recorder.recordTrailingMetadata(metadata)
                }
                return part
            } catch {
                recorder.finish(.failed(RPCError(mapping: error), isCancelled: Task.isCancelled))
                throw error
            }
        }
    }
}
