# Voltscope — High Level Design

> v0.9.0 scope update (2026-09-12): Battery History UI, login-item onboarding, native Settings, and the migrated GitHub Releases Sparkle feed ship with honest CPU-only attribution. Earlier v0.7 network/foreground/full-device apportionment tables below describe future architecture, not delivered capabilities. Hardware channels are independent measurements; they are not guaranteed to sum to battery drain. The current login item is the main app registered through `SMAppService.mainApp`; it does not install a helper, daemon, or LaunchAgent. See UI_SPEC.md and ENERGY_MODEL.md for the current contract.


> macOS-native, SwiftUI 6, public-API-first per-process energy attribution with optional privileged helper for system-level joule breakdown.

---

## Version History

| Version | Summary | Schema changes |
|---------|---------|----------------|
| **v0.1** (MVP) | Per-process sampling via `proc_pid_rusage`; SQLite persistence; SwiftUI Charts time-series. | Initial schema: `EnergyHistory`, `BatteryStatus`, `PowerEvents`. |
| **v0.5** (alpha) | Bundle-ID column. CSV export. Sleep-wake event tracking. Sparkle wiring. | `bundleIdentifier`, `parentPid` columns added to `EnergyHistory`. `PowerEvents` populated. |
| **v0.6** "Bucket honest" | System energy buckets (CPU-P/CPU-E/GPU/ANE/DRAM/Display/Wi-Fi/Fabric) via **IOReport + SMC, no root**. Total drain (V × A) integration. Storage compaction & write-volume fix. See `ENERGY_MODEL.md` for the full architecture rationale and API surface. | New `SystemBuckets` table. Retention compaction job (>24 h → per-minute, >7 d → per-hour). Sleep-throttled sampling cadence. |
| **v0.7** "iOS Battery for macOS" | Apportionment layer: per-PID network bytes (`NStatManager`), foreground-app tracker (`NSWorkspace`), derived per-app per-bucket attribution. The first macOS app delivering a Settings → Battery–equivalent stacked breakdown. | New `NetworkUsage`, `FocusIntervals`, `AppEnergyAttribution` tables. Apportionment job materialises `AppEnergyAttribution` per closed bucket. |
| **v0.9.0** "Persistent sampling" | Native Settings, first-run Welcome, optional main-app login item through `SMAppService.mainApp`, and a signed GitHub Releases Sparkle feed. | No schema change. UserDefaults stores only the onboarding-handled marker. |
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
│  │  │ (see below)    │  │ (see below)  │  │ NSWorkspace +  │ ││
│  │  │ proc_pid_rusage│  │IOPMPowerSrc  │  │ IOKit notif.   │ ││
│  │  └────────┬───────┘  └──────┬───────┘  └───────┬────────┘ ││
│  └───────────┼─────────────────┼──────────────────┼──────────┘ │
│  ┌───────────▼─────────────────▼──────────────────▼──────────┐│
│  │                Persistence Layer (GRDB.swift)              ││
│  │   Database location follows                                ││
│  └────────────────────────────────────────────────────────────┘│
│                              ▲                                  │
└──────────────────────────────┼──────────────────────────────────┘
                               │ XPC (NSXPCConnection)
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│       Planned Voltscope Helper (privileged, opt-in, v1.0)       │
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
| UI | SwiftUI (minimum target: macOS 13+), SwiftUI Charts, MenuBarExtra (window-style) |
| State | Swift Observation framework (`@Observable`); minimal Combine bridging |
| Persistence | GRDB.swift 7.x (SQLite wrapper with type-safe queries, WAL mode, migrations) |
| Sampling APIs | `proc_pid_rusage(RUSAGE_INFO_V6)`, `proc_listallpids`, `IOPMPowerSource`, `NSWorkspace.runningApplications` |
| Helper IPC | NSXPCConnection (XPC service style), Codable message types |
| Helper installation | SMAppService, `.daemon(plistName:)` |
| Main-app login item | ServiceManagement `SMAppService.mainApp`, no helper process |
| In-app updates | Sparkle 2.x with EdDSA signing; GitHub Releases appcast is the primary feed |
| Distribution | Developer ID signed .dmg from the website and GitHub Releases; notarization is stated per release |
| Build | Swift Package Manager + Xcode project (xcconfig managed) |

---

## Data Model

The current store is `history.sqlite`, opened as a GRDB `DatabasePool` with WAL
and incremental auto-vacuum. It sits in Voltscope's Application Support
folder. The former `db.sqlite` is read-only migration input and is never used
for new samples.

### Tiered history tables (current)

- `App` and `Bucket` hold stable identities. App rows group by bundle identifier
  when available and process name otherwise.
- `AppSampleRaw` and `BucketSampleRaw` keep timestamped detail for the configured
  raw retention period. App rows carry `metricVersion`, `energyNJ`, `cpuNs`, IO
  counters, PID, and parent PID. A tick also writes one `Coverage` row.
- `AppUsageMinute` / `BucketMinute` are retained for 30 days. `AppUsageHour` /
  `BucketHour` and `CoverageHour` are retained indefinitely. Rollups preserve
  metric versions and replace recomputed rows idempotently.
- `BatteryStatus` and `PowerEvents` retain their legacy column shapes and are
  copied into the new database during migration.
- `Meta` stores rollup watermarks, migration state and cursor, and
  `settings.rawRetentionDays`.

`EnergyMetric.currentVersion` is 1. Current samples use `ri_energy_nj`; CPU time
converts `ri_user_time + ri_system_time` with the machine Mach timebase. Imported
rows keep version 0 and their earlier energy values. Queries select one version
at a time. On Intel, rows with CPU time and zero energy are retained to support
CPU-time ranking; the interface reports energy as unavailable.

### Legacy database migration

At launch, sampling begins against `history.sqlite` immediately. If an old
`db.sqlite` exists and migration is incomplete, `LegacyDatabaseImporter` runs
as a background task. It reads the source in read-only, hour-sized transactions,
records a resumable cursor, verifies energy and battery counts, and then marks
the migration complete. A completed source is eligible for automatic deletion
seven days after completion; Settings also offers immediate deletion only after
verification succeeds. A failed import keeps the source file and the app
continues on the new store.

### `EnergyBaseline` (v1.5)

One row per `bundleIdentifier` (or `processName` for bundle-less daemons). Recomputed nightly from the trailing 30 days of `EnergyHistory` aggregated to per-hour-of-day buckets, so an app that is normally heavy at 9am does not trigger an anomaly at 9am.

| Field | Type | Notes |
|-------|------|-------|
| `bundleIdentifier` | TEXT PK | `NULL` for bundle-less daemons; key on `processName` instead |
| `processName` | TEXT | Fallback identity |
| `hourOfDay` | INTEGER | 0–23; baseline is per-hour to handle apps with predictable diurnal load |
| `meanEnergyNJPerSample` | INTEGER | 30-day mean of `energyNJ` per process sample within this hour |
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

1. Call `proc_listallpids`; read accessible processes through
   `proc_pid_rusage(RUSAGE_INFO_V6)` and count permission-denied processes.
2. Resolve app identity, convert CPU counters from Mach timebase ticks to
   nanoseconds, and calculate `ri_energy_nj` deltas. First observations establish
   baselines; rows without energy are retained only when CPU energy is
   unavailable and CPU time moved.
3. In one transaction, write process rows and a `Coverage` row to
   `history.sqlite`. Hardware bucket deltas are written to the same database by
   the bucket sampler.
4. The existing five-minute checkpoint timer runs the maintenance phases:
   minute rollup, hour rollup, retention pruning, and bounded incremental vacuum.
   Each rollup is idempotent and advances its watermark with the transaction.

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

### Launch at Login Flow (current)

1. At app launch, Settings presentation, app activation, and after a register or
   unregister attempt, read `SMAppService.mainApp.status`.
2. Map the status to `enabled`, `notRegistered`, `requiresApproval`, `notFound`,
   or an error for the UI. The status is the only source of truth for the
   toggle; UserDefaults stores only whether first-run onboarding was handled.
3. Before registration, resolve the app bundle path. Allow registration only
   from `/Applications` or the current user's `Applications` directory. A DMG,
   Downloads, build, or development path receives an actionable move prompt.
4. Register or unregister the main app with `SMAppService.mainApp`. Surface
   errors without treating a failed operation as a state change. For
   `requiresApproval`, offer the Login Items pane in System Settings.
5. When no user-visible window is open, keep the app in accessory activation,
   including a normal login-item launch. History, Settings, and Welcome switch
   to regular activation while visible.

### Planned Helper Installation Flow (v1.0)

The following flow is future work for optional per-PID GPU sampling. It is not
part of the current login-item setting and must not be used to implement it.

1. User clicks "Install Helper" in Preferences.
2. App calls `SMAppService.daemon(plistName: "com.dimpurr.voltscope.helper.plist").register()`.
3. macOS surfaces "Allow login items" sheet; user toggles on in System Settings → Login Items.
4. Helper plist is registered; helper binary is launched as `root`.
5. Main app polls XPC connection availability; on connection success, UI updates: "✅ System breakdown active."
6. Helper begins streaming powermetrics samples to main app via XPC.
7. Main app inserts samples into `SystemPower` table.

### Querying for the Main Chart

History queries route to raw samples, minute summaries, or hour summaries based
on the selected window. The not-yet-rolled-up tail is aggregated from raw rows.
Every app and hardware query filters one metric version; older-version buckets
are queried separately for the visual method marker. CSV reads the raw tier and
exports the same selectable window as the interface.

## Permissions Model

| Capability | API | Privilege | Sandbox-compatible |
|-----------|-----|-----------|-------------------|
| Per-process CPU / energy / IO | `proc_pid_rusage` | None (own UID) | No (sandbox blocks `proc_*` for other-UID processes) |
| Battery state | `IOPMPowerSource` | None | Yes |
| Bundle identifiers | `NSWorkspace.runningApplications` | None | Yes |
| System sleep/wake events | `NSWorkspace` notifications | None | Yes |
| Launch at login | `SMAppService.mainApp` | None | Yes |
| System CPU/GPU/ANE joule breakdown | `powermetrics` subprocess | **Root** | No |

Voltscope ships outside the App Store (Developer ID + notarization) because the per-process sampling does not survive the sandbox's `proc_listallpids` restrictions for other-UID processes. The helper (`powermetrics`) further requires root, which is App Store–prohibited.

---

## Distribution

- **Builds**: GitHub Actions on tag push, with Swift Package Manager and Xcode
  toolchains available on the runner.
- **Signing**: Developer ID Application certificate. Sparkle EdDSA public key is
  embedded in the app as `SUPublicEDKey`; the private key stays in Keychain
  account `voltscope` or CI secrets and is never stored in this repository.
- **Update trust**: v0.9.0 uses
  `https://github.com/dimpurr/voltscope/releases/latest/download/appcast.xml`.
  The appcast enclosure points to the exact tagged Release asset and includes
  Sparkle EdDSA signature, byte length, build version, short version, and
  minimum macOS version. The 0.8.1 legacy feed is retained for one migration
  release so those clients can discover v0.9.0.
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

1. **Sampling cadence for sleeping/idle Macs.** When the system enters deep sleep, the process sampling timer is suspended. On wake, do we backfill an "unknown" gap row, or skip the gap and let the chart draw a discontinuity? Probably the latter, with the gap visualized via `PowerEvents`.

2. **Process identity across PID reuse.** A short-lived process can finish and its PID be reused within the same sample window. Currently we key on `(timestamp, pid)`. If misattribution is observed, we may need to also hash the process start time.

3. **Bundle aggregation for non-app processes.** A daemon launched from `/usr/libexec/` has no bundle ID. Do we group all such processes under "System" or surface them individually? Probably surface individually, with a UI toggle to collapse them.

4. **GPU energy proxy** (v2.0). `IOAccelerator` IORegistry entries expose per-process command queue submission counts. Is this a usable proxy for GPU energy when no helper is installed? Needs measurement.

5. **Helper update mechanism.** Sparkle handles the main app, but the privileged helper installed via `SMAppService` requires its own update path. Investigate whether re-registering with a new `plistName` suffices on each version bump.
