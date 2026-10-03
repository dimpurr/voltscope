import AppKit
import Foundation
import VoltscopeCore
import UniformTypeIdentifiers

enum CSVExporter {
    /// Presents a save panel and, on confirmation, streams the energy
    /// history for the requested window into a CSV file.
    @MainActor
    static func exportEnergyHistory(database: HistoryDatabase, interval: DateInterval) async {
        let exportInterval: DateInterval
        do { exportInterval = try await database.rawCSVInterval(in: interval) }
        catch { return }
        let panel = NSSavePanel()
        panel.title = "Export Energy History as CSV"
        if exportInterval.start > interval.start {
            let date = DateFormatter.localizedString(from: exportInterval.start, dateStyle: .medium, timeStyle: .short)
            panel.message = "Raw samples are retained for the selected period, so this export starts at \(date)."
        } else {
            panel.message = "Saves the visible time range as a comma-separated values file."
        }
        panel.prompt = "Export"
        panel.allowedContentTypes = [.commaSeparatedText]
        let defaultName = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "voltscope-energy-\(defaultName).csv"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try await writeCSV(database: database, interval: exportInterval, to: url)
        } catch {
            if error is CancellationError { return }
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private static func writeCSV(database: HistoryDatabase, interval: DateInterval, to url: URL) async throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        do {
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: temporaryURL) else {
                throw NSError(domain: "Voltscope.CSVExporter", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not open output file."])
            }
            do {
                let header = HistoryDatabase.CSVSample.columnNames.joined(separator: ",") + "\n"
                try handle.write(contentsOf: Data(header.utf8))

                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                try await database.forEachHistorySamplesForCSV(in: interval) { batch in
                    for sample in batch {
                        try Task.checkCancellation()
                        let iso = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(sample.timestampMS) / 1000.0))
                        try handle.write(contentsOf: Data(sample.csvLine(iso8601: iso).utf8))
                    }
                }
                try Task.checkCancellation()
                try handle.close()
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
                } else {
                    try FileManager.default.moveItem(at: temporaryURL, to: url)
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
