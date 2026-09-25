import Foundation
import GRPCCore
import SwiftProtobuf

/// Pure functions that translate gRPC concepts into the HTTP-shaped values
/// Pulse stores for a network task.
enum GRPCTaskMapping {
    /// Describes the stored bodies (JSON), not the bytes on the wire.
    static let contentType = "application/json"

    /// The error domain used for non-OK gRPC statuses.
    static let errorDomain = "gRPC"

    // MARK: URL

    /// Builds `{grpc|grpcs}://{authority}{basePath}/{package.Service}/{Method}`.
    ///
    /// The scheme is `grpcs` when `baseURL` uses `https` or `grpcs`, `grpc` otherwise.
    /// Without a `baseURL`, the authority is derived from `remotePeer` and the scheme is `grpc`.
    static func url(baseURL: URL?, remotePeer: String, descriptor: MethodDescriptor) -> URL {
        let methodPath = "/\(descriptor.service.fullyQualifiedService)/\(descriptor.method)"
        if let baseURL, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
            let isSecure = ["https", "grpcs"].contains(components.scheme?.lowercased())
            components.scheme = isSecure ? "grpcs" : "grpc"
            let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
            components.path = basePath + methodPath
            components.query = nil
            components.fragment = nil
            if let url = components.url {
                return url
            }
        }
        let authority = self.authority(fromRemotePeer: remotePeer)
        return URL(string: "grpc://\(authority)\(methodPath)") ?? URL(string: "grpc://unknown\(methodPath)")!
    }

    /// Extracts a URL authority from a `ClientContext.remotePeer` description.
    ///
    /// - `ipv4:127.0.0.1:31415` → `127.0.0.1:31415`
    /// - `ipv6:[::1]:443` → `[::1]:443`
    /// - `in-process:27182` → `in-process`
    /// - `unix:/tmp/socket` → `unix`
    static func authority(fromRemotePeer remotePeer: String) -> String {
        guard let separator = remotePeer.firstIndex(of: ":") else {
            return remotePeer.isEmpty ? "unknown" : remotePeer
        }
        let transport = remotePeer[..<separator]
        let address = remotePeer[remotePeer.index(after: separator)...]
        switch transport {
        case "ipv4", "ipv6":
            return address.isEmpty ? "unknown" : String(address)
        default:
            return transport.isEmpty ? "unknown" : String(transport)
        }
    }

    // MARK: Request

    static func makeRequest(baseURL: URL?, context: ClientContext, metadata: Metadata) -> URLRequest {
        var request = URLRequest(url: url(baseURL: baseURL, remotePeer: context.remotePeer, descriptor: context.descriptor))
        request.httpMethod = "POST"
        var headers = removingContentType(from: headers(from: metadata))
        headers["Content-Type"] = contentType
        request.allHTTPHeaderFields = headers
        return request
    }

    // MARK: Headers

    /// Converts metadata to headers. Repeated keys are joined with `", "`,
    /// binary values are base64-encoded.
    static func headers(from metadata: Metadata) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in metadata {
            let string: String = switch value {
            case .string(let string): string
            case .binary(let bytes): Data(bytes).base64EncodedString()
            }
            if let existing = headers[key] {
                headers[key] = existing + ", " + string
            } else {
                headers[key] = string
            }
        }
        return headers
    }

    /// Merges two header dictionaries, joining the values of clashing keys with `", "`.
    static func merging(_ lhs: [String: String], _ rhs: [String: String]) -> [String: String] {
        lhs.merging(rhs) { "\($0), \($1)" }
    }

    static func removingContentType(from headers: [String: String]) -> [String: String] {
        headers.filter { $0.key.lowercased() != "content-type" }
    }

    // MARK: Bodies

    /// Encodes a message as JSON. Protobuf messages use their canonical JSON
    /// mapping; anything else becomes a JSON string of `String(describing:)`.
    static func encode(_ message: some Sendable, options: JSONEncodingOptions) -> String {
        if let message = message as? any SwiftProtobuf.Message,
           let json = try? message.jsonString(options: options) {
            return json
        }
        return jsonStringLiteral(String(describing: message))
    }

    /// No messages → `nil`, one message → the message, more → a JSON array.
    static func body(fromJSONMessages messages: [String]) -> Data? {
        switch messages.count {
        case 0: nil
        case 1: Data(messages[0].utf8)
        default: Data("[\(messages.joined(separator: ","))]".utf8)
        }
    }

    private static func jsonStringLiteral(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string), let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }

    // MARK: Timeouts

    /// Parses a `grpc-timeout` value such as `50m` (50 ms) or `2S` (2 seconds).
    static func timeout(fromHeaderValue value: String) -> Duration? {
        guard let unit = value.last, let amount = Int64(value.dropLast()) else { return nil }
        switch unit {
        case "H": return .seconds(amount * 3600)
        case "M": return .seconds(amount * 60)
        case "S": return .seconds(amount)
        case "m": return .milliseconds(amount)
        case "u": return .microseconds(amount)
        case "n": return .nanoseconds(amount)
        default: return nil
        }
    }

    // MARK: Status & Errors

    /// The canonical gRPC status name, e.g. `NOT_FOUND` for `5`.
    static func statusName(forCode code: Int) -> String {
        switch code {
        case 0: "OK"
        case 1: "CANCELLED"
        case 2: "UNKNOWN"
        case 3: "INVALID_ARGUMENT"
        case 4: "DEADLINE_EXCEEDED"
        case 5: "NOT_FOUND"
        case 6: "ALREADY_EXISTS"
        case 7: "PERMISSION_DENIED"
        case 8: "RESOURCE_EXHAUSTED"
        case 9: "FAILED_PRECONDITION"
        case 10: "ABORTED"
        case 11: "OUT_OF_RANGE"
        case 12: "UNIMPLEMENTED"
        case 13: "INTERNAL"
        case 14: "UNAVAILABLE"
        case 15: "DATA_LOSS"
        case 16: "UNAUTHENTICATED"
        default: "CODE_\(code)"
        }
    }

    /// An `NSError` in the `gRPC` domain whose description reads `NOT_FOUND (5): message`.
    static func error(for rpcError: RPCError) -> NSError {
        let code = rpcError.code.rawValue
        let name = statusName(forCode: code)
        let description = rpcError.message.isEmpty ? "\(name) (\(code))" : "\(name) (\(code)): \(rpcError.message)"
        return NSError(domain: errorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }

    /// Maps an error raised while reading a response to an `RPCError`.
    static func rpcError(from error: any Error) -> RPCError {
        if let error = error as? RPCError {
            return error
        }
        if let convertible = error as? any RPCErrorConvertible {
            return RPCError(convertible)
        }
        if error is CancellationError {
            return RPCError(code: .cancelled, message: "The RPC was cancelled.")
        }
        return RPCError(code: .unknown, message: String(describing: error))
    }
}
