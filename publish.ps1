<#
  publish.ps1 — package Shoyru's custom ESO addons into this repo so they appear in the
  "Shoyru's Addons" tab of the Shoyru's ESO Addons manager.

  Usage:
    .\publish.ps1                              # publish ALL custom addons from the source repo
    .\publish.ps1 -Addons ShoyrUI,ShoyHouse    # publish only these
#>
param(
    [string]$Source = "C:\Users\jaker\eso-addons",
    [string[]]$Addons = @(),
    [switch]$Force    # publish even if the dependency lint finds issues
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$pub       = $PSScriptRoot
$addonsDir = Join-Path $pub "addons"
$rawBase   = "https://raw.githubusercontent.com/shoyru-ai/shoyru-eso-addons/main/addons"
# App-only: preserve each addon's EXISTING description so an addon without a local "## Description"
# keeps what it already had. We do NOT reach out to ESOUI (that network fetch also used to hang).
$prevDesc = @{}
$prevManifest = Join-Path $pub "manifest.json"
if (Test-Path $prevManifest) {
    try {
        $pm = Get-Content $prevManifest -Raw | ConvertFrom-Json
        foreach ($e in $pm.addons) { if ($e.name) { $prevDesc[$e.name] = [string]$e.description } }
    } catch {}
}
# The published set is EXACTLY the addons passed in — wipe first so removed ones are deleted.
if (Test-Path $addonsDir) { Remove-Item $addonsDir -Recurse -Force }
New-Item -ItemType Directory -Force $addonsDir | Out-Null

if (-not $Addons -or $Addons.Count -eq 0) {
    $Addons = Get-ChildItem $Source -Directory |
        Where-Object { $_.Name -ne '_setup' -and $_.Name -notlike '.*' } |
        Select-Object -ExpandProperty Name
}

# Pre-publish lint: catch "works on my machine" dependency bugs (e.g. unguarded LibStub) before sharing.
$checker = Join-Path $pub "check-addons.ps1"
if (Test-Path $checker) {
    Write-Host "Linting addons before publish..." -ForegroundColor Cyan
    & $checker -Source $Source -Addons $Addons
    if ($LASTEXITCODE -ne 0 -and -not $Force) {
        throw "Addon lint found issues (above). Fix them, or re-run with -Force to publish anyway."
    }
}

function Get-Field($file, $key) {
    if (-not $file -or -not (Test-Path $file)) { return "" }
    $m = Select-String -Path $file -Pattern ("^##\s*" + [regex]::Escape($key) + ":\s*(.+)$") | Select-Object -First 1
    if ($m) { ($m.Matches.Groups[1].Value -replace '\|c[0-9A-Fa-f]{6}','' -replace '\|r','').Trim() } else { "" }
}

function Get-Dependencies($file) {
    # Reads BOTH "## DependsOn:" and "## OptionalDependsOn:" (space-separated libs), strips version
    # constraints, dedups -> @("Lib1","Lib2"). Optional libs are INCLUDED so the app still calls them
    # out / installs them: e.g. SMX declares LibCombat as OptionalDependsOn (it loads without it) but
    # is effectively useless without the combat data, so users must be told they need it.
    if (-not $file -or -not (Test-Path $file)) { return @() }
    $deps = [System.Collections.Generic.List[string]]::new()
    foreach ($m in (Select-String -Path $file -Pattern '^##\s*(Optional)?DependsOn:\s*(.+)$')) {
        foreach ($tok in ($m.Matches.Groups[2].Value -split '\s+')) {
            $nm = ($tok -replace '([<>=!]=?\d.*)$','').Trim()   # drop >=N / >N / ==N etc.
            if ($nm -and -not $deps.Contains($nm)) { $deps.Add($nm) }
        }
    }
    return $deps.ToArray()
}

function Strip-BBCode($s) {
    if (-not $s) { return "" }
    $s = $s -replace '(?i)\[url=[^\]]+\]([^\[]*)\[/url\]', '$1'
    $s = $s -replace '(?i)\[img\][^\[]*\[/img\]', ''
    $s = $s -replace '(?i)\[/?[a-z][^\]]*\]', ''
    $s = [System.Net.WebUtility]::HtmlDecode($s)
    ($s -replace "`r", '' -replace "`n{3,}", "`n`n").Trim()
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
    if (-not $desc) { $desc = $prevDesc[$name] }   # keep the existing description; no ESOUI fetch

    # zip WITH the base folder at the zip root (so it extracts to AddOns\<Name>\). Stage a clean copy
    # first so dev-only folders never ship to users: docs/ (listing screenshots), tests/, and VCS dirs.
    $zip = Join-Path $addonsDir ($name + ".zip")
    if (Test-Path $zip) { Remove-Item $zip -Force }
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ("shoyru-pub\" + $name)
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Force $stage | Out-Null
    robocopy $folder $stage /E /XD docs tests .git .github /XF *.md .gitignore /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed staging $name (code $LASTEXITCODE)" }
    $global:LASTEXITCODE = 0   # robocopy returns 1 on success-with-copies; don't let it look like a failure
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, 'Optimal', $true)
    Remove-Item $stage -Recurse -Force

    $entries += [ordered]@{
        name         = $name
        title        = $title
        version      = $version
        description  = $desc
        dependencies = @(Get-Dependencies $manifest)
        downloadUrl  = "$rawBase/$name.zip"
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
