import AppKit
import Foundation
import VoltscopeCore
import UniformTypeIdentifiers

/// The app's half of the CSV export: the save panel and the alert. The streaming
/// and byte-level formatting live in `VoltscopeCore.CSVExport`, which the
/// command-line tool also calls, so both write the same file.
enum CSVExporter {
    /// Presents a save panel and, on confirmation, streams the energy
    /// history for the requested window into a CSV file.
    @MainActor
    static func exportEnergyHistory(database: HistoryDatabase, interval: DateInterval) async {
        let exportInterval: DateInterval
        do {
            exportInterval = try await database.rawCSVInterval(in: interval)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = "Could not calculate export interval: \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
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
        try await CSVExport.writeReplacingDocument(database: database, interval: interval, to: url)
    }
}
