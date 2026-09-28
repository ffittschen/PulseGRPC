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

extension Data {
    /// No messages → `nil`, one message → the message, more → a JSON array.
    init?(jsonMessages messages: [String]) {
        switch messages.count {
        case 0: return nil
        case 1: self.init(messages[0].utf8)
        default: self.init("[\(messages.joined(separator: ","))]".utf8)
        }
    }
}
