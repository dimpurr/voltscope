import AppKit
import Foundation
import VoltscopeCore
import UniformTypeIdentifiers

enum CSVExporter {
    /// Presents a save panel and, on confirmation, streams the energy
    /// history for the requested window into a CSV file.
    @MainActor
    static func exportEnergyHistory(database: AppDatabase, interval: DateInterval) async {
        let panel = NSSavePanel()
        panel.title = "Export Energy History as CSV"
        panel.message = "Saves the visible time range as a comma-separated values file."
        panel.prompt = "Export"
        panel.allowedContentTypes = [.commaSeparatedText]
        let defaultName = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "voltscope-energy-\(defaultName).csv"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try await writeCSV(database: database, interval: interval, to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private static func writeCSV(database: AppDatabase, interval: DateInterval, to url: URL) async throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw NSError(
                domain: "Voltscope.CSVExporter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not open output file."]
            )
        }
        defer { try? handle.close() }

        let header = "timestamp_ms,iso8601,pid,parent_pid,bundle_id,process_name,path,cpu_user_ns,cpu_system_ns,energy_nj,wakeups,disk_read_bytes,disk_write_bytes\n"
        try handle.write(contentsOf: Data(header.utf8))

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let samples = try await database.historySamples(in: interval)
        for sample in samples {
            let iso = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(sample.timestamp) / 1000.0))
            let line = [
                String(sample.timestamp),
                iso,
                String(sample.pid),
                sample.parentPid.map(String.init) ?? "",
                csvEscape(sample.bundleIdentifier ?? ""),
                csvEscape(sample.processName),
                csvEscape(sample.path ?? ""),
                String(sample.cpuUserNs),
                String(sample.cpuSystemNs),
                String(sample.energyNJ),
                String(sample.wakeups),
                String(sample.diskReadBytes),
                String(sample.diskWriteBytes)
            ].joined(separator: ",") + "\n"
            try handle.write(contentsOf: Data(line.utf8))
        }
    }

    private static func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }
}
