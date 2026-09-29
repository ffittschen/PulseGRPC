import Foundation
import SwiftProtobuf

extension String {
    /// Encodes a message as JSON. Protobuf messages use their canonical JSON
    /// mapping; anything else becomes a JSON string of `String(describing:)`.
    init(json message: some Sendable, options: JSONEncodingOptions) {
        if let message = message as? any SwiftProtobuf.Message,
           let json = try? message.jsonString(options: options) {
            self = json
        } else if let literal = try? JSONEncoder().encode(String(describing: message)) {
            self.init(decoding: literal, as: UTF8.self)
        } else {
            self = "\"\""
        }
    }
}

/// The messages of one side of a call as JSON, kept until the body reaches `sizeLimit`.
///
/// The store only keeps bodies smaller than its size limit, so a longer stream's messages
/// are dropped as soon as the body gets there, rather than buffered until the call ends.
struct JSONMessages: Sendable {
    let sizeLimit: Int
    private var messages: [String] = []
    /// The number of messages, including dropped ones.
    private(set) var count = 0
    /// The size of the body, including dropped messages.
    private(set) var size = 0

    init(sizeLimit: Int) {
        self.sizeLimit = sizeLimit
    }

    /// No messages or too large → `nil`, one message → the message, more → a JSON array.
    var data: Data? {
        guard size < sizeLimit else { return nil }
        switch messages.count {
        case 0: return nil
        case 1: return Data(messages[0].utf8)
        default: return Data("[\(messages.joined(separator: ","))]".utf8)
        }
    }

    mutating func append(_ json: String) {
        count += 1
        // A second message turns the body into an array: `[`, `]` and a `,` before each later message.
        size += json.utf8.count + (count == 1 ? 0 : count == 2 ? 3 : 1)
        if size < sizeLimit {
            messages.append(json)
        } else {
            messages.removeAll()
        }
    }
}
