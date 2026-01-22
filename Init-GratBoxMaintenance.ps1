# Note:
# Operational mode starts a fresh GratBox PowerShell process
# using the standard PS-SMART-GratBox-EPM-PRIVATE.cmd launcher.
# The process runs in the same console window, but does not reuse
# the maintenance PowerShell session state.

Set-Location -Path $PSScriptRoot

$modulePath  = Join-Path $PSScriptRoot 'modules\GratBox\GratBox.psd1'
$launcherCmd = Join-Path $PSScriptRoot 'PS-SMART-GratBox-EPM-PRIVATE.cmd'

if (-not (Test-Path $modulePath)) {
    throw "GratBox module not found: $modulePath"
}

Import-Module $modulePath -Force

Write-Host ''
Write-Host '=== GratBox MAINTENANCE MODE ===' -ForegroundColor Cyan
Write-Host 'You are running elevated. Graph authentication has NOT started.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Available commands:' -ForegroundColor Gray
Write-Host '  Get-GratBox3pStatus' -ForegroundColor Gray
Write-Host '  Update-GratBox3p -Latest' -ForegroundColor Gray
Write-Host ''
Write-Host 'When ready, run:' -ForegroundColor Gray
Write-Host '  Start-GratBoxOperational' -ForegroundColor Green
Write-Host ''

function Start-GratBoxOperational {
    Write-Host '[INFO] Starting GratBox operational mode...' -ForegroundColor Cyan

    if (-not (Test-Path $launcherCmd)) {
        throw "Operational launcher not found: $launcherCmd"
    }

    & $launcherCmd
}

