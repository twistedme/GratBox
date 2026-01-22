# Shim so ". .\Export-IntuneManagedDevicesFromGroup.ps1" still works from the root
# I have moved the original function script to the set moduels location and created this to work as it was
# Prefer the module if Init-IntuneGraph.ps1 already imported it
try { Import-Module GratBox -ErrorAction Stop } catch { }

# Fallback to the Public function file if module isn't present
$publicFn = Join-Path $PSScriptRoot 'modules\GratBox\Public\Export-IntuneManagedDevicesFromGroup.ps1'
if (Test-Path $publicFn) { . $publicFn }
