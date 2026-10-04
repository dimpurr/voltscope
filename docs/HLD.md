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
| Sampling APIs | `proc_pid_rusage(RUSAGE_INFO_V6)`, `proc_listallpids`, `IOPMPowerSource`, `IOReportConnectSampler`, `NSWorkspace.runningApplications` |
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
  when available and process name otherwise, with the bundle-less versioned CLI
  rule below.
- `AppSampleRaw` and `BucketSampleRaw` keep UTC-aligned 30-second windows for
  the configured raw retention period. Sampling remains every five seconds;
  the in-memory writer sums each process/PID and hardware bucket before writing.
  `Coverage` stores the last scan's visible/unreadable counts per window and is
  pruned with raw history. Canonical hardware bucket names are defined in
  [ENERGY_MODEL.md](ENERGY_MODEL.md#current-sampler-metric-contract).
- `AppUsageMinute` / `BucketMinute` are retained for 2 days. `AppUsageHour` /
  `BucketHour` and `CoverageHour` are retained indefinitely. Rollups preserve
  metric versions and replace recomputed rows idempotently.
- `BatteryStatus` and `PowerEvents` retain their legacy column shapes, are
  copied into the new database during migration, and are retained indefinitely.
- `Meta` stores rollup watermarks, migration state and cursor, and
  `settings.rawRetentionDays`.

The current schema has thirteen tables: eleven tiered tables (`App`,
`AppSampleRaw`, `AppUsageMinute`, `AppUsageHour`, `Bucket`, `BucketSampleRaw`,
`BucketMinute`, `BucketHour`, `Coverage`, `CoverageHour`, and `Meta`), plus
`BatteryStatus` and `PowerEvents`, which retain their legacy schemas. The only
explicit `CREATE INDEX` statements are `AppSampleRaw_ts` on
`AppSampleRaw(ts)` and `BucketSampleRaw_ts` on `BucketSampleRaw(ts)`.
`App.groupKey` and `Bucket.name` also have unique constraints. Minute and hour
summary tables use composite primary keys `(minute|hour, appId|bucketId,
metricVersion)` and `WITHOUT ROWID`; `Coverage` and `CoverageHour` use timestamp
and hour primary keys, respectively.

`EnergyMetric.currentVersion` is 1. Current samples use `ri_energy_nj`; CPU time
converts `ri_user_time + ri_system_time` with the machine Mach timebase. Imported
rows keep version 0 and their earlier energy values. Queries select one version
at a time. On Intel, rows with CPU time and zero energy are retained; the
interface behavior is specified in
[UI_SPEC.md](UI_SPEC.md#010--tiered-history-presentation-current).

### App identity for versioned CLI executables (current)

Bundle IDs remain authoritative. For a process without a bundle ID, infer a
stable CLI identity only when both the process name and executable filename
match entirely numeric components separated by dots, with at least one dot
(for example, `2.1.287`). The stored canonical display name is also accepted
when re-reading rows written by this rule. The executable path must have the
exact shape `…/<name>/versions/<version>`: the executable's direct parent must
be named `versions` case-insensitively, and `<name>` must be nonempty, not a
dotted numeric version, and not a shared location. Do not skip or walk through
other packaging directories. Shared names are rejected case-insensitively:
`usr`, `local`, `opt`, `homebrew`, `share`, `.local`, `applications`,
`application support`, `library`, `cellar`, `helpers`, `frameworks`, `users`,
`home`, `tmp`, `private`, `var`, `etc`, `system`, `volumes`, `resources`,
`support`, and `vendor`. Other path shapes keep the existing process-name
identity. The slug is the `cli:<slug>` App `groupKey`; `claude` displays as
`Claude Code`, and other slugs display as title-cased directory names.

For example, `~/.local/share/claude/versions/2.1.286` and
`~/.local/share/claude/versions/2.1.287` resolve to `cli:claude` / `Claude
Code`. `/opt/acme-tool/bin/3.4.1` keeps the existing process-name identity
because it is not in a `versions` directory.
Names such as `claude`, `v2.1.287`, and `2.1-beta`, a missing path, or a path
with any other shape keep the existing process-name identity. This narrow rule
avoids guessing from arbitrary executable names. Stable group keys also give
all versions the same persisted chart color identity. A bundle-less process is
classified as a user app only when the full identity resolution produces a
`cli:` key; other bundle-less processes remain system-classified.

Existing App and sample rows are not rewritten. History queries apply the same
path rule to bundle-less version-named rows and add their energy and CPU within
each chart bucket, so old versions can appear as one app when their stored path
contains a meaningful parent. Rows without such paths remain separate. Raw CSV
continues to report stored process/PID rows and is not rewritten or merged.

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

### Process and hardware sampling (every 5s)

1. Run the process scan and independent IOReport bucket scan. The process scan
   calls `proc_listallpids`, reads accessible processes through
   `proc_pid_rusage(RUSAGE_INFO_V6)`, and counts permission-denied processes.
   The current parent PID and `pbi_comm` are read for each process every tick.
   Path, bundle, process-name, and resolved app-identity metadata is cached by
   `(pid, ri_proc_start_abstime)` while `pbi_comm` is unchanged, capped at 4,096
   entries, and pruned when a process has neither a readable snapshot nor a
   retained counter baseline. Metadata follows baselines through their two-scan
   transient-read grace period. A changed `pbi_comm` invalidates and re-resolves
   the cached identity.
2. Reuse cached app identity, convert CPU counters from Mach timebase ticks to
   nanoseconds, and calculate `ri_energy_nj` deltas. First observations establish
   baselines; rows without energy are retained only when CPU energy is
   unavailable and CPU time moved.
3. Accumulate process and hardware deltas in memory and write one row per
   `(30-second UTC window, app, PID, metric version)` or
   `(window, bucket, metric version)` to `history.sqlite`. CSV exports those
   stored process/PID rows with the window-start timestamp and counters summed
   across the underlying process ticks. Each flush resolves a distinct app
   group once, then reuses its ID for that group's process rows. Flush on window
   change, maintenance, sleep, shutdown, and every 15 seconds so an open window
   has a bounded crash-loss interval;
   `Coverage` records the last scan in each window. Failed transactions remain
   queued in order and retry on the next flush. The queue holds at most eight
   completed windows; when full, the writer rejects a further boundary change
   without clearing the active window. Shutdown only proceeds after the final
   flush succeeds; on failure sampling resumes and termination is cancelled so
   the queued batch can be retried. A partial final window is persisted as-is.
4. The existing five-minute checkpoint timer runs the maintenance phases:
   minute rollup, hour rollup, retention pruning, and bounded incremental vacuum.
   It then requests an out-of-transaction `wal_checkpoint(TRUNCATE)` so the
   reclaimed database tail reaches the main file and the WAL can be truncated.
   An active reader may defer the truncate; the next five-minute pass retries.
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
exports the same selectable window as the interface. The shortest chart range
uses raw; intermediate ranges, including the full-day view, use minute
summaries; the week view uses permanent hour summaries. Range names and bucket
widths are owned by [UI_SPEC.md](UI_SPEC.md). CSV uses an ordered raw database
cursor and writes fixed-size batches so export memory does not grow with the
selected interval. Cancellation stops cursor iteration and removes the
incomplete output file. Two-day minute retention leaves a full day of margin
for the full-day query.

Before returning app chart points, query results with the same inferred CLI
identity are combined per bucket across raw, minute, and hour tiers. The exact
identity predicate and examples are defined in [App identity for versioned CLI
executables](#app-identity-for-versioned-cli-executables-current).

### Storage budget (current estimates)

QA observed about 2.23 million raw process rows/day on Apple silicon and about
1.78 million/day on Intel at five-second writes. Six-tick coalescing reduces
these to approximately 372,000 and 297,000 process rows/day. With the default
seven-day raw retention, that is about 2.60 million / 2.08 million retained
process rows before indexes and bucket, minute, and hour tiers. The W14 storage
report measures a 54.23-byte average with the raw columns and timestamp index:
about 20.2 MB/day and 141.1 MB for seven days on Apple silicon, and 16.1
MB/day / 112.6 MB for seven days on Intel. Actual size varies with process
count, values, indexes, WAL activity, and page reuse. Thirty-day raw retention
can exceed the default budget by design. These are raw-tier estimates, not a
total-database size cap: `BatteryStatus` is sampled every 30 seconds and is not
currently pruned, while hourly rollups are retained indefinitely. The raw tier
can reach a bounded seven-day row count even as the whole database continues to
grow slowly.

## Permissions Model

| Capability | API | Privilege | Sandbox-compatible |
|-----------|-----|-----------|-------------------|
| Per-process CPU / energy / IO | `proc_pid_rusage` | None (own UID) | No (sandbox blocks `proc_*` for other-UID processes) |
| Battery state | `IOPMPowerSource` | None | Yes |
| Bundle identifiers | `NSWorkspace.runningApplications` | None | Yes |
| System sleep/wake events | `NSWorkspace` notifications | None | Yes |
| Launch at login | `SMAppService.mainApp` | None | Yes |
| Current system hardware energy buckets | `IOReportHub` via `IOConnect` on all supported macOS versions | No root; private system interface | No (private API) |
| Planned per-PID GPU time refinement | `powermetrics --show-process-gpu` helper | **Root** | No |

Voltscope ships outside the App Store (Developer ID + notarization) because the per-process sampling does not survive the sandbox's `proc_listallpids` restrictions for other-UID processes. The optional, planned `powermetrics` helper also requires root, which is App Store–prohibited.

---

## Distribution

- **Build validation**: GitHub Actions runs pull requests and pushes to `main`.
  The latest stable Xcode arm64 job and the macOS 14 / macOS 15 Intel jobs are
  defined in [CONTRIBUTING.md](../CONTRIBUTING.md).
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

## Performance and self-cost

| Operation | Frequency / workload | Evidence |
|-----------|----------------------|----------|
| Process scan | Every 5s | One scan per process tick |
| Battery snapshot | Every 30s | One snapshot per battery tick |
| App identity lookup during flush | Once per distinct app group in a window | `HistoryWriter.persistWindow` caches IDs within the flush |
| Window flush and 7-day chart query | Opt-in benchmark: 330 process rows per flush; 330 apps × 168 hourly rows queried | `SelfCostBenchmarkTests`; skipped unless `VOLTSCOPE_SELF_COST_BENCHMARK=1` |

The benchmark reports measured timings on the machine running it. No fixed
CPU percentage or per-operation latency is promised. The latest Xcode and
architecture CI matrix is maintained in [CONTRIBUTING.md](../CONTRIBUTING.md).

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
