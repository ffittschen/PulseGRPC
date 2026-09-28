import Foundation
import GRPCCore

extension HTTPURLResponse {
    /// The response Pulse logs for an RPC: status `200` over HTTP/2, with the initial and
    /// trailing metadata as headers, plus `grpc-status`, `grpc-message` (when non-empty)
    /// and `Content-Type: application/json`.
    ///
    /// - parameters:
    ///   - rpcError: The call's error, or `nil` if it succeeded. Its metadata are the trailers
    ///     of a failed call.
    convenience init?(url: URL, initialMetadata: Metadata, trailingMetadata: Metadata?, rpcError: RPCError?) {
        var headers = [String: String](initialMetadata)
            .merging([String: String](trailingMetadata ?? [:])) { "\($0), \($1)" }
        if let rpcError {
            headers.merge([String: String](rpcError.metadata)) { "\($0), \($1)" }
        }
        headers["content-type"] = nil
        headers["grpc-status"] = String(rpcError?.code.rawValue ?? 0)
        if let message = rpcError?.message, !message.isEmpty {
            headers["grpc-message"] = message
        }
        headers["Content-Type"] = [String: String].jsonContentType
        self.init(url: url, statusCode: 200, httpVersion: "HTTP/2", headerFields: headers)
    }
}
