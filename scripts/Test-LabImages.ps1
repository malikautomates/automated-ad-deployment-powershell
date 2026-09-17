#Requires -Version 5.1
<#
.SYNOPSIS
    Checks that every lab screenshot a README references exists, and that no
    screenshot on disk goes unreferenced.

.DESCRIPTION
    Parses every lab README for Markdown image references, then checks each
    referenced file exists. Also flags image files that no README references -
    an orphaned screenshot is usually a renamed reference or an unreviewed
    capture, and unreviewed captures are how sensitive data gets published.

    Exits non-zero on any missing or orphaned image, so it can gate CI.

.PARAMETER Lab
    Optional lab number filter, e.g. '06'. Omit to check all labs.

.EXAMPLE
    .\scripts\Test-LabImages.ps1

.EXAMPLE
    .\scripts\Test-LabImages.ps1 -Lab 06
#>

[CmdletBinding()]
param(
    [ValidatePattern('^\d{2}$')]
    [string] $Lab
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$labsRoot = Join-Path $repoRoot 'labs'

if (-not (Test-Path -LiteralPath $labsRoot)) {
    throw "No labs directory found at $labsRoot"
}

$labDirs = @(Get-ChildItem -LiteralPath $labsRoot -Directory | Sort-Object Name)
if ($Lab) {
    $labDirs = @($labDirs | Where-Object { $_.Name -like "$Lab-*" })
    if ($labDirs.Count -eq 0) { throw "No lab directory matching '$Lab-*'" }
}

$totalReferenced = 0
$totalMissing = 0
$totalOrphaned = 0

foreach ($dir in $labDirs) {
    $readme = Join-Path $dir.FullName 'README.md'
    if (-not (Test-Path -LiteralPath $readme)) {
        Write-Host ("{0,-44} no README.md" -f $dir.Name) -ForegroundColor Red
        $totalMissing++
        continue
    }

    $content = Get-Content -LiteralPath $readme -Raw

    # Markdown image references of the form ![alt](images/name.png)
    $imageMatches = [regex]::Matches($content, '!\[[^\]]*\]\((images/[^)\s]+)\)')
    $referenced = @($imageMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

    $missing = @($referenced | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $dir.FullName ($_ -replace '/', [IO.Path]::DirectorySeparatorChar)))
        })

    $imagesDir = Join-Path $dir.FullName 'images'
    $orphaned = @()
    if (Test-Path -LiteralPath $imagesDir) {
        $orphaned = @(Get-ChildItem -LiteralPath $imagesDir -File |
                Where-Object { $_.Name -ne '.gitkeep' } |
                ForEach-Object { "images/$($_.Name)" } |
                Where-Object { $_ -notin $referenced })
    }

    $totalReferenced += $referenced.Count
    $totalMissing += $missing.Count
    $totalOrphaned += $orphaned.Count

    $have = $referenced.Count - $missing.Count
    $colour = if ($missing.Count -eq 0 -and $orphaned.Count -eq 0) { 'Green' } else { 'Yellow' }
    Write-Host ("{0,-44} {1,2}/{2,-2} present" -f $dir.Name, $have, $referenced.Count) -ForegroundColor $colour

    foreach ($m in $missing) { Write-Host "      missing   $m" -ForegroundColor Red }
    foreach ($o in $orphaned) { Write-Host "      orphaned  $o" -ForegroundColor DarkYellow }
}

Write-Host ''
Write-Host ('Referenced: {0}   Present: {1}   Missing: {2}   Orphaned: {3}' -f
    $totalReferenced, ($totalReferenced - $totalMissing), $totalMissing, $totalOrphaned) -ForegroundColor Cyan

if ($totalMissing -gt 0 -or $totalOrphaned -gt 0) { exit 1 }
