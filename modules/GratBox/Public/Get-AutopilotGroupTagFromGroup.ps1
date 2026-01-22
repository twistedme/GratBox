<#
.SYNOPSIS
Inventory current Windows Autopilot Group Tags for all (transitive) device members of an Entra group.

.DESCRIPTION
Resolves the target group's device members, looks up each device's Intune managed device
(to obtain serial number, model, etc.), then queries the Autopilot device identity to read
the CURRENT Group Tag. This command is READ-ONLY. It does not compute or propose changes.

Auth integrates with your GratBox helpers when present (private/incognito + device code);
otherwise it reuses your existing Graph context. Output goes to the toolkit's reports folder,
unless -OutPath is provided.
#>
function Get-AutopilotGroupTagFromGroup {
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$GroupId,

  [string]$GroupName,

  [switch]$StrictMdmOnly,
  [switch]$IncludeUsers,
  [switch]$PreferWai,   # kept for symmetry; WAI is used for AP lookups

  # Auth pass-through (no embedded auth; will call your pre-auth ONLY if you ask)
  [string]$Tenant,
  [string]$Account,
  [ValidateSet('edge','chrome','system')][string]$BrowserPreference = 'edge',
  [switch]$UseDeviceCode,

  # Output
  [string]$OutPath,
  [int]$MaxRetries = 5,
  [int]$RetryBaseDelaySec = 2,
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- Respect v8 design: NO embedded auth. Optionally trigger your pre-auth if caller asks. ----
if ($UseDeviceCode -and (Get-Command Start-GratBoxPreAuth -ErrorAction SilentlyContinue)) {
  $p = @{}
  if ($Tenant)            { $p.Tenant            = $Tenant }
  if ($Account)           { $p.Account           = $Account }
  if ($BrowserPreference) { $p.BrowserPreference = $BrowserPreference }
  $p.UseDeviceCode = $true
  Start-GratBoxPreAuth @p | Out-Null
}

# ----------------- helpers -----------------
function Invoke-WithRetry {
  param([scriptblock]$Script,[int]$Max=$MaxRetries,[int]$BaseDelay=$RetryBaseDelaySec,[string]$Op='Graph call')
  $attempt=0
  while ($true) {
    try { return & $Script } catch {
      $attempt++; if ($attempt -ge $Max) { throw }
      $sleep=[Math]::Min(30,[Math]::Pow(2,$attempt-1)*$BaseDelay)
      Write-Verbose ("Retry {0}/{1} after error during {2}: {3}. Sleeping {4}s..." -f $attempt,$Max,$Op,$_.Exception.Message,$sleep)
      Start-Sleep -Seconds $sleep
    }
  }
}

function Add-Items {
  param($List,$Value)
  foreach($v in @($Value)){ if($null -ne $v){ [void]$List.Add($v) } }
}

function Invoke-GraphPaged {
  param([string]$Uri)
  $items = New-Object System.Collections.Generic.List[object]
  $next  = $Uri
  while ($next) {
    $resp = Invoke-WithRetry -Op "GET $next" -Script { Invoke-MgGraphRequest -Uri $next -Method GET -OutputType PSObject }
    # Handle dictionary-like or PSObject responses, with value as single object or array
    $val  = $null; $nl = $null
    if ($resp -is [System.Collections.IDictionary]) {
      if ($resp.ContainsKey('value'))          { $val = $resp['value'] }
      if ($resp.ContainsKey('@odata.nextLink')){ $nl  = $resp['@odata.nextLink'] }
    } else {
      try { $val = $resp.value } catch { $val = $null }
      try { $nl  = $resp.PSObject.Properties['@odata.nextLink'].Value } catch { $nl = $null }
    }
    Add-Items -List $items -Value $val
    $next = if ($nl) { [string]$nl } else { $null }
  }
  return ,$items.ToArray()
}

function New-ReportFilePath {
  param([string]$Override,[string]$FuncName,[string]$Tag,[switch]$Mdmonly)
  $tag  = if ($Tag) { ($Tag -replace '[^A-Za-z0-9._-]','_') } else { '' }
  $time = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $suf  = if ($Mdmonly) { '-MDMonly' } else { '' }
  $file = if ($tag) { "{0}-{1}-{2}{3}.csv" -f $FuncName,$tag,$time,$suf } else { "{0}-{1}{2}.csv" -f $FuncName,$time,$suf }

  if ($Override) {
    if (Test-Path -LiteralPath $Override -PathType Container) {
      $dir = $Override
      $__old = $WhatIfPreference; $WhatIfPreference = $false
      try { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } }
      finally { $WhatIfPreference = $__old }
      return (Join-Path $dir $file)
    } else {
      $dir = Split-Path -Parent $Override
      if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $__old = $WhatIfPreference; $WhatIfPreference = $false
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } finally { $WhatIfPreference = $__old }
      }
      return $Override
    }
  }

  $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
  $dir  = Join-Path $root "reports\Get-AutopilotGroupTagFromGroup"
  if (-not (Test-Path -LiteralPath $dir)) {
    $__old = $WhatIfPreference; $WhatIfPreference = $false
    try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } finally { $WhatIfPreference = $__old }
  }
  return (Join-Path $dir $file)
}
# -------------- end helpers ----------------

$base = "https://graph.microsoft.com/v1.0"

# Resolve group details (displayName)
$grp = Invoke-WithRetry -Op "GET group $GroupId" -Script {
  Invoke-MgGraphRequest -Uri "$base/groups/$($GroupId)?`$select=id,displayName,securityEnabled,membershipRule" -Method GET -OutputType PSObject
}
if (-not $GroupName) { $GroupName = $grp.displayName }

$outFile = New-ReportFilePath -Override $OutPath -FuncName 'Get-AutopilotGroupTagFromGroup' -Tag $GroupName -Mdmonly:$StrictMdmOnly
Write-Host ("Output will be saved to: {0}" -f $outFile)

# 1) Get device members of the group (paged)
$memberUri = "$base/groups/$($GroupId)/members/microsoft.graph.device?`$select=id,displayName"
$memberDevices = Invoke-GraphPaged -Uri $memberUri

# Always materialize as an array (avoid scalar .Count issues)
$aadObjIds   = @($memberDevices | ForEach-Object { $_.id } | Where-Object { $_ })
$aadObjCount = $aadObjIds.Count

# 2) Map AAD objectId -> device.deviceId (required to join with managedDevices.azureADDeviceId)
$aadDevIds = @()
foreach ($objId in $aadObjIds) {
  $dev = Invoke-WithRetry -Op "GET device $objId" -Script {
    Invoke-MgGraphRequest -Uri "$base/devices/$($objId)?`$select=deviceId" -Method GET -OutputType PSObject
  }
  if ($dev -and $dev.deviceId) { $aadDevIds += $dev.deviceId }
}
$aadDevIds   = @($aadDevIds | Where-Object { $_ })
$aadDevCount = $aadDevIds.Count

# 3) Get Intune managed devices matching those Azure AD deviceIds (one query per id; reliable)
$select = "id,azureADDeviceId,deviceName,operatingSystem,serialNumber,manufacturer,model,managementAgent,userId,userPrincipalName"
$managed = New-Object System.Collections.Generic.List[object]
foreach ($devId in $aadDevIds) {
  $uri  = "$base/deviceManagement/managedDevices?`$select=$select&`$filter=azureADDeviceId eq '$devId'"
  $page = Invoke-GraphPaged -Uri $uri
  Add-Items -List $managed -Value $page
}

$allManaged  = @($managed.ToArray())
$beforeCount = $allManaged.Count

if ($StrictMdmOnly) {
  $allManaged = @($allManaged | Where-Object { ('' + $_.managementAgent) -match 'mdm' })
  $filtered = $beforeCount - $allManaged.Count
  Write-Host ("Strict MDM filter: kept {0} of {1}; filtered out {2} non-MDM devices." -f $allManaged.Count,$beforeCount,$filtered)
}

# 4) Resolve Autopilot by serial (WAI module)
try { Import-Module WindowsAutoPilotIntune -ErrorAction Stop | Out-Null } catch { }

$rows  = New-Object System.Collections.Generic.List[object]
$withAp = 0

foreach ($m in $allManaged) {
  $serial = $m.serialNumber
  $ap = $null
  if ($serial) {
    try { $ap = Get-AutopilotDevice -serial $serial -ErrorAction Stop | Select-Object -First 1 } catch { $ap = $null }
  }
  if ($ap) { $withAp++ }

  $row = [ordered]@{
    GroupId             = $GroupId
    GroupName           = $GroupName
    AadDeviceObjectId   = $m.azureADDeviceId     # equals device.deviceId, not device.id
    ManagedDeviceId     = $m.id
    IntuneDeviceName    = $m.deviceName
    OperatingSystem     = $m.operatingSystem
    SerialNumber        = $serial
    Manufacturer        = $m.manufacturer
    Model               = $m.model
    ManagementAgent     = $m.managementAgent
    AutopilotId         = if ($ap) { $ap.Id } else { $null }
    GroupTag            = if ($ap) { $ap.groupTag } else { $null }
    Source              = if ($ap) { 'Autopilot' } else { 'IntuneOnly' }
    Note                = if (-not $serial) { 'No serial in Intune record' } else { $null }
  }
  if ($IncludeUsers) {
    $row['AssignedUser'] = if ($ap -and $ap.userPrincipalName) { $ap.userPrincipalName } elseif ($m.userPrincipalName) { $m.userPrincipalName } else { $null }
  }

  [void]$rows.Add([pscustomobject]$row)
}

# Always write the CSV report, even during -WhatIf
$__oldWip = $WhatIfPreference; $WhatIfPreference = $false
try {
  $rows | Export-Csv -LiteralPath $outFile -NoTypeInformation -Encoding UTF8
}
finally {
  $WhatIfPreference = $__oldWip
}

Write-Host ("Group devices: {0} | AAD deviceIds resolved: {1} | Intune-managed (after filter): {2} | With Autopilot: {3} | Report: {4}" -f $aadObjCount,$aadDevCount,$allManaged.Count,$withAp,$outFile)
if ($PassThru) { return $rows }
}
