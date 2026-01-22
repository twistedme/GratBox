<#
.SYNOPSIS
Clear (remove) the Autopilot Group Tag for devices in an Entra group.

.DESCRIPTION
Resolves group device members (and, optionally, user-owned devices), looks up Intune managed
devices to get serials, then finds Autopilot identities and clears the Group Tag for those that
currently have one (or match -TagFilter). Writes a CSV report. Supports -WhatIf and -StrictMdmOnly.

.PARAMETER GroupId
Target Entra group GUID (required). GroupName is optional and used for labels.

.PARAMETER GroupName
Optional label for reports; auto-resolved from GroupId if omitted.

.PARAMETER TagFilter
Only clear tags that exactly match this value. If omitted, clears any non-empty tag.

.PARAMETER StrictMdmOnly
Filter to Intune MDM/easMdm managed devices and log how many were filtered out.

.PARAMETER IncludeUsers
Also include devices owned by user members of the group (unioned with device members).

.PARAMETER PreferWai
Prefer WindowsAutoPilotIntune for updates (Graph is the default).

.PARAMETER UseDeviceCode, Tenant, Account, BrowserPreference
Auth controls; integrates with Start-GratBoxPreAuth if present.

.PARAMETER WhatIf
Preview changes without applying them.

.PARAMETER OutPath
Explicit report path; otherwise writes to reports\Remove-AutopilotGroupTagFromGroup\...

.PARAMETER PassThru
Also return the results to the pipeline.
#>
function Remove-AutopilotGroupTagFromGroup {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact='Medium')]
  param(
    [Parameter(Mandatory)][string]$GroupId,
    [string]$GroupName,

    [string]$TagFilter,

    [switch]$StrictMdmOnly,
    [switch]$IncludeUsers,
    [switch]$PreferWai,

    # Auth
    [switch]$UseDeviceCode,
    [string]$Tenant,
    [string]$Account,
    [ValidateSet('edge','chrome','system')]
    [string]$BrowserPreference = 'edge',

    # Output
    [string]$OutPath,
    [switch]$PassThru
  )

  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'

  # ---------- helpers ----------
  function Invoke-GratBoxAuth {
  $scopes = @('Directory.Read.All','Group.Read.All','DeviceManagementManagedDevices.Read.All','DeviceManagementServiceConfig.ReadWrite.All')
  if (Get-Command -Name Start-GratBoxPreAuth -ErrorAction SilentlyContinue) {
    $helper = Get-Command Start-GratBoxPreAuth -ErrorAction SilentlyContinue
    $p = @{ Scopes = $scopes }
    if ($Tenant) { $p['Tenant'] = $Tenant }
    if ($UseDeviceCode) {
      if ($helper.Parameters.ContainsKey('DeviceCode'))        { $p['DeviceCode']    = $true }
      elseif ($helper.Parameters.ContainsKey('UseDeviceCode')) { $p['UseDeviceCode'] = $true }
    }
    if ($Account) { $p['Account'] = $Account }
    if ($helper.Parameters.ContainsKey('BrowserPreference') -and $BrowserPreference) { $p['BrowserPreference'] = $BrowserPreference }
    Start-GratBoxPreAuth @p | Out-Null
  } else {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $c = @{ Scopes = $scopes }
    if ($Tenant)       { $c['TenantId']      = $Tenant }
    if ($Account)      { $c['Account']       = $Account }
    if ($UseDeviceCode){ $c['UseDeviceCode'] = $true }
    Connect-MgGraph @c | Out-Null
  }
}


  function GGET { param([string]$Uri,[hashtable]$Headers) Invoke-MgGraphRequest -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop }

  function Resolve-ReportsPath {
    param([string]$Override)
    if ($Override) {
      $dir = Split-Path -Parent $Override
      if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
      return $Override
    }
    $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $dir = Join-Path $moduleRoot 'reports\Remove-AutopilotGroupTagFromGroup'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir ("Remove-AutopilotGroupTagFromGroup-{0}.csv" -f (Get-Date).ToString('yyyyMMdd-HHmmss')))
  }

  function Get-GroupInfo {
    return (GGET "/v1.0/groups/$GroupId?`$select=id,displayName" @{})
  }

  function Get-GroupDevices {
    # Device members (transitive)
    $acc=@(); $next="/v1.0/groups/$GroupId/transitiveMembers/microsoft.graph.device?`$select=id,deviceId,displayName&`$top=999"
    while ($next) { $r=GGET $next @{}; if ($r.value){ $acc += $r.value }; $next=$r.'@odata.nextLink' }
    return $acc
  }

  function Get-GroupUsers {
    $acc=@(); $next="/v1.0/groups/$GroupId/transitiveMembers/microsoft.graph.user?`$select=id,userPrincipalName,displayName&`$top=999"
    while ($next) { $r=GGET $next @{}; if ($r.value){ $acc += $r.value }; $next=$r.'@odata.nextLink' }
    return $acc
  }

  function Get-ManagedDeviceByAadDeviceId {
    param([string]$AadDevId)
    $aid=$AadDevId.Replace("'", "''")
    $uri="/v1.0/deviceManagement/managedDevices?`$select=id,azureADDeviceId,deviceName,operatingSystem,serialNumber,manufacturer,model,managementAgent,userPrincipalName&`$filter=azureADDeviceId eq '$aid'&`$top=1"
    try { $r=GGET $uri @{}; if ($r.value -and $r.value.Count -gt 0){ return $r.value[0] } } catch { }
    return $null
  }

  function Get-ManagedDevicesByUserUpn {
    param([string]$Upn)
    $u=$Upn.Replace("'", "''")
    $uri="/v1.0/deviceManagement/managedDevices?`$select=id,azureADDeviceId,deviceName,operatingSystem,serialNumber,manufacturer,model,managementAgent,userPrincipalName&`$filter=userPrincipalName eq '$u'&`$top=999"
    try { return (GGET $uri @{}).value } catch { return @() }
  }

  function Get-AutopilotBySerial {
    param([string]$Serial,[switch]$PreferWaiLocal)
    if ($Serial) {
      $s=$Serial.Replace("'", "''")
      $uri="/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$select=id,serialNumber,groupTag,manufacturer,model,azureAdDeviceId&`$filter=serialNumber eq '$s'&`$top=1"
      try { $r=GGET $uri @{}; if ($r.value -and $r.value.Count -gt 0){ return $r.value[0] } } catch { }
      if ($PreferWaiLocal) {
        try {
          Import-Module WindowsAutoPilotIntune -ErrorAction Stop
          $d = Get-AutopilotDevice -serial $Serial -ErrorAction Stop | Select-Object -First 1
          if ($d) {
            return [pscustomobject]@{
              id=$d.Id; serialNumber=$d.SerialNumber; groupTag=$d.GroupTag
              manufacturer=$d.Manufacturer; model=$d.Model; azureAdDeviceId=$d.AzureAdDeviceId
            }
          }
        } catch { }
      }
    }
    return $null
  }

  function Clear-AutopilotTag {
    param([string]$Id,[switch]$PreferWaiLocal)
    # Try Graph first
    try {
      Import-Module Microsoft.Graph.DeviceManagement.Enrollment -ErrorAction Stop
      $body = @{ groupTag = "" }
      Update-MgDeviceManagementWindowsAutopilotDeviceIdentity `
        -WindowsAutopilotDeviceIdentityId $Id `
        -BodyParameter $body | Out-Null
      return $true
    } catch {
      if ($PreferWaiLocal) {
        try {
          Import-Module WindowsAutoPilotIntune -ErrorAction Stop
          Set-AutopilotDevice -Id $Id -GroupTag '' | Out-Null
          return $true
        } catch { throw }
      } else { throw }
    }
  }
  # ---------- end helpers ----------

  Start-GraphAuth
  $g = Get-GroupInfo
  if (-not $GroupName) { $GroupName = $g.displayName }

  $reportPath = Resolve-ReportsPath -OutPath $OutPath

  # Build target Intune managed devices from device members (+users if requested)
  $deviceMembers = Get-GroupDevices
  $managed = New-Object System.Collections.Generic.List[object]

  foreach ($d in $deviceMembers) {
    $md = if ($d.deviceId) { Get-ManagedDeviceByAadDeviceId -AadDeviceId $d.deviceId } else { $null }
    if ($md) { $managed.Add($md) | Out-Null }
  }

  if ($IncludeUsers) {
    $users = Get-GroupUsers
    foreach ($u in $users) {
      $ud = Get-ManagedDevicesByUserUpn -Upn $u.userPrincipalName
      foreach ($md in $ud) { $managed.Add($md) | Out-Null }
    }
  }

  # De-dupe by azureADDeviceId
  $managed = $managed | Group-Object azureADDeviceId | ForEach-Object { $_.Group[0] }

  # Strict MDM filter (with log)
  if ($StrictMdmOnly) {
    $preCount = @($managed).Count
    $managed  = $managed | Where-Object { $_.managementAgent -in @('mdm','easMdm') }
    $postCount = @($managed).Count
    $filtered  = $preCount - $postCount
    Write-Host ("Strict MDM filter: kept {0} of {1}; filtered out {2} non‑MDM devices." -f $postCount, $preCount, $filtered)
  }

  if (-not $managed -or $managed.Count -eq 0) {
    Write-Warning "No eligible Intune managed devices found in group '$GroupName'."
    @() | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
    if ($PassThru) { return @() }
    return
  }

  # Process
  $results = New-Object System.Collections.Generic.List[object]
  $total = $managed.Count; $i = 0

  foreach ($md in $managed) {
    $i++; $pct=[int](($i/$total)*100)
    Write-Progress -Id 1 -Activity "Clearing Autopilot Group Tags" -Status "$i of $total ($pct%)" -PercentComplete $pct

    $serial = $md.serialNumber
    $ap = $null
    if ($serial) { $ap = Get-AutopilotBySerial -Serial $serial -PreferWaiLocal:$PreferWai }

    $row = [ordered]@{
      GroupId          = $g.id
      GroupName        = $GroupName
      ManagedDeviceId  = $md.id
      IntuneDeviceName = $md.deviceName
      OperatingSystem  = $md.operatingSystem
      SerialNumber     = $serial
      AutopilotId      = $ap.id
      OldGroupTag      = $ap.groupTag
      Action           = ''
      Result           = ''
      ErrorMessage     = $null
    }

    try {
      if (-not $ap) {
        $row.Action='Skip-NoAutopilot'; $row.Result='Success'
      } elseif ([string]::IsNullOrWhiteSpace($ap.groupTag)) {
        $row.Action='Skip-NoTag'; $row.Result='Success'
      } elseif ($TagFilter -and ($ap.groupTag -ne $TagFilter)) {
        $row.Action='Skip-FilterNoMatch'; $row.Result='Success'
      } else {
        $row.Action='ClearTag'
        if ($PSCmdlet.ShouldProcess("AutopilotId $($ap.id)","Clear GroupTag")) {
          $ok = Clear-AutopilotTag -Id $ap.id -PreferWaiLocal:$PreferWai
          if ($ok) { $row.Result='Success' } else { $row.Result='NoChange' }
        } else {
          $row.Result='WhatIf'
        }
      }
    } catch {
      $row.Result='Error'; $row.ErrorMessage=$_.Exception.Message
    }

    $results.Add([pscustomobject]$row) | Out-Null
  }

  # Write CSV + summary
  $results | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
  $cleared = ($results | Where-Object { $_.Action -eq 'ClearTag'  -and $_.Result -eq 'Success' }).Count
  $skipped = ($results | Where-Object { $_.Action -like 'Skip*' }).Count
  $errors  = ($results | Where-Object { $_.Result -eq 'Error' }).Count
  Write-Host ("Cleared: {0} | Skipped: {1} | Errors: {2} | Report: {3}" -f $cleared,$skipped,$errors,$reportPath)

  if ($PassThru) { return $results }
}


