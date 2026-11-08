# RoadPilot-Installer
Central build, packaging and release management for the RoadPilot ecosystem.

> **Status: repository foundation only.** The build, packaging and release pipeline is **planned, not implemented**. This repository cannot currently build or release RoadPilot.

## What exists today

- A release manifest definition: [schema](config/release-manifest.schema.json) and a clearly marked [example](config/release-manifest.example.json) (not a verified release).
- Documentation: [architecture](docs/architecture.md), [release manifest](docs/release-manifest.md), [Git identity policy](docs/git-identity-policy.md).
- Lightweight validation for the manifest and the repository structure, run locally and in GitHub Actions.
- [Release pipeline architecture](docs/release-pipeline-architecture.md) (design only) and, from it, Phase 2B: [manifest resolution and pre-build consistency checks](docs/release-manifest-resolution.md). Nothing is built or published yet.

## Validate

Requires Windows PowerShell 5.1 or later.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-Foundation.ps1
```

## Layout

```text
.github/workflows/   CI: validation only (no tags, releases or pushes)
config/              Release manifest schema and example
docs/                Architecture, manifest and Git policy documentation
scripts/             Validation scripts (PowerShell)
tests/               Manifest rule tests
```

## Git policy

Commits, pushes, tags and releases for this repository are reserved for the `RoadPilotHQ` account. See [docs/git-identity-policy.md](docs/git-identity-policy.md).

## License

No license has been chosen yet.
