# Copies the mod into the TF3 staging area (for uploading via the in-game Mod Manager, "My Mods")
# of every Steam user on this machine. Use -Target mods to install it as a plain local mod instead.
# The copy in the other folder is removed, so the mod ID never exists twice.
param(
    [ValidateSet('staging_area', 'mods')]
    [string]$Target = 'staging_area'
)
$ErrorActionPreference = 'Stop'

$modName = 'glcrte_curve_tool_guidelines_1'
$source = Join-Path $PSScriptRoot "..\mod\$modName"
$userdata = 'C:\Program Files (x86)\Steam\userdata'
$other = if ($Target -eq 'mods') { 'staging_area' } else { 'mods' }

$locals = Get-ChildItem $userdata -Directory | ForEach-Object { Join-Path $_.FullName '3493540\local' } | Where-Object { Test-Path $_ }
if (-not $locals) { throw "No TF3 local folder found under $userdata" }

foreach ($local in $locals) {
    $stale = Join-Path $local "$other\$modName"
    if (Test-Path $stale) {
        Remove-Item $stale -Recurse -Force
        Write-Host "Removed $stale"
    }

    $targetDir = Join-Path $local $Target
    New-Item -ItemType Directory -Force $targetDir | Out-Null
    $dest = Join-Path $targetDir $modName
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Copy-Item $source $dest -Recurse
    Write-Host "Deployed to $dest"
}
