import Foundation
import GRPCCore

extension URLRequest {
    /// The request Pulse logs for an RPC: a `POST` to the method's URL, with the
    /// request metadata as headers and `Content-Type: application/json`.
    init(baseURL: URL?, context: ClientContext, metadata: Metadata) {
        self.init(url: URL(baseURL: baseURL, remotePeer: context.remotePeer, descriptor: context.descriptor))
        httpMethod = "POST"
        var headers = [String: String](metadata)
        headers["content-type"] = nil
        // The stored bodies are JSON. Pulse looks up `Content-Type` case-sensitively.
        headers["Content-Type"] = "application/json"
        allHTTPHeaderFields = headers
    }
}

extension URL {
    /// Builds `{grpc|grpcs}://{authority}{basePath}/{package.Service}/{Method}`.
    ///
    /// The scheme is `grpcs` when `baseURL` uses `https` or `grpcs`, `grpc` otherwise.
    /// Without a `baseURL`, the scheme is `grpc` and the authority is a best-effort reading of
    /// `remotePeer`, whose format isn't stable (see ``PeerAddress``):
    ///
    /// - `ipv4:127.0.0.1:31415` → `127.0.0.1:31415`
    /// - `ipv6:[::1]:443` → `[::1]:443`
    /// - otherwise the text before the first `:`, e.g. `in-process` or `unix`
    /// - `unknown` if that doesn't make a valid URL
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
        let transport = remotePeer.prefix { $0 != ":" }
        let authority = PeerAddress(peer: remotePeer)?.authority ?? (transport.isEmpty ? "unknown" : String(transport))
        self = URL(string: "grpc://\(authority)\(methodPath)") ?? URL(string: "grpc://unknown\(methodPath)")!
    }
}
