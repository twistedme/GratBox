function Convert-EntraDeviceIdCsvToGroupBulkImportCsv {
<#
.SYNOPSIS
Convert a CM export of device IDs into the Entra portal "bulk add members" CSV.

.DESCRIPTION
Reads a CSV and extracts a GUID column (default: 'Microsoft Entra ID Device ID').
If those GUIDs are already Entra device *object IDs*, it writes a portal-ready CSV:
  version:v1.0
  Member object ID or user principal name [memberObjectIdOrUpn] Required
  <objectId>
  <objectId>
If you instead have the device's *deviceId* (the one returned by /devices), you can
pass -ResolveObjectIdWithGraph to look up object IDs via Microsoft Graph.

This function does NOT embed auth. It uses your current Graph context if you ask
for -ResolveObjectIdWithGraph. Otherwise, it needs no token.

.PARAMETER CsvPath
Input CSV from CM.

.PARAMETER DeviceIdColumn
Column name to read (default: 'Microsoft Entra ID Device ID').

.PARAMETER OutPath
Output file path or folder. If folder, the function creates a unique filename
under that folder. If omitted, writes under ...\reports\Convert-EntraDeviceIdCsvToGroupBulkImportCsv.

.PARAMETER ResolveObjectIdWithGraph
If your column contains deviceId (not objectId), resolve to objectId using Graph.

.PARAMETER Tenant, Account, BrowserPreference, UseDeviceCode
Accepted for symmetry; not used unless you add your own pre-auth wrapper.

.PARAMETER PassThru
Return a small object {OutPath, Count} in addition to writing the file.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ })]
  [string]$CsvPath,

  [string]$DeviceIdColumn = 'Microsoft Entra ID Device ID',

  [string]$OutPath,

  [switch]$ResolveObjectIdWithGraph,

  # Kept for signature symmetry; this function does not embed auth.
  [string]$Tenant,
  [string]$Account,
  [ValidateSet('edge','chrome','system')][string]$BrowserPreference = 'edge',
  [switch]$UseDeviceCode,

  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- helpers ---------------------------------------------------------------
function Normalize([string]$s) { if ($null -eq $s) { '' } else { ($s -replace [char]0xFEFF,'').Trim() } }

function New-ReportPath {
  param([string]$Override,[string]$SourcePath)
  $time = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $base = [IO.Path]::GetFileNameWithoutExtension($SourcePath)
  $name = "Convert-EntraDeviceIdCsvToGroupBulkImportCsv-$base-$time.csv"

  if ($Override) {
    if ([IO.Path]::GetExtension($Override)) {
      $dir = Split-Path -Parent $Override
      if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $old=$WhatIfPreference; $WhatIfPreference=$false
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } finally { $WhatIfPreference=$old }
      }
      return $Override
    } else {
      $dir = $Override
      $old=$WhatIfPreference; $WhatIfPreference=$false
      try { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } finally { $WhatIfPreference=$old }
      return (Join-Path $dir $name)
    }
  }

  $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
  $dir  = Join-Path $root 'reports\Convert-EntraDeviceIdCsvToGroupBulkImportCsv'
  $old=$WhatIfPreference; $WhatIfPreference=$false
  try { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } finally { $WhatIfPreference=$old }
  return (Join-Path $dir $name)
}

function Resolve-DeviceIdsToObjectIds {
  param([string[]]$DeviceIds)
  $resolved = New-Object System.Collections.Generic.List[string]
  if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
    throw "Resolving deviceId -> objectId requires Microsoft.Graph.*. Please Connect-MgGraph (or run your Init-IntuneGraph) and rerun with -ResolveObjectIdWithGraph."
  }
  foreach ($id in $DeviceIds) {
    $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=deviceId eq '$id'&`$select=id,deviceId"
    try {
      $resp = Invoke-MgGraphRequest -Uri $uri -Method GET -OutputType PSObject
      $val  = @($resp.value)
      if ($val.Count -gt 0 -and $val[0].id) { [void]$resolved.Add([string]$val[0].id) }
    } catch {
Write-Warning "Graph lookup failed for deviceId ${id}: $($_.Exception.Message)"
    }
  }
  return ,($resolved | Sort-Object -Unique)
}
# ---------------------------------------------------------------------------

# Output path (folder or file)
$outFile = New-ReportPath -Override $OutPath -SourcePath $CsvPath
Write-Host ("Output will be saved to: {0}" -f $outFile)

# Read input and locate the column
$rows = Import-Csv -LiteralPath $CsvPath
if (-not $rows) { throw "No data rows found in '$CsvPath'." }

$props = ($rows | Select-Object -First 1 | Get-Member -MemberType NoteProperty).Name
$map = @{}
foreach ($p in $props) { $map[(Normalize $p).ToLowerInvariant()] = $p }

$want = (Normalize $DeviceIdColumn).ToLowerInvariant()
if (-not $map.ContainsKey($want)) {
  throw "Column '$DeviceIdColumn' not found. Available: $($props -join ', ')"
}
$colName = $map[$want]

# Extract candidate GUIDs
$guid = '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
$rawIds = @()
foreach ($r in $rows) {
  $val = $r.$colName
  if ($null -eq $val) { continue }
  $s = Normalize ($val.ToString())
  if ($s -match $guid) { $rawIds += $s }
}
$rawIds = $rawIds | Sort-Object -Unique

# Decide whether to resolve via Graph
$objectIds = @()
if ($ResolveObjectIdWithGraph) {
  $objectIds = Resolve-DeviceIdsToObjectIds -DeviceIds $rawIds
} else {
  # Treat the column as already containing objectIds (typical for 'Microsoft Entra ID Device ID' from CM)
  $objectIds = $rawIds
}

# Always write the file (even under -WhatIf)
$__old = $WhatIfPreference; $WhatIfPreference = $false
try {
  "version:v1.0" | Set-Content -LiteralPath $outFile -Encoding UTF8
  "Member object ID or user principal name [memberObjectIdOrUpn] Required" | Add-Content -LiteralPath $outFile -Encoding UTF8
  $objectIds | Sort-Object -Unique | ForEach-Object { $_ | Add-Content -LiteralPath $outFile -Encoding UTF8 }
}
finally { $WhatIfPreference = $__old }

Write-Host ("Created: {0} | IDs written: {1}" -f $outFile, $objectIds.Count)
if ($PassThru) { [pscustomobject]@{ OutPath = $outFile; Count = $objectIds.Count } }
}
