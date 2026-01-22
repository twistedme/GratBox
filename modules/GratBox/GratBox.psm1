# GratBox.psm1 (clean export of Public only)

Set-StrictMode -Version Latest

# --- Load Private helpers (not exported) ---
$privateDir = Join-Path $PSScriptRoot 'Private'
if (Test-Path $privateDir) {
  Get-ChildItem -Path $privateDir -Filter *.ps1 -ErrorAction SilentlyContinue |
    ForEach-Object { . $_.FullName }
}

# --- Load Public functions (export only what Public adds) ---
$publicDir = Join-Path $PSScriptRoot 'Public'
$exports = @()

if (Test-Path $publicDir) {
  Get-ChildItem -Path $publicDir -Filter *.ps1 -ErrorAction SilentlyContinue | ForEach-Object {
    $before = @(Get-ChildItem Function:\ | Select-Object -ExpandProperty Name)
    . $_.FullName
    $after  = @(Get-ChildItem Function:\ | Select-Object -ExpandProperty Name)
    $added  = Compare-Object -ReferenceObject $before -DifferenceObject $after |
              Where-Object SideIndicator -eq '=>' |
              ForEach-Object InputObject
    if ($added) { $exports += $added }
  }
}

if ($exports.Count -gt 0) {
  Export-ModuleMember -Function $exports
} else {
  Export-ModuleMember  # nothing new (keeps module import clean)
}
