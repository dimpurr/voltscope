# Voltscope contributor guide

This is the public source repository for Voltscope, a native macOS battery and
energy-history monitor. Keep this file focused on durable engineering rules;
current product details belong in `docs/` and released behavior belongs in
`CHANGELOG.md`.

## Source of truth

- Running code and tests define what is actually shipped.
- `docs/UI_SPEC.md` owns current interaction and layout.
- `docs/ENERGY_MODEL.md` owns units, denominators, intervals, and attribution limits.
- `docs/HLD.md` owns architecture, persistence, sampling, and permissions.
- `docs/VISION.md` owns product intent and scope.
- `RELEASE.md` owns the public release procedure.
- `README.md` is the public orientation document.

Do not duplicate a detailed rule across documents. Update the owning document and
link to it from the others.

## Durable product constraints

- Voltscope is macOS 13+ and uses SwiftUI, SwiftUI Charts, and Swift Package Manager.
- The History toolbar has one time control: Live / 1H / 24H / 7D. All history
  surfaces follow that selection.
- App attribution is recorded CPU energy only. It must not be described as a
  complete allocation of whole-device battery drain.
- Battery level is a 0–100% state-of-charge trace and is separate from app
  attribution.
- Preserve the History composition: battery trace, App CPU chart, then the
  shared Energy breakdown | Apps columns in one outer scroll view.
- Keep app colors stable by bundle identity and preserve gaps for missing data.
- Voltscope has no telemetry, analytics, or remote crash reporting.

## Change and validation workflow

1. Read the relevant source-of-truth document and inspect existing callers before editing.
2. Make the smallest coherent change. Do not redesign unrelated surfaces.
3. Add meaningful tests for changed data semantics and range behavior.
4. Run `git diff --check`, `swift test`, and the appropriate app build.
5. Update the owning documentation and changelog for shipped behavior.
6. Keep commits focused and explain user impact in pull requests.

The repository may contain a local, ignored `.private/` directory for maintainer
notes. It is optional and must never be required to build or test the project.
Never put passwords, private keys, API tokens, or signing credentials in Git.
