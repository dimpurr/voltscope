import Foundation
import VoltscopeCore

/// The tool's behaviour: parse the command line, read the database without
/// writing it, print, and choose an exit code.
///
/// Arguments, environment, clock, and the battery reader are all parameters, so a
/// test can drive any command without starting a process or needing a battery.
enum VoltscopeCLI {
    /// How long a last-sample timestamp may sit idle before the tool says
    /// Voltscope has stopped recording. Battery samples arrive every 30 seconds.
    static let staleAfter: TimeInterval = 5 * 60

    static func run(
        arguments: [String],
        environment: [String: String],
        now: Date = Date(),
        batteryReader: @escaping @Sendable () -> BatterySnapshot? = { BatterySampler().sample() },
        output: OutputSink,
        errors: OutputSink
    ) async -> Int32 {
        let request: CLIRequest
        do {
            request = try CLIRequest.parse(arguments)
        } catch let error as CLIError {
            errors.write("voltscope: \(error.message)\n")
            return error.exitCode
        } catch {
            errors.write("voltscope: \(error.localizedDescription)\n")
            return CLIExit.usage
        }
        if request.wantsHelp {
            output.write(CLIHelp.text + "\n")
            return CLIExit.ok
        }
        do {
            return try await perform(request, environment: environment, now: now,
                                     batteryReader: batteryReader, output: output, errors: errors)
        } catch let error as CLIError {
            errors.write("voltscope: \(error.message)\n")
            return error.exitCode
        } catch let error as HistoryDatabaseOpenError {
            errors.write("voltscope: \(error.localizedDescription)\n")
            return error.cliExitCode
        } catch {
            errors.write("voltscope: \(error.localizedDescription)\n")
            return CLIExit.usage
        }
    }

    private static func perform(
        _ request: CLIRequest,
        environment: [String: String],
        now: Date,
        batteryReader: @escaping @Sendable () -> BatterySnapshot?,
        output: OutputSink,
        errors: OutputSink
    ) async throws -> Int32 {
        if request.command == .status {
            return try await status(request: request, environment: environment, now: now,
                                    batteryReader: batteryReader, output: output, errors: errors)
        }
        guard let url = DatabaseLocation.resolve(environment: environment) else {
            throw CLIError(CLIExit.databaseUnavailable,
                           "Cannot find the Application Support folder. Set VOLTSCOPE_DB_PATH to a history.sqlite file.")
        }
        let database = try HistoryDatabase.openReadOnly(url: url)
        let lastSampleAt = try await latestSample(in: database)
        switch request.command {
        case .status:
            return CLIExit.ok  // answered above; status needs no database to be opened this way
        case .top:
            try await top(request: request, database: database, url: url, lastSampleAt: lastSampleAt,
                          now: now, output: output)
        case .history:
            try await history(request: request, database: database, url: url, lastSampleAt: lastSampleAt,
                              now: now, output: output)
        case .export:
            try await export(request: request, database: database, url: url, lastSampleAt: lastSampleAt,
                             now: now, output: output, errors: errors)
        }
        return CLIExit.ok
    }

    // MARK: - status

    /// Prints the live battery first: it needs no database, and the last sample
    /// time is the part that might be missing.
    private static func status(
        request: CLIRequest,
        environment: [String: String],
        now: Date,
        batteryReader: @escaping @Sendable () -> BatterySnapshot?,
        output: OutputSink,
        errors: OutputSink
    ) async throws -> Int32 {
        let battery = batteryReader()
        var path: String?
        var lastSampleAt: Date?
        var databaseIssue: String?
        var exitCode = CLIExit.ok
        if let url = DatabaseLocation.resolve(environment: environment) {
            path = url.path
            do {
                let database = try HistoryDatabase.openReadOnly(url: url)
                lastSampleAt = try await latestSample(in: database)
            } catch let error as HistoryDatabaseOpenError {
                databaseIssue = error.localizedDescription
                exitCode = error.cliExitCode
            }
        } else {
            databaseIssue = "Cannot find the Application Support folder. Set VOLTSCOPE_DB_PATH to a history.sqlite file."
            exitCode = CLIExit.databaseUnavailable
        }

        let age = lastSampleAt.map { now.timeIntervalSince($0) }
        let stale = age.map { $0 > staleAfter } ?? true

        if request.json {
            var payload = CLIFormat.envelope(command: "status", generatedAt: now, lastSampleAt: lastSampleAt,
                                            databasePath: path)
            payload["battery"] = battery.map(batteryJSON) ?? .null
            if let age, let lastSampleAt {
                payload["recording"] = .object([
                    "lastSampleAt": .string(CLIFormat.isoString(lastSampleAt)),
                    "ageSeconds": .number((age * 10).rounded() / 10),
                    "staleAfterSeconds": .integer(Int64(staleAfter)),
                    "stale": .boolean(stale)
                ])
            } else {
                payload["recording"] = .null
            }
            if let databaseIssue { payload["databaseError"] = .string(databaseIssue) }
            output.write(try CLIFormat.encodeJSON(payload))
            return exitCode
        }

        output.write("Battery (read live)\n")
        if let battery {
            output.write(CLIFormat.row("Level", battery.levelPercent.map { String(format: "%.0f%%", $0) } ?? "-"))
            output.write(CLIFormat.row("Power", powerText(battery)))
            output.write(CLIFormat.row("Time remaining", battery.timeRemainingMin.map { CLIFormat.elapsed(Double($0) * 60) } ?? "-"))
            output.write(CLIFormat.row("Health", healthText(battery)))
            output.write(CLIFormat.row("Cycle count", battery.cycleCount.map(String.init) ?? "-"))
            output.write(CLIFormat.row("Charging", chargingText(battery)))
        } else {
            output.write("  No internal battery found on this machine.\n")
        }
        output.write("\n")
        output.write("Voltscope recording\n")
        output.write(CLIFormat.row("Database", path ?? "-"))
        if let lastSampleAt, let age {
            output.write(CLIFormat.row("Last sample", "\(CLIFormat.isoString(lastSampleAt)) (\(CLIFormat.elapsed(age)) ago)"))
            output.write(CLIFormat.row("Status", stale
                ? "not recording — the last sample is older than \(Int(staleAfter / 60)) minutes"
                : "recording"))
        } else {
            output.write(CLIFormat.row("Status", "no sample recorded\(databaseIssue == nil ? "" : " in this database")"))
        }
        if let databaseIssue {
            // The report above stays intact; the reason this run did not exit 0
            // goes to stderr, where a script will see it.
            errors.write("voltscope: \(databaseIssue)\n")
        }
        return exitCode
    }

    private static func batteryJSON(_ snapshot: BatterySnapshot) -> JSONValue {
        var value: [String: JSONValue] = [
            "levelPercent": snapshot.levelPercent.map { .number($0) } ?? .null,
            "powerW": snapshot.signedInstantaneousWatts.map { .number($0) } ?? .null,
            "timeRemainingMin": snapshot.timeRemainingMin.map { .integer(Int64($0)) } ?? .null,
            "healthPercent": healthPercent(snapshot).map { .number($0) } ?? .null,
            "cycleCount": snapshot.cycleCount.map { .integer(Int64($0)) } ?? .null,
            "isCharging": .boolean(snapshot.isCharging),
            "isACPlugged": .boolean(snapshot.isACPlugged)
        ]
        value["capacityMAh"] = snapshot.capacityMAh.map { .integer(Int64($0)) } ?? .null
        value["designMAh"] = snapshot.designMAh.map { .integer(Int64($0)) } ?? .null
        return .object(value)
    }

    /// Maximum capacity over design capacity, the same ratio System Settings
    /// shows as "Maximum Capacity".
    private static func healthPercent(_ snapshot: BatterySnapshot) -> Double? {
        guard let capacity = snapshot.capacityMAh, let design = snapshot.designMAh, design > 0 else { return nil }
        return Double(capacity) / Double(design) * 100
    }

    private static func powerText(_ snapshot: BatterySnapshot) -> String {
        guard let watts = snapshot.signedInstantaneousWatts else { return "-" }
        let direction = snapshot.isCharging ? "charging" : watts < 0 ? "discharging" : "idle"
        return "\(CLIFormat.power(watts)) (\(direction))"
    }

    private static func healthText(_ snapshot: BatterySnapshot) -> String {
        guard let percent = healthPercent(snapshot) else { return "-" }
        return String(format: "%.1f%% (%d mAh of %d mAh design)", percent,
                      snapshot.capacityMAh ?? 0, snapshot.designMAh ?? 0)
    }

    private static func chargingText(_ snapshot: BatterySnapshot) -> String {
        if snapshot.isCharging { return "charging on AC power" }
        return snapshot.isACPlugged ? "on AC power, not charging" : "on battery"
    }

    // MARK: - top

    private static func top(
        request: CLIRequest,
        database: HistoryDatabase,
        url: URL,
        lastSampleAt: Date?,
        now: Date,
        output: OutputSink
    ) async throws {
        let duration = try request.requiredDuration()
        let interval = DateInterval(start: now.addingTimeInterval(-duration.seconds), end: now)
        let totals = try await database.historyAppTotals(in: interval, range: duration.historyRange)
        let ranked = totals.sorted { lhs, rhs in
            let left = value(of: lhs, by: request.sort)
            let right = value(of: rhs, by: request.sort)
            return left == right ? lhs.id < rhs.id : left > right
        }
        let shown = Array(ranked.prefix(request.limit))

        if request.json {
            var payload = CLIFormat.envelope(command: "top", generatedAt: now, lastSampleAt: lastSampleAt,
                                            databasePath: url.path)
            payload["window"] = windowJSON(duration, interval: interval)
            payload["sortBy"] = .string(request.sort.rawValue)
            payload["limit"] = .integer(Int64(request.limit))
            payload["apps"] = .array(shown.map { total in
                .object([
                    "name": .string(total.processName),
                    "bundleIdentifier": total.bundleIdentifier.map { .string($0) } ?? .null,
                    "path": total.path.map { .string($0) } ?? .null,
                    "energyJ": .number(CLIFormat.joules(total.totalEnergyNJ)),
                    "cpuSeconds": .number(CLIFormat.cpuSeconds(total.totalCPUNS)),
                    "wakeups": .integer(total.totalWakeups),
                    "isSystem": .boolean(total.isSystem)
                ])
            })
            output.write(try CLIFormat.encodeJSON(payload))
            return
        }

        output.write("Top apps by \(request.sort.rawValue) — last \(duration.label), "
            + "\(duration.historyRange.rawValue) buckets of \(duration.historyRange.bucketLabel)\n")
        output.write("\(CLIFormat.energyCaveat)\n\n")
        guard !shown.isEmpty else {
            output.write("No recorded app samples in this window.\n")
            return
        }
        let nameWidth = shown.map { $0.processName.count }.max() ?? 1
        output.write("  \(CLIFormat.rightAligned("#", width: 2))  \("App".padding(toLength: nameWidth, withPad: " ", startingAt: 0))  "
            + "\(CLIFormat.rightAligned("Energy", width: 11))  \(CLIFormat.rightAligned("CPU", width: 11))  "
            + "\(CLIFormat.rightAligned("Wakeups", width: 9))\n")
        for (offset, total) in shown.enumerated() {
            output.write("  \(CLIFormat.rightAligned(String(offset + 1), width: 2))  "
                + "\(total.processName.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  "
                + "\(CLIFormat.rightAligned(CLIFormat.energy(CLIFormat.joules(total.totalEnergyNJ)), width: 11))  "
                + "\(CLIFormat.rightAligned(String(format: "%.1f s", CLIFormat.cpuSeconds(total.totalCPUNS)), width: 11))  "
                + "\(CLIFormat.rightAligned(String(total.totalWakeups), width: 9))\n")
        }
    }

    private static func value(of total: HistoryDatabase.AppUsageTotal, by sort: CLISort) -> Int64 {
        switch sort {
        case .energy: return total.totalEnergyNJ
        case .cpu: return total.totalCPUNS
        case .wakeups: return total.totalWakeups
        }
    }

    // MARK: - history

    private static func history(
        request: CLIRequest,
        database: HistoryDatabase,
        url: URL,
        lastSampleAt: Date?,
        now: Date,
        output: OutputSink
    ) async throws {
        let duration = try request.requiredDuration()
        let range = duration.historyRange
        let interval = DateInterval(start: now.addingTimeInterval(-duration.seconds), end: now)
        let points = try await database.historyEnergy(in: interval, range: range)
        let hardware = try await database.historyHardware(in: interval, range: range)
        let battery = try await database.batteryHistory(in: interval)

        let widthMS = Int64(range.bucketSeconds) * 1000
        let endMS = Int64(interval.end.timeIntervalSince1970 * 1000)
        var bucketStarts: [Int64] = []
        var cursor = (Int64(interval.start.timeIntervalSince1970 * 1000) / widthMS) * widthMS
        while cursor < endMS {
            bucketStarts.append(cursor)
            cursor += widthMS
        }

        var appEnergy: [Int64: Int64] = [:]
        for point in points {
            let bucket = Int64(point.date.timeIntervalSince1970 * 1000)
            appEnergy[bucket, default: 0] += point.energyNJ
        }
        var hardwareByBucket: [Int64: [String: Int64]] = [:]
        for summary in hardware {
            for spark in summary.sparkline {
                hardwareByBucket[Int64(spark.bucketStart.timeIntervalSince1970 * 1000), default: [:]][summary.bucketName] = spark.energyNJ
            }
        }

        var rows: [HistoryRow] = []
        rows.reserveCapacity(bucketStarts.count)
        for bucket in bucketStarts {
            let inBucket = battery.filter { $0.timestamp >= bucket && $0.timestamp < bucket + widthMS }
            let powers = inBucket.compactMap(\.signedInstantaneousWatts)
            let components = hardwareByBucket[bucket] ?? [:]
            rows.append(HistoryRow(
                startMS: bucket,
                levelPercent: inBucket.last?.levelPercent,
                powerW: powers.isEmpty ? nil : powers.reduce(0, +) / Double(powers.count),
                sampleCount: inBucket.count,
                appEnergyNJ: appEnergy[bucket] ?? 0,
                hardwareNanojoules: components
            ))
        }

        if request.json {
            var payload = CLIFormat.envelope(command: "history", generatedAt: now, lastSampleAt: lastSampleAt,
                                            databasePath: url.path)
            payload["window"] = windowJSON(duration, interval: interval)
            payload["bucketSeconds"] = .integer(Int64(range.bucketSeconds))
            payload["buckets"] = .array(rows.map { row in
                .object([
                    "start": .string(CLIFormat.isoString(Date(timeIntervalSince1970: Double(row.startMS) / 1000))),
                    "batteryPercent": row.levelPercent.map { .number($0) } ?? .null,
                    "powerW": row.powerW.map { .number($0) } ?? .null,
                    "batterySamples": .integer(Int64(row.sampleCount)),
                    "appEnergyJ": .number(CLIFormat.joules(row.appEnergyNJ)),
                    "hardwareEnergyJ": .number(CLIFormat.joules(row.hardwareNanojoules.values.reduce(0, +))),
                    "hardware": .object(row.hardwareNanojoules.keys.sorted().reduce(into: [String: JSONValue]()) { partial, name in
                        partial[name] = .number(CLIFormat.joules(row.hardwareNanojoules[name] ?? 0))
                    })
                ])
            })
            output.write(try CLIFormat.encodeJSON(payload))
            return
        }

        output.write("History — last \(duration.label), one row per \(range.bucketLabel) bucket\n")
        output.write("App energy is recorded CPU energy only. Hardware buckets are separate measurements.\n\n")
        output.write("  \("Start (UTC)".padding(toLength: 21, withPad: " ", startingAt: 0))  "
            + "\(CLIFormat.rightAligned("Level", width: 6))  \(CLIFormat.rightAligned("Power", width: 10))  "
            + "\(CLIFormat.rightAligned("Apps", width: 10))  \(CLIFormat.rightAligned("Hardware", width: 11))  "
            + "\(CLIFormat.rightAligned("Samples", width: 7))\n")
        for row in rows {
            let start = CLIFormat.isoString(Date(timeIntervalSince1970: Double(row.startMS) / 1000))
            output.write("  \(start.padding(toLength: 21, withPad: " ", startingAt: 0))  "
                + "\(CLIFormat.rightAligned(row.levelPercent.map { String(format: "%.0f%%", $0) } ?? "-", width: 6))  "
                + "\(CLIFormat.rightAligned(CLIFormat.power(row.powerW), width: 10))  "
                + "\(CLIFormat.rightAligned(CLIFormat.energy(CLIFormat.joules(row.appEnergyNJ)), width: 10))  "
                + "\(CLIFormat.rightAligned(CLIFormat.energy(CLIFormat.joules(row.hardwareNanojoules.values.reduce(0, +))), width: 11))  "
                + "\(CLIFormat.rightAligned(String(row.sampleCount), width: 7))\n")
        }
    }

    private struct HistoryRow {
        let startMS: Int64
        let levelPercent: Double?
        let powerW: Double?
        let sampleCount: Int
        let appEnergyNJ: Int64
        let hardwareNanojoules: [String: Int64]
    }

    // MARK: - export

    private static func export(
        request: CLIRequest,
        database: HistoryDatabase,
        url: URL,
        lastSampleAt: Date?,
        now: Date,
        output: OutputSink,
        errors: OutputSink
    ) async throws {
        // The CSV and the JSON envelope cannot share stdout, so --json has to
        // name a file instead of describing bytes that were never written.
        if request.json && request.outputFilePath == nil {
            throw CLIError.usage("export --json needs -o FILE, because the CSV would have nowhere to go. Without --json the CSV goes to stdout.")
        }
        let requested: DateInterval
        if let duration = request.duration {
            requested = DateInterval(start: now.addingTimeInterval(-duration.seconds), end: now)
        } else {
            // No --since: everything the store still keeps, which is what the
            // app's own export shows when the whole retention window is visible.
            requested = DateInterval(start: Date(timeIntervalSince1970: 0), end: now)
        }
        let interval = try await database.rawCSVInterval(in: requested)
        if interval.start > requested.start {
            errors.write("voltscope: raw samples are retained from "
                + "\(CLIFormat.isoString(interval.start)), so the export starts there.\n")
        }

        if let path = request.outputFilePath {
            try await CSVExport.write(database: database, interval: interval,
                                      to: URL(fileURLWithPath: path, relativeTo: nil))
        } else {
            try await CSVExport.write(database: database, interval: interval) { data in
                output.write(data)
            }
        }
        guard request.json else {
            return
        }
        var payload = CLIFormat.envelope(command: "export", generatedAt: now, lastSampleAt: lastSampleAt,
                                        databasePath: url.path)
        payload["format"] = .string("csv")
        payload["output"] = .string(request.outputFilePath ?? "")
        payload["interval"] = .object([
            "start": .string(CLIFormat.isoString(interval.start)),
            "end": .string(CLIFormat.isoString(interval.end))
        ])
        output.write(try CLIFormat.encodeJSON(payload))
    }

    // MARK: - shared

    private static func windowJSON(_ duration: CLIDuration, interval: DateInterval) -> JSONValue {
        .object([
            "since": .string(duration.text),
            "start": .string(CLIFormat.isoString(interval.start)),
            "end": .string(CLIFormat.isoString(interval.end)),
            "historyRange": .string(duration.historyRange.rawValue),
            "bucketSeconds": .integer(Int64(duration.historyRange.bucketSeconds))
        ])
    }

    /// When Voltscope last recorded a battery snapshot: the sample a reader can
    /// actually look at. Coverage rows are rolled up to bucket edges, so their
    /// timestamp can sit ahead of the samples inside the bucket and would make a
    /// stopped recorder look alive; they only stand in when there is no battery
    /// row at all.
    private static func latestSample(in database: HistoryDatabase) async throws -> Date? {
        if let milliseconds = try await database.latestBatterySnapshot()?.timestamp {
            return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }
        guard let milliseconds = try await database.latestCoverage()?.ts else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}

extension HistoryDatabaseOpenError {
    /// A newer database is the one case the caller can only fix by updating
    /// Voltscope, so it gets its own code.
    var cliExitCode: Int32 {
        switch self {
        case .migrationsUnrecognized: return CLIExit.schemaNewer
        case .fileMissing, .unreadable, .notAHistoryDatabase, .migrationsNotApplied: return CLIExit.databaseUnavailable
        }
    }
}

/// Where to read the history database from.
enum DatabaseLocation {
    /// `VOLTSCOPE_DB_PATH` when set, otherwise the app's own file. Resolving the
    /// path never creates a folder or a file.
    static func resolve(environment: [String: String]) -> URL? {
        if let raw = environment["VOLTSCOPE_DB_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return expanded(raw)
        }
        return try? AppPaths.historyDatabaseURL(create: false)
    }

    private static func expanded(_ raw: String) -> URL {
        guard raw.hasPrefix("~") else { return URL(fileURLWithPath: raw) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if raw == "~" { return URL(fileURLWithPath: home) }
        return URL(fileURLWithPath: home + raw.dropFirst())
    }
}
