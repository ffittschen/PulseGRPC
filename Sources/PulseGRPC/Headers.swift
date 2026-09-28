import Foundation
import GRPCCore

extension [String: String] {
    /// Describes the stored bodies (JSON), not the bytes on the wire.
    static let jsonContentType = "application/json"

    /// Converts metadata to headers. Repeated keys are joined with `", "`,
    /// binary values are base64-encoded, and HTTP/2 pseudo-headers (`:status`) are dropped.
    ///
    /// Keys are grouped case-insensitively, keeping the first spelling: metadata lookups
    /// and `URLRequest`/`HTTPURLResponse` treat `X-Id` and `x-id` as the same header.
    init(_ metadata: Metadata) {
        self.init()
        var spellings: [String: String] = [:] // lowercased key → first spelling
        for (key, value) in metadata where !key.hasPrefix(":") {
            let string: String = switch value {
            case .string(let string): string
            case .binary(let bytes): Data(bytes).base64EncodedString()
            }
            if let spelling = spellings[key.lowercased()] {
                self[spelling, default: ""] += ", " + string
            } else {
                spellings[key.lowercased()] = key
                self[key] = string
            }
        }
    }

    /// Merges two header dictionaries, joining the values of clashing keys with `", "`.
    /// Keys clash case-insensitively; the spelling in `self` wins.
    func mergingHeaders(_ other: [String: String]) -> [String: String] {
        var headers = self
        var spellings = Dictionary(keys.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for (key, value) in other {
            if let spelling = spellings[key.lowercased()] {
                headers[spelling, default: ""] += ", " + value
            } else {
                spellings[key.lowercased()] = key
                headers[key] = value
            }
        }
        return headers
    }

    /// The uncompressed size of `name: value` lines, a stand-in for header bytes on the wire
    /// (HTTP/2 compresses them with HPACK).
    var estimatedSize: Int64 {
        Int64(reduce(0) { $0 + $1.key.utf8.count + 2 + $1.value.utf8.count + 2 })
    }

    func removingContentType() -> [String: String] {
        filter { $0.key.lowercased() != "content-type" }
    }
}
