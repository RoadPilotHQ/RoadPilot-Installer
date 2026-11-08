<#
.SYNOPSIS
    Validates the RoadPilot-Installer repository foundation (structure, manifest, docs, hygiene).

.DESCRIPTION
    Read-only. Builds nothing, publishes nothing, pushes nothing. Windows PowerShell 5.1 compatible.
    Runs the manifest rule tests in tests/ as well.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[ ok ] $Name" }
    else { Write-Host "[FAIL] $Name $Detail"; $failures.Add($Name) }
}
function Rel([string]$p) { Join-Path $root $p }

# 1. Required structure
$required = @(
    'README.md', '.gitignore', '.github/workflows/validate.yml',
    'config/release-manifest.schema.json', 'config/release-manifest.example.json',
    'docs/architecture.md', 'docs/release-manifest.md', 'docs/git-identity-policy.md',
    'docs/release-pipeline-architecture.md', 'docs/release-manifest-resolution.md',
    'scripts/Test-Foundation.ps1', 'scripts/Test-ReleaseManifest.ps1', 'tests/ReleaseManifest.tests.ps1',
    'scripts/Resolve-ReleaseManifest.ps1', 'tests/Resolve-ReleaseManifest.tests.ps1'
)
foreach ($f in $required) { Check "exists: $f" (Test-Path -LiteralPath (Rel $f) -PathType Leaf) }

# 2. JSON files parse
foreach ($f in 'config/release-manifest.schema.json', 'config/release-manifest.example.json') {
    $ok = $true
    try { $null = Get-Content -LiteralPath (Rel $f) -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $ok = $false }
    Check "valid JSON: $f" $ok
}

# 3. The example manifest validates and stays an example
$manifestScript = Rel 'scripts/Test-ReleaseManifest.ps1'
. $manifestScript
$example = Get-Content -LiteralPath (Rel 'config/release-manifest.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$errs = Get-ReleaseManifestErrors -Manifest $example
Check 'example manifest passes validation' ($errs.Count -eq 0) ($errs -join '; ')
Check "example manifest has status 'example'" ($example.status -eq 'example')
$verifiedErrs = Get-ReleaseManifestErrors -Manifest $example -RequireVerified
Check 'example manifest is rejected as a verified manifest' ($verifiedErrs.Count -gt 0)

# A real config/release-manifest.json, if present, must be fully valid and verified.
$real = Rel 'config/release-manifest.json'
if (Test-Path -LiteralPath $real) {
    $m = Get-Content -LiteralPath $real -Raw -Encoding UTF8 | ConvertFrom-Json
    $e = Get-ReleaseManifestErrors -Manifest $m -RequireVerified
    Check 'config/release-manifest.json is a valid verified manifest' ($e.Count -eq 0) ($e -join '; ')
}

# 4. Documentation consistency
$archPath = Rel 'docs/architecture.md'
if (Test-Path -LiteralPath $archPath) {
    $arch = Get-Content -LiteralPath $archPath -Raw -Encoding UTF8
    foreach ($name in 'RoadPilot', 'RoadPilot-Telemetry', 'RoadPilot-Map', 'RoadPilot-Language', 'RoadPilot-Visualization',
        'RoadPilot-Plugin', 'RoadPilot-SDK', 'RoadPilot-Website', 'RoadPilot-Docs', 'RoadPilot-Discord', 'RoadPilot-Git', 'RoadPilot-Installer') {
        Check "architecture.md mentions $name" ($arch -match [regex]::Escape($name))
    }
    Check 'architecture.md marks planned functionality' ($arch -match '(?i)\bplanned\b')
}
$policyPath = Rel 'docs/git-identity-policy.md'
if (Test-Path -LiteralPath $policyPath) {
    $pol = Get-Content -LiteralPath $policyPath -Raw -Encoding UTF8
    Check 'git-identity-policy.md names RoadPilotHQ' ($pol -match 'RoadPilotHQ')
    foreach ($acc in 'OranjeDev', 'GorillaKeks', 'LEGION1820') { Check "git-identity-policy.md names excluded account $acc" ($pol -match $acc) }
}

# 5. Workflow must not publish, tag or push
$wf = Rel '.github/workflows/validate.yml'
if (Test-Path -LiteralPath $wf) {
    $w = Get-Content -LiteralPath $wf -Raw -Encoding UTF8
    Check 'workflow has read-only permissions' ($w -match '(?m)^permissions:\s*\r?\n\s+contents:\s*read\s*$')
    Check 'workflow has no push/tag/release commands' ($w -notmatch '(?i)git\s+push|git\s+tag|gh\s+release|action-gh-release|create-release|contents:\s*write')
}

# 6. Hygiene: no secrets, personal paths or protected local files in tracked-style content
$files = Get-ChildItem -LiteralPath $root -Recurse -File -Force |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
$secretPattern = '(?i)(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16})'
$personalPattern = '(?i)C:\\Users\\|/Users/[a-z]|C:/Users/'
$secretHits = @(); $pathHits = @()
foreach ($f in $files) {
    if ($f.Name -in 'CLAUDE.md', 'CLAUDE.local.md', 'settings.local.json') { continue }
    $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $text) { continue }
    if ($text -match $secretPattern) { $secretHits += $f.Name }
    if ($f.Name -ne 'Test-Foundation.ps1' -and $text -match $personalPattern) { $pathHits += $f.Name }
}
Check 'no secrets or tokens found' ($secretHits.Count -eq 0) ($secretHits -join ', ')
Check 'no personal user paths found' ($pathHits.Count -eq 0) ($pathHits -join ', ')

# 7. Manifest rule tests
$testOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Rel 'tests/ReleaseManifest.tests.ps1') 2>&1
$testOut | ForEach-Object { Write-Host "       $_" }
Check 'manifest rule tests pass' ($LASTEXITCODE -eq 0)

# 8. Manifest resolution tests (isolated temporary repositories, no network)
$resolveOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Rel 'tests/Resolve-ReleaseManifest.tests.ps1') 2>&1
$resolveOut | Where-Object { "$_" -notmatch '^PASS ' } | ForEach-Object { Write-Host "       $_" }
Check 'manifest resolution tests pass' ($LASTEXITCODE -eq 0)

Write-Host ''
if ($failures.Count) { Write-Host "Foundation validation FAILED ($($failures.Count) check(s))."; exit 1 }
Write-Host 'Foundation validation passed. (This validates the repository foundation only; no application build exists yet.)'
exit 0
