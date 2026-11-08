<#
.SYNOPSIS
    Resolves a verified release manifest to exact source revisions and runs the pre-build
    consistency checks (Phase 2B of docs/release-pipeline-architecture.md).

.DESCRIPTION
    Read-only with respect to every repository: it never builds, checks out, commits, tags or
    pushes. Windows PowerShell 5.1 compatible, no dependencies besides git.

    All checks fail closed. Any failed or unverifiable check means no resolved output is produced.
    A requested commit is never replaced by a branch head or any other revision.

    Checks (see docs/release-pipeline-architecture.md, section 5):
      1. The manifest passes Test-ReleaseManifest.ps1 with status "verified".
      2. Every repository is registered locally, is the expected RoadPilotHQ repository,
         contains the pinned commit, and the commit is reachable from the default branch
         (the local remote-tracking branch origin/HEAD; use -Fetch to refresh it first).
      3. The RoadPilot application version agrees in package.json, src-tauri/Cargo.toml and
         src-tauri/tauri.conf.json at the pinned commit, and with the manifest.
      4. RoadPilot's Cargo.toml git rev and Cargo.lock source for roadpilot-telemetry-client both
         equal the manifest's RoadPilot-Telemetry pin.
      5. The release tag (v<release.version>) exists neither in the Installer repository nor on
         its remote.

    The resolved output is deterministic JSON (see docs/release-manifest-resolution.md).

.PARAMETER ManifestPath
    The release manifest to resolve (normally config/release-manifest.json).

.PARAMETER RepositoryMapPath
    JSON file mapping repository names to local folders, for example {"RoadPilot": "D:/src/RoadPilot"}.

.PARAMETER GitConfigPath
    Alternative to -RepositoryMapPath: a RoadPilot-Git accounts.json; its registered
    repositories[].localPath entries are used.

.PARAMETER InstallerPath
    Local RoadPilot-Installer repository, used for the tag checks. Default: the repository of this script.

.PARAMETER TagRemote
    Remote (name or URL) asked for existing tags. Default: origin.

.PARAMETER Tag
    Optional. If given, it must equal v<release.version>; the tag is always derived from the manifest.

.PARAMETER AllowUnverified
    Allow manifest entries that have no verified role in the release (reported as warnings and
    marked "unverified" in the output). Without it they are errors.

.PARAMETER Fetch
    Run "git fetch origin" in each repository first, so reachability uses current remote state.

.PARAMETER OutFile
    Write the resolved description here (only when every check passed).
#>
[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$RepositoryMapPath,
    [string]$GitConfigPath,
    [string]$InstallerPath,
    [string]$TagRemote = 'origin',
    [string]$Tag,
    [switch]$AllowUnverified,
    [switch]$Fetch,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Test-ReleaseManifest.ps1')

$script:TagPattern = '^v\d+\.\d+\.\d+([-+][0-9A-Za-z.+-]+)?$'
$script:ApplicationName = 'RoadPilot'
$script:TelemetryName = 'RoadPilot-Telemetry'
$script:TelemetryCrate = 'roadpilot-telemetry-client'

# ---------------------------------------------------------------- git helpers (read-only)

function ConvertTo-GitArgString([string[]]$ArgList) {
    $parts = foreach ($a in $ArgList) {
        if ($null -eq $a -or $a -eq '') { '""' }
        elseif ($a -notmatch '[\s"]') { $a }
        else { '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    }
    return ($parts -join ' ')
}

function Invoke-GitRead([string]$Dir, [string[]]$GitArgs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = ConvertTo-GitArgString (@('-c', 'core.quotepath=off', '--no-optional-locks') + $GitArgs)
    $psi.WorkingDirectory = $Dir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    foreach ($k in 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT', 'GIT_OBJECT_DIRECTORY') {
        if ($psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables.Remove($k) }
    }
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; StdOut = $out; StdErr = $errTask.Result }
}

function Get-NormalizedPath([string]$P) {
    return ([System.IO.Path]::GetFullPath($P.Replace('/', '\'))).TrimEnd('\').ToLowerInvariant()
}

# Returns @{ Owner; Name } for a GitHub remote URL (https, ssh or an ssh host alias), or $null.
function ConvertFrom-GitHubUrl([string]$Url) {
    $patterns = @(
        '^(?<user>[^@/]+)@(?<host>[^:/]+):(?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?/?$',
        '^ssh://(?<user>[^@/]+)@(?<host>[^/:]+)(:\d+)?/(?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?/?$',
        '^https://(?<host>[^/]+)/(?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?/?$'
    )
    foreach ($pattern in $patterns) {
        $m = [regex]::Match($Url, $pattern)
        if ($m.Success -and $m.Groups['host'].Value -cmatch '^(github\.com|github-[a-z0-9-]+)$') {
            return @{ Owner = $m.Groups['owner'].Value; Name = $m.Groups['repo'].Value }
        }
    }
    return $null
}

# ---------------------------------------------------------------- repository registration

function Get-RepositoryMap([string]$MapPath, [string]$ConfigPath) {
    if ($MapPath -and $ConfigPath) { throw 'Use either -RepositoryMapPath or -GitConfigPath, not both.' }
    if (-not $MapPath -and -not $ConfigPath) { throw 'Provide -RepositoryMapPath or -GitConfigPath: the repositories must be registered locally.' }
    $map = @{}
    if ($MapPath) {
        if (-not (Test-Path -LiteralPath $MapPath -PathType Leaf)) { throw "Repository map not found: $MapPath" }
        $json = Get-Content -LiteralPath $MapPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $json.PSObject.Properties) { $map[[string]$prop.Name] = [string]$prop.Value }
    }
    else {
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "RoadPilot-Git config not found: $ConfigPath" }
        $json = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in @($json.repositories)) {
            if ($r.name -and $r.localPath) { $map[[string]$r.name] = [string]$r.localPath }
        }
    }
    return $map
}

# ---------------------------------------------------------------- file readers at a pinned commit

function Read-FileAtCommit([string]$Dir, [string]$Sha, [string]$RelPath) {
    $r = Invoke-GitRead $Dir @('show', "${Sha}:${RelPath}")
    if ($r.Code -ne 0) { return $null }
    return $r.StdOut.TrimStart([char]0xFEFF)
}

function Get-CargoPackageVersion([string]$Text) {
    $inPackage = $false
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*\[(?<sec>[^\]]+)\]\s*$') { $inPackage = ($Matches['sec'] -ceq 'package'); continue }
        if ($inPackage -and $line -match '^\s*version\s*=\s*"(?<v>[^"]+)"') { return $Matches['v'] }
    }
    return $null
}

# ---------------------------------------------------------------- the resolution

function Resolve-ReleaseManifest {
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)] [hashtable]$RepositoryMap,
        [Parameter(Mandatory)] [string]$InstallerPath,
        [string]$TagRemote = 'origin',
        [string]$Tag,
        [switch]$AllowUnverified,
        [switch]$Fetch
    )
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $checks = New-Object System.Collections.Generic.List[object]
    function Fail([string]$m) { $errors.Add($m) }
    function Pass([string]$name, [string]$detail) { $checks.Add([ordered]@{ name = $name; status = 'passed'; detail = $detail }) }

    # 1. Manifest rules (reuses the existing validator) and verified status.
    # The validator returns its list wrapped once, so assign it without @().
    $manifestErrors = Get-ReleaseManifestErrors -Manifest $Manifest -RequireVerified
    if ($manifestErrors.Count) {
        foreach ($e in $manifestErrors) { Fail "manifest: $e" }
        return [pscustomobject]@{ Errors = @($errors); Warnings = @($warnings); Resolved = $null }
    }
    Pass 'manifest-valid' "status verified, schemaVersion $($Manifest.schemaVersion)"

    # 2. Release tag, always derived from the manifest.
    $releaseTag = 'v' + $Manifest.release.version
    if ($releaseTag -cnotmatch $script:TagPattern) { Fail "release tag '$releaseTag' does not look like v1.2.3." }
    if ($Tag -and $Tag -cne $releaseTag) { Fail "Requested tag '$Tag' does not match the manifest release version (expected '$releaseTag')." }

    # 3. Repositories: registration, identity, pinned commit, default-branch reachability.
    $byId = @{}
    foreach ($r in @($Manifest.repositories)) { $byId[$r.id] = $r }
    $localDir = @{}
    foreach ($r in @($Manifest.repositories)) {
        $label = "$($r.name) ($($r.id))"
        if (-not $RepositoryMap.ContainsKey($r.name)) { Fail "${label}: repository is not registered locally (no entry for '$($r.name)')."; continue }
        $dir = $RepositoryMap[$r.name]
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Fail "${label}: registered folder does not exist: $dir"; continue }
        $top = Invoke-GitRead $dir @('rev-parse', '--show-toplevel')
        if ($top.Code -ne 0) { Fail "${label}: registered folder is not a Git repository: $dir"; continue }
        if ((Get-NormalizedPath $top.StdOut.Trim()) -ne (Get-NormalizedPath $dir)) { Fail "${label}: registered folder is not the repository root ($($top.StdOut.Trim()))."; continue }
        $originUrl = (Invoke-GitRead $dir @('config', '--get', 'remote.origin.url')).StdOut.Trim()
        $id = ConvertFrom-GitHubUrl $originUrl
        if (-not $id) { Fail "${label}: cannot identify origin URL '$originUrl'."; continue }
        if ($id.Owner -cne 'RoadPilotHQ' -or $id.Name -cne $r.name) { Fail "${label}: origin points to '$($id.Owner)/$($id.Name)', expected 'RoadPilotHQ/$($r.name)'."; continue }
        if ($Fetch) {
            $f = Invoke-GitRead $dir @('fetch', '--quiet', 'origin')
            if ($f.Code -ne 0) { Fail "${label}: git fetch failed: $($f.StdErr.Trim())"; continue }
        }
        $sha = [string]$r.pin.commit
        $resolved = Invoke-GitRead $dir @('rev-parse', '--verify', '--quiet', "$sha^{commit}")
        if ($resolved.Code -ne 0 -or $resolved.StdOut.Trim() -cne $sha) { Fail "${label}: pinned commit $sha does not exist in the repository."; continue }
        $head = Invoke-GitRead $dir @('symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD')
        if ($head.Code -ne 0 -or -not $head.StdOut.Trim()) { Fail "${label}: the default branch is unknown (refs/remotes/origin/HEAD is not set; run 'git remote set-head origin -a')."; continue }
        $defaultRef = $head.StdOut.Trim()
        $anc = Invoke-GitRead $dir @('merge-base', '--is-ancestor', $sha, $defaultRef)
        if ($anc.Code -ne 0) { Fail "${label}: pinned commit $sha is not reachable from the default branch ($defaultRef)."; continue }
        $localDir[$r.id] = $dir
        Pass "repository-$($r.id)" "$($r.name) at $sha, reachable from $defaultRef"
    }

    # 4. Roles and the verified dependency relationship.
    $apps = @($Manifest.repositories | Where-Object { $_.name -ceq $script:ApplicationName })
    $app = $null; $telemetry = $null
    if ($apps.Count -ne 1) { Fail "The manifest must contain exactly one '$($script:ApplicationName)' application entry (found $($apps.Count))." }
    else { $app = $apps[0] }
    $tel = @($Manifest.repositories | Where-Object { $_.name -ceq $script:TelemetryName })
    if ($tel.Count -eq 1) { $telemetry = $tel[0] }
    elseif ($app) { Fail "The manifest must contain exactly one '$($script:TelemetryName)' entry, the verified build input of the application (found $($tel.Count))." }
    $roles = @{}
    $telemetryVerified = $false

    if ($app -and $telemetry -and $localDir.ContainsKey($app.id) -and $localDir.ContainsKey($telemetry.id)) {
        $appDir = $localDir[$app.id]
        $appSha = [string]$app.pin.commit
        if (@($app.dependsOn) -cnotcontains $telemetry.id) { Fail "$($app.id): dependsOn must declare '$($telemetry.id)' (the application depends on $($script:TelemetryName))." }

        # RoadPilot version consistency, read at the pinned commit (never the working tree).
        $found = [ordered]@{}
        $pkg = Read-FileAtCommit $appDir $appSha 'package.json'
        if ($null -eq $pkg) { Fail "$($app.id): package.json is missing at $appSha." }
        else {
            try { $found['package.json'] = [string]($pkg | ConvertFrom-Json).version } catch { Fail "$($app.id): package.json is not valid JSON." }
        }
        $cargoToml = Read-FileAtCommit $appDir $appSha 'src-tauri/Cargo.toml'
        if ($null -eq $cargoToml) { Fail "$($app.id): src-tauri/Cargo.toml is missing at $appSha." }
        else { $found['src-tauri/Cargo.toml'] = [string](Get-CargoPackageVersion $cargoToml) }
        $tauri = Read-FileAtCommit $appDir $appSha 'src-tauri/tauri.conf.json'
        if ($null -eq $tauri) { Fail "$($app.id): src-tauri/tauri.conf.json is missing at $appSha." }
        else {
            try { $found['src-tauri/tauri.conf.json'] = [string]($tauri | ConvertFrom-Json).version } catch { Fail "$($app.id): src-tauri/tauri.conf.json is not valid JSON." }
        }
        $versionsOk = ($found.Count -eq 3)
        foreach ($k in $found.Keys) {
            if (-not $found[$k]) { Fail "$($app.id): no version found in $k."; $versionsOk = $false }
            elseif ($found[$k] -cne $app.version) { Fail "$($app.id): version in $k is '$($found[$k])' but the manifest says '$($app.version)'."; $versionsOk = $false }
        }
        if ($versionsOk) { Pass 'roadpilot-version' "package.json, src-tauri/Cargo.toml and src-tauri/tauri.conf.json all '$($app.version)'" }

        # Telemetry dependency: Cargo.toml rev and Cargo.lock source must both equal the manifest pin.
        $pin = [string]$telemetry.pin.commit
        $tomlOk = $false
        if ($null -ne $cargoToml) {
            $deps = [regex]::Matches($cargoToml, "(?m)^$([regex]::Escape($script:TelemetryCrate))\s*=\s*\{(?<body>[^}]*)\}")
            if ($deps.Count -ne 1) { Fail "$($app.id): src-tauri/Cargo.toml must declare $($script:TelemetryCrate) exactly once as an inline table (found $($deps.Count))." }
            else {
                $body = $deps[0].Groups['body'].Value
                $git = [regex]::Match($body, '\bgit\s*=\s*"(?<v>[^"]+)"')
                $rev = [regex]::Match($body, '\brev\s*=\s*"(?<v>[^"]+)"')
                if ($body -match '\b(branch|tag)\s*=') { Fail "$($app.id): $($script:TelemetryCrate) in Cargo.toml uses a branch or tag; only an exact rev is allowed." }
                elseif (-not $git.Success -or $git.Groups['v'].Value -cne $telemetry.url) { Fail "$($app.id): $($script:TelemetryCrate) git source in Cargo.toml is not the manifest URL $($telemetry.url)." }
                elseif (-not $rev.Success) { Fail "$($app.id): $($script:TelemetryCrate) in Cargo.toml has no rev." }
                elseif ($rev.Groups['v'].Value -cne $pin) { Fail "$($app.id): Cargo.toml rev '$($rev.Groups['v'].Value)' differs from the manifest $($script:TelemetryName) pin '$pin'." }
                else { $tomlOk = $true; Pass 'telemetry-cargo-toml' "rev $pin" }
            }
        }
        $lockOk = $false
        $cargoLock = Read-FileAtCommit $appDir $appSha 'src-tauri/Cargo.lock'
        if ($null -eq $cargoLock) { Fail "$($app.id): src-tauri/Cargo.lock is missing at $appSha." }
        else {
            $blocks = @(($cargoLock -split '(?m)^\[\[package\]\]\s*$') | Where-Object { $_ -match "(?m)^name\s*=\s*""$([regex]::Escape($script:TelemetryCrate))""\s*$" })
            if ($blocks.Count -ne 1) { Fail "$($app.id): Cargo.lock must contain $($script:TelemetryCrate) exactly once (found $($blocks.Count))." }
            else {
                $src = [regex]::Match($blocks[0], '(?m)^source\s*=\s*"(?<v>[^"]+)"')
                $m = [regex]::Match($src.Groups['v'].Value, '^git\+(?<url>[^?#]+)\?rev=(?<rev>[0-9a-f]{40})#(?<sha>[0-9a-f]{40})$')
                if (-not $src.Success -or -not $m.Success) { Fail "$($app.id): Cargo.lock source of $($script:TelemetryCrate) is not a git source pinned by rev ('$($src.Groups['v'].Value)')." }
                elseif ($m.Groups['url'].Value -cne $telemetry.url) { Fail "$($app.id): Cargo.lock source URL '$($m.Groups['url'].Value)' is not $($telemetry.url)." }
                elseif ($m.Groups['rev'].Value -cne $pin -or $m.Groups['sha'].Value -cne $pin) { Fail "$($app.id): Cargo.lock resolves $($script:TelemetryCrate) to rev '$($m.Groups['rev'].Value)' / commit '$($m.Groups['sha'].Value)', not the manifest pin '$pin'." }
                else { $lockOk = $true; Pass 'telemetry-cargo-lock' "source resolved to $pin" }
            }
        }
        $telemetryVerified = ($tomlOk -and $lockOk -and (@($app.dependsOn) -ccontains $telemetry.id))
    }

    foreach ($r in @($Manifest.repositories)) {
        if ($r.name -ceq $script:ApplicationName) { $roles[$r.id] = 'application' }
        elseif ($r.name -ceq $script:TelemetryName -and $telemetryVerified) { $roles[$r.id] = 'build-input' }
        else {
            $roles[$r.id] = 'unverified'
            $msg = "$($r.name) ($($r.id)): listed in the manifest but has no verified role in this release (no verified build dependency of the application)."
            if ($AllowUnverified) { $warnings.Add($msg) } else { Fail "$msg Remove it, or pass -AllowUnverified to accept it as an unverified entry." }
        }
    }

    # 5. Release tag availability: Installer repository and its remote. Never created or changed here.
    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Container)) { Fail "Installer repository folder not found: $InstallerPath" }
    else {
        $itop = Invoke-GitRead $InstallerPath @('rev-parse', '--show-toplevel')
        $iurl = (Invoke-GitRead $InstallerPath @('config', '--get', 'remote.origin.url')).StdOut.Trim()
        $iid = ConvertFrom-GitHubUrl $iurl
        if ($itop.Code -ne 0) { Fail "Installer folder is not a Git repository: $InstallerPath" }
        elseif (-not $iid -or $iid.Owner -cne 'RoadPilotHQ' -or $iid.Name -cne 'RoadPilot-Installer') { Fail "Installer origin '$iurl' is not RoadPilotHQ/RoadPilot-Installer." }
        else {
            $local = Invoke-GitRead $InstallerPath @('rev-parse', '--verify', '--quiet', "refs/tags/$releaseTag")
            if ($local.Code -eq 0) { Fail "Tag '$releaseTag' already exists locally in the Installer repository. Tags are never overwritten." }
            else {
                $remote = Invoke-GitRead $InstallerPath @('ls-remote', '--tags', $TagRemote, "refs/tags/$releaseTag")
                if ($remote.Code -ne 0) { Fail "Cannot verify that tag '$releaseTag' is free on remote '$TagRemote' (failing closed): $($remote.StdErr.Trim())" }
                elseif ($remote.StdOut.Trim()) { Fail "Tag '$releaseTag' already exists on remote '$TagRemote'. Tags are never overwritten." }
                else { Pass 'release-tag-free' "$releaseTag does not exist locally or on the tag remote" }
            }
        }
    }

    if ($errors.Count) { return [pscustomobject]@{ Errors = @($errors); Warnings = @($warnings); Resolved = $null } }

    # Deterministic resolved description: fixed key order, buildOrder order, no timestamps, no local paths.
    $repos = @()
    $order = 0
    foreach ($id in @($Manifest.buildOrder)) {
        $r = $byId[$id]
        $order++
        $repos += , ([ordered]@{
                order     = $order
                id        = [string]$r.id
                name      = [string]$r.name
                url       = [string]$r.url
                version   = [string]$r.version
                commit    = [string]$r.pin.commit
                role      = $roles[$r.id]
                dependsOn = @($r.dependsOn | ForEach-Object { [string]$_ })
            })
    }
    $dependencies = @()
    foreach ($id in @($Manifest.buildOrder)) {
        foreach ($d in @($byId[$id].dependsOn)) {
            $isVerified = ($byId[$id].name -ceq $script:ApplicationName -and $byId[$d].name -ceq $script:TelemetryName -and $telemetryVerified)
            $dependencies += , ([ordered]@{
                    from     = [string]$id
                    to       = [string]$d
                    verified = $isVerified
                    evidence = $(if ($isVerified) { "src-tauri/Cargo.toml rev and src-tauri/Cargo.lock source equal the pinned $($script:TelemetryName) commit" } else { 'declared in the manifest only' })
                })
        }
    }
    $result = [ordered]@{
        resolvedSchemaVersion = 1
        release               = [ordered]@{ version = [string]$Manifest.release.version; tag = $releaseTag; channel = [string]$Manifest.release.channel }
        platforms             = @($Manifest.platforms | ForEach-Object { [ordered]@{ os = [string]$_.os; arch = [string]$_.arch } })
        repositories          = $repos
        dependencies          = $dependencies
        warnings              = @($warnings)
        checks                = $checks.ToArray()
    }
    return [pscustomobject]@{ Errors = @(); Warnings = @($warnings); Resolved = $result }
}

function ConvertTo-ResolvedJson($Resolved) {
    return ((ConvertTo-Json -InputObject $Resolved -Depth 8) -replace "`r`n", "`n") + "`n"
}

# ---------------------------------------------------------------- command line

if ($MyInvocation.InvocationName -eq '.') { return }

try {
    if (-not $ManifestPath) { throw 'Provide -ManifestPath.' }
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Manifest not found: $ManifestPath" }
    try { $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Invalid JSON in ${ManifestPath}: $($_.Exception.Message)" }
    if (-not $InstallerPath) { $InstallerPath = Split-Path -Parent $PSScriptRoot }
    $map = Get-RepositoryMap $RepositoryMapPath $GitConfigPath
    $res = Resolve-ReleaseManifest -Manifest $manifest -RepositoryMap $map -InstallerPath $InstallerPath -TagRemote $TagRemote -Tag $Tag -AllowUnverified:$AllowUnverified -Fetch:$Fetch
    foreach ($w in $res.Warnings) { Write-Host "warning: $w" }
    if ($res.Errors.Count) {
        Write-Host "Resolution FAILED for ${ManifestPath}:"
        $res.Errors | ForEach-Object { Write-Host "  - $_" }
        exit 1
    }
    $json = ConvertTo-ResolvedJson $res.Resolved
    if ($OutFile) { [System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding $false)) }
    else { Write-Host $json }
    Write-Host "Resolved release $($res.Resolved.release.tag): $(@($res.Resolved.repositories).Count) repositories, all checks passed. (Nothing was built.)"
    exit 0
}
catch {
    Write-Host "STOPPED: $($_.Exception.Message)"
    exit 1
}
