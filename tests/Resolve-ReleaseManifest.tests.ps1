# Tests for scripts/Resolve-ReleaseManifest.ps1 (Phase 2B).
# Every test builds isolated temporary Git repositories. No real RoadPilot repository, tag or
# remote is read or changed, and no network is used. Windows PowerShell 5.1 compatible.
$ErrorActionPreference = 'Stop'
$InstallerRoot = Split-Path -Parent $PSScriptRoot
$ResolveScript = Join-Path $InstallerRoot 'scripts/Resolve-ReleaseManifest.ps1'
. $ResolveScript

$script:Fail = 0
$script:Pass = 0
$script:Roots = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- helpers

function Invoke-G([string]$Dir, [string[]]$GitArgs) {
    $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $Dir -c user.name=Test -c user.email=test@example.invalid -c commit.gpgsign=false -c core.autocrlf=false @GitArgs 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed in ${Dir}: $out" }
        return ($out -join "`n").Trim()
    }
    finally { $ErrorActionPreference = $saved }
}

function Write-Lf([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))
}

function New-FixtureRepo([string]$Root, [string]$Name) {
    $dir = Join-Path $Root $Name
    New-Item -ItemType Directory -Path $dir | Out-Null
    $null = Invoke-G $dir @('init', '--quiet', '-b', 'main')
    $null = Invoke-G $dir @('remote', 'add', 'origin', "https://github.com/RoadPilotHQ/$Name.git")
    return $dir
}

function Set-DefaultBranch([string]$Dir) {
    $null = Invoke-G $Dir @('update-ref', 'refs/remotes/origin/main', 'HEAD')
    $null = Invoke-G $Dir @('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
}

# Builds a consistent set of repositories (application, telemetry, installer with a local bare remote)
# and a verified manifest. -Mutate may change the application files before they are committed.
function New-Fixture([scriptblock]$Mutate) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('rpres-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $root | Out-Null
    $script:Roots.Add($root)

    $telDir = New-FixtureRepo $root 'RoadPilot-Telemetry'
    Write-Lf (Join-Path $telDir 'README.md') "telemetry`n"
    $null = Invoke-G $telDir @('add', '--all'); $null = Invoke-G $telDir @('commit', '--quiet', '-m', 'Telemetry initial commit')
    Set-DefaultBranch $telDir
    $telSha = Invoke-G $telDir @('rev-parse', 'HEAD')

    $files = [ordered]@{
        'package.json'              = '{ "name": "roadpilot", "version": "1.0.0" }'
        'src-tauri/Cargo.toml'      = "[package]`nname = `"roadpilot`"`nversion = `"1.0.0`"`n`n[dependencies]`nroadpilot-telemetry-client = { git = `"https://github.com/RoadPilotHQ/RoadPilot-Telemetry.git`", rev = `"$telSha`" }`nserde = `"1`"`n"
        'src-tauri/Cargo.lock'      = "[[package]]`nname = `"serde`"`nversion = `"1.0.0`"`n`n[[package]]`nname = `"roadpilot-telemetry-client`"`nversion = `"0.1.0`"`nsource = `"git+https://github.com/RoadPilotHQ/RoadPilot-Telemetry.git?rev=$telSha#$telSha`"`n"
        'src-tauri/tauri.conf.json' = '{ "productName": "RoadPilot", "version": "1.0.0" }'
    }
    if ($Mutate) { & $Mutate $files $telSha }
    $appDir = New-FixtureRepo $root 'RoadPilot'
    foreach ($k in @($files.Keys)) { if ($null -ne $files[$k]) { Write-Lf (Join-Path $appDir $k) $files[$k] } }
    $null = Invoke-G $appDir @('add', '--all'); $null = Invoke-G $appDir @('commit', '--quiet', '-m', 'Application initial commit')
    Set-DefaultBranch $appDir
    $appSha = Invoke-G $appDir @('rev-parse', 'HEAD')

    $instDir = New-FixtureRepo $root 'RoadPilot-Installer'
    $bare = Join-Path $root 'installer-remote.git'
    $null = Invoke-G $root @('init', '--quiet', '--bare', $bare)
    Write-Lf (Join-Path $instDir 'README.md') "installer`n"
    $null = Invoke-G $instDir @('add', '--all'); $null = Invoke-G $instDir @('commit', '--quiet', '-m', 'Installer initial commit')

    $manifest = [ordered]@{
        schemaVersion = 1; status = 'verified'
        release       = [ordered]@{ version = '1.0.0'; channel = 'alpha' }
        platforms     = @([ordered]@{ os = 'windows'; arch = 'x64' })
        repositories  = @(
            [ordered]@{ id = 'telemetry'; name = 'RoadPilot-Telemetry'; url = 'https://github.com/RoadPilotHQ/RoadPilot-Telemetry.git'; role = 'telemetry'; version = '0.1.0'; pin = [ordered]@{ commit = $telSha }; dependsOn = @() },
            [ordered]@{ id = 'roadpilot'; name = 'RoadPilot'; url = 'https://github.com/RoadPilotHQ/RoadPilot.git'; role = 'application'; version = '1.0.0'; pin = [ordered]@{ commit = $appSha }; dependsOn = @('telemetry'); dependencyEvidence = 'Cargo.toml git dependency' }
        )
        buildOrder    = @('telemetry', 'roadpilot')
    }
    return [pscustomobject]@{
        Root = $root; AppDir = $appDir; TelDir = $telDir; InstallerDir = $instDir; Bare = $bare
        TelSha = $telSha; AppSha = $appSha
        Manifest = ($manifest | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
        Map = @{ 'RoadPilot' = $appDir; 'RoadPilot-Telemetry' = $telDir }
    }
}

function Invoke-Resolve($F, [switch]$AllowUnverified, [string]$Tag, [string]$TagRemote) {
    if (-not $TagRemote) { $TagRemote = $F.Bare }
    return Resolve-ReleaseManifest -Manifest $F.Manifest -RepositoryMap $F.Map -InstallerPath $F.InstallerDir -TagRemote $TagRemote -Tag $Tag -AllowUnverified:$AllowUnverified
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Pass++; Write-Host "PASS $Name" }
    catch { $script:Fail++; Write-Host "FAIL $Name :: $($_.Exception.Message)" }
}
function Assert-True($Cond, [string]$Msg) { if (-not $Cond) { throw "Assertion failed: $Msg" } }
function Assert-Equal($Expected, $Actual, [string]$Msg) { if ($Expected -cne $Actual) { throw "$Msg (expected '$Expected', got '$Actual')" } }

# The resolution must fail closed: errors present, no resolved output, and one error matches.
function Assert-Rejected($Result, [string]$Pattern) {
    Assert-True ($Result.Errors.Count -gt 0) 'resolution reports errors'
    Assert-True ($null -eq $Result.Resolved) 'no resolved output is produced on failure'
    Assert-True (@($Result.Errors | Where-Object { $_ -match $Pattern }).Count -gt 0) "an error matches /$Pattern/ but got: $($Result.Errors -join ' | ')"
}

try {
    # ------------------------------------------------------------ valid resolution

    Test-Case 'valid manifest resolves to exact revisions, tag, roles and build order' {
        $f = New-Fixture
        $headBefore = Invoke-G $f.AppDir @('rev-parse', 'HEAD')
        $r = Invoke-Resolve $f
        Assert-True ($r.Errors.Count -eq 0) "no errors but got: $($r.Errors -join ' | ')"
        $x = $r.Resolved
        Assert-Equal 1 $x.resolvedSchemaVersion 'resolvedSchemaVersion'
        Assert-Equal 'v1.0.0' $x.release.tag 'tag'
        Assert-Equal '1.0.0' $x.release.version 'version'
        Assert-Equal 'telemetry,roadpilot' ((@($x.repositories) | ForEach-Object { $_.id }) -join ',') 'build order is preserved'
        Assert-Equal $f.TelSha $x.repositories[0].commit 'telemetry commit'
        Assert-Equal $f.AppSha $x.repositories[1].commit 'application commit'
        Assert-Equal 'build-input' $x.repositories[0].role 'telemetry role'
        Assert-Equal 'application' $x.repositories[1].role 'application role'
        Assert-Equal 'https://github.com/RoadPilotHQ/RoadPilot.git' $x.repositories[1].url 'canonical url'
        Assert-True ($x.dependencies[0].verified -eq $true -and $x.dependencies[0].from -eq 'roadpilot' -and $x.dependencies[0].to -eq 'telemetry') 'verified dependency roadpilot -> telemetry'
        Assert-True (@($x.checks | Where-Object { $_.name -eq 'telemetry-cargo-lock' }).Count -eq 1) 'checks are listed'
        Assert-Equal $headBefore (Invoke-G $f.AppDir @('rev-parse', 'HEAD')) 'repository HEAD unchanged'
        Assert-Equal '' (Invoke-G $f.AppDir @('status', '--porcelain')) 'repository working tree untouched'
    }

    Test-Case 'resolved output is deterministic and free of local paths' {
        $f = New-Fixture
        $a = ConvertTo-ResolvedJson (Invoke-Resolve $f).Resolved
        $b = ConvertTo-ResolvedJson (Invoke-Resolve $f).Resolved
        Assert-Equal $a $b 'two resolutions produce identical text'
        Assert-True ($a.StartsWith("{`n")) 'LF line endings, starts with the object'
        Assert-True ($a.IndexOf('resolvedSchemaVersion') -lt $a.IndexOf('"release"') -and $a.IndexOf('"release"') -lt $a.IndexOf('"repositories"')) 'fixed key order'
        Assert-True (-not $a.Contains($f.Root.Replace('\', '\\'))) 'no local folder is written to the output'
        $parsed = $a | ConvertFrom-Json
        Assert-Equal 2 @($parsed.repositories).Count 'round-trips as JSON'
    }

    Test-Case 'command line writes the same bytes twice, and nothing on failure' {
        $f = New-Fixture
        $mf = Join-Path $f.Root 'manifest.json'; $mp = Join-Path $f.Root 'map.json'
        [System.IO.File]::WriteAllText($mf, ($f.Manifest | ConvertTo-Json -Depth 8))
        [System.IO.File]::WriteAllText($mp, ($f.Map | ConvertTo-Json))
        $o1 = Join-Path $f.Root 'out1.json'; $o2 = Join-Path $f.Root 'out2.json'
        foreach ($o in $o1, $o2) {
            $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ResolveScript -ManifestPath $mf -RepositoryMapPath $mp -InstallerPath $f.InstallerDir -TagRemote $f.Bare -OutFile $o 2>&1
            Assert-Equal 0 $LASTEXITCODE "exit code writing $o"
        }
        Assert-Equal ([System.IO.File]::ReadAllText($o1)) ([System.IO.File]::ReadAllText($o2)) 'identical output files'
        # A pin that does not exist while the branch head exists: no fallback, no output file.
        $bad = $f.Manifest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $bad.repositories[1].pin.commit = ('a' * 40)
        $mf2 = Join-Path $f.Root 'manifest-bad.json'; $o3 = Join-Path $f.Root 'out3.json'
        [System.IO.File]::WriteAllText($mf2, ($bad | ConvertTo-Json -Depth 8))
        $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ResolveScript -ManifestPath $mf2 -RepositoryMapPath $mp -InstallerPath $f.InstallerDir -TagRemote $f.Bare -OutFile $o3 2>&1
        Assert-Equal 1 $LASTEXITCODE 'exit code on failure'
        Assert-True (-not (Test-Path -LiteralPath $o3)) 'no output file after a failed resolution'
    }

    Test-Case 'repositories can be registered through a RoadPilot-Git style config' {
        $f = New-Fixture
        $cfg = [ordered]@{ repositories = @(
                [ordered]@{ name = 'RoadPilot'; localPath = $f.AppDir.Replace('\', '/') },
                [ordered]@{ name = 'RoadPilot-Telemetry'; localPath = $f.TelDir.Replace('\', '/') }) }
        $cp = Join-Path $f.Root 'accounts.json'
        [System.IO.File]::WriteAllText($cp, ($cfg | ConvertTo-Json -Depth 5))
        $map = Get-RepositoryMap $null $cp
        $f.Map = $map
        Assert-True ((Invoke-Resolve $f).Errors.Count -eq 0) 'resolves with the config-derived map'
    }

    # ------------------------------------------------------------ manifest and registration

    Test-Case 'the example manifest is rejected (it is not a verified manifest)' {
        $f = New-Fixture
        $f.Manifest = Get-Content -LiteralPath (Join-Path $InstallerRoot 'config/release-manifest.example.json') -Raw | ConvertFrom-Json
        Assert-Rejected (Invoke-Resolve $f) 'verified manifest is required'
    }

    Test-Case 'unknown repository identifiers in dependsOn or buildOrder are rejected' {
        $f = New-Fixture; $f.Manifest.repositories[1].dependsOn = @('ghost')
        Assert-Rejected (Invoke-Resolve $f) "unknown id 'ghost'"
        $f = New-Fixture; $f.Manifest.buildOrder = @('telemetry', 'roadpilot', 'ghost')
        Assert-Rejected (Invoke-Resolve $f) "unknown id 'ghost'"
    }

    Test-Case 'repository that is not registered locally is rejected' {
        $f = New-Fixture; $f.Map.Remove('RoadPilot-Telemetry')
        Assert-Rejected (Invoke-Resolve $f) 'not registered locally'
    }

    Test-Case 'registered folder that does not exist or is not a repository root is rejected' {
        $f = New-Fixture; $f.Map['RoadPilot'] = Join-Path $f.Root 'does-not-exist'
        Assert-Rejected (Invoke-Resolve $f) 'folder does not exist'
        $f = New-Fixture; $sub = Join-Path $f.AppDir 'src-tauri'; $f.Map['RoadPilot'] = $sub
        Assert-Rejected (Invoke-Resolve $f) 'not the repository root'
        $f = New-Fixture; $plain = Join-Path $f.Root 'plain'; New-Item -ItemType Directory -Path $plain | Out-Null; $f.Map['RoadPilot'] = $plain
        Assert-Rejected (Invoke-Resolve $f) 'not a Git repository'
    }

    Test-Case 'a folder whose origin is a different repository is rejected' {
        $f = New-Fixture
        $null = Invoke-G $f.AppDir @('remote', 'set-url', 'origin', 'https://github.com/RoadPilotHQ/RoadPilot-Map.git')
        Assert-Rejected (Invoke-Resolve $f) "expected 'RoadPilotHQ/RoadPilot'"
        $f = New-Fixture
        $null = Invoke-G $f.AppDir @('remote', 'set-url', 'origin', 'https://github.com/someone/RoadPilot.git')
        Assert-Rejected (Invoke-Resolve $f) "expected 'RoadPilotHQ/RoadPilot'"
    }

    Test-Case 'entries without a verified role are errors, or marked unverified with -AllowUnverified' {
        $f = New-Fixture
        $mapDir = New-FixtureRepo $f.Root 'RoadPilot-Map'
        Write-Lf (Join-Path $mapDir 'README.md') "map`n"
        $null = Invoke-G $mapDir @('add', '--all'); $null = Invoke-G $mapDir @('commit', '--quiet', '-m', 'Map initial commit'); Set-DefaultBranch $mapDir
        $f.Map['RoadPilot-Map'] = $mapDir
        $entry = [pscustomobject]@{ id = 'map'; name = 'RoadPilot-Map'; url = 'https://github.com/RoadPilotHQ/RoadPilot-Map.git'; role = 'map'; version = '0.1.0'; pin = [pscustomobject]@{ commit = (Invoke-G $mapDir @('rev-parse', 'HEAD')) }; dependsOn = @() }
        $f.Manifest.repositories = @($f.Manifest.repositories) + $entry
        $f.Manifest.buildOrder = @('telemetry', 'map', 'roadpilot')
        Assert-Rejected (Invoke-Resolve $f) 'no verified role'
        $r = Invoke-Resolve $f -AllowUnverified
        Assert-True ($r.Errors.Count -eq 0) "allowed with -AllowUnverified: $($r.Errors -join ' | ')"
        Assert-Equal 'unverified' (@($r.Resolved.repositories | Where-Object { $_.id -eq 'map' })[0].role) 'role is marked unverified'
        Assert-Equal 1 @($r.Resolved.warnings).Count 'a warning is recorded'
        Assert-Equal 'telemetry,map,roadpilot' ((@($r.Resolved.repositories) | ForEach-Object { $_.id }) -join ',') 'declared build order kept'
        Assert-True (@($r.Resolved.dependencies | Where-Object { $_.verified }).Count -eq 1) 'the unverified entry creates no verified dependency'
    }

    Test-Case 'the application must declare its Telemetry dependency, and both entries must exist' {
        $f = New-Fixture; $f.Manifest.repositories[1].dependsOn = @()
        Assert-Rejected (Invoke-Resolve $f) 'dependsOn must declare'
        $f = New-Fixture
        $f.Manifest.repositories = @($f.Manifest.repositories[1]); $f.Manifest.repositories[0].dependsOn = @(); $f.Manifest.buildOrder = @('roadpilot')
        Assert-Rejected (Invoke-Resolve $f) 'RoadPilot-Telemetry. entry'
    }

    # ------------------------------------------------------------ revisions

    Test-Case 'invalid and unresolved revisions are rejected without any fallback' {
        foreach ($bad in 'UNRESOLVED', 'main', 'HEAD', 'abc1234', ('A' * 40)) {
            $f = New-Fixture; $f.Manifest.repositories[1].pin.commit = $bad
            Assert-Rejected (Invoke-Resolve $f) '(UNRESOLVED|40-character)'
        }
        $f = New-Fixture; $f.Manifest.repositories[1].pin.commit = ('a' * 40)
        $r = Invoke-Resolve $f
        Assert-Rejected $r 'does not exist in the repository'
        Assert-True ((Invoke-G $f.AppDir @('rev-parse', 'refs/remotes/origin/main')) -ne ('a' * 40)) 'branch head exists but is not substituted'
    }

    Test-Case 'a commit that exists but is not reachable from the default branch is rejected' {
        $f = New-Fixture
        $null = Invoke-G $f.AppDir @('checkout', '--quiet', '-b', 'side')
        $null = Invoke-G $f.AppDir @('commit', '--quiet', '--allow-empty', '-m', 'Side branch only commit')
        $side = Invoke-G $f.AppDir @('rev-parse', 'HEAD')
        $null = Invoke-G $f.AppDir @('checkout', '--quiet', 'main')
        $f.Manifest.repositories[1].pin.commit = $side
        Assert-Rejected (Invoke-Resolve $f) 'not reachable from the default branch'
    }

    Test-Case 'an unknown default branch fails closed' {
        $f = New-Fixture
        $null = Invoke-G $f.AppDir @('symbolic-ref', '--delete', 'refs/remotes/origin/HEAD')
        Assert-Rejected (Invoke-Resolve $f) 'default branch is unknown'
    }

    Test-Case 'reachability uses the default branch, not other remote branches' {
        $f = New-Fixture
        $null = Invoke-G $f.AppDir @('commit', '--quiet', '--allow-empty', '-m', 'Feature commit')
        $feat = Invoke-G $f.AppDir @('rev-parse', 'HEAD')
        $null = Invoke-G $f.AppDir @('update-ref', 'refs/remotes/origin/feature', $feat)
        $f.Manifest.repositories[1].pin.commit = $feat
        Assert-Rejected (Invoke-Resolve $f) 'not reachable from the default branch'
    }

    # ------------------------------------------------------------ versions

    Test-Case 'RoadPilot version mismatches are rejected in each of the three locations and against the manifest' {
        $f = New-Fixture { param($files) $files['package.json'] = '{ "version": "1.0.1" }' }
        Assert-Rejected (Invoke-Resolve $f) "package.json is '1.0.1'"
        $f = New-Fixture { param($files) $files['src-tauri/Cargo.toml'] = ($files['src-tauri/Cargo.toml'] -replace 'version = "1.0.0"', 'version = "1.0.2"') }
        Assert-Rejected (Invoke-Resolve $f) "Cargo.toml is '1.0.2'"
        $f = New-Fixture { param($files) $files['src-tauri/tauri.conf.json'] = '{ "version": "2.0.0" }' }
        Assert-Rejected (Invoke-Resolve $f) "tauri.conf.json is '2.0.0'"
        $f = New-Fixture; $f.Manifest.repositories[1].version = '1.0.3'
        Assert-Rejected (Invoke-Resolve $f) "manifest says '1.0.3'"
    }

    Test-Case 'a missing version file or version is rejected' {
        $f = New-Fixture { param($files) $files['package.json'] = $null }
        Assert-Rejected (Invoke-Resolve $f) 'package.json is missing'
        $f = New-Fixture { param($files) $files['src-tauri/tauri.conf.json'] = '{ "productName": "RoadPilot" }' }
        Assert-Rejected (Invoke-Resolve $f) 'no version found in src-tauri/tauri.conf.json'
    }

    Test-Case 'versions are read at the pinned commit, not from the working tree' {
        $f = New-Fixture
        Write-Lf (Join-Path $f.AppDir 'package.json') '{ "version": "9.9.9" }'
        $r = Invoke-Resolve $f
        Assert-True ($r.Errors.Count -eq 0) "uncommitted edits are ignored: $($r.Errors -join ' | ')"
        $null = Invoke-G $f.AppDir @('commit', '--quiet', '-am', 'Later version bump')
        Assert-True ((Invoke-Resolve $f).Errors.Count -eq 0) 'later commits do not change the pinned result'
    }

    # ------------------------------------------------------------ telemetry dependency

    Test-Case 'Cargo.toml rev that differs from the Telemetry pin is rejected' {
        $f = New-Fixture { param($files, $tel) $files['src-tauri/Cargo.toml'] = $files['src-tauri/Cargo.toml'].Replace($tel, ('b' * 40)) }
        Assert-Rejected (Invoke-Resolve $f) 'Cargo.toml rev .* differs from the manifest'
    }

    Test-Case 'Cargo.toml dependency by branch, tag, without rev or from another URL is rejected' {
        $f = New-Fixture { param($files, $tel) $files['src-tauri/Cargo.toml'] = $files['src-tauri/Cargo.toml'].Replace("rev = `"$tel`"", 'branch = "main"') }
        Assert-Rejected (Invoke-Resolve $f) 'uses a branch or tag'
        $f = New-Fixture { param($files, $tel) $files['src-tauri/Cargo.toml'] = $files['src-tauri/Cargo.toml'].Replace("rev = `"$tel`"", 'tag = "v1"') }
        Assert-Rejected (Invoke-Resolve $f) 'uses a branch or tag'
        $f = New-Fixture { param($files, $tel) $files['src-tauri/Cargo.toml'] = $files['src-tauri/Cargo.toml'].Replace(", rev = `"$tel`"", '') }
        Assert-Rejected (Invoke-Resolve $f) 'has no rev'
        $f = New-Fixture { param($files) $files['src-tauri/Cargo.toml'] = $files['src-tauri/Cargo.toml'].Replace('RoadPilotHQ/RoadPilot-Telemetry', 'evil/RoadPilot-Telemetry') }
        Assert-Rejected (Invoke-Resolve $f) 'git source in Cargo.toml is not the manifest URL'
    }

    Test-Case 'Cargo.lock that resolves the dependency to another commit is rejected' {
        $f = New-Fixture { param($files, $tel) $files['src-tauri/Cargo.lock'] = $files['src-tauri/Cargo.lock'].Replace("#$tel", ('#' + ('c' * 40))) }
        Assert-Rejected (Invoke-Resolve $f) 'Cargo.lock resolves'
        $f = New-Fixture { param($files, $tel) $files['src-tauri/Cargo.lock'] = $files['src-tauri/Cargo.lock'].Replace("rev=$tel", ('rev=' + ('d' * 40))) }
        Assert-Rejected (Invoke-Resolve $f) 'Cargo.lock resolves'
        $f = New-Fixture { param($files, $tel) $files['src-tauri/Cargo.lock'] = $files['src-tauri/Cargo.lock'].Replace("git+https://github.com/RoadPilotHQ/RoadPilot-Telemetry.git?rev=$tel#$tel", 'registry+https://github.com/rust-lang/crates.io-index') }
        Assert-Rejected (Invoke-Resolve $f) 'not a git source pinned by rev'
        $f = New-Fixture { param($files, $tel) $files['src-tauri/Cargo.lock'] = $files['src-tauri/Cargo.lock'].Replace('RoadPilotHQ/RoadPilot-Telemetry.git?rev', 'evil/RoadPilot-Telemetry.git?rev') }
        Assert-Rejected (Invoke-Resolve $f) 'Cargo.lock source URL'
        $f = New-Fixture { param($files) $files['src-tauri/Cargo.lock'] = $null }
        Assert-Rejected (Invoke-Resolve $f) 'Cargo.lock is missing'
    }

    Test-Case 'the manifest Telemetry pin must match what the application actually uses' {
        $f = New-Fixture
        $null = Invoke-G $f.TelDir @('commit', '--quiet', '--allow-empty', '-m', 'Newer telemetry commit')
        Set-DefaultBranch $f.TelDir
        $f.Manifest.repositories[0].pin.commit = (Invoke-G $f.TelDir @('rev-parse', 'HEAD'))
        $r = Invoke-Resolve $f
        Assert-Rejected $r 'Cargo.toml rev .* differs from the manifest'
        Assert-True (@($r.Errors | Where-Object { $_ -match 'Cargo.lock resolves' }).Count -eq 1) 'Cargo.lock disagreement is reported too'
    }

    # ------------------------------------------------------------ release tag

    Test-Case 'an existing local tag is rejected' {
        $f = New-Fixture
        $null = Invoke-G $f.InstallerDir @('tag', '-a', 'v1.0.0', '-m', 'Existing local tag')
        Assert-Rejected (Invoke-Resolve $f) 'already exists locally'
    }

    Test-Case 'an existing remote tag is rejected, even without a local tag' {
        $f = New-Fixture
        $null = Invoke-G $f.InstallerDir @('tag', '-a', 'v1.0.0', '-m', 'Existing remote tag')
        $null = Invoke-G $f.InstallerDir @('push', '--quiet', $f.Bare, 'refs/tags/v1.0.0')
        $null = Invoke-G $f.InstallerDir @('tag', '-d', 'v1.0.0')
        Assert-Rejected (Invoke-Resolve $f) 'already exists on remote'
    }

    Test-Case 'other tags do not block the release, and the resolver never creates or changes tags' {
        $f = New-Fixture
        $null = Invoke-G $f.InstallerDir @('tag', '-a', 'v0.9.0', '-m', 'Older release')
        $null = Invoke-G $f.InstallerDir @('push', '--quiet', $f.Bare, 'refs/tags/v0.9.0')
        $before = Invoke-G $f.InstallerDir @('tag', '-l')
        Assert-True ((Invoke-Resolve $f).Errors.Count -eq 0) 'v1.0.0 is free'
        Assert-Equal $before (Invoke-G $f.InstallerDir @('tag', '-l')) 'local tags unchanged'
        Assert-Equal '' (Invoke-G $f.Bare @('tag', '-l', 'v1.0.0')) 'remote tag not created'
    }

    Test-Case 'an unreachable tag remote fails closed instead of assuming the tag is free' {
        $f = New-Fixture
        Assert-Rejected (Invoke-Resolve $f -TagRemote (Join-Path $f.Root 'no-such-remote.git')) 'failing closed'
    }

    Test-Case 'a requested tag that differs from the manifest version is rejected, and the Installer identity is checked' {
        $f = New-Fixture
        Assert-Rejected (Invoke-Resolve $f -Tag 'v1.0.1') 'does not match the manifest release version'
        Assert-True ((Invoke-Resolve $f -Tag 'v1.0.0').Errors.Count -eq 0) 'matching tag is accepted'
        $null = Invoke-G $f.InstallerDir @('remote', 'set-url', 'origin', 'https://github.com/RoadPilotHQ/RoadPilot-Website.git')
        Assert-Rejected (Invoke-Resolve $f) 'Installer origin'
    }
}
finally {
    foreach ($r in $script:Roots) { if (Test-Path -LiteralPath $r) { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue } }
}

if ($script:Fail) { Write-Host "$($script:Fail) test(s) failed, $($script:Pass) passed."; exit 1 }
Write-Host "All $($script:Pass) resolution tests passed."
exit 0
