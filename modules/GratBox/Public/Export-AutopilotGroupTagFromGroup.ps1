<#
 Export-AutopilotGroupTagFromGroup.ps1
 Exports Autopilot "Group tag" and related details for all devices in a target Entra device group.

 Usage:
   Export-AutopilotGroupTagFromGroup -GroupId "<GUID>" [-GroupName "<friendly>"] [-OutPath "<csv>"] [-PreferWai]
   # Default report folder:
   #   <toolRoot>\reports\Export-AutopilotGroupTagFromGroup

 Notes:
   - Requires Graph read scopes:
       Group.Read.All, Directory.Read.All,
       DeviceManagementManagedDevices.Read.All, DeviceManagementServiceConfig.Read.All
   - Primary path: finds serial via managedDevices; then looks up Autopilot by serialNumber.
   - If Graph GET returns 5xx at either step (managedDevices OR Autopilot),
     or you pass -PreferWai, we fall back to WindowsAutoPilotIntune for read.
#>

function Export-AutopilotGroupTagFromGroup {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$GroupId,
    [string]$GroupName,
    [string]$OutPath,
    [switch]$PreferWai,
    [int]$MaxRetries = 5,
    [int]$RetryBaseDelaySec = 5
  )
  # StrictMode-safe init of module-level WAI cache
  if (-not (Get-Variable -Name 'waiCache' -Scope Script -ErrorAction SilentlyContinue)) {
    Set-Variable -Name 'waiCache' -Scope Script -Value $null
  }

  # ---------- helpers ----------
  $sw = [Diagnostics.Stopwatch]::StartNew()
  function Log([string]$msg,[ConsoleColor]$c='Gray'){ Write-Host ("[{0,5:n1}s] {1}" -f $sw.Elapsed.TotalSeconds,$msg) -ForegroundColor $c }

  # Use your helper if present (no-op if already signed in)
  if (Get-Command Connect-GraphPrivateSession -ErrorAction SilentlyContinue) {
    Connect-GraphPrivateSession -RequiredScopes @(
      'Group.Read.All',
      'Directory.Read.All',
      'DeviceManagementManagedDevices.Read.All',
      'DeviceManagementServiceConfig.Read.All'
    ) 2>$null
  } elseif (Get-Command Ensure-GraphPrivate -ErrorAction SilentlyContinue) {
    # Back-compat if you haven't renamed yet
    Ensure-GraphPrivate -RequiredScopes @(
      'Group.Read.All',
      'Directory.Read.All',
      'DeviceManagementManagedDevices.Read.All',
      'DeviceManagementServiceConfig.Read.All'
    ) 2>$null
  }

  # Graph wrapper with numeric backoff (bounded)
  function Invoke-GraphWithRetry {
    param(
      [Parameter(Mandatory)][ValidateSet('GET','POST','PATCH')]$Method,
      [Parameter(Mandatory)][string]$Uri,
      [hashtable]$Headers = $null,
      [object]$Body = $null,
      [switch]$PSObject
    )
    $attempt = 0
    while ($true) {
      $attempt++
      try {
        if ($Body -ne $null) {
          $json = $Body | ConvertTo-Json -Depth 8
          return Invoke-MgGraphRequest -Method $Method -Uri $Uri `
                   -Headers $Headers -Body $json -ContentType 'application/json' `
                   -OutputType ([bool]$PSObject.IsPresent ? 'PSObject' : 'String')
        } else {
          return Invoke-MgGraphRequest -Method $Method -Uri $Uri `
                   -Headers $Headers `
                   -OutputType ([bool]$PSObject.IsPresent ? 'PSObject' : 'String')
        }
      } catch {
        $msg = $_.Exception.Message
        if ($attempt -lt $MaxRetries -and ($msg -match 'InternalServerError|5\d\d|temporar|timeout|Throttl')) {
          $backoffD = [double]$RetryBaseDelaySec * [math]::Pow(2, ($attempt - 1))
          if ($backoffD -gt 60) { $backoffD = 60 }
          $sec = [int][math]::Ceiling($backoffD)
          Log ("WARNING: Graph call failed (attempt {0}/{1}): {2} → retrying in {3}s" -f $attempt,$MaxRetries,$msg,$sec) Yellow
          Start-Sleep -Seconds $sec
          continue
        }
        throw
      }
    }
  }

   # WindowsAutoPilotIntune fallback cache (lazy) - StrictMode-safe
  function Ensure-WaiCache {
    $existing = Get-Variable -Name 'waiCache' -Scope Script -ErrorAction SilentlyContinue
    if (-not $existing) { $script:waiCache = $null }
    if ($script:waiCache) { return }

    try {
      Import-Module WindowsAutoPilotIntune -ErrorAction Stop
      $all = Get-AutopilotDevice -ErrorAction Stop
      $bySerial = @{}
      $byAad    = @{}
      foreach ($d in $all) {
        if ($d.serialNumber) { $bySerial[$d.serialNumber] = $d }
        $aad = $d.azureActiveDirectoryDeviceId
        if (-not $aad) { $aad = $d.azureAdDeviceId } # older builds use this name
        if ($aad) { $byAad[$aad] = $d }
      }
      $script:waiCache = @{ BySerial = $bySerial; ByAad = $byAad }
      Log "Loaded Autopilot cache via WindowsAutoPilotIntune." Yellow
    } catch {
      Log ("WAI cache load failed: $($_.Exception.Message)") Yellow
      $script:waiCache = $null
    }
  }


  # ---------- resolve group/display name ----------
  if ([string]::IsNullOrWhiteSpace($GroupName)) {
    try {
      $g = Invoke-GraphWithRetry -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId?`$select=displayName" -PSObject
      $GroupName = $g.displayName
    } catch { }
  }

  # ---------- report path (robust for module or dot-sourced) ----------
  $root = $null
  $mod = Get-Module GratBox -ErrorAction SilentlyContinue
  if ($mod -and $mod.ModuleBase) {
    try { $root = Split-Path -Parent (Split-Path -Parent $mod.ModuleBase) } catch {}
  }
  if (-not $root) {
    $thisFile = $MyInvocation.MyCommand.Path
    if ($thisFile) {
      try {
        $publicDir = Split-Path -Parent $thisFile
        $moduleDir = Split-Path -Parent $publicDir
        $root      = Split-Path -Parent $moduleDir
      } catch {}
    }
  }
  if (-not $root) { try { $root = (Get-Location).Path } catch { $root = (Get-Location).Path } }

  $reportsDir = if ($OutPath) { Split-Path -Parent $OutPath } else { Join-Path $root 'reports\Export-AutopilotGroupTagFromGroup' }
  if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
  if (-not $OutPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $safe  = if ($GroupName) { ($GroupName -replace '[^\w\-. ]','_') } else { $GroupId }
    $OutPath = Join-Path $reportsDir ("AutopilotGroupTag_{0}_{1}.csv" -f $safe,$stamp)
  }

  Log ("Group: {0} ({1})" -f $GroupName,$GroupId) Cyan
  Log ("CSV  : {0}" -f $OutPath) Cyan

  # ---------- get group’s device members ----------
  try {
    $stubs = if (Get-Command Get-MgGroupTransitiveMemberAsDevice -ErrorAction SilentlyContinue) {
      Get-MgGroupTransitiveMemberAsDevice -GroupId $GroupId -All -Property 'id,displayName,deviceId' -ErrorAction Stop
    } else {
      Get-MgGroupTransitiveMember -GroupId $GroupId -All -Property 'id,displayName,deviceId' -ErrorAction Stop |
        Where-Object { $_.'@odata.type' -eq '#microsoft.graph.device' }
    }
  } catch {
    Log ("Could not enumerate group members: $($_.Exception.Message)") Yellow
    $stubs = @()
  }

  if (-not $stubs -or $stubs.Count -eq 0) {
    Log "No device members found." Yellow
    @() | Select-Object GroupId,GroupName,DeviceDisplayName,AadObjectId,AadDeviceId,ManagedDeviceId,DeviceName,OperatingSystem,OSVersion,ManagementAgent,EnrolledDateTime,LastCheckinDateTime,ComplianceState,SerialNumber,AutopilotId,AutoDisplayName,AutoManufacturer,AutoModel,GroupTag,LookupPath,Status,Message |
      Export-Csv -Path $OutPath -NoTypeInformation -Encoding UTF8
    return
  }

  # ---------- process ----------
  $rows = New-Object System.Collections.Generic.List[object]
  $useWai = $PreferWai.IsPresent

  foreach ($s in $stubs) {
    $row = [ordered]@{
      GroupId             = $GroupId
      GroupName           = $GroupName
      DeviceDisplayName   = $s.DisplayName
      AadObjectId         = $s.Id
      AadDeviceId         = $null
      ManagedDeviceId     = $null
      DeviceName          = $null
      OperatingSystem     = $null
      OSVersion           = $null
      ManagementAgent     = $null
      EnrolledDateTime    = $null
      LastCheckinDateTime = $null
      ComplianceState     = $null
      SerialNumber        = $null
      AutopilotId         = $null
      AutoDisplayName     = $null
      AutoManufacturer    = $null
      AutoModel           = $null
      GroupTag            = $null
      LookupPath          = $null   # 'Graph' or 'WAI'
      Status              = $null
      Message             = $null
    }

    # ensure azureADDeviceId on stub
    if (-not $s.deviceId) {
      try {
        $dev = Get-MgDevice -DeviceId $s.Id -Property 'deviceId' -ErrorAction Stop
        $s | Add-Member -NotePropertyName deviceId -NotePropertyValue $dev.deviceId -Force
      } catch {
        $row.Status  = 'Error'
        $row.Message = "Could not read deviceId: $($_.Exception.Message)"
        $rows.Add([pscustomobject]$row) | Out-Null
        continue
      }
    }
    $row.AadDeviceId = $s.deviceId

    # (1) ManagedDevice → serial (skip if PreferWai)
    if (-not $useWai) {
      try {
        $flt = "azureADDeviceId eq '$($s.deviceId)'"
        $md  = Invoke-GraphWithRetry -Method GET -Uri ("https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=id,deviceName,operatingSystem,osVersion,managementAgent,enrolledDateTime,lastSyncDateTime,complianceState,serialNumber,azureADDeviceId&`$filter={0}" -f [uri]::EscapeDataString($flt)) -PSObject
        $m   = $md.value | Select-Object -First 1
        if ($m) {
          $row.ManagedDeviceId     = $m.id
          $row.DeviceName          = $m.deviceName
          $row.OperatingSystem     = $m.operatingSystem
          $row.OSVersion           = $m.osVersion
          $row.ManagementAgent     = $m.managementAgent
          $row.EnrolledDateTime    = $m.enrolledDateTime
          $row.LastCheckinDateTime = $m.lastSyncDateTime
          $row.ComplianceState     = $m.complianceState
          if ($m.serialNumber) { $row.SerialNumber = $m.serialNumber }
        } else {
          # no result from md → prefer WAI
          $useWai = $true
          Log "No managedDevice match; switching to WindowsAutoPilotIntune path." Yellow
        }
      } catch {
        # md 5xx → switch to WAI
        $useWai = $true
        Log ("managedDevices GET is failing; switching to WindowsAutoPilotIntune. Reason: $($_.Exception.Message)") Yellow
      }
    }

    # (2) Autopilot identity
    $apFound = $false

    # Primary: Graph by serial (only if we’re still on Graph AND we have a serial)
    if (-not $useWai -and $row.SerialNumber) {
      try {
        $fltAP = "serialNumber eq '$($row.SerialNumber)'"
        $hdr   = @{ 'ConsistencyLevel'='eventual' }
        $ap    = Invoke-GraphWithRetry -Method GET -Uri ("https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$select=id,serialNumber,groupTag,manufacturer,model,azureActiveDirectoryDeviceId,managedDeviceId,displayName&`$filter={0}" -f [uri]::EscapeDataString($fltAP)) -Headers $hdr -PSObject
        $apd   = $ap.value | Select-Object -First 1
        if ($apd) {
          $row.AutopilotId      = $apd.id
          $row.AutoDisplayName  = $apd.displayName
          $row.AutoManufacturer = $apd.manufacturer
          $row.AutoModel        = $apd.model
          $row.GroupTag         = $apd.groupTag
          $row.LookupPath       = 'Graph'
          $apFound = $true
        } else {
          # no AP via Graph → try WAI
          $useWai = $true
          Log "No Autopilot match via Graph; switching to WindowsAutoPilotIntune." Yellow
        }
      } catch {
        # AP 5xx → switch to WAI
        $useWai = $true
        Log ("Autopilot GET is failing; switching to WindowsAutoPilotIntune. Reason: $($_.Exception.Message)") Yellow
      }
    }

    # Fallback/forced: WindowsAutoPilotIntune
    if (-not $apFound -and $useWai) {
      Ensure-WaiCache
      if ($waiCache) {
        $apd = $null
        if ($row.SerialNumber -and $waiCache.BySerial.ContainsKey($row.SerialNumber)) {
          $apd = $waiCache.BySerial[$row.SerialNumber]
        } elseif ($row.AadDeviceId -and $waiCache.ByAad.ContainsKey($row.AadDeviceId)) {
          $apd = $waiCache.ByAad[$row.AadDeviceId]
        }
        if ($apd) {
          $row.AutopilotId      = $apd.id
          $row.AutoDisplayName  = $apd.displayName
          $row.AutoManufacturer = $apd.manufacturer
          $row.AutoModel        = $apd.model
          $row.GroupTag         = $apd.groupTag
          if (-not $row.SerialNumber) { $row.SerialNumber = $apd.serialNumber }
          $row.LookupPath       = 'WAI'
          $apFound              = $true
        }
      }
    }

    if ($apFound) {
      $row.Status = 'FoundAutopilot'
    } else {
      if (-not $row.SerialNumber -and -not $useWai) {
        $row.Status  = 'NoManagedDeviceSerial'
        $row.Message = 'No managedDevice or serialNumber found.'
      } else {
        $row.Status  = 'NoAutopilotMatch'
        if (-not $row.Message) { $row.Message = 'No Autopilot identity found.' }
      }
    }

    $rows.Add([pscustomobject]$row) | Out-Null
  }

  # ---------- export ----------
  $rows | Sort-Object DeviceDisplayName |
    Export-Csv -Path $OutPath -NoTypeInformation -Encoding UTF8

  $found = @($rows | Where-Object { $_.Status -eq 'FoundAutopilot' }).Count
  $noap  = @($rows | Where-Object { $_.Status -eq 'NoAutopilotMatch' }).Count
  $nomd  = @($rows | Where-Object { $_.Status -eq 'NoManagedDeviceSerial' }).Count
  Log ("Group devices: {0} | Found AP: {1} | No AP: {2} | No serial: {3}" -f $stubs.Count,$found,$noap,$nomd) Cyan
  Log ("CSV: {0}" -f $OutPath) Cyan

  # emit to pipeline
  $rows
}
