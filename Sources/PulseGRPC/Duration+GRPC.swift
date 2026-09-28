extension Duration {
    /// Parses a `grpc-timeout` value such as `50m` (50 ms) or `2S` (2 seconds).
    init?(grpcTimeout value: String) {
        guard let unit = value.last, let amount = Int64(value.dropLast()) else { return nil }
        switch unit {
        case "H": self = .seconds(amount * 3600)
        case "M": self = .seconds(amount * 60)
        case "S": self = .seconds(amount)
        case "m": self = .milliseconds(amount)
        case "u": self = .microseconds(amount)
        case "n": self = .nanoseconds(amount)
        default: return nil
        }
    }

    /// Formats the duration for status messages, e.g. `160ms` or `2.5s`.
    var statusMessageDescription: String {
        let milliseconds = Int((self / .milliseconds(1)).rounded())
        guard milliseconds >= 1000 else { return "\(milliseconds)ms" }
        let tenths = (milliseconds + 50) / 100
        return tenths % 10 == 0 ? "\(tenths / 10)s" : "\(tenths / 10).\(tenths % 10)s"
    }
}
