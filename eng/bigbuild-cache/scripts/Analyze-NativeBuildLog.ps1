<#
.SYNOPSIS
  Extracts per-component CMake and Ninja work counts from a Runtime build log.

.DESCRIPTION
  Tracks CoreCLR, native-library, and CoreHost subprocesses from the repository
  build output. It records whether CMake configured or skipped and classifies
  Ninja progress entries as compile, link, generate, install, or other work.
#>
param(
    [Parameter(Mandatory)]
    [string]$BuildLog,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$BuildLog = (Resolve-Path $BuildLog).Path
$components = [ordered]@{}
$currentComponent = 'other'

function Get-Component([string]$name)
{
    if (-not $components.Contains($name))
    {
        $components[$name] = [ordered]@{
            name = $name
            invocations = 0
            cmakeConfigured = 0
            cmakeSkipped = 0
            reportedEdges = 0
            progressRecords = 0
            compile = 0
            link = 0
            generate = 0
            install = 0
            other = 0
        }
    }

    return $components[$name]
}

foreach ($line in Get-Content -LiteralPath $BuildLog)
{
    if ($line -match 'build-runtime\.(cmd|sh)')
    {
        $currentComponent = 'coreclr'
        (Get-Component $currentComponent).invocations++
        continue
    }

    if ($line -match '[\\/]native[\\/]libs[\\/]build-native\.(cmd|sh)')
    {
        $currentComponent = 'libraries-native'
        (Get-Component $currentComponent).invocations++
        continue
    }

    if ($line -match '[\\/]native[\\/]corehost[\\/]build\.(cmd|sh)')
    {
        $currentComponent = 'corehost'
        (Get-Component $currentComponent).invocations++
        continue
    }

    if ($line.Contains('The CMake command line is the same as the last run.'))
    {
        $component = Get-Component $currentComponent
        $component.cmakeSkipped++
        continue
    }

    if ($line.Contains('Running CMake again.') -or $line.Contains('Re-running CMake'))
    {
        $component = Get-Component $currentComponent
        $component.cmakeConfigured++
    }

    if ($line -notmatch '\[(\d+)/(\d+)\]\s+(.*)$')
    {
        continue
    }

    $component = Get-Component $currentComponent
    $total = [int]$matches[2]
    $description = $matches[3]
    $component.reportedEdges = [Math]::Max($component.reportedEdges, $total)
    $component.progressRecords++

    if ($description -match '^Building .+ object ')
    {
        $component.compile++
    }
    elseif ($description -match '^Linking ')
    {
        $component.link++
    }
    elseif ($description -match '^(Generating|Preprocessing) ')
    {
        $component.generate++
    }
    elseif ($description -match '^Install the project')
    {
        $component.install++
    }
    else
    {
        $component.other++
    }
}

$componentResults = @($components.Values | ForEach-Object { [pscustomobject]$_ })
$result = [ordered]@{
    buildLog = $BuildLog
    components = $componentResults
}

$parent = Split-Path -Parent $OutputPath
if ($parent)
{
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding ascii
$componentResults | Format-Table name, invocations, cmakeConfigured, cmakeSkipped, reportedEdges, compile, link, generate, install, other
