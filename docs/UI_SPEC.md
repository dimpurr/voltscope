# Voltscope — UI Specification

> Visual and interaction spec for the menubar dropdown and the History window. Companion to HLD.md and VISION.md.

---

## Status

| Surface | Spec version | Implementation |
|---|---|---|
| Menubar dropdown | v0.9.0 | v0.5.1 disclosure + v0.5.2 inline system process rows + v0.9 action hierarchy |
| History window | v0.8.1 | Battery-level trace plus range-aware stacked App CPU history, with the v0.6.2 chart-on-top and equal Energy breakdown ½ \| Apps ½ layout preserved; bundle icon uses the Battery scope mark |

The v0.5 history window shipped a SwiftUI Charts stacked **area** chart that aggregated by hour regardless of selected range — for a 1H view with 10 minutes of data this rendered as one solid color block with no time variance, indistinguishable from a bug. v0.5.1 fixes that and reframes the panel around the personas in VISION.md.

---

## Design Principles (UI layer)

These extend the project-wide principles in VISION.md:

1. **Verbose by default; structured.** Battery-monitoring users are technical. Hide nothing; group muted system processes so user-app attribution stays readable, but never drop a row.
2. **Empty state is a layout problem, not a copy problem.** A 30-second-old install should look like "I just installed this," not "no data yet" with placeholder text. Solved by axis design (full range domain, sparse bars naturally right-anchored) and a `Live` range that auto-fits to available data.
3. **Dropdown is glance; History is investigation.** Dropdown answers "what is happening right now"; History answers "what happened over time and which app caused it." Don't duplicate state-of-charge ring renderings between them.
4. **Chart form follows question.** Stacked **bars** per time bucket for "when did drain happen"; per-app sparklines for "is this app doing it constantly or in spikes"; status row for "now." Stacked area was the wrong primitive for the question being asked.
5. **Native, not novel.** SwiftUI Charts + standard `.toolbar` + `DisclosureGroup`. The app should feel like Apple shipped it — measure the Apple Settings → Battery app on iOS as the bar, not a custom design system.

---

## Menubar Dropdown

The v0.5 dropdown stays informational and compact. v0.5.1 adds two small enhancements:

```
┌──────────────────────────────────────────────┐
│ 🔋 On Battery                          78%   │
│ ████████████████████░░░░░  4h 40m until empty│
│                                Sampling ●   │
│ ──────────────────────────────────────────── │
│ Health                                 61%   │
│ ██████████████░░░░░░  ← green/orange         │
│ Cycles 292    Service Recommended            │
│ Temp   30.5 °C / 86.9 °F                     │
│ ──────────────────────────────────────────── │
│ Top energy use (last 30 min)                 │
│ ⬛ Ghostty                ●●●        →       │
│ ⬛ Voltscope              ●●○        →       │
│ ⬛ WPS Office             ●○○        →       │
│ ⬛ Spotlight              ●○○        →       │  ← hover any
│ ▸ System  (3 procs · 1.2 J)        [show]   │     row to see
│ ──────────────────────────────────────────── │     bundle ID
│ 📊 Open History   ⬇ Check Updates    ⏻ Quit  │     in tooltip
└──────────────────────────────────────────────┘
```

### v0.5.1 deltas (additive only)

| Change | Implementation | Why |
|---|---|---|
| Collapsible `▸ System (n procs · X J)` row at bottom of "Top energy use" list | Full-width row button with an explicit chevron, default collapsed | System helpers (`mdworker_shared`, Apple background services) crowded the user app list; geek users still want them on demand |
| Hover tooltip on each app row showing bundle ID + last-24h total | SwiftUI `.help(_:)` | Replaces a planned secondary panel; cheaper visually and cheaper to build |

### v0.6.2 layout (history window — superseded by v0.7)

```
┌─ Voltscope History ─── [Live  1H  24H  7D]  [⚙]  [⬆ Export as CSV] ─┐
│ 🔋 55% · ❤ 81% · 🌡 30°C · ⏳ 2h 40m · ⚡ 7.0 W                     │ ← status bar
├──────────────────────────────────────────────────────────────────── │   (pinned)
│                                                                    │
│ App attribution (CPU portion only) · 25.7 J across 57 · top: Tg…  │ ← single-line
│ ┌────────────────────────────────────────────────────────────────┐ │   ribbon
│ │  [stacked bar chart — full width]                              │ │
│ │                                                                │ │
│ └────────────────────────────────────────────────────────────────┘ │
│ ─────────────────────────────────────────────────────────────────  │
│ ┌──── Energy breakdown ────┬──── Apps  sort: total ▾ ──────────┐ │
│ │ · total 12,740 J         │                                   │ │
│ │ 🟦 CPU    ███ 59% 7518J  │ 🟦 Telegram      17 J  63% ▆█    │ │
│ │ 🟫 DRAM    █   6%  761J  │ ⬜ Voltscope    3.8 J  14% ▃▃    │ │
│ │ 🟢 Fabric  ▌   4%  515J  │ 🟥 YouTube     0.77 J   3% ▁▂    │ │
│ │ 🟪 PowMgmt ▌   3%  397J  │ ⚙ Settings    0.67 J   2% ▁▁    │ │
│ │ ⬜ SoC Othr▌   2%  305J  │ 💬 Messages   0.21 J  <1% –     │ │
│ │ 🟪 GPU     ▌   2%  249J  │ ...                              │ │
│ │ 🟡 Camera  ▌   2%  193J  │ ▾ System (41 procs · 4.5 J · 16%)│ │
│ │ 🟥 Video   ▌  <1% 3.55J  │                                  │ │
│ │ 🟥 ANE     ·  <1% 0.12J  │                                  │ │
│ │ ⬜ Other   ███ 22% 2797J │                                  │ │
│ └──────────────────────────┴──────────────────────────────────┘ │
│                                                                  │
│  ↑ HStack inside outer ScrollView; both columns share the scroll │
│    so they grow to natural height and the longer column drives   │
│    the total scroll length.                                      │
└──────────────────────────────────────────────────────────────────┘
```

| Element | Notes |
|---|---|
| Layout shape | 品字形 — chart on top full width, two columns of equal width below |
| Window min width | 900 pt — below this, columns compress sparklines uncomfortably |
| Adaptive narrowing | Not in v0.6.2. Single-column fallback for `width < ~700pt` is parked for v0.7 (`L8` in the brainstorm) |
| Scroll model | Single outer ScrollView wraps chart + columns. Two columns share that scroll; their heights are independent (the longer one drives total length) |
| Apps summary | Single-line ribbon above chart instead of two-line block — saves ~20pt vertical the columns get to use |
| Status bar | Pinned outside the ScrollView; always visible |
| Toolbar | Range / Display menu / Export — unchanged |
| What it solves | The v0.6/v0.6.1 issue where each row used ~30 % of a wide window's width and left a huge horizontal gap. Halving the per-row width snaps everything tight |

### v0.6 layout (history window — superseded by v0.6.2)

```
┌── Voltscope History ─── [Live  1H  24H  7D]  [⚙ Display]  [⬆ Export as CSV]
│
│ 🔋 83% · ❤ 64% · 🌡 30°C · ⏳ 6h 18m · ⚡ 4.2 W              ← drain pill new
│ ─────────────────────────────────────────────────────────
│ Energy breakdown · total 30,240 J                            ← NEW v0.6 section
│   Display 47% ███████████████░  14,200 J  ▂▃▅█▇▆
│   CPU     15% █████░░░░░░░░░░░   4,500 J  ▁▂▃▄▅▆
│   GPU     11% ████░░░░░░░░░░░░   3,300 J  ▁▁▂▂▃▄
│   …
│   Other (untracked · sleep · radios · residual) 23%  7,040 J ← honest wedge
│ ─────────────────────────────────────────────────────────
│ App attribution (CPU portion only)                           ← relabeled
│   24h · 437.8 J across 117 apps · top: 搜狗输入法 (33%)
│   [stacked bar chart — unchanged]
│   [apps list — unchanged]
└──────────────────────────────────────────────────────────────
```

| Element | Notes |
|---|---|
| `⚡ X.X W` pill | Latest BatterySnapshot's V × |I| (absolute). Yellow on battery, green on AC/charging. Tooltip explains the reading per power state. |
| Energy breakdown section | Each row uses the same horizontal rhythm as `AppRow` (icon + name + percentage bar + joules + percent + sparkline). Bucket colors deterministic per `bucketName` so they don't reshuffle. |
| Total denominator | `totalDrainJ` integrated from per-snapshot V × |I|, not from bucket sum. Used so the "Other / Untracked" wedge is honest — it represents real metered drain we haven't (yet) attributed to a bucket. |
| "Other" row | Always shown when non-zero. Subtitle "untracked · sleep · radios · residual" sets expectations. Has a percentage bar but no sparkline (no per-bucket time series for residual). |
| App section relabel | Title now reads `App attribution (CPU portion only)` to make the scope explicit ahead of v0.7's apportionment work. |
| macOS 26 fallback | v0.6 used to render an inline "Hardware buckets unavailable on macOS 26+ (working on it)" notice when the framework was missing. v0.6.1 ships the IOConnect path, so that notice is gone — buckets populate on macOS 26+ from the kernel IOReportHub directly. The fallback still exists for the unlikely case the kernel returns no Energy Model channels at all. |

### v0.5.2 deltas

| Change | Implementation | Why |
|---|---|---|
| When the System disclosure is expanded, render the top 5 system processes inline using the same row layout as the user app section, styled muted (0.7 opacity) | `ForEach` over `SystemAppSummary.topItems`; `+ N more in History` hint when more exist | The v0.5.1 expansion only showed a "open History" sentence — the disclosure had no actual content, defeating its purpose. Symmetry with the user app section makes the dropdown predictable |

### Out of scope for dropdown (deliberate)

- Sliding secondary panel for voltage / amperage / cell breakdown — overkill; tooltip carries the equivalent weight without animation
- Click-to-expand inline drill-down — drill-down lives in the History window (one place is enough)
- Quit-app affordance — VISION rule "report not control"

---

## History Window

Three vertical sections: status bar, main chart, app breakdown list. Toolbar holds the time-range selector and Export.

```
┌── Voltscope History ─────── [Live  1H ▾  24H  7D]  ⬆ Export CSV  ──┐
│                                                                    │
│ 🔋 78%  ↘ 0.3%/h     ❤ 61%  Service Rec.    🌡 30.5 °C    ⏳ 4h 40m │
│                                                                    │
│ ──────────────────────────────────────────────────────────────────│
│ 24 h · 247 J across 14 apps · top: Chrome 38%   [✓] Group system  │
│                                                                    │
│  J ┤                                          ▄▄                  │
│  4 ┤                                      ▄▄  ██  ▆▆              │
│  3 ┤                                  ▄▄  ██  ██  ██              │  stacked
│  2 ┤                              ▄▄  ██  ██  ██  ██              │  bars per
│  1 ┤                          ▄▄  ██  ██  ██  ██  ▇▇              │  time bucket
│  0 ┴───────────────────────────────────────────────────            │
│     16   18   20   22   00   02   04   06   08   10   12          │
│                              ⚡plug          💤sleep                │
│                                              ↑ install ─ ─ ─       │
│                                                                    │
│ ── Apps ─────────────────────────────────────── sort: total ▾ ────│
│ 🟧 Chrome              94 J  38%  ▂▃▅█▇▆▄▃▂  ▸                    │  user apps
│ 🟪 Voltscope           42 J  17%  ▁▂▃▄▅▆▆▆▆  ▸                    │  full color
│ 🟥 Ghostty             31 J  13%  ▁▁▂▂▃▄▆▅▃  ▸                    │
│ 🟦 Slack               12 J   5%  ▁▂▂▃▂▁▁▁▁  ▸                    │
│                                                                    │
│ ▾ System  (8 procs · 68 J · 27%)                                  │  collapsible
│ · WindowServer         28 J  11%  ▂▃▃▃▄▃▃▃▂  ▸                    │  muted gray
│ · mdworker_shared      18 J   7%  ▁▁▂▂▃▂▁▁▁  ▸                    │
│ · ThemeWidget…         12 J   5%  ▁▁▁▁▂▂▁▁▁  ▸                    │
│ · ... (5 more)                                                    │
└────────────────────────────────────────────────────────────────────┘
```

### Section 1 — Status bar (top, ~40 pt tall)

Single horizontal row, no decoration. Shows current charge %, charge trend arrow (`↗ / → / ↘` based on slope of last 30 minutes of `BatteryStatus`), health %, classified condition word, temperature (Celsius), time-to-empty / time-to-full.

Rationale: gives the historical chart a "current state" anchor without re-drawing the dropdown's rings (avoiding duplication; principle 3). Single-row layout keeps it under the title bar without competing visually with the chart.

### Section 2 — Main stacked-bar chart

| Property | Value | Why |
|---|---|---|
| Mark type | `BarMark` per (bucket, app) | Bars communicate "drain happened in this hour"; an area mark cannot |
| Bucket size | Range / ~30 buckets — exact widths in the generated range table under [Range selector](#range-selector) | Constant visual density across ranges |
| Bucket query | `(timestamp / bucketMs) * bucketMs AS bucketStart`, GROUP BY | Pushed into SQL; client receives pre-bucketed points |
| X-axis domain | Locked to full requested range via `chartXScale(domain:)` | Makes sparse data right-anchor naturally — a 10-min-old install on the 24H view shows one bar at the right edge, not a stretched mega-bar |
| App color slot | Top-N user apps colored per palette; system-classified rows muted gray when `Group system` is on | Verbose-by-default principle: still rendered, just demoted |
| Event markers | `RuleMark` for `'plug'`/`'unplug'` events; `'sleep'`/`'wake'` rendered as paired markers | Plug/sleep context is the answer to "why did drain spike here" |
| Hover behavior | `chartOverlay` + `DragGesture` → tooltip showing bucket time + per-app breakdown | Keeps detail contextual without adding another panel |
| Legend | Inline, top-right above chart, max 6 user apps + "System" + "Other" | Avoids the 6-row legend pollution v0.5 had |
| Empty-bucket rendering | Bars naturally absent | No placeholder text — axis design carries the "I just installed" story |

### Section 3 — App breakdown list

Per-app row: icon · name · total joules · % of range total · personal sparkline · disclosure chevron.

| Property | Value | Why |
|---|---|---|
| Sort | Default by total energy descending | "What used the most" is the primary question |
| User apps section | Full color, app icons, top of list | Primary persona's attention belongs here |
| `▾ System (n procs · X J · %)` | Collapsible group at bottom; expanded contents muted gray, no icons | Verbose retention without crowding |
| Sparkline | Per-app energy across the same time buckets as main chart, mini SwiftUI `Chart` ~80 pt wide | Tells the "constant vs spiky" story per row |
| Row chevron `▸` | Inline `DisclosureGroup` expansion | Defers full per-app drill-down to v1.5 (master-detail in own view); v0.5.1 expansion shows bundle ID, path, first/last seen |

### Range selector

The range names, windows, bucket widths, and labels are defined once in code
(`HistoryRange` in VoltscopeCore) and the table below is rendered from
`HistoryRange.allCases`. `HistoryRangeDocsTests.testGeneratedTableMatchesUISpec`
fails if this table drifts from the code
([test: HistoryRangeDocsTests.testGeneratedTableMatchesUISpec]).

<!-- generated:history-ranges:start -->
| Range | Window | Bucket width | Label |
| --- | --- | --- | --- |
| Live | 30 minutes | 30 s | 30 seconds |
| 1H | 1 hour | 120 s | 2 minutes |
| 6H | 6 hours | 600 s | 10 minutes |
| 24H | 24 hours | 1800 s | 30 minutes |
| 7D | 7 days | 21600 s | 6 hours · UTC |
<!-- generated:history-ranges:end -->

- **Live** — auto-fits the x-axis to the longer of (the Live window from the table above, time since first sample). This is the default for installs younger than 1 hour. It is what the chart "should" look like for new users without resorting to placeholder copy.
- **Fixed ranges** — x-axis locked to the full window even when data is sparse; 6H uses hourly labels so it gives a useful near-term detail view without the density of Live.
- After 1 h of accumulated data, the default range becomes `1H`. After 24 h, `24H`. The user's manual range selection is remembered and overrides the automatic default.

### Toolbar

| Item | Placement | Notes |
|---|---|---|
| Range picker (segmented) | `.principal` | Options, windows, and bucket widths are the generated table under [Range selector](#range-selector) |
| `Display` Menu (`slider.horizontal.3`) | `.principal` (right of picker) | macOS "View Options" idiom — opens a menu with checkmark items. Currently holds `Group system processes`; future toggles (event markers, sparkline visibility, top-N count) extend here without burning toolbar real estate. *Replaces v0.5.1's label-less Toggle.* |
| `Export as CSV…` | `.primaryAction` | Format named in the button so users know the output type before clicking. The save panel title also reads `Export Energy History as CSV`. While writing, the action becomes `Cancel Export`; a failed or cancelled write removes its incomplete file. |

### Accessibility identifiers

Accessibility identifiers are stable interface names for assistive technology
and UI automation. Keep identifiers in English, preserve their spelling across
releases, and update tests and automation clients deliberately when a change is
unavoidable. Labels describe the current control in plain language; dynamic
values such as charge percentage and charging state remain in the spoken label.
Decorative symbols and progress decoration are hidden from the accessibility
tree when their information is already expressed in text.

The current menu, History, Settings, and Welcome identifiers are declared in
`AccessibilityIdentifiers` and are covered by `AccessibilityIdentifierTests`.
Their public English values and controls are:

| Identifier | Control |
|---|---|
| `menu.barItem` | Menu bar item label |
| `menu.openHistory` | Menu bar Open History action |
| `menu.settings` | Menu bar Settings action |
| `menu.checkForUpdates` | Menu bar Check for Updates action |
| `menu.quit` | Menu bar Quit action |
| `menu.systemProcesses` | Menu bar System processes disclosure row |
| `menu.openAppInHistory.<app-identity>` | Per-app menu row action; `<app-identity>` is the bundle identifier, or the process name when no bundle identifier is available |
| `history.timeRange` | History time-range picker |
| `history.displayOptions` | History Display options menu |
| `history.groupSystemProcesses` | Group system processes menu item |
| `history.exportCSV` | Export as CSV action |
| `history.clearAppSelection` | Clear selected app action |
| `history.systemProcesses` | System processes row in the History app breakdown |
| `history.chartBattery` | History battery level chart |
| `history.chartEnergy` | History app CPU energy stacked chart |
| `history.statusCharge` | History status bar battery charge block |
| `history.statusHealth` | History status bar battery health block |
| `history.statusTemp` | History status bar battery temperature block |
| `history.statusTime` | History status bar battery time remaining block |
| `history.statusDrain` | History status bar battery power and drain block |
| `history.appRow.<app-identity>` | Per-app row in History app breakdown; `<app-identity>` is the bundle identifier, or the process name when no bundle identifier is available |
| `settings.launchAtLogin` | Launch at login toggle |
| `settings.openLoginItems` | Open Login Items action |
| `settings.rawRetention` | Raw detail retention period picker |
| `settings.deleteLegacyDatabase` | Delete old database action |
| `welcome.notNow` | Welcome onboarding Not Now button |
| `welcome.done` | Welcome onboarding Done button |
| `welcome.openLoginItems` | Welcome onboarding Open Login Items button |
| `welcome.enableAtLogin` | Welcome onboarding Enable at Login button |

Menu bar panel app rows are exposed as accessible containers that speak
recorded CPU energy in joules on Apple Silicon or CPU seconds on Intel,
providing an accessible action to open History. Keyboard shortcuts
(`Cmd+H` for History, `Cmd+,` for Settings, `Cmd+Q` for Quit, and `Esc` to
dismiss) are supported. The Settings window is scrollable to accommodate
large dynamic text sizes, supports `Esc` to dismiss, and requires
confirmation before deleting legacy database files. CSV export errors display
an alert prompt rather than failing silently.

The History status bar's battery power value keeps its state-specific qualifier
available both as hover help and as the combined accessibility element's hint.
The qualifier distinguishes charging flow, battery discharge, and battery
current while connected to AC; it does not describe total system or adapter
power. In light mode, the discharging indicator uses an adaptive amber color to
meet WCAG contrast requirements.

History charts provide full assistive technology coverage: the battery chart
describes charging intervals and sleep periods in its Audio Graph and VoiceOver
summary, and visual axis labels are hidden to avoid redundant spoken numbers.
The App CPU energy chart supports keyboard-based slice scrubbing via arrow keys,
legend buttons announce highlighted status, and legacy bucket intervals include
dashed boundary indicators. Hardware breakdown rows group channel metrics into
single VoiceOver elements expressing relative magnitudes of the largest hardware
channel, and app breakdown rows support keyboard selection with chart highlight
synchronization.

### Chart hover behavior (v0.5.2)

Stacked bars are colored by app via `foregroundStyle(by:)`, which makes glance-interpretation hard once more than three apps are present — the legend becomes a memory-aid lookup table. Keep the hover detail contextual to the selected bucket:

| Element | Behavior |
|---|---|
| Crosshair | A faint vertical `RuleMark` at the hovered bucket's start time |
| Tooltip card | Floating annotation at the top of the crosshair: bucket time range header, then per-app rows sorted by descending energy (system rows muted), with a Total at the bottom |
| Snap-to-bucket | Pointer date is mapped to the nearest *existing* bucket within ±`bucketSeconds`; outside that, the tooltip hides — never show a tooltip over empty axis |
| Pointer detection | `.chartOverlay { proxy in GeometryReader { ... .onContinuousHover ... } }`, computing plot-local x via `proxy.plotAreaFrame` and `proxy.value(atX:)` |
| Color matching | The card renders a 7 pt color swatch next to each app row matching the chart bar's color. We own the color scale via an explicit `chartForegroundStyleScale(domain:range:)` mapping (added in v0.5.2 patch to fix hover-induced color reshuffling), so the swatch and bar always agree |
| Container | The card is rendered inside `.chartOverlay`'s overlay layer (not a `RuleMark.annotation`) and positioned manually with `proxy.position(forX:)` clamped to the plot frame. The earlier annotation-based card caused SwiftUI Charts to compress the plot area and rescale the Y axis (75 J → 400 J) on every hover; manual placement avoids that entirely |
| Performance | The card is recomputed on every hover sample but only re-renders when the snapped bucket actually changes (state binding); ~30 buckets × ~8 apps is trivial

### Removals

- The v0.5 separate `BatteryLevelChart` (line chart of battery % over time) is removed. The current charge % is in the status bar; charge trend is the arrow next to it; charge events are markers on the main chart. This consolidates rather than duplicates.

---

## Process Classification

The current user-app and system-process classification follows the identity
resolution contract in [HLD: versioned CLI executables](HLD.md#app-identity-for-versioned-cli-executables-current).
That contract supersedes the early v0.5.1 heuristic described in this section's
history.

---

## Future iterations parked here

These were considered for v0.5.1 and consciously deferred:

| Idea | Defer to | Reason |
|---|---|---|
| Master-detail per-app drill window (selecting an app row opens a dedicated detail view) | v1.5 | Inline `DisclosureGroup` carries the v0.5.1 weight; full drill needs baseline data (v1.5) to be meaningful |
| Anomaly callouts on the chart ("Telegram drew 4× baseline at 03:14") | v1.5 | Requires `EnergyBaseline` table |
| Sleep-period drill-down view (per-app energy *while you were asleep*) | v1.0 | Sleep-pair detection is non-trivial; deserves its own design pass |
| Comparison overlays (e.g. today vs yesterday) | v2.0 | Adds chart complexity; only worthwhile after the single-day view is loved |
| Sliding secondary panel in dropdown | rejected | Tooltip carries the same information at lower cost |

## v0.8 — Battery History (shipped; current for v0.8.x)

This section supersedes all earlier History layout, chart, removal and legend rules above, including the removal of BatteryLevelChart. Menubar behavior remains independent. The v0.7.1 patch defines the window lifecycle: History uses a regular activation policy and appears in the Dock while open; closing it returns to accessory mode without terminating sampling. The v0.7.2 patch adds the dedicated blue-to-teal Battery scope bundle icon. The v0.8.0 feature release adds the 6H range.

- Compact battery history plot (80 pt), fixed 0–100% scale; a larger app CPU energy plot (200 pt); both share time bounds and plot insets.
- CPU energy uses real vertical stacks: bar height is recorded energy, colors indicate contributions. Four leading identities for the full window, System and Other apps preserve all recorded contributions. No fabricated whole-battery attribution or 100% normalization.
- Stable app colors follow bundle identity, or the conservative versioned-CLI
  identity rule in [HLD](HLD.md#app-identity-for-versioned-cli-executables-current)
  when no bundle ID is available. Matching CLI processes appear as user apps;
  other bundle-less process names stay separate and system-classified.
- The existing top range picker (see [Range selector](#range-selector)) is the only time filter. Both charts, the bottom Energy breakdown / Apps columns, and CSV export use the selected range. Hover reads a bucket; selecting an app or legend item only dims other series and never changes the range.
- Battery charging uses a green status band; sleep uses a separate muted band. Missing battery observations break the trace. No emoji event rules through the energy plot.
- Ranges use UTC-aligned buckets sized per the [generated range table](#range-selector). Edge buckets are partial and identified as such. Energy is shown in J for this CPU-only release.
- CSV exports raw process rows within the selected range and available raw
  retention window. Window formation and query-tier details are owned by
  [HLD](HLD.md#tiered-history-tables-current). The ordered public columns are
  `timestamp_ms`, `iso8601`, `pid`, `parent_pid`, `bundle_id`, `app_name`,
  `app_path`, `cpu_ns`, `energy_nj`, `wakeups`, `disk_read_bytes`,
  `disk_write_bytes`, and `metric_version`.
- The original v0.6.2 full-width chart plus equal bottom columns are preserved. Hardware measurements remain in the left Energy breakdown column and are independent of App CPU totals.
- History is a normal Dock-visible document while its window is open. Closing
  the window returns Voltscope to accessory mode; it does not terminate the
  menubar sampler or database process.
- Keyboard-accessible interval and app selection, accessible labels, compact legends, visible query errors and clear empty states.
- VoiceOver chart summaries and audio graph descriptors expose the selected time range, minimum, maximum, latest observed value, units and named data series for the battery level and App CPU charts. Apps-column rows announce recorded CPU attribution and their observed trend; missing intervals are described as no data and are never interpolated. Older metric-version buckets are identified separately and never combined with current readings. App attribution wording remains limited to recorded per-app CPU energy and does not describe whole-device battery drain allocation.

The wider per-device apportionment model remains future work. v0.8 ships the Battery interaction model with explicit CPU-only attribution and the ranges defined by `HistoryRange`.

## v0.9.0 — Startup, Login Item, and Settings (current)

This section is the current contract for startup and app configuration. It
supersedes the earlier dropdown footer sketch and any earlier suggestion that
Settings belongs in the History window's `Display` menu. The v0.8 History
section above remains current for History content and range behavior.

### Menubar dropdown actions

The dropdown is approximately 340 pt wide and about 428 to 434 pt tall at its
normal content size. `Open History` is a full-width primary row with a neutral
system background, a chart icon, and an optional trailing open-window icon. It
appears below the informational content and above a secondary row. The
secondary row keeps `Settings`, `Check for Updates vX.Y.Z`, and `Quit` together in one
horizontal row. Labels remain fully readable at the fixed width.

The `System` summary row is one full-width hit target, including its text,
summary, icon, and whitespace; only the row toggles expansion. When expanded,
the inline system process list sits in a scroll region capped at approximately
540 pt, while the footer actions remain visible below it. The collapsed panel
keeps its normal compact intrinsic height.

`Settings` opens the dedicated Voltscope Settings window. `Display` in the History
toolbar remains display-only and currently contains `Group system processes`.
Settings is not placed in that menu.

### Settings window

Settings is a native macOS window with no sidebar. General contains app startup and local history controls:

- `Launch at login`
- `Start Voltscope in the menu bar when you sign in.`

The toggle reflects `SMAppService.mainApp.status`, not a persisted Boolean.
When macOS reports `requiresApproval`, Settings shows an `Open Login Items`
button. `notFound`, registration errors, and unavailable installation paths
show concise, actionable feedback.

### First-run Welcome window

On the first normal app launch, before the first sample is available, Voltscope
may show a separate Welcome window. Sampling initialization and this window
start independently. The window uses this copy:

- Title: `Welcome to Voltscope`
- Headline: `Keep your energy history complete`
- Explanation: Voltscope records energy only while it is running. Enabling
  Launch at login keeps history continuous. The choice can be changed later
  in Settings.
- Actions: `Not Now` and `Enable at Login`

Closing the window or pressing Escape has the same effect as `Not Now`. The
choice is recorded once in a UserDefaults onboarding marker. That marker does
not store the toggle value. If registration reaches `requiresApproval`, the
primary action becomes `Open Login Items` and the window explains the next
step. Opening Login Items does not complete or dismiss Welcome: it remains as a
temporary floating context window while System Settings is open. When the user
returns to Voltscope, the login-item status is refreshed in place; an enabled
item changes the primary action to `Done`.

Normal login-item launches show only the menubar item. They do not open
Welcome or History and do not take focus. The startup decision uses the
onboarding marker together with `SMAppService.mainApp.status`; an enabled main
app login item always suppresses Welcome, including when the marker predates
the current build.

Login-item registration is offered only when the app bundle resolves inside
`/Applications` or the current user's `Applications` directory. DMG-mounted,
Downloads, build, and development paths are rejected with a prompt to move the
app before enabling the setting. No helper, daemon, or LaunchAgent is used.

### Window and Dock behavior

History, Settings, and Welcome are user-visible windows. While any of them is
visible Voltscope uses regular activation and can appear in the Dock. When the
last user-visible window closes, it returns to accessory activation. A login
launch with no visible window therefore remains accessory-only while sampling
continues.


## 0.10 — Tiered history presentation (current)

Current CPU energy remains the charted value. When an interval contains older
metric-version data, the corresponding chart buckets use an orange background
marker. Hover identifies those buckets as recorded with an older method. The
nearby note explains that earlier data used an older method and is not added to
current readings. The chart and hardware breakdown query current-version energy
by default.

On Intel Macs, app energy is unavailable. The app list and menu panel rank apps
by CPU time and show CPU time values; they do not show a zero-joule reading.
The underlying row behavior is described in
[HLD](HLD.md#tiered-history-tables-current). The History window states that
Intel Mac computers do not provide per-process energy data. After each process
scan, History can show how many system processes could not be read.

Settings includes raw-detail retention with 2, 7, 14, and 30 day choices
(default 7 days). It shows legacy import status and progress where available,
and the automatic deletion date after verification. `Delete old database now`
is enabled only after import verification is complete.
