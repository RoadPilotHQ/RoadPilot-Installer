# Git identity policy for RoadPilot-Installer

RoadPilot-Installer is a special repository. Only the GitHub account **`RoadPilotHQ`** may commit, push, create and push tags, and publish GitHub Releases here. The policy is implemented and enforced by RoadPilot-Git (commit `bf3e459`, "Add repository-specific account policies").

## Installer account policy

The Installer has an explicit repository-specific `accountPolicy` in RoadPilot-Git's `accounts.json` (a private, local file; not part of this repository):

| Operation | Policy name | Identity |
|---|---|---|
| Commit (author and committer) | `commit` | `RoadPilotHQ` |
| Push | `push` | `RoadPilotHQ` |
| Tag creation (tagger) | `tag-create` | `RoadPilotHQ` |
| Tag push | `tag-push` | `RoadPilotHQ` |
| GitHub Release publishing | `release-publish` | `RoadPilotHQ` |

The policy explicitly forbids `OranjeDev`, `GorillaKeks` and `LEGION1820` (`forbiddenAccounts`). A policy that names any of them is rejected as a configuration error.

The Installer never uses random account selection. The global defaults (`OranjeDev` as development account, random push selection among `OranjeDev`, `GorillaKeks` and `LEGION1820`) still apply to every repository **without** an `accountPolicy`; they are unchanged.

## Enforcement

RoadPilot-Git enforces the policy as follows:

- **Repository identification:** the repository is resolved from the canonical GitHub name in the `origin` URL (`RoadPilotHQ/RoadPilot-Installer`) and must be in the registered folder. There is no partial path matching.
- **Policy validation:** unknown accounts, unknown settings, invalid operation names, empty or `null` values, a list instead of a single account, and forbidden accounts all stop every command with a configuration error. A typo cannot fall back to the global behaviour.
- **No silent fallback:** if the `RoadPilotHQ` key is missing, does not log in, or logs in as a different account, the command stops. It never uses another account.
- **SSH check first:** the policy account's SSH key is verified to authenticate as that account before account-sensitive operations (and again right before a push).
- **Releases:** `release` requires the GitHub CLI (`gh`) to be logged in as `RoadPilotHQ`. It compares `gh api user` with the policy account and stops on a mismatch. It never switches `gh` accounts.
- **Tags:** an existing local or remote tag is never overwritten. Tags must be annotated, created by `RoadPilotHQ`, and placed on a commit that is already on the remote branch.
- **Unchanged safeguards:** the normal RoadPilot-Git protections still apply (no force push, no amend or rebase, `CLAUDE.md` never committed, secret scan, unrelated-change check, project checks before commit).

## Supported operations

All five operations are implemented in RoadPilot-Git and permitted for the Installer (`allowedOperations`):

| Operation | Command |
|---|---|
| `commit` | `roadpilot-git.ps1 commit ...` |
| `push` | `roadpilot-git.ps1 commit ...` (pushes) and `roadpilot-git.ps1 push` |
| `tag-create` | `roadpilot-git.ps1 tag -TagName vX.Y.Z -MessageFile ...` |
| `tag-push` | `roadpilot-git.ps1 push-tag -TagName vX.Y.Z` |
| `release-publish` | `roadpilot-git.ps1 release -TagName vX.Y.Z -NotesFile ...` |

Run `status` in this repository to see the active policy. Tag names must look like `v1.2.3` (optionally `v1.2.3-beta.1`).

## Verification status

| Behaviour | Status |
|---|---|
| Policy resolution, forbidden-account rejection, configuration validation | Covered by RoadPilot-Git's automated tests |
| Commit and push as `RoadPilotHQ`, hard failure on a missing or wrong key | Covered by RoadPilot-Git's sandbox tests (SSH logins against GitHub, pushes to a local bare repository) |
| `tag-create` and `tag-push` | Covered by sandbox tests against a local bare repository only. Not yet exercised against GitHub |
| `release-publish` | Covered by tests that use a fake `gh` script. **No real GitHub Release has been published or tested.** Real publishing is unverified |

## Rules

- Do not commit, push, tag or release in this repository with any account other than `RoadPilotHQ`, and never with plain `git commit`, `git push` or `gh release`.
- Do not change the remote URL, the global Git identity or RoadPilot-Git's configuration to work around a failure. If the script stops, report the problem.
- Before the first real release, verify `gh` is logged in as `RoadPilotHQ` (`gh auth status`) and run `release ... -DryRun` first.
