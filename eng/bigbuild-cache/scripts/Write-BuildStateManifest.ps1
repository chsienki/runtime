<#
.SYNOPSIS
  Writes a content manifest for build outputs.
#>
param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string[]]$Roots,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [int]$Throttle = 16
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path $RepoRoot).Path
$resolvedRoots = [System.Collections.Generic.List[string]]::new()
$relativeRoots = [System.Collections.Generic.List[string]]::new()

foreach ($root in $Roots)
{
    $fullPath = if ([System.IO.Path]::IsPathRooted($root))
    {
        [System.IO.Path]::GetFullPath($root)
    }
    else
    {
        [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $root))
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Container))
    {
        throw "Manifest root does not exist: $fullPath"
    }

    $relativePath = [System.IO.Path]::GetRelativePath($RepoRoot, $fullPath)
    if ($relativePath -eq '..' -or
        $relativePath.StartsWith("../", [System.StringComparison]::Ordinal) -or
        $relativePath.StartsWith("..\", [System.StringComparison]::Ordinal))
    {
        throw "Manifest root must be inside the repository: $fullPath"
    }

    $resolvedRoots.Add($fullPath)
    $relativeRoots.Add($relativePath.Replace('\', '/'))
}

if (-not ('RuntimeBuildStateManifest' -as [type]))
{
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading.Tasks;

public sealed class RuntimeBuildStateManifestEntry
{
    public string Path { get; set; }
    public string Kind { get; set; }
    public string Sha256 { get; set; }
    public string LinkTarget { get; set; }
    public long Size { get; set; }
    public long LastWriteTimeUtcTicks { get; set; }
}

public static class RuntimeBuildStateManifest
{
    public static RuntimeBuildStateManifestEntry[] Create(
        string repoRoot,
        string[] roots,
        int maxDegreeOfParallelism)
    {
        StringComparer pathComparer = OperatingSystem.IsWindows()
            ? StringComparer.OrdinalIgnoreCase
            : StringComparer.Ordinal;
        var files = new HashSet<string>(pathComparer);
        var links = new Dictionary<string, bool>(pathComparer);
        foreach (string root in roots)
        {
            EnumerateRoot(root, files, links);
        }

        var entries = new ConcurrentBag<RuntimeBuildStateManifestEntry>();
        Parallel.ForEach(
            files,
            new ParallelOptions { MaxDegreeOfParallelism = maxDegreeOfParallelism },
            path =>
            {
                byte[] hash;
                using (var algorithm = SHA256.Create())
                using (var stream = new FileStream(
                    path,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete,
                    1024 * 1024,
                    FileOptions.SequentialScan))
                {
                    hash = algorithm.ComputeHash(stream);
                }

                var file = new FileInfo(path);
                entries.Add(new RuntimeBuildStateManifestEntry
                {
                    Path = Path.GetRelativePath(repoRoot, path).Replace('\\', '/'),
                    Kind = "file",
                    Sha256 = BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant(),
                    Size = file.Length,
                    LastWriteTimeUtcTicks = file.LastWriteTimeUtc.Ticks,
                });
            });

        foreach (KeyValuePair<string, bool> link in links)
        {
            FileSystemInfo info = link.Value
                ? new DirectoryInfo(link.Key)
                : new FileInfo(link.Key);
            info.Refresh();
            string target = info.LinkTarget;
            if (target == null)
            {
                throw new IOException($"Cannot read symbolic link target: {link.Key}");
            }

            entries.Add(new RuntimeBuildStateManifestEntry
            {
                Path = Path.GetRelativePath(repoRoot, link.Key).Replace('\\', '/'),
                Kind = "symbolicLink",
                LinkTarget = target,
            });
        }

        return entries.OrderBy(entry => entry.Path, StringComparer.Ordinal).ToArray();
    }

    private static void EnumerateRoot(
        string root,
        HashSet<string> files,
        Dictionary<string, bool> links)
    {
        var pending = new Stack<string>();
        pending.Push(root);

        while (pending.Count != 0)
        {
            string directory = pending.Pop();
            foreach (string path in Directory.EnumerateFileSystemEntries(directory))
            {
                FileAttributes attributes = File.GetAttributes(path);
                bool isDirectory = (attributes & FileAttributes.Directory) != 0;
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                {
                    links[path] = isDirectory;
                }
                else if (isDirectory)
                {
                    pending.Push(path);
                }
                else
                {
                    files.Add(path);
                }
            }
        }
    }
}
'@
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$entries = @([RuntimeBuildStateManifest]::Create($RepoRoot, $resolvedRoots.ToArray(), $Throttle))
$stopwatch.Stop()

$totalBytes = [long]0
foreach ($entry in $entries)
{
    $totalBytes += $entry.Size
}

$manifest = [ordered]@{
    schemaVersion = 1
    repoRoot = $RepoRoot
    roots = $relativeRoots.ToArray()
    generatedUtc = [DateTime]::UtcNow.ToString('o')
    fileCount = $entries.Count
    totalBytes = $totalBytes
    entries = $entries
}

$parent = Split-Path -Parent $OutputPath
if ($parent)
{
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Host "[manifest] wrote $($entries.Count) files and $totalBytes bytes to $OutputPath in $($stopwatch.Elapsed)"
