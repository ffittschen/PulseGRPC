/// The IP address and port in a `ClientContext.remotePeer` or `localPeer` description.
///
/// - Important: This relies on a format that isn't stable. grpc-swift-2 describes
///   `<transport>:<address>` as "a guideline for how implementations should format
///   descriptions; different implementations may not follow this format, so don't make
///   assumptions based on it." Only the documented `ipv4:` and `ipv6:` forms are recognized,
///   and anything else is `nil`. Every caller must fall back gracefully: show the raw
///   description or leave the field empty, but never drop, fail or delay the logged task
///   because a description couldn't be parsed.
struct PeerAddress: Equatable {
    var host: String
    var port: Int

    /// `host:port`, with an IPv6 host in brackets, for use as a URL authority.
    var authority: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// - `ipv4:127.0.0.1:31415` → (`127.0.0.1`, `31415`)
    /// - `ipv6:[::1]:443` → (`::1`, `443`)
    /// - anything else, e.g. `in-process:27182` or `unix:/tmp/socket` → `nil`
    init?(peer: String) {
        let parts = peer.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == "ipv4" || parts[0] == "ipv6",
              let separator = parts[1].lastIndex(of: ":"),
              let port = Int(parts[1][parts[1].index(after: separator)...]) else {
            return nil
        }
        var host = parts[1][..<separator]
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = host.dropFirst().dropLast()
        }
        guard !host.isEmpty else { return nil }
        self.host = String(host)
        self.port = port
    }
}
