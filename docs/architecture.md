# RoadPilot-Installer architecture

> **Status: foundation only.** Everything described below as *planned* is not implemented. Today the repository contains the release manifest definition, documentation and lightweight validation. It cannot build, package or release anything.

## Purpose

RoadPilot-Installer is the central build, packaging and release orchestration repository of the RoadPilot ecosystem. Its job is to answer one question reproducibly: *which exact versions of which repositories make up a given RoadPilot release, and how is that release built, checked, packaged and published?*

It orchestrates; it does not own application code. It must not duplicate functionality of the repositories below.

## Relationship to other repositories

| Repository | Responsibility | Role for the Installer |
|---|---|---|
| `RoadPilot` | Tauri desktop application and dashboard | Primary build target (planned) |
| `RoadPilot-Telemetry` | SCS telemetry integration | Build input. `RoadPilot` already pins it by git `rev` in `src-tauri/Cargo.toml` (verified) |
| `RoadPilot-Map` | Map data and map functionality | Possible build input (dependency not yet verified) |
| `RoadPilot-Language` | Localization | Possible build input (not yet verified) |
| `RoadPilot-Visualization` | Visualization components | Possible build input (not yet verified) |
| `RoadPilot-Plugin` | Plugin functionality | Possible build input (not yet verified) |
| `RoadPilot-SDK` | Input SDK | Possible build input (not yet verified) |
| `RoadPilot-Website` | Website | Not part of the application build; may later consume release metadata |
| `RoadPilot-Docs` | Documentation | Not part of the application build |
| `RoadPilot-Discord` | Discord integration | Not part of the application build |
| `RoadPilot-Git` | Git workflow management (local tooling, private) | Governs how this repository is committed to; see [git-identity-policy.md](git-identity-policy.md) |
| `RoadPilot-Installer` | Build, packaging and release orchestration | This repository |

Which repositories are build inputs is decided by the release manifest, and only dependencies that have been observed are listed there. Repositories are never assumed to share a version.

## Release manifest (implemented as a definition)

`release-manifest.json` is the single source of truth for a release: repositories, URLs, exact commit pins, dependency relationships, build order, target platforms and release metadata. See [release-manifest.md](release-manifest.md). The schema and validator exist; no verified manifest exists yet.

## Planned build process (planned, not implemented)

1. Read and validate a **verified** manifest (`-RequireVerified`).
2. Clone each repository into an isolated work directory and check out the pinned commit (never a branch head).
3. Confirm each checkout matches its pin exactly.
4. Build repositories in `buildOrder`, passing each dependency's output to its dependents.
5. Build the `RoadPilot` Tauri application for each supported platform (Windows x64 first).

## Planned validation process (planned, not implemented)

- Manifest validation (implemented today as a standalone check).
- Per-repository checks equivalent to those each repository already defines for itself.
- Verification that build outputs correspond to the pinned commits.
- Smoke checks of the packaged application.
- No release is created if any step fails, and no fake "successful build" is ever reported.

## Planned packaging process (planned, not implemented)

- Produce the Windows installer from the Tauri build.
- Record SHA-256 checksums of every artifact.
- Attach the manifest used for the build so the release is reproducible.
- Code signing is undecided and will be designed in a later phase.

## Planned release process (planned, not implemented)

- Tag and GitHub Release creation are performed only by the `RoadPilotHQ` account (see the policy document).
- Release notes are derived from the manifest.
- A release is published only from a verified manifest and a fully successful pipeline.

## Current CI

`.github/workflows/validate.yml` runs `scripts/Test-Foundation.ps1` with read-only permissions. It cannot push, tag or publish.

## Open decisions

- Repository license (none of the RoadPilot repositories currently contains a LICENSE file; the choice belongs to the repository owner).
- Whether builds run on GitHub-hosted runners, locally, or both.
- Code signing approach.
- Which repositories beyond `RoadPilot-Telemetry` are real build dependencies of `RoadPilot`.
