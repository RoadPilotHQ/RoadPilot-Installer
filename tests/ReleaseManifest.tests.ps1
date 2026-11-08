# Rule tests for scripts/Test-ReleaseManifest.ps1. Windows PowerShell 5.1 compatible, no dependencies.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts/Test-ReleaseManifest.ps1')

$examplePath = Join-Path $root 'config/release-manifest.example.json'
$script:fail = 0
function New-Example { Get-Content -LiteralPath $examplePath -Raw -Encoding UTF8 | ConvertFrom-Json }
function New-Verified {
    $m = New-Example
    $m.status = 'verified'
    $m.release.version = '1.0.0'
    $n = 0
    foreach ($r in $m.repositories) {
        $n++
        $r.version = '0.1.0'
        # Synthetic test-only SHAs; they do not refer to any real commit.
        $r.pin.commit = ('{0:x}' -f $n).PadLeft(40, 'a')
    }
    $m
}
function Expect([string]$Name, $Manifest, [bool]$ShouldBeValid, [string]$ErrorLike = '', [switch]$RequireVerified) {
    $errs = Get-ReleaseManifestErrors -Manifest $Manifest -RequireVerified:$RequireVerified
    $valid = $errs.Count -eq 0
    $ok = ($valid -eq $ShouldBeValid) -and ($ShouldBeValid -or -not $ErrorLike -or (@($errs | Where-Object { $_ -like $ErrorLike }).Count -gt 0))
    if ($ok) { Write-Host "PASS $Name" } else { Write-Host "FAIL $Name :: $($errs -join ' | ')"; $script:fail++ }
}

Expect 'example is valid' (New-Example) $true
Expect 'example is rejected when verified is required' (New-Example) $false '*verified manifest is required*' -RequireVerified
Expect 'fully pinned verified manifest is valid' (New-Verified) $true
Expect 'fully pinned verified manifest passes RequireVerified' (New-Verified) $true -RequireVerified

$m = New-Verified; $m.repositories[0].pin.commit = 'UNRESOLVED'
Expect 'verified rejects UNRESOLVED commit' $m $false '*pin.commit is UNRESOLVED*'

$m = New-Verified; $m.release.version = 'UNRESOLVED'
Expect 'verified rejects UNRESOLVED release version' $m $false '*release.version is UNRESOLVED*'

$m = New-Verified; $m.repositories[0].pin.commit = 'main'
Expect 'branch name is not a valid pin' $m $false '*40-character*'

$m = New-Verified; $m.repositories[0].pin.commit = 'ABCDEF'.PadRight(40, '0')
Expect 'uppercase or short SHA is rejected' $m $false '*40-character*'

$m = New-Example; $m.repositories[0] | Add-Member -NotePropertyName branch -NotePropertyValue 'main'
Expect 'branch property is rejected' $m $false '*unknown property*branch*'

$m = New-Example; $m.repositories[0].url = 'https://github.com/someone/RoadPilot-Telemetry.git'
Expect 'foreign repository URL is rejected' $m $false '*url must be*'

$m = New-Example; $m.repositories[1].id = $m.repositories[0].id
Expect 'duplicate id is rejected' $m $false '*Duplicate repository id*'

$m = New-Example; $m.buildOrder = @('roadpilot', 'telemetry')
Expect 'build order violating a dependency is rejected' $m $false '*before its dependency*'

$m = New-Example; $m.buildOrder = @('telemetry')
Expect 'repository missing from build order is rejected' $m $false '*missing from buildOrder*'

$m = New-Example; $m.repositories[1].dependsOn = @('nonexistent')
Expect 'unknown dependency is rejected' $m $false '*unknown id*'

$m = New-Example; $m.repositories[0].dependsOn = @('roadpilot'); $m.repositories[0] | Add-Member -NotePropertyName dependencyEvidence -NotePropertyValue 'test'
Expect 'dependency cycle is rejected' $m $false '*cycle*'

$m = New-Example; $m.repositories[1].PSObject.Properties.Remove('dependencyEvidence')
Expect 'dependency without evidence is rejected' $m $false '*requires dependencyEvidence*'

$m = New-Example; $m.platforms = @([pscustomobject]@{ os = 'linux'; arch = 'x64' })
Expect 'unsupported platform is rejected' $m $false '*Unsupported platform*'

$m = New-Example; $m.PSObject.Properties.Remove('buildOrder')
Expect 'missing top-level property is rejected' $m $false '*Missing top-level*'

# The example manifest describes only the verified build inputs: RoadPilot depends on RoadPilot-Telemetry.
function Expect-True([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { Write-Host "PASS $Name" } else { Write-Host "FAIL $Name :: $Detail"; $script:fail++ }
}
$ex = New-Example
$schema = Get-Content -LiteralPath (Join-Path $root 'config/release-manifest.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$exErrors = Get-ReleaseManifestErrors -Manifest $ex
Expect-True 'example passes the manifest validation rules' ($exErrors.Count -eq 0) ($exErrors -join '; ')
Expect-True 'example is marked as an example, not verified' ($ex.status -eq 'example')
$exNames = (@($ex.repositories | ForEach-Object { $_.name }) -join ',')
Expect-True 'example contains exactly the two verified repositories' ($exNames -ceq 'RoadPilot-Telemetry,RoadPilot') $exNames
Expect-True 'example has no unverified repository (Map, Language, Visualization, Plugin, SDK)' (@($ex.repositories | Where-Object { $_.name -cnotin 'RoadPilot', 'RoadPilot-Telemetry' }).Count -eq 0)
$telEntry = @($ex.repositories | Where-Object { $_.name -ceq 'RoadPilot-Telemetry' })[0]
$appEntry = @($ex.repositories | Where-Object { $_.name -ceq 'RoadPilot' })[0]
Expect-True 'RoadPilot depends on RoadPilot-Telemetry and carries its evidence' (((@($appEntry.dependsOn) -join ',') -ceq $telEntry.id) -and ($appEntry.dependencyEvidence -match 'Cargo\.toml'))
Expect-True 'RoadPilot-Telemetry has no dependencies' (@($telEntry.dependsOn).Count -eq 0)
Expect-True 'build order is telemetry before roadpilot' ((@($ex.buildOrder) -join ',') -ceq "$($telEntry.id),$($appEntry.id)")
$namePattern = $schema.properties.repositories.items.properties.name.pattern
$urlPattern = $schema.properties.repositories.items.properties.url.pattern
Expect-True 'example repository names and URLs match the schema patterns' (@($ex.repositories | Where-Object { $_.name -cnotmatch $namePattern -or $_.url -cnotmatch $urlPattern }).Count -eq 0)
Expect-True 'example invents no values: every version and commit is UNRESOLVED' ((@($ex.repositories | Where-Object { $_.version -cne 'UNRESOLVED' -or $_.pin.commit -cne 'UNRESOLVED' }).Count -eq 0) -and ($ex.release.version -ceq 'UNRESOLVED'))
Expect-True 'example is rejected where a verified manifest is required' ((Get-ReleaseManifestErrors -Manifest $ex -RequireVerified).Count -gt 0)

if ($script:fail) { Write-Host "$($script:fail) test(s) failed."; exit 1 }
Write-Host 'All manifest rule tests passed.'
exit 0
