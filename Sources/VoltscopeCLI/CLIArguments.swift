import Foundation
import VoltscopeCore

/// A command the tool accepts.
enum CLICommand: String, CaseIterable {
    case status
    case top
    case history
    case export
}

/// What `top` ranks apps by.
enum CLISort: String, CaseIterable {
    case energy
    case cpu
    case wakeups
}

/// Exit codes. The set is fixed by the tool's contract: 0 ok, 1 usage,
/// 2 database missing or unreadable, 3 database newer than this tool.
enum CLIExit {
    static let ok: Int32 = 0
    static let usage: Int32 = 1
    static let databaseUnavailable: Int32 = 2
    static let schemaNewer: Int32 = 3
}

/// A request the caller got wrong, or a refusal to run. Always printed with a
/// `voltscope:` prefix; the caller never sees a stack trace.
struct CLIError: Error {
    let exitCode: Int32
    let message: String

    init(_ exitCode: Int32, _ message: String) {
        self.exitCode = exitCode
        self.message = message
    }

    static func usage(_ message: String) -> CLIError {
        CLIError(CLIExit.usage, message)
    }
}

/// A `--since` window.
struct CLIDuration: Equatable {
    /// Window length in whole minutes.
    let minutes: Int
    /// The window as the caller wrote it, for echoing back.
    let text: String

    var seconds: TimeInterval { Double(minutes) * 60 }

    /// The bucket width the History window would use for this window.
    ///
    /// An exact match wins. Any other window takes the narrowest range whose own
    /// window is at least as wide, so a query is never coarser than the caller
    /// asked for; anything wider than a week keeps the week's six-hour buckets.
    var historyRange: HistoryRange {
        if let exact = HistoryRange.allCases.first(where: { $0.minutes == minutes }) { return exact }
        return HistoryRange.allCases.first(where: { $0.minutes > minutes }) ?? .d7
    }

    /// Accepts a whole number and one of `m`, `h`, or `d`, for example `30m`,
    /// `6h`, `1d`, `7d`, `30d`. The largest window is 365 days.
    static func parse(_ raw: String) -> CLIDuration? {
        guard let unit = raw.last else { return nil }
        let digits = String(raw.dropLast())
        guard let amount = Int(digits), amount > 0 else { return nil }
        let minutes: Int
        switch Character(unit.lowercased()) {
        case "m": minutes = amount
        case "h": minutes = amount * 60
        case "d": minutes = amount * 60 * 24
        default: return nil
        }
        guard minutes > 0, minutes <= 365 * 60 * 24 else { return nil }
        return CLIDuration(minutes: minutes, text: raw)
    }

    /// A window label for output: "24 hours" rather than "1440 minutes".
    var label: String {
        if minutes % (60 * 24) == 0 {
            let days = minutes / (60 * 24)
            return days == 1 ? "1 day" : "\(days) days"
        }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

/// One parsed command line.
struct CLIRequest {
    var command: CLICommand
    var wantsHelp = false
    var json = false
    var duration: CLIDuration?
    var sort = CLISort.energy
    var limit = 10
    var csv = false
    var outputFilePath: String?
    /// Canonical names of the options the caller actually passed, so a flag that
    /// belongs to another command is refused instead of quietly ignored.
    var givenOptions: Set<String> = []

    /// The window a query runs over, or a usage error where it is required.
    func requiredDuration() throws -> CLIDuration {
        guard let duration else {
            throw CLIError.usage("\(command.rawValue) needs --since <dur>, for example --since 1d.")
        }
        return duration
    }
}

extension CLIRequest {
    /// Options each command accepts. `--help` is accepted everywhere.
    private static let allowedOptions: [CLICommand: Set<String>] = [
        .status: ["--json"],
        .top: ["--json", "--since", "--by", "--limit"],
        .history: ["--json", "--since"],
        .export: ["--json", "--csv", "--since", "-o"]
    ]

    /// Parses a command line. Options may also be written `--since=1d`.
    static func parse(_ arguments: [String]) throws -> CLIRequest {
        guard let head = arguments.first else {
            throw CLIError.usage("No command given. Run `voltscope --help`.")
        }
        if ["-h", "--help", "help"].contains(head) {
            return CLIRequest(command: .status, wantsHelp: true)
        }
        guard let command = CLICommand(rawValue: head.lowercased()) else {
            throw CLIError.usage("Unknown command '\(head)'. Commands are: \(CLICommand.allCases.map { $0.rawValue }.joined(separator: ", ")).")
        }
        var request = CLIRequest(command: command)
        var index = 1
        while index < arguments.count {
            let token = arguments[index]
            let (rawFlag, inlineValue) = Self.split(token)
            let flag = (rawFlag == "--out" || rawFlag == "--output") ? "-o" : rawFlag
            func value() throws -> String {
                if let inlineValue { return inlineValue }
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw CLIError.usage("\(flag) needs a value.")
                }
                return arguments[index]
            }
            switch flag {
            case "--json":
                request.json = true
            case "--csv":
                request.csv = true
            case "--since":
                let raw = try value()
                guard let parsed = CLIDuration.parse(raw) else {
                    throw CLIError.usage("Cannot read --since '\(raw)'. Use a whole number with m, h, or d, for example 30m, 6h, 1d, 7d, 30d.")
                }
                request.duration = parsed
            case "--by":
                let raw = try value()
                guard let sort = CLISort(rawValue: raw.lowercased()) else {
                    throw CLIError.usage("Cannot read --by '\(raw)'. Choose \(CLISort.allCases.map { $0.rawValue }.joined(separator: ", ")).")
                }
                request.sort = sort
            case "--limit":
                let raw = try value()
                guard let limit = Int(raw), limit > 0 else {
                    throw CLIError.usage("Cannot read --limit '\(raw)'. Use a whole number of rows above zero.")
                }
                request.limit = limit
            case "-o":
                request.outputFilePath = try value()
            case "-h", "--help":
                request.wantsHelp = true
            default:
                throw CLIError.usage(token.hasPrefix("-")
                    ? "Unknown option '\(token)'. Run `voltscope --help`."
                    : "Unexpected argument '\(token)'. Run `voltscope --help`.")
            }
            request.givenOptions.insert(flag)
            index += 1
        }
        try request.validate()
        return request
    }

    private static func split(_ token: String) -> (flag: String, value: String?) {
        guard token.hasPrefix("--"), let separator = token.firstIndex(of: "=") else { return (token, nil) }
        return (String(token[..<separator]), String(token[token.index(after: separator)...]))
    }

    /// Per-command options, so a mistyped flag never quietly does nothing.
    private func validate() throws {
        let helpFlags: Set<String> = ["-h", "--help"]
        guard let allowed = Self.allowedOptions[command] else { return }
        if let unexpected = givenOptions.subtracting(allowed).subtracting(helpFlags).sorted().first {
            throw CLIError.usage("\(command.rawValue) does not take \(unexpected). Run `voltscope --help`.")
        }
        switch command {
        case .top, .history:
            try requiredDuration()
        default:
            break
        }
    }
}

/// The tool's own `--help`. Everything a caller needs is here: the window-to-bucket
/// table, `VOLTSCOPE_DB_PATH`, and the exit codes.
enum CLIHelp {
    static var text: String {
        """
        voltscope — read the battery and energy history Voltscope records

        Usage:
          voltscope status
          voltscope top --since <dur> [--by energy|cpu|wakeups] [--limit N]
          voltscope history --since <dur>
          voltscope export --csv [--since <dur>] [-o FILE]

        Commands:
          status    Live battery (charge, power, time remaining, health, cycles,
                    charging state) plus the last time Voltscope recorded a
                    sample and whether recording has stopped.
          top       Per-app ranking over a window. Energy is recorded CPU energy.
          history   Battery level, power, and app and hardware energy per bucket.
          export    The same CSV the app writes. Goes to standard output unless
                    -o FILE is given. CSV is the only format in this version.

        Options:
          --json            JSON on standard output. Top level is always
                            {"schema": 1, "generatedAt": …, "lastSampleAt": …|null, …}
                            and units are in the field names (energyJ, powerW,
                            cpuSeconds). export needs -o FILE with --json: the CSV
                            and the envelope cannot share standard output.
          --since <dur>     Window ending now. A whole number with m, h, or d:
                            30m, 1h, 6h, 1d, 7d, 30d. Required by top and history.
          --by <signal>     top ranking: energy (default), cpu, or wakeups.
          --limit N         How many top rows to print (default 10).
          --csv             export format, the default; accepted for clarity.
          -o, --output FILE Write the CSV to FILE instead of standard output.
          -h, --help        This text.

        Bucket widths match the History window for the same window, so the
        numbers agree with the app:
          30m -> 30 second buckets     6h -> 10 minute buckets     7d -> 6 hour buckets
          1h  -> 2 minute buckets      1d -> 30 minute buckets     30d -> 6 hour buckets
        A window between those sizes uses the narrowest range at least as wide.

        Energy is recorded CPU energy only. It is not a share of whole-device
        battery drain, and hardware buckets are separate measurements that are
        not guaranteed to sum to battery drain.

        Environment:
          VOLTSCOPE_DB_PATH   Read this history.sqlite file instead of
                              ~/Library/Application Support/Voltscope/history.sqlite.
                              For tests and for reading a copied database.

        This tool never writes the database. Exit codes: 0 ok, 1 usage error,
        2 database missing or unreadable, 3 database newer than this tool
        (update Voltscope).
        """
    }
}
