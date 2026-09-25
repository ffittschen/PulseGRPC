import GRPCCore

/// Records every request message before passing it on to the real writer.
struct RecordingWriter<Element: Sendable>: RPCWriterProtocol {
    let base: RPCWriter<Element>
    let recorder: RPCRecorder

    func write(_ element: Element) async throws {
        recorder.recordRequestMessage(element)
        try await base.write(element)
    }

    func write(contentsOf elements: some Sequence<Element>) async throws {
        let elements = Array(elements)
        for element in elements {
            recorder.recordRequestMessage(element)
        }
        try await base.write(contentsOf: elements)
    }
}
