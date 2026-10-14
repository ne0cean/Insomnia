import Foundation

/// A command from the `insomnia://` URL scheme, so scripts, Shortcuts and
/// other apps can drive a session (`scripts/insomnia-ctl.sh` wraps it):
///
///     insomnia://start                 the default preset
///     insomnia://start?hours=8         or ?seconds=28800
///     insomnia://extend?hours=1        or ?seconds=3600
///     insomnia://end
///     insomnia://pause                 freeze the countdown (sleep stays held)
///     insomnia://resume                let it run again
///     insomnia://status                writes the session state to the log
///
/// A duration is one of `seconds` or `hours`, positive and finite; giving
/// both, or neither for extend, is refused rather than guessed at.
enum URLCommand: Equatable, Sendable {
    static let scheme = "insomnia"

    /// nil: the default preset.
    case start(TimeInterval?)
    case extend(TimeInterval)
    case end
    case pause
    case resume
    case status

    /// Pure: the command `url` names, or nil for anything else.
    static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased()
        else { return nil }
        let items = parts.queryItems ?? []
        switch host {
        case "start":
            switch duration(items) {
            case .absent: return .start(nil)
            case let .value(seconds): return .start(seconds)
            case .invalid: return nil
            }
        case "extend":
            guard case let .value(seconds) = duration(items) else { return nil }
            return .extend(seconds)
        case "end":
            return .end
        case "pause":
            return .pause
        case "resume":
            return .resume
        case "status":
            return .status
        default:
            return nil
        }
    }

    private enum DurationQuery: Equatable {
        case absent
        case value(TimeInterval)
        case invalid
    }

    private static func duration(_ items: [URLQueryItem]) -> DurationQuery {
        let seconds = items.first { $0.name == "seconds" }
        let hours = items.first { $0.name == "hours" }
        switch (seconds, hours) {
        case (nil, nil):
            return .absent
        case (.some, .some):
            return .invalid
        case let (.some(item), nil):
            return positive(item.value, unit: 1)
        case let (nil, .some(item)):
            return positive(item.value, unit: 3600)
        }
    }

    /// The longest duration a URL may ask for. Anything past it is refused
    /// rather than clamped: `Int(…)` of a huge Double traps, and a URL any
    /// page can open must not be able to crash the app.
    static let maxDuration: TimeInterval = 365 * 24 * 3600

    private static func positive(_ text: String?, unit: TimeInterval) -> DurationQuery {
        guard let text, let number = Double(text), number.isFinite, number > 0 else { return .invalid }
        let seconds = number * unit
        guard seconds.isFinite, seconds <= maxDuration else { return .invalid }
        return .value(seconds)
    }
}
