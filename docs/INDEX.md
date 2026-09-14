# Documentation index

Status: prepared for v0.9.0 (build 9); publication is maintained by the release owner.

## Source of truth

When documents disagree, use this order:

1. Running code and tests define what is actually shipped.
2. `UI_SPEC.md` defines current interaction and layout.
3. `ENERGY_MODEL.md` defines units, denominators, interval bounds, and
   attribution limits.
4. `HLD.md` defines architecture, storage, sampling, permissions, and budgets.
5. `VISION.md` defines product intent and deliberate scope.
6. `RELEASE.md` defines the public website and GitHub release procedure.
7. `CHANGELOG.md` records what shipped; it is not an implementation spec.
8. `README.md` is the public orientation and setup summary.
9. `AGENTS.md` and `CLAUDE.md` define durable contributor rules.

Do not copy a detailed requirement into several normative documents. Put it in
the owning document and link to it from the others.

## Document ownership

| Question | Owner |
| --- | --- |
| What the user sees and how controls interact | `UI_SPEC.md` |
| What a joule, drain estimate, bucket, or percentage means | `ENERGY_MODEL.md` |
| How sampling, storage, windows, and permissions work | `HLD.md` |
| Why the product exists and what is out of scope | `VISION.md` |
| What shipped in a release | `CHANGELOG.md` |
| How to build, sign, install, and publish | `RELEASE.md` |
| Public setup and downloads | `README.md` |
| Contributor and agent workflow | `AGENTS.md` and `CLAUDE.md` |

## Current and historical material

Each durable spec should make its status obvious. Use `Current / shipped`,
`Planned`, `Superseded`, or `Research`. Historical sections explain why the
architecture looks the way it does, but they never override running code or a
current contract.

The v0.9.0 Startup, Login Item, and Settings section plus the v0.8 Battery
History section in `UI_SPEC.md` are the current UI contract. The v0.5 and v0.6
sections are retained as rationale and regression context.
The current energy contract is CPU-only app attribution; future whole-device
apportionment ideas remain planned until code, tests, and copy support them.

Raw private research, deployment details, and maintainer-only decision records
live outside this public repository. Public docs must remain useful without
access to those materials.

## Change-to-document guide

- UI control, layout, label, range, chart, Dock/window, or accessibility change:
  update `UI_SPEC.md` and `CHANGELOG.md`.
- Query interval, energy unit, integration rule, denominator, or attribution
  claim: update `ENERGY_MODEL.md`, the relevant HLD section, and tests.
- Schema, sampler, permission, performance, or distribution architecture:
  update `HLD.md` and, when energy semantics change, `ENERGY_MODEL.md`.
- Release version, signature, notarization, installation, or publication:
  update `RELEASE.md`, `CHANGELOG.md`, `README.md`, and version metadata.
- Contributor or agent workflow: update `AGENTS.md` and keep `CLAUDE.md` identical.
