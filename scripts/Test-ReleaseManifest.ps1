<#
.SYNOPSIS
    Validates a RoadPilot release manifest (Windows PowerShell 5.1 compatible, no dependencies).

.DESCRIPTION
    Implements the rules documented in config/release-manifest.schema.json and
    docs/release-manifest.md. Validation only: nothing is built, cloned or modified.

    status "example"  : UNRESOLVED placeholders are allowed.
    status "verified" : no placeholders; every repository needs a full 40-character commit SHA.

    Returns an array of error strings (empty when valid) when dot-sourced and called as
    Get-ReleaseManifestErrors. When run as a script it prints the result and exits 0 or 1.

.PARAMETER Path
    Manifest file to validate.

.PARAMETER RequireVerified
    Fail unless the manifest status is "verified". Release automation must use this switch.
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$RequireVerified
)

$ErrorActionPreference = 'Stop'

function Get-ReleaseManifestErrors {
    param([Parameter(Mandatory)] $Manifest, [switch]$RequireVerified)

    $errors = New-Object System.Collections.Generic.List[string]
    function Add-Err([string]$m) { $errors.Add($m) }
    function Has($o, [string]$n) { $null -ne $o -and $null -ne $o.PSObject.Properties[$n] }

    $unresolved = 'UNRESOLVED'
    $semver = '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'

    foreach ($k in 'schemaVersion', 'status', 'release', 'platforms', 'repositories', 'buildOrder') {
        if (-not (Has $Manifest $k)) { Add-Err "Missing top-level property '$k'." }
    }
    if ($errors.Count) { return , @($errors) }

    $allowedTop = 'schemaVersion', 'status', 'release', 'platforms', 'repositories', 'buildOrder'
    foreach ($p in $Manifest.PSObject.Properties.Name) {
        if ($allowedTop -notcontains $p) { Add-Err "Unknown top-level property '$p'." }
    }

    if ($Manifest.schemaVersion -ne 1) { Add-Err "schemaVersion must be 1." }
    if ($Manifest.status -notin 'example', 'verified') { Add-Err "status must be 'example' or 'verified'." }
    $isVerified = $Manifest.status -eq 'verified'
    if ($RequireVerified -and -not $isVerified) { Add-Err "Manifest status is '$($Manifest.status)'; a verified manifest is required." }

    # release
    $rel = $Manifest.release
    if (-not (Has $rel 'version') -or -not (Has $rel 'channel')) { Add-Err "release needs 'version' and 'channel'." }
    else {
        if ($rel.channel -notin 'stable', 'beta', 'alpha') { Add-Err "release.channel must be stable, beta or alpha." }
        if ($rel.version -eq $unresolved) {
            if ($isVerified) { Add-Err "release.version is UNRESOLVED in a verified manifest." }
        }
        elseif ($rel.version -notmatch $semver) { Add-Err "release.version '$($rel.version)' is not SemVer." }
    }

    # platforms
    $platforms = @($Manifest.platforms)
    if (-not $platforms.Count) { Add-Err "platforms must not be empty." }
    foreach ($pf in $platforms) {
        if ($pf.os -ne 'windows' -or $pf.arch -ne 'x64') { Add-Err "Unsupported platform '$($pf.os)/$($pf.arch)'. Only windows/x64 is supported at this stage." }
    }

    # repositories
    $repos = @($Manifest.repositories)
    if (-not $repos.Count) { Add-Err "repositories must not be empty." }
    $ids = @{}
    foreach ($r in $repos) {
        foreach ($k in 'id', 'name', 'url', 'role', 'version', 'pin', 'dependsOn') {
            if (-not (Has $r $k)) { Add-Err "Repository '$($r.id)' is missing '$k'." }
        }
        $allowedRepo = 'id', 'name', 'url', 'role', 'version', 'pin', 'dependsOn', 'dependencyEvidence'
        foreach ($p in $r.PSObject.Properties.Name) {
            if ($allowedRepo -notcontains $p) { Add-Err "Repository '$($r.id)' has unknown property '$p' (branch references are not allowed)." }
        }
        if (-not (Has $r 'id') -or -not (Has $r 'name')) { continue }
        if ($r.id -notmatch '^[a-z0-9][a-z0-9-]*$') { Add-Err "Invalid repository id '$($r.id)'." }
        if ($ids.ContainsKey($r.id)) { Add-Err "Duplicate repository id '$($r.id)'." }
        $ids[$r.id] = $r
        if ($r.name -notmatch '^RoadPilot(-[A-Za-z]+)?$') { Add-Err "Repository '$($r.id)': invalid name '$($r.name)'." }
        elseif ($r.url -cne "https://github.com/RoadPilotHQ/$($r.name).git") { Add-Err "Repository '$($r.id)': url must be https://github.com/RoadPilotHQ/$($r.name).git." }

        if ($r.version -eq $unresolved) { if ($isVerified) { Add-Err "Repository '$($r.id)': version is UNRESOLVED in a verified manifest." } }
        elseif ($r.version -notmatch $semver) { Add-Err "Repository '$($r.id)': version '$($r.version)' is not SemVer." }

        if (Has $r 'pin') {
            foreach ($p in $r.pin.PSObject.Properties.Name) {
                if ($p -notin 'commit', 'tag') { Add-Err "Repository '$($r.id)': pin has unknown property '$p'." }
            }
            if (-not (Has $r.pin 'commit')) { Add-Err "Repository '$($r.id)': pin.commit is required." }
            elseif ($r.pin.commit -eq $unresolved) { if ($isVerified) { Add-Err "Repository '$($r.id)': pin.commit is UNRESOLVED in a verified manifest." } }
            elseif ($r.pin.commit -cnotmatch '^[0-9a-f]{40}$') { Add-Err "Repository '$($r.id)': pin.commit must be a full 40-character lowercase SHA." }
        }

        if ($r.dependsOn -and -not (Has $r 'dependencyEvidence')) { Add-Err "Repository '$($r.id)': dependsOn requires dependencyEvidence." }
    }

    # dependencies: known ids, no cycles
    foreach ($r in $repos) {
        foreach ($d in @($r.dependsOn)) {
            if (-not $ids.ContainsKey($d)) { Add-Err "Repository '$($r.id)' depends on unknown id '$d'." }
            elseif ($d -eq $r.id) { Add-Err "Repository '$($r.id)' depends on itself." }
        }
    }
    $state = @{}
    function Visit($id, $stack) {
        if ($state[$id] -eq 2) { return }
        if ($state[$id] -eq 1) { Add-Err "Dependency cycle: $($stack -join ' -> ') -> $id"; return }
        $state[$id] = 1
        foreach ($d in @($ids[$id].dependsOn)) { if ($ids.ContainsKey($d)) { Visit $d ($stack + $id) } }
        $state[$id] = 2
    }
    foreach ($id in @($ids.Keys)) { Visit $id @() }

    # build order
    $order = @($Manifest.buildOrder)
    $pos = @{}
    for ($i = 0; $i -lt $order.Count; $i++) {
        if (-not $ids.ContainsKey($order[$i])) { Add-Err "buildOrder lists unknown id '$($order[$i])'." }
        elseif ($pos.ContainsKey($order[$i])) { Add-Err "buildOrder lists '$($order[$i])' more than once." }
        else { $pos[$order[$i]] = $i }
    }
    foreach ($id in $ids.Keys) { if (-not $pos.ContainsKey($id)) { Add-Err "Repository '$id' is missing from buildOrder." } }
    foreach ($r in $repos) {
        foreach ($d in @($r.dependsOn)) {
            if ($pos.ContainsKey($r.id) -and $pos.ContainsKey($d) -and $pos[$d] -gt $pos[$r.id]) {
                Add-Err "buildOrder builds '$($r.id)' before its dependency '$d'."
            }
        }
    }

    return , @($errors)
}

if ($Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Write-Host "Manifest not found: $Path"; exit 1 }
    try { $manifest = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Host "Invalid JSON in ${Path}: $($_.Exception.Message)"; exit 1 }
    $errs = Get-ReleaseManifestErrors -Manifest $manifest -RequireVerified:$RequireVerified
    if ($errs.Count) {
        Write-Host "Manifest INVALID: $Path"
        $errs | ForEach-Object { Write-Host "  - $_" }
        exit 1
    }
    Write-Host "Manifest valid (status: $($manifest.status)): $Path"
    exit 0
}
