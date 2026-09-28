import Foundation

extension Duration {
    /// Parses a `grpc-timeout` value such as `50m` (50 ms) or `2S` (2 seconds).
    ///
    /// Follows the gRPC spec (`PROTOCOL-HTTP2.md`, "Timeout"): 1 to 8 ASCII digits, then one of
    /// `H`, `M`, `S`, `m`, `u` or `n`. Anything else is `nil`. The 8-digit limit also keeps
    /// hours and minutes from overflowing.
    ///
    /// This deliberately differs from grpc-swift's internal `Timeout(decoding:)`, which accepts at
    /// most 8 characters. That rejects the 8-digit values grpc-swift itself sends, e.g.
    /// `29999986u` for a 30 s timeout.
    init?(grpcTimeout value: String) {
        let digits = value.dropLast()
        guard let unit = value.last,
              (1...8).contains(digits.count),
              digits.allSatisfy({ ("0"..."9").contains($0) }),
              let amount = Int64(digits) else {
            return nil
        }
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
}

extension FormatStyle where Self == Duration.UnitsFormatStyle {
    /// Durations in status messages, e.g. `160ms` or `2.5s`: a single unit, seconds or
    /// milliseconds, with at most one fractional digit. The locale is fixed because the
    /// messages are English.
    static var statusMessage: Self {
        .units(allowed: [.seconds, .milliseconds], width: .narrow, maximumUnitCount: 1, fractionalPart: .init(lengthLimits: 0...1))
            .locale(Locale(identifier: "en_US_POSIX"))
    }
}
