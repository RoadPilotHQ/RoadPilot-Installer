# Release manifest resolution

Implements Phase 2B of [release-pipeline-architecture.md](release-pipeline-architecture.md): turn a verified manifest into an exact, checked description of the sources of one release, and refuse everything that is inconsistent, incomplete or unverifiable **before any build starts**.

> **Scope.** This is read-only validation. It builds nothing, produces no artifacts or checksums, publishes nothing, and never changes a repository (no checkout, fetch unless `-Fetch` is passed, commit or tag).

- Script: [scripts/Resolve-ReleaseManifest.ps1](../scripts/Resolve-ReleaseManifest.ps1)
- Tests: [tests/Resolve-ReleaseManifest.tests.ps1](../tests/Resolve-ReleaseManifest.tests.ps1)
- Manifest rules it reuses: [scripts/Test-ReleaseManifest.ps1](../scripts/Test-ReleaseManifest.ps1)

## Usage

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Resolve-ReleaseManifest.ps1 `
    -ManifestPath config/release-manifest.json `
    -RepositoryMapPath local-repositories.json `
    -OutFile resolved-release.json
```

| Parameter | Meaning |
|---|---|
| `-ManifestPath` | The manifest to resolve. It must have `status: "verified"`; the example manifest is always rejected |
| `-RepositoryMapPath` | JSON file mapping repository **names** to local folders, e.g. `{ "RoadPilot": "D:/src/RoadPilot" }`. Keep it outside the repository: it holds machine-specific paths |
| `-GitConfigPath` | Alternative: a RoadPilot-Git `accounts.json`; its registered `repositories[].localPath` entries are the map. Exactly one of the two must be given |
| `-InstallerPath` | The local Installer repository used for the tag checks. Default: the repository containing the script |
| `-TagRemote` | Remote asked for existing tags. Default: `origin` |
| `-Tag` | Optional. If given it must equal `v<release.version>`; the tag is always derived from the manifest |
| `-AllowUnverified` | Accept manifest entries with no verified role (see below) as warnings |
| `-Fetch` | Run `git fetch origin` in each repository first, so reachability is checked against current remote state |
| `-OutFile` | Where to write the resolved JSON. Written only when every check passed. Without it the JSON is printed |

Exit code 0 means every check passed; 1 means at least one failed (all failures are listed) and **no output file is written**.

## Resolution

1. The manifest is validated with the existing rules (`Get-ReleaseManifestErrors -RequireVerified`): SemVer versions, full 40-character lowercase commit SHAs, no branch references, unique ids, known `dependsOn` ids, build order consistent with dependencies.
2. Each repository **name** is looked up in the local map. An unregistered repository, a folder that does not exist, is not a Git repository, or is not the repository root is an error.
3. The folder's `origin` must be `RoadPilotHQ/<name>` (https, ssh or an ssh host alias). A folder that is another repository is an error.
4. The pinned commit is resolved with `git rev-parse --verify <sha>^{commit}` and must come back unchanged. Because only full SHAs are accepted, nothing is ambiguous. A pin is **never** replaced by a branch head or any other commit: a missing commit is an error.
5. The commit must be reachable from the repository's default branch, taken from the local `refs/remotes/origin/HEAD`. If that is not set, the check fails closed (`git remote set-head origin -a` sets it). Reachability is judged against the local remote-tracking branch, so run with `-Fetch` (or fetch yourself) to be sure it is current.
6. The declared `buildOrder` is preserved exactly.

## Consistency checks

All of these fail closed. Files are read **at the pinned commit** with `git show <sha>:<path>`, never from the working tree, so uncommitted edits cannot influence the result.

| Check | Rule |
|---|---|
| Application entry | The manifest must contain exactly one `RoadPilot` entry and exactly one `RoadPilot-Telemetry` entry, and the application must declare the Telemetry id in `dependsOn` |
| RoadPilot version | `package.json` `version`, `src-tauri/Cargo.toml` `[package] version` and `src-tauri/tauri.conf.json` `version` (the three locations found in the real repository) must all equal the manifest `version` of the application entry |
| Telemetry `Cargo.toml` | `roadpilot-telemetry-client` must be one inline-table dependency with `git` equal to the manifest URL and `rev` equal to the manifest Telemetry pin. `branch`, `tag` or a missing `rev` are errors |
| Telemetry `Cargo.lock` | The single `roadpilot-telemetry-client` package must have a `git+<manifest URL>?rev=<sha>#<sha>` source where both SHAs equal the manifest Telemetry pin |
| Release tag | `v<release.version>` must look like `v1.2.3`, must not exist in the Installer repository, and must not exist on the tag remote. If the remote cannot be asked, the check fails (a tag is never assumed free). The Installer's `origin` must be `RoadPilotHQ/RoadPilot-Installer` |

Nothing creates, changes or deletes a tag.

### Roles, and the example manifest

The resolver does not treat every listed repository as a build dependency. Each entry gets a role:

| Role | Meaning |
|---|---|
| `application` | The `RoadPilot` entry |
| `build-input` | `RoadPilot-Telemetry`, because its dependency was **verified** by the two Cargo checks above |
| `unverified` | Anything else. This is an **error** by default ("no verified role in this release"). With `-AllowUnverified` it is accepted, marked `unverified` in the output and reported as a warning |

This matches the finding of Phase 2A: only RoadPilot to RoadPilot-Telemetry is a verified build dependency.

**The example manifest.** `config/release-manifest.example.json` contains only the two verified build inputs, `RoadPilot-Telemetry` and `RoadPilot` (build order: telemetry, then roadpilot), with the verified dependency of the application on Telemetry. It deliberately lists no other repository. It cannot be resolved as it stands: it has `status: "example"` and every version and commit is `UNRESOLVED`, and the resolver never fills such values in or guesses them. The tests promote the example to a verified manifest using values taken from isolated fixture repositories and confirm that it then resolves completely (two repositories, roles `build-input` and `application`, one verified dependency, no warnings), and that adding Map, Language or Visualization back is rejected.

More components (for example RoadPilot-Map or the C++ plugins) can be added once their relationship to the release has been verified; until then the validator's rule that every listed repository appears in `buildOrder` and the schema's lack of a "shipped component" field mean the safest manifest lists build inputs only. A fuller solution (explicit roles, toolchain pins) needs a schema change, which is a later decision.

## Resolved output

Deterministic JSON: fixed key order, entries in `buildOrder` order, LF line endings, UTF-8 without BOM, **no timestamps and no local paths**, so the same manifest and sources always give identical bytes.

```json
{
  "resolvedSchemaVersion": 1,
  "release": { "version": "1.0.0", "tag": "v1.0.0", "channel": "alpha" },
  "platforms": [ { "os": "windows", "arch": "x64" } ],
  "repositories": [
    {
      "order": 1, "id": "telemetry", "name": "RoadPilot-Telemetry",
      "url": "https://github.com/RoadPilotHQ/RoadPilot-Telemetry.git",
      "version": "0.1.0", "commit": "<40-character SHA>",
      "role": "build-input", "dependsOn": []
    }
  ],
  "dependencies": [
    { "from": "roadpilot", "to": "telemetry", "verified": true,
      "evidence": "src-tauri/Cargo.toml rev and src-tauri/Cargo.lock source equal the pinned RoadPilot-Telemetry commit" }
  ],
  "warnings": [],
  "checks": [ { "name": "manifest-valid", "status": "passed", "detail": "..." } ]
}
```

- `dependencies[].verified` is `true` only where a check above proved it; other declared dependencies are `false` with the evidence `declared in the manifest only`.
- `checks` lists every check that passed. Failures never produce output.
- This is a description of sources, **not** a build record: it contains no tool versions, artifacts or checksums (later phases).

## Remaining limitations

- Reachability relies on the local remote-tracking branch; without `-Fetch` it can be stale.
- The remote tag check needs network access to the tag remote and fails closed without it.
- Only the verified RoadPilot to RoadPilot-Telemetry relationship has checks. Other components need their own verified checks before they can have a role.
- The manifest schema is unchanged, so toolchain versions and distribution roles cannot be expressed yet.
- Nothing here verifies that the sources build; that is Phase 2C onward.
