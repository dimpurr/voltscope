import SwiftUI
import VoltscopeCore

struct HistoryWindow: View {
    @EnvironmentObject private var appState: AppState
    typealias Range = HistoryRange
    @State private var range: Range = .h24
    @State private var data: HistorySnapshot?
    @State private var cache: [Range: HistorySnapshot] = [:]
    @State private var model = HistoryChartModel(points: [], groupSystem: true)
    @State private var selectedApp: String?
    @State private var groupSystem = true
    @State private var isExporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var rangeManuallyChosen = false

    private var loaded: Bool { data?.range == range }
    private var refreshSeconds: Double {
        switch range {
        case .live: return 10
        case .h1: return 30
        case .h6: return 60
        case .h24: return 120
        case .d7: return 300
        }
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
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Error: \(errorMessage)")
                    }
                    if let data, loaded {
                        BatteryHistoryChart(snapshots: data.battery, events: data.events, domain: data.domain, selection: nil)
                        HStack(spacing: 8) {
                            Text("App attribution").font(.callout.bold()).foregroundStyle(.secondary)
                            Text(appState.processEnergyAvailable
                                 ? "CPU portion only · \(range.rawValue) · \(String(format: "%.1f J", data.totalJ)) across \(data.apps.count) apps"
                                 : "Intel Mac · ranked by CPU time")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text("J / \(range.bucketLabel)").font(.caption).foregroundStyle(.secondary)
                            if selectedApp != nil {
                                Button { selectedApp = nil } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).help("Clear app highlight")
                                    .accessibilityLabel("Clear app highlight")
                                    .accessibilityIdentifier(AccessibilityIdentifiers.historyClearAppSelection)
                            }
                        }
                        .help("Recorded CPU attribution only. Not a share of whole-device battery drain. Blank periods may be idle or missing observations; edge buckets may be partial.")
                        if !appState.processEnergyAvailable {
                            Text("Intel Mac computers do not provide per-process energy data.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !data.legacyBuckets.isEmpty {
                            Text("Earlier data is marked in orange. Earlier data was recorded using an older method and is not added to current readings.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if appState.unreadableProcessCount > 0 {
                            Text("\(appState.unreadableProcessCount) system processes could not be read in the latest sample.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
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
                            AppBreakdownList(entries: data.apps.map(\.breakdownEntry), sparklines: data.sparklines,
                                             groupSystem: groupSystem, energyAvailable: appState.processEnergyAvailable,
                                             range: data.domain, bucketSeconds: range.bucketSeconds)
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
        .onChange(of: errorMessage) { msg in
            if let msg {
                if #available(macOS 14.0, *) {
                    AccessibilityNotification.Announcement("Error: \(msg)").post()
                } else {
                    let element: Any = NSApp.mainWindow ?? NSApp
                    NSAccessibility.post(
                        element: element,
                        notification: .announcementRequested,
                        userInfo: [.announcement: "Error: \(msg)", .priority: NSAccessibilityPriorityLevel.high.rawValue]
                    )
                }
            }
        }
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
            Picker("Time range", selection: $range) {
                ForEach(Range.allCases) { option in
                    // The wrapper identifier stays on the radio group; per-segment
                    // identifiers keep every range addressable on its own.
                    Text(option.rawValue)
                        .accessibilityIdentifier(AccessibilityIdentifiers.historyTimeRangeOption(option))
                        .tag(option)
                }
            }
                .pickerStyle(.segmented).frame(minWidth: 280)
                .accessibilityLabel("Time range")
                .accessibilityIdentifier(AccessibilityIdentifiers.historyTimeRange)
                .onChange(of: range) { _ in rangeManuallyChosen = true }
        }
        ToolbarItem(placement: .principal) {
            // AppKit-backed so the spoken name is "Display options" rather than
            // the toolbar menu's default "Edit" title (audit F-18).
            ToolbarMenu(
                systemImage: "slider.horizontal.3",
                accessibilityLabel: AccessibilityLabels.displayOptionsName,
                accessibilityValue: AccessibilityLabels.displayOptionsValue(groupSystemProcesses: groupSystem),
                identifier: AccessibilityIdentifiers.historyDisplayOptions,
                itemTitle: "Group system processes",
                itemIdentifier: AccessibilityIdentifiers.historyGroupSystemProcesses,
                itemIsOn: groupSystem,
                itemAction: { groupSystem.toggle() }
            )
        }
        ToolbarItem(placement: .primaryAction) {
            // AppKit-backed so the action is one accessible button, not the
            // toolbar wrapper plus an inner SwiftUI button (audit F-06).
            ToolbarButton(
                systemImage: isExporting ? "xmark.circle" : "square.and.arrow.up",
                title: isExporting ? "Cancel Export" : "Export as CSV…",
                accessibilityLabel: isExporting ? "Cancel CSV export" : "Export as CSV",
                identifier: AccessibilityIdentifiers.historyExportCSV,
                isEnabled: isExporting || (loaded && appState.database != nil),
                action: {
                    if isExporting { exportTask?.cancel() } else { exportCurrent() }
                }
            )
        }
    }

    private func rebuildModel() {
        guard let data, loaded else { return }
        model = HistoryChartModel(points: data.points, groupSystem: groupSystem, selectedApp: selectedApp,
                                  legacyBuckets: Set(data.legacyBuckets))
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
            async let p = db.historyEnergy(in: interval, range: requestedRange)
            async let b = db.batteryHistory(in: interval)
            async let e = db.historyEvents(in: interval)
            async let h = db.historyHardware(in: interval, range: requestedRange)
            async let v = db.metricVersionCoverage(in: interval, range: requestedRange)
            async let a = db.historyAppBreakdown(in: interval, range: requestedRange,
                                                 energyAvailable: appState.processEnergyAvailable)
            let result = try await (p, b, e, h, v, a)
            guard !Task.isCancelled, range == requestedRange else { return }
            let snapshot = HistorySnapshot(range: requestedRange, domain: start...end, points: result.0,
                                           battery: result.1, events: result.2, hardware: result.3,
                                           legacyBuckets: result.4.bucketStarts, appEntries: result.5)
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
        exportTask = Task { @MainActor in
            defer {
                isExporting = false
                exportTask = nil
            }
            await CSVExporter.exportEnergyHistory(database: db, interval: DateInterval(start: data.domain.lowerBound, end: data.domain.upperBound))
        }
    }
}

private struct HistorySnapshot {
    let range: HistoryWindow.Range
    let domain: ClosedRange<Date>
    let points: [HistoryEnergyPoint]
    let battery: [BatterySnapshot]
    let events: [PowerEvent]
    let hardware: [HistoryDatabase.BucketSummary]
    let legacyBuckets: [Date]
    let apps: [HistoryApp]
    let sparklines: [String: [SparkPoint]]
    let totalJ: Double
    let drainJ: Double

    init(range: HistoryWindow.Range, domain: ClosedRange<Date>, points: [HistoryEnergyPoint], battery: [BatterySnapshot], events: [PowerEvent], hardware: [HistoryDatabase.BucketSummary], legacyBuckets: [Date], appEntries: [HistoryDatabase.AppBreakdownEntry]) {
        self.range = range; self.domain = domain; self.points = points
        self.battery = battery; self.events = events; self.hardware = hardware; self.legacyBuckets = legacyBuckets
        apps = appEntries.map { HistoryApp(id: $0.id, name: $0.processName, bundleIdentifier: $0.bundleIdentifier,
                                           path: $0.path, isSystem: $0.isSystem, energyNJ: $0.totalEnergyNJ, cpuNS: $0.totalCPUNS) }
        totalJ = Double(apps.reduce(0) { $0 + $1.energyNJ }) / 1e9
        drainJ = HistoryMath.drainJ(battery, within: DateInterval(start: domain.lowerBound, end: domain.upperBound))
        sparklines = Dictionary(grouping: points, by: \.appID).mapValues { rows in
            rows.map { SparkPoint(date: $0.date, value: Double($0.energyNJ) / 1e9) }
        }
    }
}
