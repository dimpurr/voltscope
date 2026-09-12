# Voltscope

> A native macOS battery and energy-history monitor inspired by iPhone Settings → Battery.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift)](https://swift.org)
[![CI](https://github.com/dimpurr/voltscope/actions/workflows/ci.yml/badge.svg)](https://github.com/dimpurr/voltscope/actions/workflows/ci.yml)

Voltscope records per-process energy attribution from `proc_pid_rusage`, stores
the history locally in SQLite, and presents it in a native SwiftUI interface.
It helps answer which processes kept using energy while you were away.

## Current status

**v0.7.2 — Battery History preview.** The History window includes a compact
0–100% battery trace, a range-aware stacked App CPU chart, and the original
Energy breakdown | Apps columns. Live / 1H / 24H / 7D is the single time
control; 7D uses four six-hour bars per day with daily axis labels.

App attribution is explicitly **CPU portion only**. It does not claim to divide
the whole device's battery drain among apps. The current artifact is Developer
ID signed but not notarized; the public download is available from the
[Voltscope website](https://voltscope.dimp.studio), and source releases are
tracked through [GitHub Releases](https://github.com/dimpurr/voltscope/releases).

## Build and run

Requires macOS 13+, Xcode 16+, and a Swift 6 toolchain.

```bash
swift build
swift test
./scripts/build-app.sh release
open build/Voltscope.app
```

The app requests no helper permissions in its current release and stores its
database at `~/Library/Application Support/Voltscope/db.sqlite`.

## Documents

| Document | Purpose |
| --- | --- |
| [docs/INDEX.md](docs/INDEX.md) | Documentation ownership and source-of-truth rules |
| [docs/VISION.md](docs/VISION.md) | Product intent, principles, and scope |
| [docs/HLD.md](docs/HLD.md) | Architecture, storage, sampling, and permissions |
| [docs/ENERGY_MODEL.md](docs/ENERGY_MODEL.md) | Energy units, attribution limits, and aggregation |
| [docs/UI_SPEC.md](docs/UI_SPEC.md) | Current interaction and layout contract |
| [RELEASE.md](RELEASE.md) | Website and GitHub dual-release procedure |
| [CHANGELOG.md](CHANGELOG.md) | User-visible release history |

## Scope and limitations

Voltscope reports energy use. It does not kill or suspend processes, limit
charging, dim the display, toggle radios, or sync history to a server. Hardware
channels are independent measurements and may overlap; they are not guaranteed
to sum to app battery drain.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md). Issues,
focused pull requests, documentation improvements, and macOS compatibility
reports are welcome.

## License

Voltscope is released under the [MIT License](LICENSE).
