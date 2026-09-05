<#
.SYNOPSIS
  Extracts authoritative CoreCompile execution and skip evidence from a Runtime binlog.
#>
param(
    [Parameter(Mandatory)]
    [string]$Binlog,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$Binlog = (Resolve-Path $Binlog).Path
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$dotnet = Join-Path $repoRoot $(if ($IsWindows) { 'dotnet.cmd' } else { 'dotnet.sh' })
$project = Join-Path $PSScriptRoot 'CoreCompileBinlogAnalyzer\CoreCompileBinlogAnalyzer.csproj'

& $dotnet run --project $project --configuration Release -- $Binlog $OutputPath
if ($LASTEXITCODE -ne 0)
{
    throw "CoreCompile binlog analyzer failed ($LASTEXITCODE)."
}
