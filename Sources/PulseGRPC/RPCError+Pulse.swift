import Foundation
import GRPCCore

extension RPCError {
    /// Maps an error raised while reading a response to an `RPCError`.
    init(mapping error: any Error) {
        if let error = error as? RPCError {
            self = error
        } else if let convertible = error as? any RPCErrorConvertible {
            self.init(convertible)
        } else if error is CancellationError {
            self.init(code: .cancelled, message: "The RPC was cancelled.")
        } else {
            self.init(code: .unknown, message: String(describing: error))
        }
    }

    /// Whether the error reports a cancellation rather than a status from the server:
    /// `CANCELLED`, or a `CancellationError` that grpc-swift-2 wrapped as `UNKNOWN`.
    var isCancellation: Bool {
        code == .cancelled || cause is CancellationError
    }
}

extension RPCError.Code {
    /// The canonical gRPC status name, e.g. `NOT_FOUND`.
    ///
    /// `description` is the Swift spelling (`notFound`), which other gRPC tools don't use.
    var canonicalName: String {
        switch self {
        case .cancelled: "CANCELLED"
        case .unknown: "UNKNOWN"
        case .invalidArgument: "INVALID_ARGUMENT"
        case .deadlineExceeded: "DEADLINE_EXCEEDED"
        case .notFound: "NOT_FOUND"
        case .alreadyExists: "ALREADY_EXISTS"
        case .permissionDenied: "PERMISSION_DENIED"
        case .resourceExhausted: "RESOURCE_EXHAUSTED"
        case .failedPrecondition: "FAILED_PRECONDITION"
        case .aborted: "ABORTED"
        case .outOfRange: "OUT_OF_RANGE"
        case .unimplemented: "UNIMPLEMENTED"
        case .internalError: "INTERNAL"
        case .unavailable: "UNAVAILABLE"
        case .dataLoss: "DATA_LOSS"
        case .unauthenticated: "UNAUTHENTICATED"
        default: "CODE_\(rawValue)"
        }
    }
}

extension NSError {
    /// The error domain used for non-OK gRPC statuses.
    static let grpcDomain = "gRPC"

    /// An error in the `gRPC` domain whose description reads `NOT_FOUND (5): message`.
    convenience init(_ rpcError: RPCError) {
        let code = rpcError.code.rawValue
        let name = rpcError.code.canonicalName
        let description = rpcError.message.isEmpty ? "\(name) (\(code))" : "\(name) (\(code)): \(rpcError.message)"
        self.init(domain: Self.grpcDomain, code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
