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
}

private extension Metadata.Value {
    var headerValue: String {
        switch self {
        case .string(let string): string
        case .binary(let bytes): Data(bytes).base64EncodedString()
        }
    }
}
