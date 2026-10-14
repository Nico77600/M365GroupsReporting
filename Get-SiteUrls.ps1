<#
.SYNOPSIS
    Recupere en MASSE les URLs des sites SharePoint de groupe (GroupId -> Url) via SharePoint Admin.
    Bien plus rapide que /sites/root par groupe (quelques appels au lieu de N).
.DESCRIPTION
    Prerequis : module Microsoft.Online.SharePoint.PowerShell + role admin SharePoint.
    Le script connecte SPO (interactif) si besoin, puis Get-SPOSite -Template GROUP#0 -Limit All,
    et exporte siteurls.csv { GroupId, Url }.
.PARAMETER AdminUrl
    URL d'admin SPO, ex: https://m365cpi89259425-admin.sharepoint.com
.PARAMETER WorkDir
    Dossier de sortie de siteurls.csv (cree si absent). Par defaut : le dossier de ce script.
.EXAMPLE
    .\Get-SiteUrls.ps1 -AdminUrl https://m365cpi89259425-admin.sharepoint.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AdminUrl,
    [string] $WorkDir = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'
if (-not $WorkDir) { throw "WorkDir could not be resolved (script folder unknown). Pass -WorkDir." }
if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
Import-Module Microsoft.Online.SharePoint.PowerShell -ErrorAction Stop

# Connecte si pas deja connecte (Get-SPOTenant echoue si non connecte)
$connected = $false
try { Get-SPOTenant -ErrorAction Stop | Out-Null; $connected = $true } catch { }
if (-not $connected) {
    Write-Host "Connexion SPO ($AdminUrl)... (fenetre d'auth interactive)" -ForegroundColor Cyan
    Connect-SPOService -Url $AdminUrl -ModernAuth $true -UseSystemBrowser $true
}
Write-Host "Recuperation des sites de groupe (Get-SPOSite -Template GROUP#0 -Limit All)..." -ForegroundColor Cyan
$sites = Get-SPOSite -Template "GROUP#0" -Limit All

$rows = New-Object System.Collections.Generic.List[object]
foreach ($s in $sites) {
    $gid = [string]$s.GroupId
    if ($gid -and $gid -ne '00000000-0000-0000-0000-000000000000') {
        $rows.Add([pscustomobject]@{ GroupId = $gid; Url = [string]$s.Url })
    }
}
if ($rows.Count -eq 0) { throw 'SharePoint returned no GROUP#0 site URLs; refusing to create a completed empty source.' }
$out = Join-Path $WorkDir 'siteurls.csv'
$rows | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8
Write-Host "OK : $($rows.Count) sites de groupe -> $out" -ForegroundColor Green
