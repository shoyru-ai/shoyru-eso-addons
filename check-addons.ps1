<#
  check-addons.ps1 - lint ESO addons for "works on my machine" dependency bugs BEFORE sharing.

  Your own game is a dirty environment full of libraries (you have standalone LibStub, etc.), so an
  addon can implicitly rely on a global that a friend's clean install will not have. This catches
  that without launching the game:
    ERROR: unguarded LibStub(...)  - deprecated; crashes on clean installs (modern LibAddonMenu-2.0
           no longer registers LibStub). Use the library global instead (e.g. LibAddonMenu2).
    WARN:  a known library global is referenced but the providing library is not in DependsOn.

  Usage:
    .\check-addons.ps1                            # check every addon in the source repo
    .\check-addons.ps1 -Addons ShoyruCrosshair    # check specific ones
#>
param(
    [string]$Source = "C:\Users\jaker\eso-addons",
    [string[]]$Addons = @()
)

# Known ESO library global -> the AddOn name that must be in DependsOn to provide it.
$libGlobals = [ordered]@{
    'LibAddonMenu2'    = 'LibAddonMenu-2.0'
    'LibCustomMenu'    = 'LibCustomMenu'
    'LibGPS'           = 'LibGPS'
    'LibMapPing'       = 'LibMapPing'
    'LibChatMessage'   = 'LibChatMessage'
    'LibSavedVars'     = 'LibSavedVars'
    'LibAsync'         = 'LibAsync'
    'LibDebugLogger'   = 'LibDebugLogger'
    'LibHistoire'      = 'LibHistoire'
    'LibMediaProvider' = 'LibMediaProvider'
    'LibAddonKeybinds' = 'LibAddonKeybinds'
    'LibFeedback'      = 'LibFeedback'
}

if (-not $Addons -or $Addons.Count -eq 0) {
    $Addons = Get-ChildItem $Source -Directory |
        Where-Object { $_.Name -ne '_setup' -and $_.Name -notlike '.*' } |
        Select-Object -ExpandProperty Name
}

$total = 0
foreach ($name in $Addons) {
    $folder = Join-Path $Source $name
    if (-not (Test-Path $folder)) { continue }

    $manifest = Join-Path $folder ($name + ".txt")
    if (-not (Test-Path $manifest)) {
        $first = Get-ChildItem $folder -Filter *.txt -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($first) { $manifest = $first.FullName }
    }
    $manifestText = ""
    if ($manifest -and (Test-Path $manifest)) { $manifestText = Get-Content $manifest -Raw }

    # declared dependencies (DependsOn + OptionalDependsOn), version constraints stripped
    $declared = @()
    foreach ($line in ($manifestText -split "`n")) {
        if ($line -match '^##\s*(Optional)?DependsOn:\s*(.+)$') {
            foreach ($tok in ($Matches[2] -split '\s+')) {
                $d = ($tok -replace '([<>=!]=?\d.*)$', '').Trim()
                if ($d) { $declared += $d }
            }
        }
    }

    # Skip tests/ and docs/ -- dev-only, not shipped, and they can be large (bloats the scan).
    $luaFiles = Get-ChildItem $folder -Filter *.lua -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](tests|docs)[\\/]' }
    # code lines only -- drop full-line Lua comments so a comment mentioning LibStub() isn't flagged.
    # A generic List (not += on an array) keeps this O(n): += recopies the whole array every line,
    # which is O(n^2) and hung for minutes on a large addon (SMX is ~7k lines in one file).
    $codeLines = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $luaFiles) {
        foreach ($ln in (Get-Content $f.FullName)) {
            if (-not $ln.Trim().StartsWith('--')) { $codeLines.Add($ln) }
        }
    }
    $code = $codeLines -join "`n"

    $issues = @()

    # 1) unguarded LibStub(...)  -- a "LibStub and LibStub(...)" or "if LibStub" guard is fine
    foreach ($ln in $codeLines) {
        if (($ln -match 'LibStub\s*\(') -and ($ln -notmatch 'LibStub\s+and') -and ($ln -notmatch 'if\s+LibStub')) {
            $issues += "ERROR  unguarded LibStub(...) - crashes on clean installs. Use the library global (e.g. LibAddonMenu2)."
            break
        }
    }

    # 2) known library global used but its library not declared
    foreach ($g in $libGlobals.Keys) {
        $pattern = '\b' + [regex]::Escape($g) + '\b'
        if ($code -match $pattern) {
            $lib = $libGlobals[$g]
            if ($declared -notcontains $lib) {
                $issues += ("WARN   uses global " + $g + " but " + $lib + " is not in DependsOn - add it so clean installs get it.")
            }
        }
    }

    if ($issues.Count -gt 0) {
        Write-Host "[$name]" -ForegroundColor Yellow
        foreach ($i in $issues) { Write-Host "   $i"; $total++ }
    }
    else {
        Write-Host "[$name] OK" -ForegroundColor Green
    }
}

Write-Host ""
if ($total -gt 0) {
    Write-Host "$total issue(s) found - fix before sharing." -ForegroundColor Yellow
    exit 1
}
else {
    Write-Host "All checked addons are clean." -ForegroundColor Green
    exit 0
}
