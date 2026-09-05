<#
.SYNOPSIS
  Compares replay outputs with a captured build-state manifest.
#>
param(
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..\..\..'),

    [Parameter(Mandatory)]
    [string]$StateDir,

    [string]$ResultPath,

    [int]$Throttle = 16
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path $RepoRoot).Path
$StateDir = (Resolve-Path $StateDir).Path
$metadata = Get-Content -LiteralPath (Join-Path $StateDir 'meta.json') -Raw | ConvertFrom-Json
$comparison = if ($IsWindows)
{
    [System.StringComparison]::OrdinalIgnoreCase
}
else
{
    [System.StringComparison]::Ordinal
}

if (-not $RepoRoot.Equals([string]$metadata.repoRoot, $comparison))
{
    throw "Build state was captured for '$($metadata.repoRoot)', not '$RepoRoot'. Runtime CMake state is path-specific."
}

$referencePath = Join-Path $StateDir $metadata.manifestFile
$reference = Get-Content -LiteralPath $referencePath -Raw | ConvertFrom-Json

$replayPath = Join-Path $StateDir 'replay-output-manifest.json'
& (Join-Path $PSScriptRoot 'Write-BuildStateManifest.ps1') `
    -RepoRoot $RepoRoot `
    -Roots @($metadata.manifestRoots) `
    -OutputPath $replayPath `
    -Throttle $Throttle
$replay = Get-Content -LiteralPath $replayPath -Raw | ConvertFrom-Json

$referenceEntries = [System.Collections.Generic.Dictionary[string, object]]::new(
    [System.StringComparer]::Ordinal)
foreach ($entry in @($reference.entries))
{
    $referenceEntries.Add([string]$entry.Path, $entry)
}

$replayEntries = [System.Collections.Generic.Dictionary[string, object]]::new(
    [System.StringComparer]::Ordinal)
foreach ($entry in @($replay.entries))
{
    $replayEntries.Add([string]$entry.Path, $entry)
}

$added = [System.Collections.Generic.List[object]]::new()
$removed = [System.Collections.Generic.List[object]]::new()
$contentChanged = [System.Collections.Generic.List[object]]::new()
$mtimeOnly = [System.Collections.Generic.List[object]]::new()

foreach ($path in $replayEntries.Keys)
{
    if (-not $referenceEntries.ContainsKey($path))
    {
        $added.Add($replayEntries[$path])
        continue
    }

    $before = $referenceEntries[$path]
    $after = $replayEntries[$path]
    if ($before.Kind -ne $after.Kind -or
        $before.Sha256 -ne $after.Sha256 -or
        $before.LinkTarget -ne $after.LinkTarget)
    {
        $contentChanged.Add([pscustomobject]@{
            path = $path
            referenceKind = $before.Kind
            replayKind = $after.Kind
            referenceSha256 = $before.Sha256
            replaySha256 = $after.Sha256
            referenceLinkTarget = $before.LinkTarget
            replayLinkTarget = $after.LinkTarget
            referenceSize = $before.Size
            replaySize = $after.Size
        })
    }
    elseif (
        ([long]$before.LastWriteTimeUtcTicks - ([long]$before.LastWriteTimeUtcTicks % [TimeSpan]::TicksPerSecond)) -ne
        ([long]$after.LastWriteTimeUtcTicks - ([long]$after.LastWriteTimeUtcTicks % [TimeSpan]::TicksPerSecond)))
    {
        $mtimeOnly.Add($after)
    }
}

foreach ($path in $referenceEntries.Keys)
{
    if (-not $replayEntries.ContainsKey($path))
    {
        $removed.Add($referenceEntries[$path])
    }
}

$result = [ordered]@{
    referenceFiles = $referenceEntries.Count
    replayFiles = $replayEntries.Count
    added = $added.Count
    removed = $removed.Count
    contentChanged = $contentChanged.Count
    mtimeOnly = $mtimeOnly.Count
    addedFiles = @($added | Select-Object -First 100)
    removedFiles = @($removed | Select-Object -First 100)
    contentChanges = @($contentChanged | Select-Object -First 100)
}

if (-not $ResultPath)
{
    $ResultPath = Join-Path $StateDir 'comparison.json'
}
$resultParent = Split-Path -Parent $ResultPath
if ($resultParent)
{
    New-Item -ItemType Directory -Path $resultParent -Force | Out-Null
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding utf8NoBOM

Write-Host "[compare] reference=$($result.referenceFiles) replay=$($result.replayFiles) added=$($result.added) removed=$($result.removed) content=$($result.contentChanged) mtimeOnly=$($result.mtimeOnly)"
if ($contentChanged.Count -gt 0)
{
    $contentChanged | Select-Object -First 40 | Format-Table path, referenceSize, replaySize
}

if ($added.Count -ne 0 -or $removed.Count -ne 0 -or $contentChanged.Count -ne 0)
{
    throw "Build output comparison failed. See $ResultPath."
}

$global:LASTEXITCODE = 0
