import GRPCCore

/// Blocks callers until opened.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Echoes requests back.
struct EchoService: Echo_Echo.ServiceProtocol {
    /// Thrown by `Get` instead of replying, and by `Expand` after streaming all words.
    var failure: RPCError?
    /// Awaited by `Get` before replying, and by `Expand` after the first word.
    var gate: Gate?

    func get(
        request: ServerRequest<Echo_EchoRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Echo_EchoResponse> {
        if let gate {
            await gate.wait()
        }
        if let failure {
            throw failure
        }
        return ServerResponse(
            message: .with { $0.text = request.message.text },
            metadata: ["x-initial": "1"],
            trailingMetadata: ["x-trailing": "2"]
        )
    }

    /// Streams back one message per word.
    func expand(
        request: ServerRequest<Echo_EchoRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Echo_EchoResponse> {
        StreamingServerResponse { [gate, failure] writer in
            for (index, word) in request.message.text.split(separator: " ").enumerated() {
                try await writer.write(.with { $0.text = String(word) })
                if index == 0, let gate {
                    await gate.wait()
                }
            }
            if let failure {
                throw failure
            }
            return [:]
        }
    }

    /// Joins all received messages with spaces.
    func collect(
        request: StreamingServerRequest<Echo_EchoRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Echo_EchoResponse> {
        var words: [String] = []
        for try await message in request.messages {
            words.append(message.text)
        }
        return ServerResponse(message: .with { $0.text = words.joined(separator: " ") })
    }

    /// Echoes each message as it arrives.
    func update(
        request: StreamingServerRequest<Echo_EchoRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Echo_EchoResponse> {
        StreamingServerResponse { writer in
            for try await message in request.messages {
                try await writer.write(.with { $0.text = message.text })
            }
            return [:]
        }
    }
}
