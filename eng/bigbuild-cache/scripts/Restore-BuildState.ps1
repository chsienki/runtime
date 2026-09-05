<#
.SYNOPSIS
  Restores Runtime build state into its canonical checkout path.
#>
param(
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..\..\..'),

    [Parameter(Mandatory)]
    [string]$StateDir,

    [switch]$Clean,

    [switch]$SkipArchiveHashValidation
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path $RepoRoot).Path
$StateDir = (Resolve-Path $StateDir).Path
$metadataPath = Join-Path $StateDir 'meta.json'
if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf))
{
    throw "Build-state metadata is missing: $metadataPath"
}

$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
if ($metadata.schemaVersion -ne 1)
{
    throw "Unsupported build-state schema version: $($metadata.schemaVersion)"
}

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

$archivePath = Join-Path $StateDir $metadata.archiveFile
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf))
{
    throw "Build-state archive is missing: $archivePath"
}

if (-not $SkipArchiveHashValidation)
{
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $metadata.archiveSha256)
    {
        throw "Build-state archive hash mismatch. Expected $($metadata.archiveSha256), actual $actualHash."
    }
}

$safeArchiveRoots = [System.Collections.Generic.List[string]]::new()
foreach ($root in @($metadata.archiveRoots))
{
    $target = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $root))
    $relativePath = [System.IO.Path]::GetRelativePath($RepoRoot, $target)
    $firstSegment = ($relativePath -replace '\\', '/').Split('/')[0]
    if ([string]::IsNullOrWhiteSpace($relativePath) -or
        $relativePath -eq '.' -or
        $relativePath -eq '..' -or
        $relativePath.StartsWith("../", [System.StringComparison]::Ordinal) -or
        $relativePath.StartsWith("..\", [System.StringComparison]::Ordinal) -or
        $firstSegment.Equals('.git', [System.StringComparison]::OrdinalIgnoreCase))
    {
        throw "Refusing to restore an unsafe archive root: $root"
    }

    $safeArchiveRoots.Add($relativePath.Replace('\', '/').TrimEnd('/'))
}

$tar = if ($IsWindows)
{
    Join-Path $env:SystemRoot 'System32\tar.exe'
}
else
{
    'tar'
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
Push-Location $StateDir
try
{
    $archiveEntries = @(& $tar -tf ([string]$metadata.archiveFile))
    if ($LASTEXITCODE -ne 0)
    {
        throw "tar failed ($LASTEXITCODE) while listing build state."
    }

    foreach ($entryValue in $archiveEntries)
    {
        $entry = ([string]$entryValue).Replace('\', '/')
        while ($entry.StartsWith('./', [System.StringComparison]::Ordinal))
        {
            $entry = $entry.Substring(2)
        }

        if (-not $entry -or
            $entry.StartsWith('/', [System.StringComparison]::Ordinal) -or
            $entry -match '^[A-Za-z]:' -or
            $entry -match '(^|/)\.\.(/|$)')
        {
            throw "Build-state archive contains an unsafe path: $entryValue"
        }

        $contained = $false
        foreach ($root in $safeArchiveRoots)
        {
            if ($entry.Equals($root, [System.StringComparison]::Ordinal) -or
                $entry.StartsWith("$root/", [System.StringComparison]::Ordinal))
            {
                $contained = $true
                break
            }
        }

        if (-not $contained)
        {
            throw "Build-state archive entry is outside the declared roots: $entryValue"
        }
    }

    if ($Clean)
    {
        foreach ($root in $safeArchiveRoots)
        {
            $target = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $root))
            if (Test-Path -LiteralPath $target)
            {
                Remove-Item -LiteralPath $target -Recurse -Force
            }
        }
    }

    $tarArguments = @('-xpf', [string]$metadata.archiveFile, '-C', $RepoRoot)
    & $tar @tarArguments
    if ($LASTEXITCODE -ne 0)
    {
        throw "tar failed ($LASTEXITCODE) while restoring build state."
    }
}
finally
{
    Pop-Location
}
$stopwatch.Stop()

$global:LASTEXITCODE = 0
Write-Host "[restore] sha=$($metadata.sha) archive=$archivePath seconds=$([Math]::Round($stopwatch.Elapsed.TotalSeconds, 3))"
