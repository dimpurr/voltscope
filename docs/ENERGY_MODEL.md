# Voltscope — Energy Attribution Model

> Current contract and future model for Voltscope's energy measurements. The v0.7.2 release reports recorded CPU attribution; the whole-device apportionment model remains planned.

---

## 1. The question Voltscope exists to answer

VISION.md, paragraph one: *"iOS users get a Settings → Battery view with a per-app stacked bar chart for the past 72 hours, attributing real joules to each bundle ID. Same hardware platform, same operating system family — the desktop never got the feature."*

Concretely: **a user looks at their MacBook battery, sees "88%", and wants to know how the missing 12% was spent — broken down by app, with percentages adding up to 100% of the actual drain.**

This is the user's literal question on 2026-05-13 after a 24-hour CSV export:

> "我现在电量是88%，那么这12%都花哪里了，哪些 app 百分多少"

The long-term product should answer this. v0.7.2 does not claim to do so — and
its CPU-only data source cannot do so by itself.

---

## 2. Why v0.5 cannot answer it

The v0.5 sampling architecture reads `proc_pid_rusage(RUSAGE_INFO_V6).ri_billed_energy` for every running process every 5 seconds. That field returns kernel-billed nanojoules **of the CPU portion attributed to that process**. The number is real, the granularity is per-process, the API is public — these properties are why we built on it.

But on a modern MacBook, **per-process CPU energy is only 1–3 % of total battery drain**. Empirical reconciliation from a real 24-hour export:

| Source | Joules over 24 h | % of 12 % battery drop |
|---|---|---|
| Voltscope sum of all `energyNJ` | **397 J** | ~1.3 % |
| Estimated 12 % of 70 Wh battery | ~30,240 J | 100 % |
| **Untracked gap** | **~29,840 J** | **~98.7 %** |

That ~98.7 % is real energy. It went to the display backlight, GPU/ANE/DRAM, Wi-Fi/BT/cellular radios, SoC static power, idle drain, sleep drain, kernel-mode work not attributed to any user PID, and so on. None of it appears in `ri_billed_energy`. So Voltscope can rank apps against each other on CPU usage, but it cannot put a percentage of *the actual battery* next to any app, which is what the user actually wants.

This is not a bug. It is an **architectural ceiling** of the chosen data source. Lifting the ceiling is a v0.6+ scope expansion.

---

## 3. General two-layer model

A whole-device history view needs two related measurements:

1. **Bucket layer** — measure energy consumed by hardware components such as the
   CPU, GPU, display, memory, and radios over time.
2. **Apportionment layer** — divide a bucket across processes using an explicit
   activity signal, such as CPU energy, foreground time, or network bytes.

The iPhone Battery screen is the product reference for the interaction model,
not a promise that every displayed number is directly metered. Voltscope keeps
that distinction visible: v0.7.2 reports measured per-process CPU energy, while
whole-device apportionment remains planned until each proxy and denominator is
validated.

A residual is always allowed. Hardware channels can overlap, and a process
proxy cannot explain every system or sleep cost. The UI must label unknown or
unattributed energy instead of silently turning an estimate into a measurement.

## 4. macOS API surface — what is reachable

| Signal | API | Public? | Root? | Per-process? |
|---|---|---|---|---|
| Total drain (V × A) | `IOPSCopyPowerSourcesInfo`, `IOPSGetProvidingPowerSourceType` | **Public** | No | No (system) |
| Per-PID CPU energy | `proc_pid_rusage(RUSAGE_INFO_V6).ri_billed_energy` | **Public** | No | **Yes** ✓ |
| Per-PID wakeups, QoS | `task_info(TASK_POWER_INFO)`; also in `rusage_info_v6` | **Public** | No | **Yes** |
| System component energy buckets — CPU-P / CPU-E / GPU / ANE / DRAM / Display / Fabric | **IOReport** framework — groups: `Energy Model`, `CPU Stats`, `GPU Stats`; channels: `PMP`, `DISP`/`DISPEXT`, `ANE`, `DCS`, `AMCC` | Private but no entitlement, no root, callable from user code via `dlopen` | **No** | No (system per bucket) |
| Display backlight power (M1–M4) | SMC key `PDBR` | Private but stable | No | No |
| Display backlight power (M5+) | SMC key `PBwo` | Private | No | No |
| Wi-Fi radio power | SMC key `wiPm`, IOReport `WiFi` | Private | No | No |
| Per-PID network bytes | `NetworkStatistics.framework` (`NStatManagerCreate`, `NStatSourceQueryDescriptor`) | Private but linkable | No | **Yes** |
| Foreground app, screen-on state | `NSWorkspace.frontmostApplication`, `IOPMAssertionCopyProperties`, `CGSessionCopyCurrentDictionary` | **Public** (foreground); semi-public (screen-on) | No | **Yes** (foreground) |
| Per-PID GPU **time** (not joules) | `powermetrics --show-process-gpu` (root only); `MTLCommandBuffer` GPU exec (in-app only) | Tooling only | **Yes** | Partial |
| Per-PID GPU **energy** | None public | — | — | — |
| Per-PID ANE energy | None | — | — | — |

### Interpretation

- **Bucket layer is achievable without root**, using IOReport (`Energy Model` group) plus a few SMC keys for display/Wi-Fi power. The HN reverse-engineering of Apple's GPU energy model (item 47388794) demonstrated <2 % error vs ground truth on M4 Max with no entitlement.
- **Apportionment layer is achievable without root** for everything except true per-PID GPU and ANE energy. Those two we **proportionally apportion** by CPU/foreground share — exactly what iOS itself does.
- **A privileged helper** (`SMAppService`, the modern replacement for `SMJobBless` planned in HLD v1.0) buys real per-PID GPU **time** via `powermetrics`, refining the GPU bucket apportionment from "proxy by CPU share" to "proxy by GPU ms/s share." Useful but optional. It does not enable any *new* bucket — only better attribution within an existing one.

## 5. Voltscope's target architecture

```
┌────────────────────────────────────────────────────────────────────┐
│                         Voltscope.app                              │
│                                                                    │
│  ┌──────────────────┐    ┌──────────────────────────────────────┐ │
│  │ Sampling layer   │    │           Apportionment layer        │ │
│  │                  │    │                                      │ │
│  │ ProcessSampler   ├──► │ CPU bucket  ÷  per-PID ri_billed_J  │ │
│  │  (rusage)        │    │ GPU bucket  ÷  per-PID GPU ms/s     │ │
│  │                  │    │              (or CPU share fallback) │ │
│  │ BucketSampler    │    │ Display bkt ÷  foreground app time   │ │
│  │  (IOReport+SMC)  ├──► │ Wi-Fi bkt   ÷  per-PID bytes         │ │
│  │                  │    │ ANE/DRAM/Fabric ÷ CPU share          │ │
│  │ NetworkSampler   │    │ Sleep bucket → "System (sleep)"      │ │
│  │  (NStatManager)  ├──► │ Residual    → "Other (untracked)"    │ │
│  │                  │    │                                      │ │
│  │ FocusTracker     │    │  ↓                                   │ │
│  │  (NSWorkspace)   ├──► │ AppEnergyAttribution table           │ │
│  │                  │    │  per-app per-bucket joules           │ │
│  └──────────────────┘    └──────────────────────────────────────┘ │
│                                       │                            │
│                                       ▼                            │
│                          ┌─────────────────────────────┐           │
│                          │ History UI                  │           │
│                          │   - "iOS Battery" stacked   │           │
│                          │     pie / bar (% of total)  │           │
│                          │   - per-app drilldown       │           │
│                          │   - bucket strip chart      │           │
│                          │   - Drain rate (W) live     │           │
│                          └─────────────────────────────┘           │
└────────────────────────────────────────────────────────────────────┘
```

### New tables (additive to v0.5 schema)

- **`SystemBuckets`** — `(timestamp, bucketName, joules)` — bucket sampler output. Bucket names: `cpu_p`, `cpu_e`, `gpu`, `ane`, `dram`, `fabric`, `display`, `wifi`, `bt`, `sleep`. ~10 buckets × 1 sample/5 s = ~170 KB/day.
- **`NetworkUsage`** — `(timestamp, pid, bundleIdentifier, bytesIn, bytesOut)` — per-PID byte deltas from `NStatManager`. Sample cadence 30 s.
- **`FocusIntervals`** — `(startTimestamp, endTimestamp, bundleIdentifier, screenWasOn)` — emit one row per focus change.
- **`AppEnergyAttribution`** — `(timestamp, bundleIdentifier, bucketName, joules)` — apportionment output, materialised by a periodic job. **This is the table the iOS-Battery view reads.**

### Schema reconciliation

The v0.5 `EnergyHistory` table stays as the raw per-PID CPU energy source. `AppEnergyAttribution` is **derived**, recomputed lazily for the visible window plus an aggregate-on-write background job for closed time buckets.

### Apportionment rules (v0.7 first cut)

| Bucket | Apportionment proxy | Notes |
|---|---|---|
| CPU (cpu_p + cpu_e) | per-PID `energyNJ` ratio within the same time bucket | Already accurate — direct measurement, just normalized to bucket total |
| GPU | per-PID GPU time if helper installed; else per-PID CPU energy ratio (proxy) | Honest fallback flagged in UI when helper absent |
| ANE | per-PID CPU energy ratio | No public per-PID accounting |
| DRAM, Fabric | per-PID CPU energy ratio | Memory-traffic accounting requires `PCMM`-class private interfaces; defer |
| Display | 100 % to the foreground app while screen-on; 0 % when locked/asleep | Standard iOS/Android apportionment |
| Wi-Fi | per-PID bytes ratio | Classic radio apportionment; tail-energy refinement deferred to v1.5 |
| BT, Cellular | per-PID bytes ratio | Same as Wi-Fi |
| Sleep | bucketed under literal "System (sleep)" attribution | Unattributable to any app; surfaced honestly |
| Residual / Other | total drain (V × A) − sum(buckets) | Always shown — never silently absorbed into another bucket |

### Honesty principle

The "iOS Battery" stacked view always shows an explicit **Other / Untracked** wedge for the residual between metered V × A drain and the sum of attributed buckets. This wedge will rarely be zero; pretending otherwise is the failure mode we refuse. iOS hides this wedge and silently apportions it to the largest-CPU app, which is a known accuracy compromise their UI quietly accepts. We won't.

---

## 5b. macOS 26 (Tahoe) IOReport.framework removal — implementation pivot

While prototyping v0.6 on macOS 26.3.1 we discovered that **`IOReport.framework` is no longer present** on disk and **no longer in the dyld shared cache**. Every dlopen variant fails with `not in dyld cache`. The implementation therefore uses the kernel-facing IOConnect path on systems where the wrapper is unavailable.

**What still works on macOS 26 (verified in-tree):**

| Component | Status |
|---|---|
| `IOReportFamily.kext` | ✅ Loaded; kernel-side reporter API unchanged |
| `IOServiceMatching("IOReportHub")` | ✅ Returns 1 service; can be opened via `IOServiceOpen` |
| `IOReportLegend` property on services | ✅ Readable via `IORegistryEntryCreateCFProperties` (5+ bearers found in the first IORegistry sweep) |
| `proc_pid_rusage(RUSAGE_INFO_V6).ri_billed_energy` | ✅ Per-process CPU energy (the v0.5 layer) |
| `IOPSCopyPowerSourcesInfo` (V × I integration) | ✅ Total drain denominator |
| `powermetrics` binary | ✅ Still ships at `/usr/bin/powermetrics`, still requires root |
| `PowerLog.framework` | ✅ Auto-loaded into every Swift process — symbols undocumented |

**What's gone:**

| Component | Status on macOS 26 |
|---|---|
| `IOReport.framework` (`/System/Library/PrivateFrameworks/IOReport.framework/IOReport`) | ❌ Removed; not in dyld cache |
| `IOReportCopyChannelsInGroup`, `IOReportCreateSubscription`, `IOReportSimpleGetIntegerValue`, `IOReportIterate` (the user-space wrappers) | ❌ Cannot be loaded by dlopen |
| Any new public replacement framework (EnergyKit, PowerKit, …) | ❌ None added in macOS 26.0–26.3 |

### The path forward — direct IOConnect

The framework was a thin user-space wrapper around an `IOReportHub` user client. The kernel mechanism is intact. Detailed protocol notes and exploratory measurements remain in the private maintainer archive.

The replacement architecture for macOS 26+:

1. **`IOServiceMatching("IOReportHub")` → `IOServiceOpen` → `io_connect_t`**
2. **`IOConnectCallStructMethod` with documented selectors:**
   - `kIOReportUserClientOpen = 0`
   - `kIOReportUserClientConfigureInterests = 2`
   - `kIOReportUserClientUpdateKernelBuffer = 3`
3. **`IOConnectMapMemory` to get the kernel sample buffer**
4. **Decode `IOReportChannel` / `IOReportChannelType` structs** (layouts in IOReport_decompile + Apple's open-source XNU)

Estimated effort: **1–2 weeks** to ship a stable subset (CPU/GPU/ANE/DRAM), gated to macOS 26+ at runtime; macOS 13–15 keeps using the existing `IOReport.framework` dlopen path.

### Design consequences

- The bucket layer can run without root on supported systems.
- The IOConnect path avoids depending on a removed user-space wrapper.
- A helper remains an optional refinement for true per-PID GPU time; it is not
  required for the default history view.

### v0.6 ship plan (delivered)

- v0.6 shipped: WAL fix, ⚡ W status bar, V × I total drain, Energy breakdown UI section, IOReport.framework path (works on macOS 13–15; falls through to v0.6.1's IOConnect path on macOS 26+).
- **v0.6.1 shipped**: direct IOConnect path against `IOReportHub`. Bypasses the missing `IOReport.framework` entirely. Verified end-to-end on macOS 26.3.1 / Apple Silicon M3 — 149 Energy Model channels enumerated, real per-channel cumulative joule counters returned.
- v0.7 ships apportionment as originally planned.

### v0.6.1 implementation record

The v0.6.1 implementation established the direct IOConnect path against
`IOReportHub` and returned real per-channel cumulative energy counters on
Apple Silicon. The shipped implementation is
`Sources/VoltscopeCore/Sampling/IOReportConnect.swift`. Detailed exploratory
measurements and abandoned struct-layout attempts remain in the private
maintainer archive; they are evidence, not part of this public contract.

What v0.6.1 delivers on a representative Apple Silicon sample window:

| Bucket | Reading | Notes |
|---|---|---|
| CPU | ~4.6 W | Performance + efficiency clusters summed |
| DRAM | ~440 mW | Memory subsystem |
| Fabric | ~310 mW | AMCC + DCS + MSR (memory cache controller, fabric) |
| Power Mgmt | ~210 mW | ECPM/PCPM (the cost of running power management itself) |
| SoC Other | ~180 mW | SOC_REST + SOC_AON unaccounted SoC |
| Camera | ~115 mW | ISP — Continuity Camera or other camera activity |
| GPU | ~65 mW | Idle GPU |
| Video | ~2 mW | AVE — video encoder largely idle |

Bucket name normalization in `BucketSampler.normalizeBucketName` collapses
raw channel names into user-facing categories while preserving the unaccounted
residual under “SoC Other”. This is distinct from the V×I “Other / Untracked”
value in the UI, which captures sleep, radios, and drain not explained by any
bucket.

## 6. Roadmap

| Version | Headline change | Scope |
|---|---|---|
| **v0.5.x** (shipped) | CPU per-app history with `proc_pid_rusage` | Stable. The CPU layer of the future architecture. |
| **v0.6** "Bucket honest (foundation)" | + WAL checkpoint storage fix <br> + V × I total-drain top line (⚡ W in status bar) <br> + Energy breakdown UI section + DB schema <br> + IOReport.framework dlopen path (works on macOS 13–15; gracefully reports unavailable on macOS 26+ per §5b) | Foundation ships with the bucket UI in place; bucket data populates on systems where the framework still loads. macOS 26+ users see the honest "working on it" notice. |
| **v0.6.1** "macOS 26 buckets" ✅ | + Direct IOConnect bucket sampler against `IOReportHub` (no framework dependency, no root). Verified end-to-end on macOS 26.3.1 M3. | Restores bucket data on macOS 26+. Both paths shipped: framework on macOS 13–15, IOConnect everywhere else. See §5b. |
| **Future v0.7+** "iOS Battery for macOS" | + `NStatManager` per-PID network <br> + `NSWorkspace` foreground-time tracker <br> + Apportionment engine writing `AppEnergyAttribution` <br> + New default panel mode: stacked pie / bar where percentages sum to 100 % of metered drain | Planned; not part of the v0.7.2 contract. |
| **v1.0** "Privileged helper" | + `SMAppService` helper running `powermetrics` for per-PID GPU ms/s <br> + Notarised, Developer-ID-signed release with Sparkle keys | GPU bucket gets real per-PID apportionment instead of CPU-share proxy. Helper is opt-in; v0.7 still works without it. |
| **v1.5** | Anomaly detection on bucket-attributed energy (per-app baseline ± 3σ) | Builds on v0.7's apportioned per-app values, not raw CPU. |
| **v2.0** | Tail-energy radio model; sleep-period drilldown; PDF/PNG export | Refinements per VISION. |

The original HLD planned `SystemPower` table and `SMAppService` helper for v1.0. v0.6 effectively **brings the system bucket measurement forward and removes its root requirement** by routing through IOReport instead of `powermetrics`. The helper still buys per-PID GPU but is no longer the gating dependency for the system-bucket view.

---

## 7. Storage budget revision

The v0.5 HLD claimed "~3 MB raw per day (30 processes × 17,280 samples × ~50 B/row)." Empirical measurement on a real machine writes **~400 MB to ~1 GB per day** because:

- `proc_listallpids` returns 300–500 processes on a typical machine, not 30.
- SQLite WAL writes amplify by ~2–3 × (WAL append + checkpoint rewrite).
- `ri_diskio_byteswritten` counted by the rusage of Voltscope itself further inflates the *reported* number by including mmap-backed cache writes against the WAL file (the on-disk file is smaller than the rusage figure suggests).

Fixes shipping with v0.6:

1. Drop zero-energy rows at insert time (most of the 500-process roster has `ri_billed_energy == 0` per sample).
2. Periodic SQLite `wal_checkpoint(TRUNCATE)` every 5 minutes to bound WAL growth.
3. Background compaction job: rows older than 24 h are aggregated to per-minute per-bundle rollups; rows older than 7 days to per-hour rollups. Drops storage to <50 MB per 30-day rolling window.
4. Add `SAMPLE_INTERVAL_SLEEP` — when `IOPMAssertion` says display is off and no AC is plugged, throttle to 30-s sampling.

Revised storage target: **<5 MB raw per day at active use, <50 MB lifetime for a 30-day rolling window after compaction.**

---

## 8. Public contract summary

| Capability | Current status |
|---|---|
| Per-process CPU energy in joules | Shipped and persisted locally |
| Multi-range history with stable time semantics | Shipped in v0.7.2 |
| System hardware buckets | Shipped where the platform exposes usable counters |
| Whole-device per-app battery percentages | Planned; not claimed by v0.7.2 |
| Residual / untracked energy | Kept explicit; never silently absorbed |
| Default install without root | Supported for the current sampling paths |

## Further reading

The implementation is based on public Apple platform APIs where available and
carefully isolated private system interfaces where the platform exposes no
public equivalent. The repository's private maintainer archive contains the
source notes and measurements behind those decisions.

## v0.7 implementation contract (supersedes earlier release promises)

The shipped chart remains recorded `ri_billed_energy` CPU attribution. It does not scale CPU shares to whole-device drain, nor claim that component channels are disjoint. Untracked device energy is unknown, not a computed wedge. All recorded app groups are retained before top-four presentation grouping. Percentages in the app list use the selected interval's recorded CPU total only.

Battery discharge integration requires both adjacent endpoints to be unplugged, non-charging, with nonpositive signed current and valid voltage. Gaps over 90 seconds and supply transitions are excluded; trapezoidal integration is clipped to the query bounds. This is observed discharge, not a full-window total. Sleep and missing coverage are not inferred. Hardware channels are displayed independently in joules without battery percentages or subtraction-based Other.

Network attribution, foreground tracking, cross-channel calibration and derived
whole-device AppEnergyAttribution remain planned. No schema migration is
required for v0.7.2's history queries.
