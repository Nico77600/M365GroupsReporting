<#
.SYNOPSIS
    Builds the Group Inventory engine (.NET 8 + SQLite) offline into engine\bin.
.DESCRIPTION
    No package is downloaded: SQLite comes from the DLLs already present in lib\sqlite and the
    engine is a plain class library (engine\GroupInventory.Engine.csproj).
    When the .NET 8 targeting pack is not installed, the engine is compiled against the newest
    installed Microsoft.NETCore.App 8.0.x runtime (found with 'dotnet --list-runtimes') instead.
    The build fails with a precise message when neither the SDK nor a .NET 8 runtime is available.
    Invoke-M365GroupsReporting.ps1 loads the result from engine\bin; rebuild after changing src.
.PARAMETER Configuration
    Release (default) or Debug.
.PARAMETER OutputDir
    Output folder. Default: engine\bin next to this script.
.EXAMPLE
    .\Build-Engine.ps1
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')] [string] $Configuration = 'Release',
    [string] $OutputDir
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { throw 'The script folder could not be resolved.' }
$project = Join-Path $root 'engine\GroupInventory.Engine.csproj'
if (-not $OutputDir) { $OutputDir = Join-Path $root 'engine\bin' }
if (-not (Test-Path -LiteralPath $project)) { throw "Engine project not found: $project" }
foreach ($f in 'Microsoft.Data.Sqlite.dll', 'SQLitePCLRaw.core.dll', 'SQLitePCLRaw.batteries_v2.dll', 'SQLitePCLRaw.provider.e_sqlite3.dll', 'runtimes\win-x64\e_sqlite3.dll') {
    if (-not (Test-Path -LiteralPath (Join-Path $root "lib\sqlite\$f"))) { throw "Missing local SQLite file lib\sqlite\$f (the build never downloads dependencies)." }
}

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) { throw 'The dotnet SDK was not found in PATH. Install a .NET SDK (8.0 or later) to build the engine.' }
$sdks = @(& $dotnet.Source --list-sdks 2>$null)
if ($sdks.Count -eq 0) { throw 'No .NET SDK is installed (dotnet --list-sdks is empty): a runtime alone cannot build the engine.' }

# Is the .NET 8 targeting pack installed? (packs\Microsoft.NETCore.App.Ref\8.*)
$dotnetRoot = ($sdks | Select-Object -Last 1) -replace '^\S+\s+\[(.*)\]$', '$1'
$dotnetRoot = Split-Path -Parent $dotnetRoot
$packDir = Join-Path $dotnetRoot 'packs\Microsoft.NETCore.App.Ref'
$havePack = (Test-Path -LiteralPath $packDir) -and @(Get-ChildItem -LiteralPath $packDir -Directory -Filter '8.*' -ErrorAction SilentlyContinue).Count -gt 0

$buildArgs = @('build', $project, '-c', $Configuration, '-o', $OutputDir, '--nologo', '-v:minimal', '-p:UseSharedCompilation=false')
if ($havePack) {
    Write-Host 'Using the installed .NET 8 targeting pack.' -ForegroundColor DarkGray
} else {
    $rt = @(& $dotnet.Source --list-runtimes 2>$null | ForEach-Object {
            if ($_ -match '^Microsoft\.NETCore\.App\s+(8\.\d+\.\d+)\s+\[(.*)\]$') { [pscustomobject]@{ Version = [version]$Matches[1]; Dir = (Join-Path $Matches[2] $Matches[1]) } }
        } | Sort-Object Version -Descending)
    if ($rt.Count -eq 0) { throw 'Neither the .NET 8 targeting pack nor a Microsoft.NETCore.App 8.0.x runtime is installed. Install the .NET 8 SDK or runtime; nothing is downloaded by this script.' }
    Write-Host "No .NET 8 targeting pack: compiling against the local runtime $($rt[0].Version) (offline)." -ForegroundColor Yellow
    $buildArgs += "-p:Net8RuntimeDir=$($rt[0].Dir)"
}

$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
& $dotnet.Source @buildArgs
if ($LASTEXITCODE -ne 0) { throw "Engine build failed (dotnet exit code $LASTEXITCODE)." }

$dll = Join-Path $OutputDir 'GroupInventory.Engine.dll'
if (-not (Test-Path -LiteralPath $dll)) { throw "Build reported success but $dll is missing." }
$asm = [System.Reflection.AssemblyName]::GetAssemblyName($dll)
Write-Host "Engine built: $dll (assembly version $($asm.Version))" -ForegroundColor Green
