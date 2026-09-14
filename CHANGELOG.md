# Changelog

## Unreleased

- Use a neutral system background for the `Open History` action instead of a
  tinted accent fill.
- Remove unnecessary ellipses from the menu bar action labels.
- Keep the first-run Welcome context visible while Login Items is open, refresh
  the status on return, and show a clear `Done` action after approval.

## 0.9.0 — 2026-09-12

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
