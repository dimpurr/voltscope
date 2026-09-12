import SwiftUI
import VoltscopeCore

struct HistoryWindow: View {
    @EnvironmentObject private var appState: AppState
    enum Range: String, CaseIterable, Identifiable {
        case live = "Live", h1 = "1H", h24 = "24H", d7 = "7D"
        var id: String { rawValue }
        var minutes: Int {
            switch self { case .live: return 30; case .h1: return 60; case .h24: return 1440; case .d7: return 10080 }
        }
        var bucketSeconds: Int {
            switch self { case .live: return 30; case .h1: return 120; case .h24: return 1800; case .d7: return 21600 }
        }
        var bucketLabel: String {
            switch self { case .live: return "30 seconds"; case .h1: return "2 minutes"; case .h24: return "30 minutes"; case .d7: return "6 hours · UTC" }
        }
    }
    @State private var range: Range = .h24
    @State private var data: HistorySnapshot?
    @State private var cache: [Range: HistorySnapshot] = [:]
    @State private var model = HistoryChartModel(points: [], groupSystem: true)
    @State private var selectedApp: String?
    @State private var groupSystem = true
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var rangeManuallyChosen = false

    private var loaded: Bool { data?.range == range }
    private var refreshSeconds: Double {
        switch range { case .live: return 10; case .h1: return 30; case .h24: return 120; case .d7: return 300 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HistoryStatusBar(battery: appState.lastBattery)
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let data, loaded {
                        BatteryHistoryChart(snapshots: data.battery, events: data.events, domain: data.domain, selection: nil)
                        HStack(spacing: 8) {
                            Text("App attribution").font(.callout.bold()).foregroundStyle(.secondary)
                            Text("CPU portion only · \(range.rawValue) · \(String(format: "%.1f J", data.totalJ)) across \(data.apps.count) apps")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text("J / \(range.bucketLabel)").font(.caption).foregroundStyle(.secondary)
                            if selectedApp != nil {
                                Button { selectedApp = nil } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).help("Clear app highlight")
                            }
                        }
                        .help("Recorded CPU attribution only. Not a share of whole-device battery drain. Blank periods may be idle or missing observations; edge buckets may be partial.")
                        EnergyStackedChart(model: model, bucketSeconds: range.bucketSeconds,
                                           xDomain: data.domain, selectedApp: $selectedApp)
                            .id(range)
                        Divider()
                        // Preserve v0.6.2: equal columns, original rows, one shared scroll.
                        HStack(alignment: .top, spacing: 24) {
                            EnergyBreakdownSection(summaries: data.hardware, totalDrainJ: data.drainJ,
                                bucketSeconds: range.bucketSeconds, bucketSamplerAvailable: !data.hardware.isEmpty || appState.bucketSamplerActive)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            Divider()
                            AppBreakdownList(entries: data.apps.map(\.breakdownEntry), sparklines: data.sparklines, groupSystem: groupSystem)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        ProgressView("Loading \(range.rawValue) history…")
                            .frame(maxWidth: .infinity, minHeight: 400)
                    }
                }.padding(.horizontal, 20).padding(.vertical, 14)
            }
        }
        .toolbar { toolbar }
        .onChange(of: groupSystem) { _ in rebuildModel() }
        .onChange(of: selectedApp) { _ in rebuildModel() }
        .task {
            guard let db = appState.database, !rangeManuallyChosen else { return }
            if let earliest = try? await db.earliestSampleTimestamp(), !rangeManuallyChosen {
                let age = Date().timeIntervalSince(earliest)
                if age < 3600 { range = .live }
                else if age < 86400 { range = .h1 }
            }
        }
        .task(id: range) {
            selectedApp = nil
            errorMessage = nil
            if let cached = cache[range] {
                data = cached
                rebuildModel()
            }
            while !Task.isCancelled {
                await loadData()
                do { try await Task.sleep(nanoseconds: UInt64(refreshSeconds * 1e9)) } catch { return }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Time range", selection: $range) { ForEach(Range.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(width: 280)
                .onChange(of: range) { _ in rangeManuallyChosen = true }
        }
        ToolbarItem(placement: .principal) {
            Menu { Toggle("Group system processes", isOn: $groupSystem) } label: { Label("Display", systemImage: "slider.horizontal.3") }
                .menuIndicator(.visible).help("Display options")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { exportCurrent() } label: { Label("Export as CSV…", systemImage: "square.and.arrow.up") }
                .disabled(isExporting || !loaded || appState.database == nil)
        }
    }

    private func rebuildModel() {
        guard let data, loaded else { return }
        model = HistoryChartModel(points: data.points, groupSystem: groupSystem, selectedApp: selectedApp)
    }

    private func loadData() async {
        guard let db = appState.database else { return }
        let requestedRange = range
        let end = Date()
        var start = end.addingTimeInterval(-Double(requestedRange.minutes) * 60)
        if requestedRange == .live, let earliest = try? await db.earliestSampleTimestamp() {
            start = max(start, min(earliest, end.addingTimeInterval(-30)))
        }
        let interval = DateInterval(start: start, end: end)
        do {
            async let p = db.historyEnergy(in: interval, bucketSeconds: requestedRange.bucketSeconds)
            async let b = db.batteryHistory(in: interval)
            async let e = db.historyEvents(in: interval)
            async let h = db.historyHardware(in: interval, bucketSeconds: requestedRange.bucketSeconds)
            let result = try await (p, b, e, h)
            guard !Task.isCancelled, range == requestedRange else { return }
            let snapshot = HistorySnapshot(range: requestedRange, domain: start...end, points: result.0,
                                           battery: result.1, events: result.2, hardware: result.3)
            HistoryColors.register(snapshot.apps.map(\.id))
            cache[requestedRange] = snapshot
            data = snapshot
            rebuildModel()
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "History could not refresh. \(loaded ? "Showing the previous observations." : "Retrying automatically.")"
        }
    }
    private func exportCurrent() {
        guard let db = appState.database, let data, loaded else { return }
        isExporting = true
        Task { @MainActor in
            await CSVExporter.exportEnergyHistory(database: db, interval: DateInterval(start: data.domain.lowerBound, end: data.domain.upperBound))
            isExporting = false
        }
    }
}

private struct HistorySnapshot {
    let range: HistoryWindow.Range
    let domain: ClosedRange<Date>
    let points: [HistoryEnergyPoint]
    let battery: [BatterySnapshot]
    let events: [PowerEvent]
    let hardware: [AppDatabase.BucketSummary]
    let apps: [HistoryApp]
    let sparklines: [String: [SparkPoint]]
    let totalJ: Double
    let drainJ: Double

    init(range: HistoryWindow.Range, domain: ClosedRange<Date>, points: [HistoryEnergyPoint], battery: [BatterySnapshot], events: [PowerEvent], hardware: [AppDatabase.BucketSummary]) {
        self.range = range; self.domain = domain; self.points = points
        self.battery = battery; self.events = events; self.hardware = hardware
        apps = HistoryMath.apps(points)
        totalJ = Double(apps.reduce(0) { $0 + $1.energyNJ }) / 1e9
        drainJ = HistoryMath.drainJ(battery, within: DateInterval(start: domain.lowerBound, end: domain.upperBound))
        sparklines = Dictionary(grouping: points, by: \.appID).mapValues { rows in
            rows.map { SparkPoint(date: $0.date, value: Double($0.energyNJ) / 1e9) }
        }
    }
}
