<#
.SYNOPSIS
  Extracts per-invocation CMake and Ninja work counts from a Runtime build log.

.DESCRIPTION
  Tracks each CoreCLR, native-library, and CoreHost subprocess from the
  repository build output. It records the target, intermediate directory,
  CMake timing, and classifies Ninja progress entries as compile, link,
  generate, install, or other work.
#>
param(
    [Parameter(Mandatory)]
    [string]$BuildLog,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$BuildLog = (Resolve-Path $BuildLog).Path
$invocations = [System.Collections.Generic.List[object]]::new()
$currentInvocation = $null
$componentInvocationCounts = @{}

function Start-Invocation([string]$component, [string]$commandLine)
{
    if (-not $componentInvocationCounts.ContainsKey($component))
    {
        $componentInvocationCounts[$component] = 0
    }

    $componentInvocationCounts[$component]++
    $invocation = [ordered]@{
        index = $invocations.Count + 1
        component = $component
        componentInvocation = $componentInvocationCounts[$component]
        target = if ($commandLine -match '(?:^|\s)-component\s+([^\s"]+)') { $matches[1] } else { 'install' }
        intermediateDirectory = $null
        cmakeState = 'unknown'
        cmakeConfigureSeconds = 0.0
        cmakeGenerateSeconds = 0.0
        cmakeSeconds = 0.0
        reportedEdges = 0
        progressRecords = 0
        compile = 0
        link = 0
        generate = 0
        install = 0
        other = 0
    }

    $invocations.Add($invocation)
    return $invocation
}

foreach ($line in Get-Content -LiteralPath $BuildLog)
{
    if ($line -match '^\s*Executing "[^"]*build-runtime\.(cmd|sh)"\s')
    {
        $currentInvocation = Start-Invocation 'coreclr' $line
        continue
    }

    if ($line -match '^\s*"[^"]*[\\/]native[\\/]libs[\\/]build-native\.(cmd|sh)"\s')
    {
        $currentInvocation = Start-Invocation 'libraries-native' $line
        continue
    }

    if ($line -match '^\s*"[^"]*[\\/]native[\\/]corehost[\\/]build\.(cmd|sh)"\s')
    {
        $currentInvocation = Start-Invocation 'corehost' $line
        continue
    }

    if ($null -eq $currentInvocation)
    {
        continue
    }

    if ($line -match 'Commencing build of "(.+?)" target in ".+?" for .+ in (.+)$')
    {
        $currentInvocation.target = $matches[1].Trim()
        $currentInvocation.intermediateDirectory = $matches[2].Trim()
        continue
    }

    if ($line -match 'gen-buildsys\.(?:cmd|sh)"?\s+"[^"]+"\s+"([^"]+)"')
    {
        $currentInvocation.intermediateDirectory = $matches[1]
    }

    if ($line -match '-- Build files have been written to:\s*(.+)$')
    {
        $currentInvocation.intermediateDirectory = $matches[1].Trim()
    }

    if ($line.Contains('The CMake command line is the same as the last run.'))
    {
        $currentInvocation.cmakeState = 'skipped'
        continue
    }

    if ($line.Contains('Running CMake again.') -or $line.Contains('Re-running CMake'))
    {
        $currentInvocation.cmakeState = 'configured'
    }

    if ($line -match '-- Configuring done \(([\d.]+)s\)')
    {
        $currentInvocation.cmakeState = 'configured'
        $currentInvocation.cmakeConfigureSeconds += [double]$matches[1]
        $currentInvocation.cmakeSeconds = $currentInvocation.cmakeConfigureSeconds + $currentInvocation.cmakeGenerateSeconds
        continue
    }

    if ($line -match '-- Generating done \(([\d.]+)s\)')
    {
        $currentInvocation.cmakeState = 'configured'
        $currentInvocation.cmakeGenerateSeconds += [double]$matches[1]
        $currentInvocation.cmakeSeconds = $currentInvocation.cmakeConfigureSeconds + $currentInvocation.cmakeGenerateSeconds
        continue
    }

    if ($line -notmatch '\[(\d+)/(\d+)\]\s+(.*)$')
    {
        continue
    }

    $total = [int]$matches[2]
    $description = $matches[3]
    $currentInvocation.reportedEdges = [Math]::Max($currentInvocation.reportedEdges, $total)
    $currentInvocation.progressRecords++

    if ($description -match '^Building .+ object ')
    {
        $currentInvocation.compile++
    }
    elseif ($description -match '^Linking ')
    {
        $currentInvocation.link++
    }
    elseif ($description -match '^(Generating|Preprocessing) ')
    {
        $currentInvocation.generate++
    }
    elseif ($description -match '^Install the project')
    {
        $currentInvocation.install++
    }
    else
    {
        $currentInvocation.other++
    }
}

$invocationResults = @($invocations | ForEach-Object { [pscustomobject]$_ })
$result = [ordered]@{
    buildLog = $BuildLog
    invocations = $invocationResults
}

$parent = Split-Path -Parent $OutputPath
if ($parent)
{
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding ascii
$invocationResults | Format-Table index, component, componentInvocation, target, cmakeState, cmakeSeconds, reportedEdges, compile, link, generate, install, other
