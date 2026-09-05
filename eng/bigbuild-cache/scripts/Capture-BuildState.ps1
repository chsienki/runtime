<#
.SYNOPSIS
  Captures Runtime build state and a correctness manifest.

.DESCRIPTION
  Archives path-specific native and managed intermediates while preserving
  timestamps, permissions, and symlinks. The output manifest provides the
  reference side of the replay correctness oracle.
#>
param(
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..\..\..'),

    [Parameter(Mandatory)]
    [string]$StateDir,

    [string[]]$ArchiveRoots = @('artifacts/obj', 'artifacts/bin'),

    [string[]]$ManifestRoots = @('artifacts/bin'),

    [string]$ArchiveName = 'build-state.tar',

    [int]$Throttle = 16,

    # Replays must pass this value as SourceRevisionId during the cacheable build.
    [string]$SourceRevisionId
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path $RepoRoot).Path
$StateDir = [System.IO.Path]::GetFullPath($StateDir)
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

$trackedChanges = @(git -C $RepoRoot status --porcelain --untracked-files=no)
if ($LASTEXITCODE -ne 0)
{
    throw "git status failed ($LASTEXITCODE)."
}

if ($trackedChanges.Count -ne 0)
{
    throw "Tracked files must be clean before capturing build state."
}

$shaOutput = git -C $RepoRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0)
{
    throw "git rev-parse failed ($LASTEXITCODE)."
}
$sha = $shaOutput.Trim()
if (-not $SourceRevisionId)
{
    $SourceRevisionId = $sha
}

$relativeArchiveRoots = [System.Collections.Generic.List[string]]::new()
$expandedFiles = 0
$expandedBytes = [long]0
$minimumOutputTime = [DateTime]::MaxValue
$maximumOutputTime = [DateTime]::MinValue
$pathComparison = if ($IsWindows)
{
    [System.StringComparison]::OrdinalIgnoreCase
}
else
{
    [System.StringComparison]::Ordinal
}

foreach ($root in $ArchiveRoots)
{
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $root))
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container))
    {
        throw "Archive root does not exist: $fullPath"
    }

    $relativePath = [System.IO.Path]::GetRelativePath($RepoRoot, $fullPath)
    $firstSegment = ($relativePath -replace '\\', '/').Split('/')[0]
    if ([string]::IsNullOrWhiteSpace($relativePath) -or
        $relativePath -eq '.' -or
        $relativePath -eq '..' -or
        $relativePath.StartsWith("../", [System.StringComparison]::Ordinal) -or
        $relativePath.StartsWith("..\", [System.StringComparison]::Ordinal) -or
        $firstSegment.Equals('.git', [System.StringComparison]::OrdinalIgnoreCase))
    {
        throw "Archive root must be a safe child of the repository: $fullPath"
    }

    $rootPrefix = $fullPath.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if ($StateDir.Equals($fullPath, $pathComparison) -or $StateDir.StartsWith($rootPrefix, $pathComparison))
    {
        throw "StateDir must not be inside an archived root: $StateDir"
    }

    $relativeArchiveRoots.Add($relativePath.Replace('\', '/'))
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($fullPath)
    while ($pending.Count -ne 0)
    {
        foreach ($path in [System.IO.Directory]::EnumerateFileSystemEntries($pending.Pop()))
        {
            $attributes = [System.IO.File]::GetAttributes($path)
            $isDirectory = ($attributes -band [System.IO.FileAttributes]::Directory) -ne 0
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
            {
                $expandedFiles++
            }
            elseif ($isDirectory)
            {
                $pending.Push($path)
            }
            else
            {
                $info = [System.IO.FileInfo]::new($path)
                $expandedFiles++
                $expandedBytes += $info.Length
                if ($info.LastWriteTimeUtc -lt $minimumOutputTime)
                {
                    $minimumOutputTime = $info.LastWriteTimeUtc
                }
                if ($info.LastWriteTimeUtc -gt $maximumOutputTime)
                {
                    $maximumOutputTime = $info.LastWriteTimeUtc
                }
            }
        }
    }
}

if ($expandedFiles -eq 0)
{
    throw "The selected archive roots contain no files."
}
if ($minimumOutputTime -eq [DateTime]::MaxValue)
{
    throw "The selected archive roots contain no regular files."
}

$manifestPath = Join-Path $StateDir 'output-manifest.json'
& (Join-Path $PSScriptRoot 'Write-BuildStateManifest.ps1') `
    -RepoRoot $RepoRoot `
    -Roots $ManifestRoots `
    -OutputPath $manifestPath `
    -Throttle $Throttle

if ([System.IO.Path]::GetFileName($ArchiveName) -ne $ArchiveName)
{
    throw "ArchiveName must be a file name without directory components: $ArchiveName"
}

$archivePath = Join-Path $StateDir $ArchiveName
if (Test-Path -LiteralPath $archivePath)
{
    Remove-Item -LiteralPath $archivePath -Force
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
    $tarArguments = @('-cf', $ArchiveName, '-C', $RepoRoot) + $relativeArchiveRoots.ToArray()
    & $tar @tarArguments
    if ($LASTEXITCODE -ne 0)
    {
        throw "tar failed ($LASTEXITCODE) while capturing build state."
    }
}
finally
{
    Pop-Location
}
$stopwatch.Stop()

$archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
$preferredInputTime = [DateTime]::SpecifyKind([DateTime]'2000-01-01', [DateTimeKind]::Utc)
$inputTime = if ($minimumOutputTime -gt $preferredInputTime)
{
    $preferredInputTime
}
else
{
    $minimumOutputTime.AddDays(-1)
}

$metadata = [ordered]@{
    schemaVersion = 1
    sha = $sha
    sourceRevisionId = $SourceRevisionId
    repoRoot = $RepoRoot
    archiveFile = $ArchiveName
    archiveSha256 = $archiveHash
    archiveRoots = $relativeArchiveRoots.ToArray()
    manifestFile = 'output-manifest.json'
    manifestRoots = $ManifestRoots
    expandedFiles = $expandedFiles
    expandedBytes = $expandedBytes
    minimumOutputTimestampUtc = $minimumOutputTime.ToString('o')
    maximumOutputTimestampUtc = $maximumOutputTime.ToString('o')
    inputTimestampUtc = $inputTime.ToString('o')
    captureSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
    capturedUtc = [DateTime]::UtcNow.ToString('o')
}

$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $StateDir 'meta.json') -Encoding utf8NoBOM
$global:LASTEXITCODE = 0
Write-Host "[capture] sha=$sha files=$expandedFiles bytes=$expandedBytes archive=$archivePath seconds=$($metadata.captureSeconds)"
