# Changelog

## 0.10.3 — 2026-10-04

- Add accessibility label, value, and stable identifier to the menu bar status item.
- Speak recorded CPU energy in Joules (or CPU seconds on Intel) for menu bar panel app rows, group rows as accessible containers, and provide an action to open History.
- Hide decorative app icons and battery health bar progress visuals from the accessibility tree to eliminate duplicate VoiceOver speech.
- Add keyboard shortcuts (`Cmd+H`, `Cmd+,`, `Cmd+Q`, `Esc`) to the menu bar panel and Settings window.
- Respect `reduceMotion` accessibility setting when expanding system processes in the menu bar panel.
- Increase contrast and support high contrast outline mode for `IntensityDots`.
- Provide customizable summaries and accessibility hiding on `SparklineMini`.
- Add confirmation dialog and destructive action styling for manual legacy database deletion in Settings.
- Make the Settings window scrollable and flexibly sized to prevent clipping under large dynamic text sizes.
- Label database migration progress and surface deletion errors in Settings.
- Add stable accessibility identifiers for onboarding action buttons in the Welcome window.
- Display an alert dialog on CSV export interval calculation failure instead of failing silently.
- Added standard application menu shortcuts for Settings (`Cmd+,`) and Open History (`Cmd+1`).
- Added accessibility announcements for History loading errors and resilient layout sizing for the time-range picker under enlarged text.
- Enhanced History status bar accessibility with stable identifiers.
- Enhanced Battery history chart accessibility: charging and sleep intervals are spoken in the VoiceOver summary with occurrence counts and totals clipped to the selected range, and the chart descriptor carries only real battery readings.
- Added keyboard-based time slice scrubbing to the App CPU energy chart using arrow keys; the inspected bucket's time and recorded CPU energy reading are spoken, distinguishing a bucket with no record from a zero-energy bucket. Legend items expose selection traits.
- Consolidated hardware breakdown rows into unified accessibility elements reporting channel magnitude relative to the largest hardware channel.
- Added per-app accessibility identifiers for rows in the History app breakdown list.

## 0.10.2 — 2026-10-04

- Label CSV group metadata as `app_name` and `app_path` so exports do not imply
  those values identify each PID's process.
- Repair hourly coverage totals when late or replacement coverage rows arrive
  after the hour rollup watermark.
- Exclude a partially overlapping left-edge hour from 7-day summaries after
  finer-grained rows expire, avoiding out-of-range energy in the result.
- Recheck process start time after identity lookup and discard snapshots if a
  PID was reused during the read.
- Preserve process counter deltas when a full history write queue rejects a
  sampling tick, and restrict rollups to indexed timestamp ranges after their
  watermarks.
- Preserve process and hardware counter deltas when a full history write queue
  rejects a sampling tick, and restrict rollups to indexed timestamp ranges
  after their watermarks.
- Anchor legacy raw import, verification, and source expiry to the persisted
  sleep-inclusive safe clock so wall-clock jumps cannot skip retained detail or
  remove the recovery database early.
- Persist completed source revisions and revalidate a completed legacy source
  once at its deletion deadline instead of rescanning it at every launch;
  imports completed by earlier versions stay complete.

## 0.10.1 — 2026-10-04

- Recheck the legacy SQLite source revision during import convergence so
  timestamp rollback commits are rescanned before completion.
- Bound revision-change verification retries to ten rounds per launch, and keep
  completed legacy imports verifiable when older records lack a raw cutoff.
- Limit CSV energy rows to the current metric version, matching chart totals.
- Refresh process identity metadata when `pbi_comm` changes, and read each
  process's current parent PID on every sampling tick.
- Persist partial history windows every 15 seconds and before sleep; retain failed
  window writes in a bounded FIFO for retry and cancel shutdown when the final
  flush fails. Preserve process counter baselines through up to two temporarily
  missed scans.
- Keep late samples visible after rollup watermarks advance, protect retention
  pruning from forward wall-clock jumps, advance retention across system sleep,
  re-anchor after reboot, and include the summarized left-edge hour in 7D
  history queries.
- Stream CSV exports through a bounded database cursor and fixed-size batches; exports can be cancelled and incomplete files are removed on failure.
- Added VoiceOver summaries and audio graph data descriptions for History battery and App CPU charts, and spoken CPU attribution values and trends in the Apps column. Missing intervals are announced as no data, and older metric versions remain identified separately.
- Reduce per-window history flush work by resolving each distinct app group once.
- Group bundle-less, version-named CLI processes only under
  `<name>/versions/<version>` paths. History queries also combine matching
  existing rows within each bucket without rewriting stored history.

## 0.10.0 — 2026-10-03

- Raw history and CSV now store one summed row per process/PID and UTC-aligned
  30-second window while sampling continues every five seconds. Minute summaries
  are retained for two days; hourly summaries remain permanent. Legacy imports
  use the same raw window size and minute retention.
- Added stable accessibility labels and identifiers for menu bar actions,
  History controls, and interactive Settings controls. Battery status values
  now have descriptive spoken labels for VoiceOver and UI automation. App-row
  History actions have per-app identifiers and labels that describe opening
  History from the row; the battery power qualifier is available as hover help
  and an accessibility hint.
- App energy now uses the per-task CPU energy counter. Values may be hundreds
  or thousands of times larger than older readings because the previous counter
  reported energy billed through a task bank rather than the task’s own energy.
- Older readings remain available with an orange chart marker and an
  explanation; the app never adds old and current metric versions together.
- CSV export now includes `cpu_ns` and `metric_version`, and uses one `cpu_ns`
  column instead of separate user and system CPU columns.
- New local history is written to `history.sqlite` with tiered summaries and
  configurable raw detail retention. Existing `db.sqlite` data is imported in
  the background, verified, and kept for seven days after completion before
  automatic deletion. Settings offers deletion after import completes.
- Intel Macs rank app activity by CPU time and explain that per-process energy
  data is unavailable.

## 0.9.1 — 2026-10-02

- Process samples that recorded no energy for the interval are no longer
  stored, so the database grows much more slowly over long runs.
- CSV export no longer includes zero-energy rows.
- Existing databases do not shrink in this version; storage compaction is
  planned for 0.10.0.
- Bundle metadata is 0.9.1 / build 10. This is a SemVer patch release because
  it fixes stored data volume without changing features.

## 0.9.0 — 2026-09-14

- Added a first-run Welcome window for keeping sampling continuous at login.
- Added native Settings with a `Launch at login` toggle backed by
  `SMAppService.mainApp`.
- Reworked the menu bar actions so `Open History` is the primary action and
  Settings, updates, and Quit remain readable secondary actions.
- Login-item registration now requires the app to be installed in an
  Applications directory and reports approval or registration errors clearly.
- Restored in-app update checks with a signed GitHub Releases appcast.
  Existing 0.8.1 builds remain on the legacy feed for the one-release
  migration path.
- Makes the entire `System` row tappable, keeps the footer visible while the
  expanded system list scrolls, and returns the Dock icon to accessory mode
  after the last Voltscope window closes.
- Shows the current app version beside `Check for Updates` and replaces the
  generic Sparkle error with a clear unavailable-service message.
- Makes the menu bar `Settings` action open the dedicated settings window
  reliably on macOS 13 and newer.
- Uses a neutral system background for `Open History`, removes unnecessary
  ellipses from menu actions, and keeps the first-run Welcome context visible
  while Login Items is open.
- Bundle metadata is 0.9.0 / build 9. This is a SemVer minor release because
  it adds backwards-compatible user-facing features.

## 0.8.1 — 2026-09-12

Prepared the first public universal2 distribution release.

- Ships one signed, notarized, and stapled DMG for Apple silicon and Intel Macs.
- Keeps the website DMG and GitHub Release asset byte-for-byte identical.
- Adds the maintained `dimpurr/homebrew-tap` installation path.
- Bundle metadata is 0.8.1 / build 8. This is a SemVer patch release.

## 0.8.0 — 2026-09-12

Added a focused six-hour history range.

- Added `6H` to the single top-level time picker between `1H` and `24H`.
- The 6H view queries ten-minute UTC-aligned buckets and uses hourly axis labels
  for a readable near-term view.
- Both charts, the Energy breakdown | Apps columns, refresh cadence, hover
  buckets, and CSV export follow the selected 6H range.
- Bundle metadata is 0.8.0 / build 7. This is a SemVer minor release because
  it adds a backwards-compatible user-facing range.

## 0.7.2 — 2026-09-12

Refined the Voltscope app icon.

- Added a macOS bundle icon with a blue-to-teal monitoring ring, green battery
  charge, graphite shell, and a larger yellow charging bolt.
- Added a reproducible SVG-to-ICNS generator so the icon can be updated without
  relying on a generated raster image.
- Bundle metadata is 0.7.2 / build 6. This is a SemVer patch release.

## 0.7.1 — 2026-09-12

Dock behavior follows the History window lifecycle.

- Opening History changes the app to a regular activation policy so Voltscope
  appears in the Dock while the dashboard is open.
- Closing the History window returns Voltscope to accessory mode. The menubar
  item, sampler, database, and update controller stay alive; closing the window
  never terminates the app.
- Bundle metadata is 0.7.1 / build 5. This is a SemVer patch release.

## 0.7.0 — 2026-09-12

Battery History redesign, preserving the v0.6.2 window structure.

- Added a compact 0–100% battery-level history graph above the App CPU attribution graph.
- Replaced floating marks with true stacked CPU-energy bars. App colors are stable by bundle identity; System and Other retain the long tail.
- The existing top `Live / 1H / 24H / 7D` range picker is the only time filter. Both graphs, the original Energy breakdown / Apps columns, and CSV export follow it.
- Kept the original shared outer scroll view and equal bottom columns. Hardware measurements remain an independent, expandable detail section.
- Added range, grouping, discharge-integration, stack-conservation, and export-bound tests.
- Reduced redraw work and changed row sparklines to lightweight canvas rendering. Refresh cadence is range-aware.
- 7D now uses four six-hour bars per day instead of one daily bar, preserving visible intraday peaks without changing the top-tab meaning.

This release reports recorded App CPU attribution. It does not claim to apportion whole-device battery drain to apps, and it is not notarized.

## 0.6.2 — 2026-09-11

Internal development checkpoint before the Battery History redesign. Existing code originated at `36213f9`; this checkpoint aligns bundle metadata with the documented UI version.

- Hardware energy sampling through IOReport / IOConnect, live battery status, app CPU history, CSV export, and development DMG packaging.
- Known issues: floating rather than stacked energy marks; hardware percentages use an incompatible denominator; battery integration can include charging; no linked battery history selection.
- Not a notarized public release. No historical release tags are reconstructed.

## Historical milestones — reconstructed from Git history

The project did not publish version tags for these early checkpoints. The
entries below preserve the implementation history without treating every
development commit as a public release.

### 0.6.1 development checkpoint — 2026-05-13

- Added a direct IOConnect sampler for system Energy Model channels on newer
  macOS versions.
- Kept the framework-backed path for systems where it remains available.
- Added hardware bucket presentation and availability handling to the history
  window.

### 0.6.0 development checkpoint — 2026-05-13

- Added hardware energy sampling, the energy breakdown section, and a live
  power indicator derived from voltage and current.
- Added database checkpointing and storage-budget work for long-running local
  history.
- Added explicit handling for unavailable system measurements.

### 0.5.2 development checkpoint — 2026-05-13

- Added chart hover details, display-state context, CSV export, stable app
  colors, and range-aware history presentation.
- Moved range controls into the window toolbar and kept the chart frame stable
  while resizing.

### 0.5.0 development checkpoint — 2026-05-02 to 2026-05-13

- Added bundle-level process aggregation, app breakdown rows, system grouping,
  sparklines, and the first menubar history window.
- Added Sparkle integration scaffolding and reproducible local app packaging.

### 0.1.0 development checkpoint — 2026-05-01 to 2026-05-02

- Added the first working sampler, SQLite persistence, battery status model,
  SwiftUI menubar shell, and unit-test scaffold.
- Established the initial product, architecture, and energy-model documents.

### Project baseline — 2026-05-01

- Created the repository, MIT license, initial design documents, and the
  zero-permission local-storage direction that still shapes the app.
