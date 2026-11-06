import Foundation

/// Streams and formats the CSV energy-history export.
///
/// The app's Export-as-CSV button and `voltscope export` both come through here,
/// so the two produce the same bytes: same header, same escaping, same
/// fractional-second timestamps, same database order. What stays outside this
/// type is the app's save panel and alert.
public enum CSVExport {
    /// The header line, terminating newline included.
    public static var header: String {
        HistoryDatabase.CSVSample.columnNames.joined(separator: ",") + "\n"
    }

    /// How a finished temporary file reaches the destination.
    private enum Replacement: Sendable {
        /// The destination is replaced. This is shell-style `>` behaviour, what
        /// a command-line `-o` caller expects.
        case overwrite
        /// The destination document is retired through `FileManager`, which
        /// keeps its metadata and moves the previous copy to the Trash. The save
        /// panel needs that because the user is re-saving a document.
        case document
    }

    /// Streams the whole CSV for `interval` through `send`, header first.
    ///
    /// Rows are handed over in bounded batches, so memory does not grow with the
    /// interval, and `send` runs on the database reading queue.
    public static func write(
        database: HistoryDatabase,
        interval: DateInterval,
        send: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        let sink = CSVSinkBox(send)
        try sink.send(Data(header.utf8))
        try await database.forEachHistorySamplesForCSV(in: interval) { batch in
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for sample in batch {
                try Task.checkCancellation()
                let iso = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(sample.timestampMS) / 1000.0))
                try sink.send(Data(sample.csvLine(iso8601: iso).utf8))
            }
        }
        try Task.checkCancellation()
    }

    /// Writes the CSV to `url`. The bytes land in a temporary file in the
    /// destination's own directory and are renamed into place only once the
    /// export is complete, so a cancelled or failed export never leaves a
    /// half-written file at `url`.
    public static func write(database: HistoryDatabase, interval: DateInterval, to url: URL) async throws {
        try await write(database, interval: interval, to: url, replacement: .overwrite)
    }

    /// The app's path: same bytes and the same temporary file, but an existing
    /// document at `url` is retired through `FileManager.replaceItemAt`.
    public static func writeReplacingDocument(database: HistoryDatabase, interval: DateInterval, to url: URL) async throws {
        try await write(database, interval: interval, to: url, replacement: .document)
    }

    private static func write(_ database: HistoryDatabase, interval: DateInterval, to url: URL,
                              replacement: Replacement) async throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        do {
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: temporaryURL) else {
                throw CSVExportError.couldNotOpenOutput
            }
            do {
                let file = CSVFileBox(handle)
                try await write(database: database, interval: interval) { data in try file.write(data) }
                try handle.close()
                switch replacement {
                case .overwrite:
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    try FileManager.default.moveItem(at: temporaryURL, to: url)
                case .document:
                    if FileManager.default.fileExists(atPath: url.path) {
                        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
                    } else {
                        try FileManager.default.moveItem(at: temporaryURL, to: url)
                    }
                }
            } catch {
                try? handle.close()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}

/// Why a CSV export could not be written. `errorDescription` is short enough to
/// show in an alert or print on standard error.
public enum CSVExportError: LocalizedError, Equatable {
    case couldNotOpenOutput

    public var errorDescription: String? {
        switch self {
        case .couldNotOpenOutput:
            return "Could not open output file."
        }
    }
}

/// Carries a caller's byte sink into GRDB's database queue, which runs the batch
/// callback off the caller's task. Only one task ever touches the sink at a time.
private final class CSVSinkBox: @unchecked Sendable {
    private let send: @Sendable (Data) throws -> Void

    init(_ send: @escaping @Sendable (Data) throws -> Void) {
        self.send = send
    }

    func send(_ data: Data) throws {
        try send(data)
    }
}

/// `FileHandle` is not `Sendable`; one export owns one handle, and its writes
/// happen from the database queue while the calling task waits.
private final class CSVFileBox: @unchecked Sendable {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }
}
