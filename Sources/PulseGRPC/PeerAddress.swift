/// The IP address and port in a `ClientContext` peer description.
struct PeerAddress: Equatable {
    var host: String
    var port: Int

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
