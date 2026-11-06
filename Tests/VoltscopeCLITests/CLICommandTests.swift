import Foundation
import GRDB
import XCTest
@testable import VoltscopeCore
@testable import voltscope_cli

/// End-to-end runs of the four commands against a temporary history file. The
/// numbers must equal what the History window's own queries compute, the CSV must
/// equal what the app writes, and the file must come out untouched.
final class CLICommandTests: XCTestCase {
    private var removals: [URL] = []

    override func tearDownWithError() throws {
        for directory in removals {
            try? FileManager.default.removeItem(at: directory)
        }
        removals.removeAll()
    }

    private func own(_ url: URL) {
        removals.append(url.deletingLastPathComponent())
    }

    private struct Run {
        let code: Int32
        let output: String
        let errors: String
    }

    private func run(_ arguments: [String], environment: [String: String], now: Date,
                     battery: BatterySnapshot? = nil) async -> Run {
        let output = OutputSink()
        let errors = OutputSink()
        let code = await VoltscopeCLI.run(arguments: arguments, environment: environment, now: now,
                                         batteryReader: { battery }, output: output, errors: errors)
        return Run(code: code, output: output.capturedText, errors: errors.capturedText)
    }

    private func milliseconds(_ date: Date?) -> Int64 {
        Int64((date?.timeIntervalSince1970 ?? 0) * 1000)
    }

    // MARK: - top

    func testTopForOneDayEqualsTheHistoryWindowNumbers() async throws {
        let fixture = try await CLIFixture.make(latestOffsetSeconds: nil)
        own(fixture.url)
        let interval = DateInterval(start: fixture.now.addingTimeInterval(-86_400), end: fixture.now)
        let expected = try await fixture.database.historyAppBreakdown(in: interval, range: .h24)
        XCTAssertEqual(expected.count, 3)

        let result = await run(["top", "--since", "1d", "--json"], environment: fixture.environment, now: fixture.now)
        XCTAssertEqual(result.code, CLIExit.ok, result.errors)
        let json = decodedJSON(result.output)
        assertEnvelope(json, command: "top", now: fixture.now)
        XCTAssertEqual(decodedString(json["sortBy"]), "energy")
        XCTAssertEqual(decodedInt(json["limit"]), 10)

        let window = json["window"] as? [String: Any] ?? [:]
        XCTAssertEqual(decodedString(window["historyRange"]), "24H", "one day must use the interface's 24H bucket rules")
        XCTAssertEqual(decodedInt(window["bucketSeconds"]), 1_800)
        XCTAssertEqual(milliseconds(decodedDate(window["start"])), milliseconds(interval.start))
        XCTAssertEqual(milliseconds(decodedDate(window["end"])), milliseconds(interval.end))

        let apps = decodedArray(json["apps"])
        XCTAssertEqual(apps.map { decodedString($0["name"]) }, expected.map(\.processName))
        for (row, entry) in zip(apps, expected) {
            assertApprox(decodedDouble(row["energyJ"]), Double(entry.totalEnergyNJ) / 1_000_000_000, 1e-9,
                           "energy for \(entry.processName) must match the History query")
            assertApprox(decodedDouble(row["cpuSeconds"]), Double(entry.totalCPUNS) / 1_000_000_000, 1e-9,
                           "CPU time for \(entry.processName) must match the History query")
        }

        // Hand-computed anchor: the window holds exactly the 24 hourly samples,
        // so the two older hours are excluded. Reading an hour or minute index as
        // seconds would move the window by a factor of 60 or 3600 and change this.
        let alpha = try XCTUnwrap(apps.first { decodedString($0["name"]) == "Alpha" })
        assertApprox(decodedDouble(alpha["energyJ"]), Double(24 * 900) / 1_000_000_000, 1e-12)
        assertApprox(decodedDouble(alpha["cpuSeconds"]), Double(24) * 0.9, 1e-9)
        XCTAssertEqual(decodedInt(alpha["wakeups"]), 24 * 9)
        let agent = try XCTUnwrap(apps.first { decodedString($0["name"]) == "ExampleAgent" })
        XCTAssertEqual(decodedString(agent["bundleIdentifier"]), "com.apple.example-agent")
        XCTAssertEqual(agent["isSystem"] as? Bool, true)
    }

    func testTopRanksByCPURowsAndWakeupsDifferentlyFromEnergy() async throws {
        let fixture = try await CLIFixture.make(hours: 6, latestOffsetSeconds: nil)
        own(fixture.url)

        let byEnergy = decodedArray(decodedJSON((await run(["top", "--since", "6h", "--json"],
            environment: fixture.environment, now: fixture.now)).output)["apps"])
        XCTAssertEqual(byEnergy.map { decodedString($0["name"]) }, ["Alpha", "ExampleAgent", "Beta"])

        let byCPU = decodedJSON((await run(["top", "--since", "6h", "--by", "cpu", "--json"],
            environment: fixture.environment, now: fixture.now)).output)
        XCTAssertEqual(decodedString(byCPU["sortBy"]), "cpu")
        XCTAssertEqual(decodedArray(byCPU["apps"]).map { decodedString($0["name"]) }, ["Beta", "Alpha", "ExampleAgent"])

        let byWakeups = decodedJSON((await run(["top", "--since", "6h", "--by", "wakeups", "--json"],
            environment: fixture.environment, now: fixture.now)).output)
        XCTAssertEqual(decodedString(byWakeups["sortBy"]), "wakeups")
        let wakeupApps = decodedArray(byWakeups["apps"])
        XCTAssertEqual(wakeupApps.map { decodedString($0["name"]) }, ["Beta", "Alpha", "ExampleAgent"])
        XCTAssertEqual(decodedInt(wakeupApps.first?["wakeups"]), 6 * 40)
    }

    func testTopLimitAndTextOutput() async throws {
        let fixture = try await CLIFixture.make(hours: 3)
        own(fixture.url)

        let limited = await run(["top", "--since", "6h", "--limit", "1", "--json"],
                               environment: fixture.environment, now: fixture.now)
        XCTAssertEqual(decodedArray(decodedJSON(limited.output)["apps"]).count, 1)

        let text = await run(["top", "--since", "6h"], environment: fixture.environment, now: fixture.now)
        XCTAssertEqual(text.code, CLIExit.ok)
        XCTAssertTrue(text.output.contains("Alpha"))
        XCTAssertTrue(text.output.contains("Beta"))
        XCTAssertTrue(text.output.contains("recorded CPU energy only"),
                      "the caveat must be printed, not only in --help")
    }

    func testTopWithNoSamplesInWindow() async throws {
        let fixture = try await CLIFixture.make(hours: 3, latestOffsetSeconds: nil)
        own(fixture.url)

        let json = await run(["top", "--since", "30m", "--json"], environment: fixture.environment, now: fixture.now)
        XCTAssertEqual(json.code, CLIExit.ok)
        XCTAssertTrue(decodedArray(decodedJSON(json.output)["apps"]).isEmpty)

        let text = await run(["top", "--since", "30m"], environment: fixture.environment, now: fixture.now)
        XCTAssertTrue(text.output.contains("No recorded app samples"))
    }

    // MARK: - history

    func testHistoryRowsMatchTheCoreQueries() async throws {
        let fixture = try await CLIFixture.make(latestOffsetSeconds: nil)
        own(fixture.url)
        let interval = DateInterval(start: fixture.now.addingTimeInterval(-86_400), end: fixture.now)
        let points = try await fixture.database.historyEnergy(in: interval, range: .h24)
        let hardware = try await fixture.database.historyHardware(in: interval, range: .h24)

        let result = await run(["history", "--since", "1d", "--json"], environment: fixture.environment, now: fixture.now)
        XCTAssertEqual(result.code, CLIExit.ok, result.errors)
        let json = decodedJSON(result.output)
        assertEnvelope(json, command: "history", now: fixture.now)
        XCTAssertEqual(decodedInt(json["bucketSeconds"]), 1_800)

        let rows = decodedArray(json["buckets"])
        let grid = expectedBucketStarts(start: interval.start, end: interval.end, bucketSeconds: 1_800)
        XCTAssertEqual(rows.map { milliseconds(decodedDate($0["start"])) / 1_000 }, grid,
                       "one row per bucket across the window, gaps included")
        XCTAssertTrue((86_400 / 1_800 ... 86_400 / 1_800 + 1).contains(grid.count),
                      "a day of 30 minute buckets, plus the bucket the window opens in: \(grid.count)")
        for row in rows {
            XCTAssertEqual(milliseconds(decodedDate(row["start"])) % 1_800_000, 0,
                           "buckets must be aligned to the same epoch edges as the queries")
        }

        var expectedAppEnergy: [Int64: Double] = [:]
        for point in points {
            expectedAppEnergy[milliseconds(point.date), default: 0] += Double(point.energyNJ) / 1_000_000_000
        }
        var expectedHardware: [Int64: Double] = [:]
        for summary in hardware {
            for spark in summary.sparkline {
                expectedHardware[milliseconds(spark.bucketStart), default: 0] += Double(spark.energyNJ) / 1_000_000_000
            }
        }
        var reportedBuckets: Set<Int64> = []
        for row in rows {
            let bucket = milliseconds(decodedDate(row["start"]))
            reportedBuckets.insert(bucket)
            assertApprox(decodedDouble(row["appEnergyJ"]), expectedAppEnergy[bucket] ?? 0, 1e-9,
                           "app energy for \(decodedString(row["start"]) ?? "?") must match the chart query")
            assertApprox(decodedDouble(row["hardwareEnergyJ"]), expectedHardware[bucket] ?? 0, 1e-9)
        }
        XCTAssertTrue(Set(expectedAppEnergy.keys).isSubset(of: reportedBuckets),
                      "every bucket the chart query returns must appear in the tool's grid")

        // The hour five rows back: two battery snapshots inside one bucket, so the
        // level is the newest one and the power is their mean.
        let hourFive = Int64(fixture.now.timeIntervalSince1970) - 5 * 3_600
        let bucket = (hourFive / 1_800) * 1_800
        let row = try XCTUnwrap(rows.first { milliseconds(decodedDate($0["start"])) == bucket * 1_000 })
        assertApprox(decodedDouble(row["batteryPercent"]), 95, 0.0001)
        assertApprox(decodedDouble(row["powerW"]), -3.6, 0.0001,
                       "power is voltage times signed amperage, so discharging is negative")
        XCTAssertEqual(decodedInt(row["batterySamples"]), 2)
        let hardwareCells = row["hardware"] as? [String: Any] ?? [:]
        assertApprox(decodedDouble(hardwareCells["CPU"]), Double(5_000) / 1_000_000_000, 1e-12)
        assertApprox(decodedDouble(hardwareCells["GPU"]), Double(1_000) / 1_000_000_000, 1e-12)
    }

    func testHistoryKeepsGapsVisibleInsteadOfDroppingThem() async throws {
        let fixture = try await CLIFixture.make(hours: 3, latestOffsetSeconds: nil)
        own(fixture.url)

        let json = decodedJSON((await run(["history", "--since", "1h", "--json"],
            environment: fixture.environment, now: fixture.now)).output)
        let rows = decodedArray(json["buckets"])
        // An hour of history is the app's 1H chart, which draws 2 minute buckets.
        XCTAssertEqual(decodedInt(json["bucketSeconds"]), 120)
        let grid = expectedBucketStarts(start: fixture.now.addingTimeInterval(-3_600), end: fixture.now,
                                        bucketSeconds: 120)
        XCTAssertEqual(rows.count, grid.count, "one row per 2 minute bucket across the hour")
        XCTAssertTrue(rows.contains { ($0["batteryPercent"] is NSNull) && decodedDouble($0["appEnergyJ"]) == 0 },
                      "a bucket with nothing recorded is reported as empty, not omitted")

        let text = await run(["history", "--since", "1h"], environment: fixture.environment, now: fixture.now)
        XCTAssertEqual(text.code, CLIExit.ok, text.errors)
        XCTAssertEqual(text.output.split(separator: "\n").filter { $0.hasPrefix("  2") }.count, grid.count,
                       "every bucket gets a line")
        XCTAssertTrue(text.output.contains("recorded CPU energy only"))
    }

    // MARK: - status

    func testStatusReportsLiveBatteryAndThatRecordingIsAlive() async throws {
        let fixture = try await CLIFixture.make(hours: 3)
        own(fixture.url)
        let now = fixture.now
        let result = await run(["status", "--json"], environment: fixture.environment, now: now,
                              battery: CLIFixture.liveBattery(at: now))
        XCTAssertEqual(result.code, CLIExit.ok, result.errors)
        let json = decodedJSON(result.output)
        assertEnvelope(json, command: "status", now: now)

        let battery = json["battery"] as? [String: Any] ?? [:]
        assertApprox(decodedDouble(battery["levelPercent"]), 84, 0.0001)
        assertApprox(decodedDouble(battery["powerW"]), Double(12_400 * -520) / 1_000_000, 1e-9,
                       "power must be signed: negative while discharging")
        assertApprox(decodedDouble(battery["healthPercent"]), 96, 0.0001,
                       "health is maximum capacity over design capacity")
        XCTAssertEqual(decodedInt(battery["cycleCount"]), 143)
        XCTAssertEqual(decodedInt(battery["timeRemainingMin"]), 195)
        XCTAssertEqual(battery["isCharging"] as? Bool, false)

        let recording = json["recording"] as? [String: Any] ?? [:]
        XCTAssertEqual(recording["stale"] as? Bool, false, "a sample from a minute ago is still recording")
        XCTAssertEqual(decodedInt(recording["staleAfterSeconds"]), 300)
        assertApprox(decodedDate(json["lastSampleAt"])?.timeIntervalSince1970,
                     now.timeIntervalSince1970 - 60, 2, "the newest sample is the tick from a minute ago")
    }

    func testStatusSaysWhenRecordingHasStopped() async throws {
        let fixture = try await CLIFixture.make(hours: 3, latestOffsetSeconds: 900)
        own(fixture.url)
        let text = await run(["status"], environment: fixture.environment, now: fixture.now,
                             battery: CLIFixture.liveBattery(at: fixture.now))
        XCTAssertEqual(text.code, CLIExit.ok)
        XCTAssertTrue(text.output.contains("not recording"), text.output)
        XCTAssertTrue(text.output.contains("84%"), text.output)

        let json = decodedJSON((await run(["status", "--json"], environment: fixture.environment, now: fixture.now,
                                          battery: CLIFixture.liveBattery(at: fixture.now))).output)
        XCTAssertEqual((json["recording"] as? [String: Any])?["stale"] as? Bool, true)
    }

    func testStatusStillReadsTheBatteryWhenTheDatabaseIsMissingAndExitsTwo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voltscope-cli-absent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removals.append(directory)
        let environment = ["VOLTSCOPE_DB_PATH": directory.appendingPathComponent("history.sqlite").path]

        let text = await run(["status"], environment: environment, now: Date(),
                             battery: CLIFixture.liveBattery(at: Date()))
        XCTAssertEqual(text.code, CLIExit.databaseUnavailable)
        XCTAssertTrue(text.output.contains("84%"), "the live battery needs no database:\n\(text.output)")
        XCTAssertTrue(text.errors.contains("No Voltscope history database"), text.errors)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.sqlite").path),
                       "a missing database must not be created by reading")

        let json = decodedJSON((await run(["status", "--json"], environment: environment, now: Date(),
                                          battery: CLIFixture.liveBattery(at: Date()))).output)
        XCTAssertTrue(json["lastSampleAt"] is NSNull)
        XCTAssertNotNil(json["battery"])
    }

    func testStatusRefusesADatabaseFromANewerVoltscopeWithExitThree() async throws {
        let fixture = try await CLIFixture.make(hours: 2)
        own(fixture.url)
        try await fixture.database.dbPool.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: ["v2_someday"])
        }
        let result = await run(["status"], environment: fixture.environment, now: fixture.now,
                              battery: CLIFixture.liveBattery(at: fixture.now))
        XCTAssertEqual(result.code, CLIExit.schemaNewer)
        XCTAssertTrue(result.errors.contains("newer"), result.errors)
    }

    // MARK: - export

    /// The bytes the app writes: `CSVExport` in Core, called with the same window.
    private func expectedCSV(_ samples: [HistoryDatabase.CSVSample]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var text = HistoryDatabase.CSVSample.columnNames.joined(separator: ",") + "\n"
        for sample in samples {
            let iso = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(sample.timestampMS) / 1000))
            text += sample.csvLine(iso8601: iso)
        }
        return text
    }

    func testExportFileEqualsTheAppsCSVBytes() async throws {
        let fixture = try await CLIFixture.make(hours: 3)
        own(fixture.url)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voltscope-cli-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removals.append(directory)
        let destination = directory.appendingPathComponent("energy.csv")
        let interval = DateInterval(start: fixture.now.addingTimeInterval(-3_600), end: fixture.now)
        let samples = try await fixture.database.historySamplesForCSV(in: interval)
        XCTAssertFalse(samples.isEmpty)

        let result = await run(["export", "--csv", "--since", "1h", "-o", destination.path],
                              environment: fixture.environment, now: fixture.now)
        XCTAssertEqual(result.code, CLIExit.ok, result.errors)
        XCTAssertEqual(result.errors, "", "nothing is retained away inside one hour:\n\(result.errors)")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), expectedCSV(samples))
    }

    func testExportToStandardOutputEqualsTheAppsBytes() async throws {
        let fixture = try await CLIFixture.make(hours: 3)
        own(fixture.url)
        let piped = await run(["export", "--csv", "--since", "6h"], environment: fixture.environment, now: fixture.now)
        XCTAssertEqual(piped.code, CLIExit.ok, piped.errors)
        let interval = DateInterval(start: fixture.now.addingTimeInterval(-6 * 3_600), end: fixture.now)
        let samples = try await fixture.database.historySamplesForCSV(in: interval)
        XCTAssertEqual(piped.output, expectedCSV(samples))
        XCTAssertTrue(piped.output.hasPrefix(CSVExport.header), "the header is Core's header")
    }

    func testExportJSONDescribesTheExportInsteadOfPrintingCSV() async throws {
        let fixture = try await CLIFixture.make(hours: 3)
        own(fixture.url)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voltscope-cli-json-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removals.append(directory)
        let destination = directory.appendingPathComponent("energy.csv")

        let result = await run(["export", "--csv", "--since", "1h", "--json", "-o", destination.path],
                              environment: fixture.environment, now: fixture.now)
        XCTAssertEqual(result.code, CLIExit.ok, result.errors)
        let json = decodedJSON(result.output)
        assertEnvelope(json, command: "export", now: fixture.now)
        XCTAssertEqual(decodedString(json["format"]), "csv")
        XCTAssertEqual(decodedString(json["output"]), destination.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        let withoutFile = await run(["export", "--json"], environment: fixture.environment, now: fixture.now)
        XCTAssertEqual(withoutFile.code, CLIExit.usage, withoutFile.errors)
        XCTAssertTrue(withoutFile.errors.contains("-o"), withoutFile.errors)
        XCTAssertTrue(withoutFile.output.isEmpty, "a refused export writes nothing to stdout")

        let toStdout = await run(["export", "--since", "6h"], environment: fixture.environment, now: fixture.now)
        XCTAssertEqual(toStdout.code, CLIExit.ok, toStdout.errors)
        let streamed = try await fixture.database.historySamplesForCSV(
            in: DateInterval(start: fixture.now.addingTimeInterval(-6 * 3_600), end: fixture.now))
        XCTAssertEqual(toStdout.output, expectedCSV(streamed), "without -o the CSV bytes go to standard output")
    }

    func testExportIsClippedToTheRawRetentionWindow() async throws {
        let fixture = try await CLIFixture.make(hours: 3)
        own(fixture.url)
        // A five-day-old sample that the two-day retention no longer covers.
        try await fixture.database.writeTick(
            timestamp: Int64(fixture.now.timeIntervalSince1970 * 1000) - 5 * 86_400_000,
            apps: [SampledApp(groupKey: "com.example.ancient", bundleIdentifier: "com.example.ancient",
                              displayName: "Ancient", path: "/Apps/Ancient.app", pid: 99,
                              energyNJ: 100, cpuNs: 100, wakeups: 1)],
            buckets: [], coverage: SampleCoverage(visible: 1, unreadable: 0))
        try await fixture.database.flushPendingWindow()
        try await fixture.database.setRawRetentionDays(2)

        let result = await run(["export", "--csv", "--since", "7d"], environment: fixture.environment, now: fixture.now)
        XCTAssertEqual(result.code, CLIExit.ok, result.errors)
        XCTAssertTrue(result.errors.contains("retained from"), result.errors)
        XCTAssertFalse(result.output.contains("Ancient"), "raw samples past retention are not exported")
        XCTAssertTrue(result.output.contains("Alpha"))
    }

    // MARK: - exit codes and the file on disk

    func testQueryCommandsExitTwoWhenTheDatabaseIsMissing() async throws {
        let environment = ["VOLTSCOPE_DB_PATH": FileManager.default.temporaryDirectory
            .appendingPathComponent("voltscope-cli-nope-\(UUID().uuidString)/history.sqlite").path]
        for arguments in [["top", "--since", "1h"], ["history", "--since", "1h"], ["export", "--csv"]] {
            let result = await run(arguments, environment: environment, now: Date())
            XCTAssertEqual(result.code, CLIExit.databaseUnavailable, "\(arguments): \(result.errors)")
            XCTAssertTrue(result.errors.contains("No Voltscope history database"), result.errors)
        }
    }

    func testUsageErrorExitsOneAndHelpExitsZero() async throws {
        let bad = await run(["top"], environment: [:], now: Date())
        XCTAssertEqual(bad.code, CLIExit.usage)
        XCTAssertTrue(bad.errors.hasPrefix("voltscope: "), bad.errors)

        let help = await run(["--help"], environment: [:], now: Date())
        XCTAssertEqual(help.code, CLIExit.ok)
        XCTAssertTrue(help.output.contains("VOLTSCOPE_DB_PATH"))
    }

    func testDatabasePathExpandsOnlyTheDocumentedTildeForms() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertEqual(DatabaseLocation.resolve(environment: ["VOLTSCOPE_DB_PATH": "~"])?.path, home)
        XCTAssertEqual(
            DatabaseLocation.resolve(environment: ["VOLTSCOPE_DB_PATH": "~/Library/history.sqlite"])?.path,
            home + "/Library/history.sqlite"
        )

        // `~otheruser/…` is some other account's home, which this tool has no
        // business resolving. It stays the literal path it spells, so the command
        // reports a missing file instead of quietly reading this user's store.
        let foreign = try XCTUnwrap(
            DatabaseLocation.resolve(environment: ["VOLTSCOPE_DB_PATH": "~otheruser/history.sqlite"])
        )
        XCTAssertNotEqual(foreign.path, home + "/otheruser/history.sqlite")
        XCTAssertTrue(foreign.path.hasSuffix("/~otheruser/history.sqlite"), foreign.path)
    }

    func testReadingLeavesTheHistoryFileUntouched() async throws {
        let (url, now) = try await CLIFixture.makeClosed(hours: 3)
        own(url)
        let before = try fileState(of: url)
        let environment = ["VOLTSCOPE_DB_PATH": url.path]

        for arguments in [["status"], ["top", "--since", "1d"], ["history", "--since", "1d"], ["export", "--csv"]] {
            let result = await run(arguments, environment: environment, now: now,
                                  battery: CLIFixture.liveBattery(at: now))
            XCTAssertEqual(result.code, CLIExit.ok, "\(arguments): \(result.errors)")
        }

        let after = try fileState(of: url)
        XCTAssertEqual(after.size, before.size)
        XCTAssertEqual(after.walSize, before.walSize, "reading must not add WAL content")
        XCTAssertEqual(after.modificationTime, before.modificationTime, accuracy: 0.001,
                       "reading must not touch the database file")
    }

    private struct FileState {
        let modificationTime: TimeInterval
        let size: Int64
        let walSize: Int64
    }

    private func fileState(of url: URL) throws -> FileState {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let wal = try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")
        return FileState(modificationTime: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                         size: attributes[.size] as? Int64 ?? 0,
                         walSize: wal?[.size] as? Int64 ?? 0)
    }
}
