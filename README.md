# Voltscope

> A native macOS battery and energy-history monitor inspired by iPhone Settings → Battery.

[![Swift CI](https://github.com/dimpurr/voltscope/actions/workflows/ci.yml/badge.svg)](https://github.com/dimpurr/voltscope/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/dimpurr/voltscope)](https://github.com/dimpurr/voltscope/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/dimpurr/voltscope/total)](https://github.com/dimpurr/voltscope/releases)
[![License](https://img.shields.io/github/license/dimpurr/voltscope)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue?logo=apple)](https://www.apple.com/macos/)

Voltscope runs quietly in the menu bar and records which processes keep using
energy over time. Open History when you want a longer view: battery level,
stacked App CPU attribution, hardware energy buckets, and the Apps breakdown
share one time range.

![Voltscope History](docs/assets/voltscope-history.png)

## Download

**[Download the latest DMG](https://voltscope.dimp.studio/Voltscope.dmg)** ·
**[View GitHub Releases](https://github.com/dimpurr/voltscope/releases/latest)**

The official DMG currently targets Apple silicon and requires macOS 13 or
later. Intel Macs can build Voltscope from source until a universal release
artifact is published.

An official Homebrew Cask is not published yet; use the DMG above for the
current release.

The current artifact is Developer ID signed but not notarized. The SHA-256
checksum is recorded in the matching GitHub Release and in the private release
runbook. Do not describe this build as notarized.

## Getting started

1. Download and open `Voltscope-<version>-arm64.dmg`.
2. Drag `Voltscope.app` to `Applications` and open it.
3. Voltscope appears in the menu bar. Open its menu and choose **History**.
4. Leave it running while you work. The sampler stores observations locally.
5. Use **Live**, **1H**, **6H**, **24H**, or **7D** in the History toolbar. The
   battery chart, App CPU chart, bottom columns, hover details, and CSV export
   all follow that single range.

No account, helper service, or special permission is required by the current
release. The local database is stored at:

```text
~/Library/Application Support/Voltscope/db.sqlite
```

## What Voltscope measures

- **App attribution** is the CPU portion attributed to each process by
  `proc_pid_rusage`. It is not a claim that the entire battery drain can be
  divided among apps.
- **Battery level** is a separate 0–100% state-of-charge history with charging,
  sleep, and missing-observation context.
- **Hardware buckets** are independent system measurements. They may overlap
  and are not expected to sum to App CPU attribution.
- Data stays on the Mac. Voltscope has no telemetry, analytics, or remote crash
  reporting.

## Build from source

Requirements:

- macOS 13 or later
- Xcode 16.3+ or a compatible Swift 6.1+ toolchain

Clone the repository and run the tests:

```bash
git clone https://github.com/dimpurr/voltscope.git
cd voltscope
swift test -Xswiftc -swift-version -Xswiftc 5
```

The compatibility flag keeps Swift 6.1 builds working with GRDB's current
Dispatch annotations; newer Swift toolchains may also accept plain `swift test`.

Build and open a local app bundle:

```bash
./scripts/build-app.sh release
open build/Voltscope.app
```

Create a Developer ID signed DMG when a signing identity is available:

```bash
./scripts/build-dmg.sh --signed
```

The complete website/GitHub release, checksum, signing, and installation
procedure is documented in [RELEASE.md](RELEASE.md).

## Documentation

| Document | Purpose |
| --- | --- |
| [docs/INDEX.md](docs/INDEX.md) | Documentation ownership and source-of-truth rules |
| [docs/VISION.md](docs/VISION.md) | Product intent, principles, and scope |
| [docs/HLD.md](docs/HLD.md) | Architecture, persistence, sampling, and permissions |
| [docs/ENERGY_MODEL.md](docs/ENERGY_MODEL.md) | Energy units, denominators, intervals, and limits |
| [docs/UI_SPEC.md](docs/UI_SPEC.md) | Current interaction and layout contract |
| [CHANGELOG.md](CHANGELOG.md) | User-visible release history |
| [RELEASE.md](RELEASE.md) | Website and GitHub release procedure |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contribution expectations |

## Contributing

Issues, focused pull requests, documentation improvements, and macOS
compatibility reports are welcome. Read [AGENTS.md](AGENTS.md) before changing
code; it explains which document owns each decision and the checks expected for
a change.

Keep changes focused, run `git diff --check` and the test command above, and
update the owning specification and [CHANGELOG.md](CHANGELOG.md) when behavior
changes.

## License

Voltscope is released under the [MIT License](LICENSE).
