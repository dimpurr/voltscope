# Voltscope — High Level Design

> v0.7 scope update (2026-09-11): Battery History UI, linked selection and honest CPU-only attribution ship first. Earlier v0.7 network/foreground/full-device apportionment tables below describe future architecture, not delivered capabilities. Hardware channels are independent measurements; they are not guaranteed to sum to battery drain. See UI_SPEC.md and ENERGY_MODEL.md for the current contract.


> macOS-native, SwiftUI 6, public-API-first per-process energy attribution with optional privileged helper for system-level joule breakdown.

---

## Version History

| Version | Summary | Schema changes |
|---------|---------|----------------|
| **v0.1** (MVP) | Per-process sampling via `proc_pid_rusage`; SQLite persistence; SwiftUI Charts time-series. | Initial schema: `EnergyHistory`, `BatteryStatus`, `PowerEvents`. |
| **v0.5** (alpha) | Bundle-ID column. CSV export. Sleep-wake event tracking. Sparkle wiring. | `bundleIdentifier`, `parentPid` columns added to `EnergyHistory`. `PowerEvents` populated. |
| **v0.6** "Bucket honest" | System energy buckets (CPU-P/CPU-E/GPU/ANE/DRAM/Display/Wi-Fi/Fabric) via **IOReport + SMC, no root**. Total drain (V × A) integration. Storage compaction & write-volume fix. See `ENERGY_MODEL.md` for the full architecture rationale and API surface. | New `SystemBuckets` table. Retention compaction job (>24 h → per-minute, >7 d → per-hour). Sleep-throttled sampling cadence. |
| **v0.7** "iOS Battery for macOS" | Apportionment layer: per-PID network bytes (`NStatManager`), foreground-app tracker (`NSWorkspace`), derived per-app per-bucket attribution. The first macOS app delivering a Settings → Battery–equivalent stacked breakdown. | New `NetworkUsage`, `FocusIntervals`, `AppEnergyAttribution` tables. Apportionment job materialises `AppEnergyAttribution` per closed bucket. |
| **v1.0** (planned) | Optional `SMAppService` privileged helper running `powermetrics --show-process-gpu` for per-PID GPU ms/s. Refines the GPU-bucket apportionment from CPU-share proxy to true GPU-time share. Notarized release. | Optional `SystemPowerHelper` table for helper-streamed `powermetrics` plist (kept as supplementary signal even after v0.6's no-root bucket layer subsumes the headline use case). |
| **v1.5** (planned) | Adaptive per-app energy baseline + 3σ anomaly notifications, computed against the **apportioned** per-app energy from v0.7 (not the v0.5 raw CPU number). | `EnergyBaseline` table keyed on (bundle, hourOfDay) with `meanJoulesPerSample` over apportioned values. `NotificationLog` table. |
| **v2.0** (planned) | Tail-energy radio model (Pathak/Hu/Zhang) refining Wi-Fi/BT/cellular bucket apportionment. Sleep-period drilldown. Localization. | New event types in `PowerEvents` for radio state transitions. |

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          Voltscope.app                          │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                     SwiftUI Layer                           ││
│  │  ┌──────────────────┐    ┌──────────────────────────────┐ ││
│  │  │  MenuBarExtra    │    │  Main History Window         │ ││
│  │  │  (always present)│    │  (on demand)                 │ ││
│  │  │  - Power label   │    │  - Time range selector       │ ││
│  │  │  - Quick panel   │    │  - SwiftUI Charts            │ ││
│  │  │  - Top 3 apps    │    │  - Drill-down per-app        │ ││
│  │  └──────────────────┘    └──────────────────────────────┘ ││
│  └─────────────────────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                     Sampling Layer                          ││
│  │  ┌────────────────┐  ┌──────────────┐  ┌────────────────┐ ││
│  │  │ ProcessSampler │  │BatterySampler│  │ EventListener  │ ││
│  │  │  (5s interval) │  │ (30s interval)│ │ NSWorkspace +  │ ││
│  │  │ proc_pid_rusage│  │IOPMPowerSrc  │  │ IOKit notif.   │ ││
│  │  └────────┬───────┘  └──────┬───────┘  └───────┬────────┘ ││
│  └───────────┼─────────────────┼──────────────────┼──────────┘ │
│  ┌───────────▼─────────────────▼──────────────────▼──────────┐│
│  │                Persistence Layer (GRDB.swift)              ││
│  │   ~/Library/Application Support/Voltscope/db.sqlite        ││
│  └────────────────────────────────────────────────────────────┘│
│                              ▲                                  │
└──────────────────────────────┼──────────────────────────────────┘
                               │ XPC (NSXPCConnection)
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│              Voltscope Helper (privileged, opt-in)              │
│  /Library/PrivilegedHelperTools/com.dimpurr.voltscope.helper    │
│  Installed via: SMAppService.daemon(plistName:)                 │
│  ┌────────────────────────────────────────────────────────────┐│
│  │  PowermetricsStream                                        ││
│  │  - Spawns `powermetrics --samplers cpu_power gpu_power     ││
│  │    ane_power -i 1000 -f plist`                             ││
│  │  - Parses streamed plist                                   ││
│  │  - XPC sendEvent → main app every 1s                       ││
│  └────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

### Tech Stack

| Layer | Technology |
|-------|------------|
| UI | SwiftUI (macOS 13+), SwiftUI Charts, MenuBarExtra (window-style) |
| State | Swift Observation framework (`@Observable`); minimal Combine bridging |
| Persistence | GRDB.swift 7.x (SQLite wrapper with type-safe queries, WAL mode, migrations) |
| Sampling APIs | `proc_pid_rusage(RUSAGE_INFO_V6)`, `proc_listallpids`, `IOPMPowerSource`, `NSWorkspace.runningApplications` |
| Helper IPC | NSXPCConnection (XPC service style), Codable message types |
| Helper installation | SMAppService (macOS 13+), `.daemon(plistName:)` |
| Auto-update | Sparkle 2.x with EdDSA signing |
| Distribution | Developer ID signed .dmg from the website and GitHub Releases; notarization is stated per release |
| Build | Swift Package Manager + Xcode project (xcconfig managed) |

---

## Data Model

All tables live in `~/Library/Application Support/Voltscope/db.sqlite`. WAL mode, foreign-key checks on, monthly `VACUUM` triggered during app idle.

### `EnergyHistory`

The core per-process per-sample table. Each sample writes one row per running process; ~30 rows per sample on a typical machine.

| Field | Type | Notes |
|-------|------|-------|
| `sampleId` | INTEGER PK | Auto-increment |
| `timestamp` | INTEGER | Unix epoch milliseconds |
| `pid` | INTEGER | Process ID at sample time |
| `bundleIdentifier` | TEXT | Reverse-DNS bundle ID; `NULL` for system processes without a bundle |
| `processName` | TEXT | `proc_pidpath`-derived name |
| `path` | TEXT | Full executable path |
| `parentPid` | INTEGER | For grouping helper processes under their parent app |
| `cpuUserNs` | INTEGER | `ri_user_time` in nanoseconds |
| `cpuSystemNs` | INTEGER | `ri_system_time` in nanoseconds |
| `energyNJ` | INTEGER | `ri_billed_energy` (nanojoules) — **the headline metric** |
| `wakeups` | INTEGER | `ri_pkg_idle_wkups + ri_interrupt_wkups` |
| `diskReadBytes` | INTEGER | `ri_diskio_bytesread` |
| `diskWriteBytes` | INTEGER | `ri_diskio_byteswritten` |
| `year` | INTEGER | Denormalized for `GROUP BY year, month, day` |
| `month` | INTEGER | |
| `day` | INTEGER | |
| `hour` | INTEGER | |
| `minute` | INTEGER | |

Indexes: `(timestamp)`, `(bundleIdentifier, timestamp)`, `(year, month, day)`.

### `BatteryStatus`

System-level battery state. ~30s sampling cadence.

| Field | Type | Notes |
|-------|------|-------|
| `timestamp` | INTEGER PK | Unix epoch ms |
| `levelPercent` | REAL | `kIOPSCurrentCapacityKey / kIOPSMaxCapacityKey` |
| `capacityMAh` | INTEGER | Current charge mAh |
| `designMAh` | INTEGER | Design capacity (constant per battery) |
| `cycleCount` | INTEGER | `BatteryCycleCount` from `AppleSmartBattery` IORegistry |
| `voltageMV` | INTEGER | Millivolts |
| `amperageMA` | INTEGER | Milliamps, signed (positive = charging) |
| `temperatureC` | REAL | Battery temperature |
| `timeRemainingMin` | INTEGER | macOS estimate; `NULL` if "calculating" |
| `isCharging` | INTEGER | 0 or 1 |
| `isACPlugged` | INTEGER | 0 or 1 |

### `PowerEvents`

Discrete events: sleep, wake, AC plug/unplug, low-power-mode toggle.

| Field | Type | Notes |
|-------|------|-------|
| `timestamp` | INTEGER PK | Unix epoch ms |
| `eventType` | TEXT | `'sleep'`, `'wake'`, `'plug'`, `'unplug'`, `'lowpower_on'`, `'lowpower_off'` |
| `durationSeconds` | INTEGER | Pairing column for sleep→wake span; `NULL` for instantaneous events |
| `metadata` | TEXT | JSON for extra fields (e.g. wake reason from `pmset -g log`) |

### `EnergyBaseline` (v1.5)

One row per `bundleIdentifier` (or `processName` for bundle-less daemons). Recomputed nightly from the trailing 30 days of `EnergyHistory` aggregated to per-hour-of-day buckets, so an app that is normally heavy at 9am does not trigger an anomaly at 9am.

| Field | Type | Notes |
|-------|------|-------|
| `bundleIdentifier` | TEXT PK | `NULL` for bundle-less daemons; key on `processName` instead |
| `processName` | TEXT | Fallback identity |
| `hourOfDay` | INTEGER | 0–23; baseline is per-hour to handle apps with predictable diurnal load |
| `meanEnergyNJPerSample` | INTEGER | 30-day mean of `energyNJ` per 5s sample within this hour |
| `stddevEnergyNJ` | INTEGER | Population stddev within the same window |
| `sampleCount` | INTEGER | Number of contributing samples; used to gate notifications (require `>= 100` samples to trust the baseline) |
| `lastRecomputedAt` | INTEGER | Unix epoch ms |

**Anomaly rule**: a per-process sample triggers a notification candidate when `energyNJ > mean + 3 * stddev` AND the absolute value exceeds 0.5 J/sample (suppress noise from low-energy apps doing a tiny relative spike). Candidates are then deduplicated against `NotificationLog` (max one notification per bundle ID per hour) before delivery.

**Why this matters**: fixed process lists do not generalize across users. Voltscope's future baseline work is intended to cover every process and adapt to the user's workload.

### `SystemPower` (helper-only)

Populated only when helper is installed. Contains powermetrics-derived joule rates.

| Field | Type | Notes |
|-------|------|-------|
| `timestamp` | INTEGER PK | |
| `cpuPowerMW` | REAL | CPU package power (milliwatts) |
| `gpuPowerMW` | REAL | GPU power |
| `anePowerMW` | REAL | Apple Neural Engine power |
| `dramPowerMW` | REAL | DRAM power |
| `packagePowerMW` | REAL | Total package power (sum + uncategorized) |

---

## Core Flows

### Sampling Loop (foreground, every 5s)

1. Timer fires.
2. Call `proc_listallpids` → array of active PIDs.
3. For each PID: call `proc_pid_rusage(pid, RUSAGE_INFO_V6, &rusage)`. Skip on error (process may have exited).
4. Resolve bundle identifier: `NSRunningApplication(processIdentifier:)?.bundleIdentifier` if present, else `proc_pidpath` + parsing.
5. Compute deltas vs previous sample: `energyDelta = current.ri_billed_energy - previous.ri_billed_energy`. First sample after process start is skipped (no baseline).
6. Open GRDB write transaction; insert N rows with shared `timestamp`.
7. Check retention threshold; trigger background compaction job if needed.

### Battery Sampling Loop (every 30s)

1. Open `IOPSCopyPowerSourcesInfo()` snapshot.
2. Iterate `IOPSCopyPowerSourcesList`; pick the internal battery source.
3. Read `kIOPSCurrentCapacityKey`, `kIOPSMaxCapacityKey`, `kIOPSDesignCapacityKey`, `kIOPSCycleCountKey`, etc.
4. For voltage/amperage/temperature: open `IOServiceMatching("AppleSmartBattery")` → read properties.
5. Insert one `BatteryStatus` row.

### Event Listening (continuous)

| Source | Event | Mapping |
|--------|-------|---------|
| `NSWorkspace.shared.notificationCenter` | `.willSleepNotification` | `'sleep'` |
| `NSWorkspace.shared.notificationCenter` | `.didWakeNotification` | `'wake'` |
| `IOPMPowerSource` callback | AC source change | `'plug'` / `'unplug'` |
| `NSProcessInfo.processInfo` | `.thermalStateDidChangeNotification` | metadata field on next event |
| `pmset -g lowpowermode` polling | Low-power-mode toggle | `'lowpower_on'` / `'lowpower_off'` |

### Helper Installation Flow

1. User clicks "Install Helper" in Preferences.
2. App calls `SMAppService.daemon(plistName: "com.dimpurr.voltscope.helper.plist").register()`.
3. macOS surfaces "Allow login items" sheet; user toggles on in System Settings → Login Items.
4. Helper plist is registered; helper binary is launched as `root`.
5. Main app polls XPC connection availability; on connection success, UI updates: "✅ System breakdown active."
6. Helper begins streaming powermetrics samples to main app via XPC.
7. Main app inserts samples into `SystemPower` table.

### Querying for the Main Chart

For the "last 7 days, stacked by app" view:

```sql
SELECT
    bundleIdentifier,
    year, month, day, hour,
    SUM(energyNJ) AS totalEnergyNJ
FROM EnergyHistory
WHERE timestamp >= ? AND timestamp < ?
GROUP BY bundleIdentifier, year, month, day, hour
ORDER BY day, hour;
```

Top-N apps determined by `SUM(energyNJ)` over the visible range. Apps outside the top N are bucketed into "Other" client-side.

---

## Permissions Model

| Capability | API | Privilege | Sandbox-compatible |
|-----------|-----|-----------|-------------------|
| Per-process CPU / energy / IO | `proc_pid_rusage` | None (own UID) | No (sandbox blocks `proc_*` for other-UID processes) |
| Battery state | `IOPMPowerSource` | None | Yes |
| Bundle identifiers | `NSWorkspace.runningApplications` | None | Yes |
| System sleep/wake events | `NSWorkspace` notifications | None | Yes |
| System CPU/GPU/ANE joule breakdown | `powermetrics` subprocess | **Root** | No |

Voltscope ships outside the App Store (Developer ID + notarization) because the per-process sampling does not survive the sandbox's `proc_listallpids` restrictions for other-UID processes. The helper (`powermetrics`) further requires root, which is App Store–prohibited.

---

## Distribution

- **Builds**: GitHub Actions on tag push, with Swift Package Manager and Xcode
  toolchains available on the runner.
- **Signing**: Developer ID Application certificate. Sparkle EdDSA keys, when
  enabled, stay in the maintainer's Keychain or CI secrets.
- **Notarization**: use Apple's notary service when credentials are configured;
  release notes must state the actual result.
- **Packaging**: the maintained DMG script creates the application bundle.
- **Channels**: publish the same verified DMG on the official website and in the
  matching GitHub Release. The checksum must agree.
- **Update cadence**: patch releases as needed; minor releases when a coherent
  user-facing capability is ready.

---

## Performance Budget

| Operation | Frequency | Target cost on M1 Pro |
|-----------|-----------|----------------------|
| `proc_listallpids` + `proc_pid_rusage × 100` | Every 5s | ~3 ms CPU |
| `IOPMPowerSource` snapshot | Every 30s | <1 ms |
| GRDB write of ~30 rows | Every 5s | ~2 ms |
| SwiftUI Charts repaint (visible window) | On range change | ~50 ms initial, <16 ms on tick |
| Helper `powermetrics` subprocess | Continuous (1s interval) | ~0.3% CPU (helper process) |
| **Aggregate Voltscope CPU** | — | **<0.5% averaged** |

Storage: ~3 MB raw per day (30 processes × 17,280 samples × ~50 B/row). Compaction at 30 days collapses to hourly aggregates; 365-day footprint <200 MB.

---

## Out-of-scope (deliberately)

- iOS / iPadOS clients
- Battery health forecasting
- Charge limiting
- Process killing, app suspension, Turbo Boost control, screen dimming, and radio toggling
- Network throughput display
- Cloud sync of history (privacy by construction)

---

## Open Design Questions

These are deliberately unresolved at the design-phase commit and will be settled during implementation:

1. **Sampling cadence for sleeping/idle Macs.** When the system enters deep sleep, the 5s timer is suspended. On wake, do we backfill an "unknown" gap row, or skip the gap and let the chart draw a discontinuity? Probably the latter, with the gap visualized via `PowerEvents`.

2. **Process identity across PID reuse.** A short-lived process can finish and its PID be reused within the same sample window. Currently we key on `(timestamp, pid)`. If misattribution is observed, we may need to also hash the process start time.

3. **Bundle aggregation for non-app processes.** A daemon launched from `/usr/libexec/` has no bundle ID. Do we group all such processes under "System" or surface them individually? Probably surface individually, with a UI toggle to collapse them.

4. **GPU energy proxy** (v2.0). `IOAccelerator` IORegistry entries expose per-process command queue submission counts. Is this a usable proxy for GPU energy when no helper is installed? Needs measurement.

5. **Helper update mechanism.** Sparkle handles the main app, but the privileged helper installed via `SMAppService` requires its own update path. Investigate whether re-registering with a new `plistName` suffices on each version bump.
