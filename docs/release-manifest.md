# Release manifest

The manifest describes exactly which repository states make up one RoadPilot release.

- Schema (reference): [config/release-manifest.schema.json](../config/release-manifest.schema.json)
- Example (**not** a release): [config/release-manifest.example.json](../config/release-manifest.example.json)
- Validator (authoritative rules): [scripts/Test-ReleaseManifest.ps1](../scripts/Test-ReleaseManifest.ps1)

Windows PowerShell 5.1 has no JSON Schema validator, so the PowerShell script implements the rules and the schema file documents the shape. Keep both in sync; `tests/ReleaseManifest.tests.ps1` covers the rules.

## Example versus verified

| | `status: "example"` | `status: "verified"` |
|---|---|---|
| `UNRESOLVED` placeholders | allowed | rejected |
| Commit pins | `UNRESOLVED` or a 40-character SHA | 40-character lowercase SHA required |
| Used for releases | never | only this |

The only committed manifest is `release-manifest.example.json`. A real release manifest is saved as `config/release-manifest.json` and is only valid with `status: "verified"`. Release automation must call the validator with `-RequireVerified`. Nobody should set `verified` until the compatible set has actually been built and tested together.

## Fields

- `schemaVersion`: currently `1`.
- `release`: `version` (SemVer), `channel` (`stable`, `beta`, `alpha`), optional `notes`.
- `platforms`: list of `{ os, arch }`. Only `windows`/`x64` is accepted for now.
- `repositories[]`:
  - `id`: short key used in `dependsOn` and `buildOrder`.
  - `name` and `url`: must be a `RoadPilotHQ` repository, `https://github.com/RoadPilotHQ/<name>.git`.
  - `role`: what the repository is for.
  - `version`: that repository's **own** version. Versions are independent between repositories.
  - `pin.commit`: the exact commit. `pin.tag` is optional and informational only; the commit is authoritative.
  - `dependsOn`: ids of repositories this one needs. Must have `dependencyEvidence` saying where the dependency was observed.
- `buildOrder`: every repository id exactly once, dependencies before dependents.

## Rules

- Mutable branch names are never a pin. A `branch` field is rejected outright.
- Commit SHAs and versions are never invented. Unknown values stay `UNRESOLVED`.
- Dependencies are listed only when they have been observed. The example currently records one: `RoadPilot` depends on `RoadPilot-Telemetry` (git `rev` dependency in `src-tauri/Cargo.toml`).
- `RoadPilot-Plugin` and `RoadPilot-SDK` are intentionally absent from the example until their role in the build is verified.

## Validate

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-ReleaseManifest.ps1 -Path config/release-manifest.example.json
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-ReleaseManifest.ps1 -Path config/release-manifest.json -RequireVerified
```
