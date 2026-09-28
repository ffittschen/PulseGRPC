import Foundation
import GRPCCore

extension URLRequest {
    /// The request Pulse logs for an RPC: a `POST` to the method's URL, with the
    /// request metadata as headers and `Content-Type: application/json`.
    init(baseURL: URL?, context: ClientContext, metadata: Metadata) {
        self.init(url: URL(baseURL: baseURL, remotePeer: context.remotePeer, descriptor: context.descriptor))
        httpMethod = "POST"
        var headers = [String: String](metadata).removingContentType()
        headers["Content-Type"] = [String: String].jsonContentType
        allHTTPHeaderFields = headers
    }
}

extension URL {
    /// Builds `{grpc|grpcs}://{authority}{basePath}/{package.Service}/{Method}`.
    ///
    /// The scheme is `grpcs` when `baseURL` uses `https` or `grpcs`, `grpc` otherwise.
    /// Without a `baseURL`, the authority is derived from `remotePeer` and the scheme is `grpc`.
    init(baseURL: URL?, remotePeer: String, descriptor: MethodDescriptor) {
        let methodPath = "/\(descriptor.service.fullyQualifiedService)/\(descriptor.method)"
        if let baseURL, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
            let isSecure = ["https", "grpcs"].contains(components.scheme?.lowercased())
            components.scheme = isSecure ? "grpcs" : "grpc"
            let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
            components.path = basePath + methodPath
            components.query = nil
            components.fragment = nil
            if let url = components.url {
                self = url
                return
            }
        }
        let authority = Self.authority(fromRemotePeer: remotePeer)
        self = URL(string: "grpc://\(authority)\(methodPath)") ?? URL(string: "grpc://unknown\(methodPath)")!
    }

    /// Extracts a URL authority from a `ClientContext.remotePeer` description.
    ///
    /// - `ipv4:127.0.0.1:31415` → `127.0.0.1:31415`
    /// - `ipv6:[::1]:443` → `[::1]:443`
    /// - `in-process:27182` → `in-process`
    /// - `unix:/tmp/socket` → `unix`
    private static func authority(fromRemotePeer remotePeer: String) -> String {
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
}
