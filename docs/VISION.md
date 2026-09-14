# Voltscope vision

> A native macOS view of energy history that is as understandable as iPhone Settings → Battery.

## Mission

macOS users can see an instantaneous Energy Impact number, but they cannot
easily answer what kept using energy yesterday or overnight. Voltscope samples
the public process-energy APIs, stores the observations locally, and turns them
into a readable history.

## Principles

1. **Use measured data where the platform exposes it.** The current app reads
   `rusage_info_v6.ri_billed_energy`, the kernel-billed energy value available to
   each sampled process.
2. **Be honest about denominators.** The current App attribution view reports
   CPU energy only. It does not pretend to allocate every watt-hour of the
   machine to an app.
3. **History first.** The product is a local time-series database with a native
   interface, not a realtime widget that happens to draw a chart.
4. **Native macOS behavior.** Use SwiftUI, standard window and Dock behavior,
   and platform APIs instead of an embedded web dashboard.
5. **Privacy by construction.** Data stays in the user's application-support
   directory. Voltscope has no telemetry, analytics, or remote crash reporting.
6. **Report before it controls.** Voltscope explains energy use; it does not
   kill processes, cap charging, toggle radios, or alter the user's workflow.

## Current product shape

- A menubar item with battery state, power estimate, health information, and
  top current CPU-energy consumers.
- A History window modeled on iPhone Battery: battery-level trace, stacked App
  CPU history, range selection, and Energy breakdown | Apps summaries.
- A first-run Welcome prompt and an optional native main-app login item, with
  configuration in the standard macOS Settings window.
- Local SQLite persistence with CSV export.
- A zero-helper baseline that works without privileged installation.

## Deliberate limits

The current release does not provide whole-device per-app battery apportionment,
per-PID GPU energy, cloud history sync, charge limiting, process suspension, or
an App Store sandbox build. These may be investigated independently, but they
are not promises of the current product.

## Future direction

Future work may refine hardware channels, attribution proxies, anomaly
detection, accessibility, and release automation. Each proposal becomes part of
the product only after its measurement semantics, UI copy, tests, and migration
path are documented. Roadmap ideas are not current behavior.
