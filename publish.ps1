<#
  publish.ps1 — package Shoyru's custom ESO addons into this repo so they appear in the
  "Shoyru's Addons" tab of the Shoyru's ESO Addons manager.

  Usage:
    .\publish.ps1                              # publish ALL custom addons from the source repo
    .\publish.ps1 -Addons ShoyrUI,ShoyHouse    # publish only these
#>
param(
    [string]$Source = "C:\Users\jaker\eso-addons",
    [string[]]$Addons = @()
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$pub       = $PSScriptRoot
$addonsDir = Join-Path $pub "addons"
$rawBase   = "https://raw.githubusercontent.com/shoyru-ai/shoyru-eso-addons/main/addons"
# The published set is EXACTLY the addons passed in — wipe first so removed ones are deleted.
if (Test-Path $addonsDir) { Remove-Item $addonsDir -Recurse -Force }
New-Item -ItemType Directory -Force $addonsDir | Out-Null

if (-not $Addons -or $Addons.Count -eq 0) {
    $Addons = Get-ChildItem $Source -Directory |
        Where-Object { $_.Name -ne '_setup' -and $_.Name -notlike '.*' } |
        Select-Object -ExpandProperty Name
}

function Get-Field($file, $key) {
    if (-not $file -or -not (Test-Path $file)) { return "" }
    $m = Select-String -Path $file -Pattern ("^##\s*" + [regex]::Escape($key) + ":\s*(.+)$") | Select-Object -First 1
    if ($m) { ($m.Matches.Groups[1].Value -replace '\|c[0-9A-Fa-f]{6}','' -replace '\|r','').Trim() } else { "" }
}

function Strip-BBCode($s) {
    if (-not $s) { return "" }
    $s = $s -replace '(?i)\[url=[^\]]+\]([^\[]*)\[/url\]', '$1'
    $s = $s -replace '(?i)\[img\][^\[]*\[/img\]', ''
    $s = $s -replace '(?i)\[/?[a-z][^\]]*\]', ''
    $s = [System.Net.WebUtility]::HtmlDecode($s)
    ($s -replace "`r", '' -replace "`n{3,}", "`n`n").Trim()
}

$script:catalog = $null
function Get-EsouiDescription($addonName) {
    try {
        if (-not $script:catalog) { $script:catalog = Invoke-RestMethod "https://api.mmoui.com/v3/game/ESO/filelist.json" -TimeoutSec 30 }
        $entry = $script:catalog | Where-Object { $_.UIDir -contains $addonName } | Select-Object -First 1
        if (-not $entry) { return "" }
        $d = (Invoke-RestMethod ("https://api.mmoui.com/v3/game/ESO/filedetails/{0}.json" -f $entry.UID) -TimeoutSec 30)[0]
        $desc = Strip-BBCode $d.UIDescription
        if ($desc.Length -gt 400) { $desc = $desc.Substring(0, 400).Trim() + "…" }
        return $desc
    } catch { return "" }
}

$entries = @()
foreach ($name in $Addons) {
    $folder = Join-Path $Source $name
    if (-not (Test-Path $folder)) { Write-Host "skip $name (not found)" -ForegroundColor Yellow; continue }

    $manifest = Join-Path $folder ($name + ".txt")
    if (-not (Test-Path $manifest)) { $manifest = Get-ChildItem $folder -Filter *.txt -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }

    $title   = Get-Field $manifest "Title";       if (-not $title)   { $title = $name }
    $version = Get-Field $manifest "Version";      if (-not $version) { $version = "1.0" }
    $desc    = Get-Field $manifest "Description"
    if (-not $desc) { $desc = Get-EsouiDescription $name }

    # zip WITH the base folder at the zip root (so it extracts to AddOns\<Name>\)
    $zip = Join-Path $addonsDir ($name + ".zip")
    if (Test-Path $zip) { Remove-Item $zip -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($folder, $zip, 'Optimal', $true)

    $entries += [ordered]@{
        name        = $name
        title       = $title
        version     = $version
        description = $desc
        downloadUrl = "$rawBase/$name.zip"
    }
    Write-Host ("packaged {0} v{1}" -f $name, $version) -ForegroundColor Green
}

([ordered]@{ author = "Shoyru"; addons = $entries } | ConvertTo-Json -Depth 6) |
    Out-File -Encoding utf8 (Join-Path $pub "manifest.json")

@"
# Shoyru's ESO Addons (published)

Addons by Shoyru, published for the **Shoyru's ESO Addons** manager (the *Shoyru's Addons* tab).
Each addon is in ``addons/<Name>.zip``; ``manifest.json`` lists them. Get the app:
https://github.com/shoyru-ai/eso-addon-manager
"@ | Out-File -Encoding utf8 (Join-Path $pub "README.md")

git -C $pub add -A
git -C $pub commit -m "Publish: $($entries.name -join ', ')" 2>&1 | Out-Null
git -C $pub push 2>&1 | Out-Null
Write-Host "Published $($entries.Count) addon(s)." -ForegroundColor Cyan
