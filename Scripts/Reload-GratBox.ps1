# Reload-GratBox.ps1
# Reloads the GratBox module from this local folder (portable; no hard-coded paths).

$Root = Split-Path -Parent $PSScriptRoot   # ...\GratBox (script lives in ...\GratBox\Scripts)
$Manifest = Join-Path $Root 'modules\GratBox\GratBox.psd1'

if (-not (Test-Path $Manifest)) {
    throw "GratBox module manifest not found: $Manifest"
}

Remove-Module GratBox -Force -ErrorAction SilentlyContinue
Import-Module $Manifest -Force -ErrorAction Stop

Write-Host "[INFO] GratBox module reloaded from: $Manifest" -ForegroundColor Green
