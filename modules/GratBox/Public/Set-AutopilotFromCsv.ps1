function Set-AutopilotFromCsv {
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact='Medium')]
param(
  [Parameter(Mandatory, Position=0)]
  [ValidateScript({ Test-Path -LiteralPath $_ })]
  [string]$CsvPath,

  [string]$Delimiter = ',',

  # Header mapping (override if your CSV uses different names)
  [string]$SerialHeader   = 'Device Serial Number',
  [string]$GroupTagHeader = 'Group Tag',
  [string]$UserHeader     = 'Assigned User',

  # Optional: apply a single tag to all rows (overrides CSV tag if supplied)
  [string]$NewGroupTag,

  # Auth pass-through (no direct auth; calls your pre-auth only if you ask)
  [string]$Tenant,
  [string]$Account,
  [ValidateSet('edge','chrome','system')][string]$BrowserPreference = 'edge',
  [switch]$UseDeviceCode,

  # Behavior
  [switch]$PreferWai,

  # Output
  [string]$OutDir,
  [int]$MaxRetries = 5,
  [int]$RetryBaseDelaySec = 2,
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- Respect v8 design: NO embedded auth here. Optionally trigger your pre-auth if caller asks. ----
if ($UseDeviceCode -and (Get-Command Start-GratBoxPreAuth -ErrorAction SilentlyContinue)) {
  $p = @{}
  if ($Tenant)            { $p.Tenant            = $Tenant }
  if ($Account)           { $p.Account           = $Account }
  if ($BrowserPreference) { $p.BrowserPreference = $BrowserPreference }
  $p.UseDeviceCode = $true
  Start-GratBoxPreAuth @p | Out-Null
}

# ---------- local, safe helpers (non-auth) ----------
function Import-IfPresent([string]$Name){
  try { Import-Module $Name -ErrorAction Stop -Force } catch { }
}

function New-ReportFilePath {
  param(
    [string]$Override,
    [string]$SubFolder,
    [string]$FuncName,
    [string]$CsvPathLocal
  )
  # Build filename: <Func>-<CsvBase>-<timestamp>.csv
  $csvTag = [System.IO.Path]::GetFileNameWithoutExtension($CsvPathLocal)
  if ($csvTag) { $csvTag = ($csvTag -replace '[^A-Za-z0-9._-]','_') }
  $time = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $fileName = if ($csvTag) { "{0}-{1}-{2}.csv" -f $FuncName,$csvTag,$time } else { "{0}-{1}.csv" -f $FuncName,$time }

  if ($Override) {
    # If Override is a directory, place the file inside it; if it's a file path, use it verbatim
    if (Test-Path -LiteralPath $Override -PathType Container) {
      $dir = $Override
      $__oldWip = $WhatIfPreference; $WhatIfPreference = $false
      try { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } }
      finally { $WhatIfPreference = $__oldWip }
      return (Join-Path $dir $fileName)
    } else {
      $dir = Split-Path -Parent $Override
      if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $__oldWip = $WhatIfPreference; $WhatIfPreference = $false
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        finally { $WhatIfPreference = $__oldWip }
      }
      return $Override
    }
  }

  $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
  $dir  = Join-Path $root ("reports\" + $SubFolder)
  if (-not (Test-Path -LiteralPath $dir)) {
    $__oldWip = $WhatIfPreference; $WhatIfPreference = $false
    try { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    finally { $WhatIfPreference = $__oldWip }
  }
  return (Join-Path $dir $fileName)
}

# BOM-safe, case-insensitive column reader
function Get-CsvCellValue {
  param([psobject]$Row,[string]$HeaderName)
  function Normalize-Header([string]$s) {
    if ($null -eq $s) { return '' }
    $s = [string]$s
    $s = $s.Trim()
    $s = $s.TrimStart([char]0xFEFF)   # remove BOM if present
    return $s.ToLower()
  }
  $target = Normalize-Header $HeaderName
  foreach ($p in $Row.PSObject.Properties) {
    $name = Normalize-Header $($p.Name)
    if ($name -eq $target) { return [string]$p.Value }
  }
  return $null
}

function Invoke-WithRetry {
  param([scriptblock]$Script,[int]$Max=$MaxRetries,[int]$BaseDelay=$RetryBaseDelaySec,[string]$Op='operation')
  $attempt=0
  while ($attempt -lt [Math]::Max(1,$Max)) {
    try { return & $Script } catch {
      $attempt++; if ($attempt -ge $Max) { throw }
      $sleep=[Math]::Min(30,[Math]::Pow(2,$attempt-1)*$BaseDelay)
      Write-Verbose ("Retry {0}/{1} after error during {2}: {3}. Sleeping {4}s..." -f $attempt,$Max,$Op,$_.Exception.Message,$sleep)
      Start-Sleep -Seconds $sleep
    }
  }
}

function Get-AutopilotBySerial([string]$Serial){
  try {
    Import-IfPresent 'WindowsAutoPilotIntune'
    Get-AutopilotDevice -serial $Serial -ErrorAction Stop | Select-Object -First 1
  } catch { $null }
}

function Update-AutopilotRow([string]$Id,[string]$NewGroupTag,[string]$NewUPN){
  $label = "AP id=$Id" + ($(if ($NewGroupTag) { " GroupTag='$NewGroupTag'" })) + ($(if ($NewUPN) { " UPN='$NewUPN'" }))
  if ($PSCmdlet.ShouldProcess($label,'Update')) {
    Import-IfPresent 'WindowsAutoPilotIntune'
    $p = @{ Id = $Id }
    if ($NewGroupTag) { $p['GroupTag']          = $NewGroupTag }
    if ($NewUPN)      { $p['UserPrincipalName'] = $NewUPN }
    if ($p.Count -gt 1) {
      Invoke-WithRetry -Op 'WAI Set-AutopilotDevice' -Script { Set-AutopilotDevice @p | Out-Null } | Out-Null
      return $true
    }
  }
  return $false
}
# ---------- end helpers ----------

$funcName = 'Set-AutopilotFromCsv'
$outFile  = New-ReportFilePath -Override $OutDir -SubFolder $funcName -FuncName $funcName -CsvPathLocal $CsvPath
Write-Host ("Output will be saved to: {0}" -f $outFile)

$rows = Import-Csv -LiteralPath $CsvPath -Delimiter $Delimiter
if (-not $rows -or $rows.Count -eq 0) { throw "The CSV at '$CsvPath' contained no rows." }

$total=$rows.Count; $i=0; $updated=0; $skipped=0
$results = [System.Collections.Generic.List[object]]::new()

foreach ($row in $rows) {
  $i++; $pct=[int](($i/$total)*100)
  Write-Progress -Id 1 -Activity "Updating Autopilot from CSV" -Status "Row $i of $total ($pct%)" -PercentComplete $pct

  $serial       = Get-CsvCellValue -Row $row -HeaderName $SerialHeader
  $groupTagCsv  = Get-CsvCellValue -Row $row -HeaderName $GroupTagHeader
  $upn          = Get-CsvCellValue -Row $row -HeaderName $UserHeader

  if ($serial)      { $serial      = $serial.Trim() }
  if ($groupTagCsv) { $groupTagCsv = $groupTagCsv.Trim() }
  if ($upn)         { $upn         = $upn.Trim() }

  # Optional override: apply one tag to all rows
  $groupTag = if ($NewGroupTag) { $NewGroupTag } else { $groupTagCsv }

  $rr = [ordered]@{
    Row             = $i
    SerialNumber    = $serial
    Exists          = $false
    Action          = ''
    GroupTagOld     = $null
    GroupTagNew     = $groupTag
    AssignedUserOld = $null
    AssignedUserNew = $upn
    Result          = 'Skipped'
    ErrorMessage    = $null
  }

  try {
    if (-not $serial) { $rr.Action='Skipped: Missing serial'; $skipped++; $results.Add([pscustomobject]$rr); continue }

    $ap = Get-AutopilotBySerial -Serial $serial
    if (-not $ap) { $rr.Action='Skipped: Not found in Autopilot'; $skipped++; $results.Add([pscustomobject]$rr); continue }

    $rr.Exists          = $true
    $rr.GroupTagOld     = $ap.GroupTag
    $rr.AssignedUserOld = if ($ap.userPrincipalName) { $ap.userPrincipalName } else { $ap.UserPrincipalName }

    $tgtTag = if ($groupTag) { $groupTag } else { $null }
    $tgtUPN = if ($upn)      { $upn }      else { $null }

    # Optional nicety: skip if nothing would change
    $noTagChange  = ($tgtTag) -and ($tgtTag -eq $rr.GroupTagOld)
    $noUserChange = ($tgtUPN) -and ($tgtUPN -eq $rr.AssignedUserOld)
    if ((-not $tgtTag -and -not $tgtUPN) -or ($noTagChange -and ($tgtUPN -eq $null -or $noUserChange))) {
      $rr.Action='Skipped: No changes requested'; $skipped++; $results.Add([pscustomobject]$rr) | Out-Null
      continue
    }

    $did = Update-AutopilotRow -Id $ap.Id -NewGroupTag $tgtTag -NewUPN $tgtUPN
    if ($did) { $rr.Action='Updated'; $rr.Result='Success'; $updated++ } else { $rr.Action='NoOp'; $rr.Result='Success' }
  } catch {
    $rr.Result='Error'; $rr.ErrorMessage=$_.Exception.Message; $skipped++
  }

  $results.Add([pscustomobject]$rr) | Out-Null
}

# Always write the report, even during -WhatIf
$__oldWip = $WhatIfPreference; $WhatIfPreference = $false
try {
  $results | Export-Csv -LiteralPath $outFile -NoTypeInformation -Encoding UTF8
}
finally {
  $WhatIfPreference = $__oldWip
}

Write-Host ("Updated: {0} | Skipped: {1} | Report: {2}" -f $updated,$skipped,$outFile)
if ($PassThru){ return $results }
}
