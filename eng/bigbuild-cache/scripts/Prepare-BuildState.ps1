<#
.SYNOPSIS
  Back-dates unchanged tracked inputs after build-state restoration.

.DESCRIPTION
  Runtime's native state contains an internally ordered CMake and Ninja graph,
  so restored output timestamps are preserved. Inputs unchanged from the
  captured commit are moved below the oldest cached output. Changed and new
  tracked inputs are moved above the newest cached output.
#>
param(
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..\..\..'),

    [Parameter(Mandatory)]
    [string]$StateDir,

    [string]$MetricsPath,

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

function Invoke-Git([string[]]$arguments)
{
    $originalOutputEncoding = [Console]::OutputEncoding
    try
    {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $result = @(& git @arguments)
        $exitCode = $LASTEXITCODE
    }
    finally
    {
        [Console]::OutputEncoding = $originalOutputEncoding
    }

    if ($exitCode -ne 0)
    {
        throw "git $($arguments -join ' ') failed ($exitCode)."
    }

    return $result
}

Invoke-Git @('-C', $RepoRoot, 'cat-file', '-e', "$($metadata.sha)^{commit}") | Out-Null

function Add-GitPaths(
    [System.Collections.Generic.HashSet[string]]$paths,
    [string[]]$arguments)
{
    $gitArguments = @('-c', 'core.quotepath=false', '-C', $RepoRoot) + $arguments
    $result = @(Invoke-Git $gitArguments)

    foreach ($path in $result)
    {
        if ($path)
        {
            [void]$paths.Add($path)
        }
    }
}

$changed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
Add-GitPaths $changed @('diff', '--name-only', $metadata.sha, 'HEAD', '--')
Add-GitPaths $changed @('diff', '--name-only', 'HEAD', '--')
Add-GitPaths $changed @('diff', '--cached', '--name-only', 'HEAD', '--')

$tracked = @(Invoke-Git @('-c', 'core.quotepath=false', '-C', $RepoRoot, 'ls-files'))

$unchangedPaths = [System.Collections.Generic.List[string]]::new()
$changedPaths = [System.Collections.Generic.List[string]]::new()
$changedMissing = 0
$unchangedMissing = 0

foreach ($relativePath in $tracked)
{
    $fullPath = Join-Path $RepoRoot ($relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf))
    {
        if ($changed.Contains($relativePath))
        {
            $changedMissing++
        }
        else
        {
            $unchangedMissing++
        }
        continue
    }

    if ($changed.Contains($relativePath))
    {
        $changedPaths.Add($fullPath)
    }
    else
    {
        $unchangedPaths.Add($fullPath)
    }
}

if ($unchangedMissing -ne 0)
{
    throw "The checkout is missing $unchangedMissing tracked files that are unchanged from the captured commit."
}

if (-not ('RuntimeBuildStateTimestamps' -as [type]))
{
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Threading.Tasks;

public static class RuntimeBuildStateTimestamps
{
    public static void SetLastWriteTimeUtc(string[] paths, long ticks, int maxDegreeOfParallelism)
    {
        var timestamp = new DateTime(ticks, DateTimeKind.Utc);
        Parallel.ForEach(
            paths,
            new ParallelOptions { MaxDegreeOfParallelism = maxDegreeOfParallelism },
            path => File.SetLastWriteTimeUtc(path, timestamp));
    }
}
'@
}

function ConvertTo-UtcDateTime([object]$value)
{
    if ($value -is [DateTime])
    {
        return ([DateTime]$value).ToUniversalTime()
    }

    return [DateTimeOffset]::Parse(
        [string]$value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
}

$inputTime = ConvertTo-UtcDateTime $metadata.inputTimestampUtc
$maximumOutputTime = ConvertTo-UtcDateTime $metadata.maximumOutputTimestampUtc
$now = [DateTime]::UtcNow
if ($maximumOutputTime -gt $now.AddMinutes(5))
{
    throw "Cached outputs are more than five minutes ahead of this agent's clock: $maximumOutputTime"
}

$changedTime = [DateTime]::UtcNow
if ($changedTime -le $maximumOutputTime.AddSeconds(2))
{
    $changedTime = $maximumOutputTime.AddSeconds(2)
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
[RuntimeBuildStateTimestamps]::SetLastWriteTimeUtc($unchangedPaths.ToArray(), $inputTime.Ticks, $Throttle)
[RuntimeBuildStateTimestamps]::SetLastWriteTimeUtc($changedPaths.ToArray(), $changedTime.Ticks, $Throttle)
$stopwatch.Stop()

$untracked = @(Invoke-Git @(
    '-c',
    'core.quotepath=false',
    '-C',
    $RepoRoot,
    'ls-files',
    '--others',
    '--exclude-standard'))

$headShaOutput = Invoke-Git @('-C', $RepoRoot, 'rev-parse', 'HEAD')

$metrics = [ordered]@{
    baselineSha = $metadata.sha
    sourceRevisionId = if ($metadata.sourceRevisionId) { $metadata.sourceRevisionId } else { $metadata.sha }
    headSha = $headShaOutput.Trim()
    unchanged = $unchangedPaths.Count
    changed = $changedPaths.Count
    changedMissing = $changedMissing
    unchangedMissing = $unchangedMissing
    untracked = $untracked.Count
    inputTimestampUtc = $inputTime.ToString('o')
    changedTimestampUtc = $changedTime.ToString('o')
    elapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
}

if ($MetricsPath)
{
    $parent = Split-Path -Parent $MetricsPath
    if ($parent)
    {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $metrics | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $MetricsPath -Encoding utf8NoBOM
}

$global:LASTEXITCODE = 0
Write-Host "[prepare] sourceRevisionId=$($metrics.sourceRevisionId) unchanged=$($metrics.unchanged) changed=$($metrics.changed) changedMissing=$changedMissing untracked=$($metrics.untracked) seconds=$($metrics.elapsedSeconds)"
