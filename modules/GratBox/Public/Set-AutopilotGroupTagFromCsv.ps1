<#
 Set-AutopilotGroupTagFromCsv.ps1
 Bulk set Autopilot group tags from a CSV: SerialNumber,GroupTag

 EXAMPLE
   Set-AutopilotGroupTagFromCsv -CsvPath '<toolRoot>\devices.csv' -DryRun
   Set-AutopilotGroupTagFromCsv -CsvPath 'devices.csv'
#>

function Set-AutopilotGroupTagFromCsv {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$CsvPath,
    [string]$SerialHeader = 'SerialNumber',
    [string]$TagHeader    = 'GroupTag',
    [switch]$DryRun,
    [switch]$ForceImport,
    [int]$MaxRetries = 5,
    [int]$RetryBaseDelaySec = 5
  )

  # ----- helpers -----
  $sw = [Diagnostics.Stopwatch]::StartNew()
  function Log([string]$msg,[ConsoleColor]$c='Gray'){ Write-Host ("[{0,5:n1}s] {1}" -f $sw.Elapsed.TotalSeconds,$msg) -ForegroundColor $c }

  if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath" }

  if (Get-Command Connect-GraphPrivateSession -ErrorAction SilentlyContinue) {
    Connect-GraphPrivateSession -RequiredScopes @(
      'DeviceManagementManagedDevices.Read.All',
      'DeviceManagementServiceConfig.ReadWrite.All',
      'Directory.Read.All'
    ) -TenantHint '' -BrowserPref 'edge' 2>$null
  }

  # ----- report path -----
  $root = $null
  $mod = Get-Module GratBox -ErrorAction SilentlyContinue
  if ($mod -and $mod.ModuleBase) { try { $root = Split-Path -Parent (Split-Path -Parent $mod.ModuleBase) } catch {} }
  if (-not $root) { $thisFile = $MyInvocation.MyCommand.Path; if ($thisFile) { try { $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $thisFile)) } catch {} } }
  if (-not $root) { try { $root = (Get-Location).Path } catch { $root = (Get-Location).Path } }

  $reportsDir = Join-Path $root 'reports\Set-AutopilotGroupTagFromCsv'
  if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
  $csvOut = Join-Path $reportsDir ("AutoPilotGroupTag_FromCsv_{0}.csv" -f $stamp)
  Log ("CSV: {0}" -f $csvOut) Cyan

  # ----- load input -----
  $items = Import-Csv -Path $CsvPath
  if (-not $items -or $items.Count -eq 0) {
    Log "CSV is empty." Yellow
    @() | Select-Object SerialNumber,OldGroupTag,NewGroupTag,AutopilotId,Status,Message | Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8
    return
  }

  $all = New-Object System.Collections.Generic.List[object]
  foreach ($row in $items) {
    $sn  = $row.$SerialHeader
    $tag = $row.$TagHeader
    if (-not $sn)  { $all.Add([pscustomobject]@{ SerialNumber=''; OldGroupTag=$null; NewGroupTag=$tag; AutopilotId=$null; Status='Error'; Message="Missing $SerialHeader in row." }) | Out-Null; continue }
    if (-not $tag) { $all.Add([pscustomobject]@{ SerialNumber=$sn; OldGroupTag=$null; NewGroupTag=$null; AutopilotId=$null; Status='Error'; Message="Missing $TagHeader for serial $sn." }) | Out-Null; continue }

    # Reuse the BySerial function so behavior matches the other entry points
    $res = Set-AutopilotGroupTagBySerial -SerialNumber $sn -GroupTag $tag -DryRun:$DryRun -ForceImport:$ForceImport -MaxRetries $MaxRetries -RetryBaseDelaySec $RetryBaseDelaySec
    foreach ($r in @($res)) { $all.Add($r) | Out-Null }
  }

  $all | Sort-Object SerialNumber |
    Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8

  $all
}
