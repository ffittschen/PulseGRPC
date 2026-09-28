import Foundation
import GRPCCore

extension [String: String] {
    /// Converts metadata to headers. Repeated keys are joined with `", "`,
    /// binary values are base64-encoded, and HTTP/2 pseudo-headers (`:status`) are dropped.
    ///
    /// Keys are lowercased, as the HTTP/2 transport sends them, so `X-Id` and `x-id`
    /// become one header.
    init(_ metadata: Metadata) {
        self.init(
            metadata.lazy
                .filter { !$0.key.hasPrefix(":") }
                .map { ($0.key.lowercased(), $0.value.headerValue) },
            uniquingKeysWith: { "\($0), \($1)" }
        )
    }

    /// The uncompressed size of `name: value` lines, a stand-in for header bytes on the wire
    /// (HTTP/2 compresses them with HPACK).
    var estimatedSize: Int64 {
        Int64(reduce(0) { $0 + $1.key.utf8.count + 2 + $1.value.utf8.count + 2 })
    }
}

private extension Metadata.Value {
    var headerValue: String {
        switch self {
        case .string(let string): string
        case .binary(let bytes): Data(bytes).base64EncodedString()
        }
    }
}
