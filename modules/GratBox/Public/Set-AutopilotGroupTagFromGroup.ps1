<#
 Set-AutopilotGroupTagFromGroup.ps1
 Resolve devices in an Entra group → find their serials → set Autopilot group tag.

 EXAMPLE
   Set-AutopilotGroupTagFromGroup -GroupId '<GUID>' -GroupName 'Friendly' -GroupTag 'TAG-USER'
#>

function Set-AutopilotGroupTagFromGroup {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$GroupId,
    [string]$GroupName,
    [Parameter(Mandatory)][string]$GroupTag,
    [switch]$DryRun,
    [switch]$ForceImport,
    [int]$MaxRetries = 5,
    [int]$RetryBaseDelaySec = 5
  )

  # ----- helpers -----
  $sw = [Diagnostics.Stopwatch]::StartNew()
  function Log([string]$msg,[ConsoleColor]$c='Gray'){ Write-Host ("[{0,5:n1}s] {1}" -f $sw.Elapsed.TotalSeconds,$msg) -ForegroundColor $c }

  if (Get-Command Connect-GraphPrivateSession -ErrorAction SilentlyContinue) {
    Connect-GraphPrivateSession -RequiredScopes @(
      'DeviceManagementManagedDevices.Read.All',
      'DeviceManagementServiceConfig.ReadWrite.All',
      'Directory.Read.All',
      'Group.Read.All'
    ) -TenantHint '' -BrowserPref 'edge' 2>$null
  }

  function Invoke-GraphWithRetry {
    param(
      [Parameter(Mandatory)][ValidateSet('GET','POST','PATCH')]$Method,
      [Parameter(Mandatory)][string]$Uri,
      [object]$Body = $null,
      [switch]$PSObject,
      [hashtable]$Headers
    )
    $attempt = 0
    while ($true) {
      $attempt++
      try {
        $args = @{ Method=$Method; Uri=$Uri; OutputType = ([bool]$PSObject.IsPresent ? 'PSObject' : 'String') }
        if ($Body -ne $null) { $args.Body = ($Body | ConvertTo-Json -Depth 8); $args.ContentType = 'application/json' }
        if ($Headers)      { $args.Headers = $Headers }
        return Invoke-MgGraphRequest @args
      } catch {
        $msg = $_.Exception.Message
        if ($attempt -lt $MaxRetries -and ($msg -match 'InternalServerError|5\d\d|temporar|timeout|Throttl')) {
          $d = [double]$RetryBaseDelaySec * [Math]::Pow(2, ($attempt - 1)); if ($d -gt 60) { $d = 60 }
          $sec = [int][Math]::Ceiling($d)
          Log ("WARNING: Graph call failed (attempt {0}/{1}): {2} → retrying in {3}s" -f $attempt,$MaxRetries,$msg,$sec) Yellow
          Start-Sleep -Seconds $sec
          continue
        }
        throw
      }
    }
  }

  # ----- report path -----
  $root = $null
  $mod = Get-Module GratBox -ErrorAction SilentlyContinue
  if ($mod -and $mod.ModuleBase) { try { $root = Split-Path -Parent (Split-Path -Parent $mod.ModuleBase) } catch {} }
  if (-not $root) { $thisFile = $MyInvocation.MyCommand.Path; if ($thisFile) { try { $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $thisFile)) } catch {} } }
  if (-not $root) { try { $root = (Get-Location).Path } catch { $root = (Get-Location).Path } }

  $reportsDir = Join-Path $root 'reports\Set-AutopilotGroupTagFromGroup'
  if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
  if ([string]::IsNullOrWhiteSpace($GroupName)) {
    try {
      $g = Invoke-GraphWithRetry -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId?`$select=displayName" -PSObject
      $GroupName = $g.displayName
    } catch {}
  }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
  $safe  = if ($GroupName) { ($GroupName -replace '[^\w\-. ]','_') } else { $GroupId }
  $csv   = Join-Path $reportsDir ("AutoPilotGroupTag_{0}_{1}.csv" -f $safe,$stamp)

  Log ("Group: {0} ({1})" -f $GroupName,$GroupId) Cyan
  Log ("Target Group Tag: {0}" -f $GroupTag) Cyan
  Log ("CSV Log: {0}" -f $csv) Cyan

  # ----- enumerate group device members -----
  $stubs = @()
  try {
    if (Get-Command Get-MgGroupTransitiveMemberAsDevice -ErrorAction SilentlyContinue) {
      $stubs = Get-MgGroupTransitiveMemberAsDevice -GroupId $GroupId -All -Property 'id,displayName,deviceId' -ErrorAction Stop
    } else {
      $stubs = Get-MgGroupTransitiveMember -GroupId $GroupId -All -Property 'id,displayName,deviceId' -ErrorAction Stop |
               Where-Object { $_.'@odata.type' -eq '#microsoft.graph.device' }
    }
  } catch {
    Log ("Could not enumerate group members: $($_.Exception.Message)") Yellow
  }

  if (-not $stubs -or $stubs.Count -eq 0) {
    Log "No device members found." Yellow
    @() | Select-Object GroupId,GroupName,DeviceDisplayName,AadObjectId,AadDeviceId,SerialNumber,OldGroupTag,NewGroupTag,AutopilotId,Status,Message |
      Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
    return
  }

  # ----- map to serials via managedDevices -----
  $serialMap = @{}   # serial -> @{DisplayName=..; AadObjectId=..; AadDeviceId=..}
  foreach ($s in $stubs) {
    $display = $s.displayName
    $aadObj  = $s.id
    $aadDev  = $s.deviceId
    if (-not $aadDev) {
      try {
        $dev = Get-MgDevice -DeviceId $s.Id -Property 'deviceId' -ErrorAction Stop
        $aadDev = $dev.deviceId
      } catch { continue }
    }
    try {
      $flt = "azureADDeviceId eq '$aadDev'"
      $md  = Invoke-GraphWithRetry -Method GET -Uri ("https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=id,serialNumber,deviceName,azureADDeviceId&`$filter={0}" -f [uri]::EscapeDataString($flt)) -PSObject
      $m   = $md.value | Select-Object -First 1
      if ($m -and $m.serialNumber) {
        $serialMap[$m.serialNumber] = @{ DisplayName=$display; AadObjectId=$aadObj; AadDeviceId=$aadDev }
      }
    } catch {}
  }

  if ($serialMap.Count -eq 0) {
    Log "No managedDevice serials resolved from group members." Yellow
    @() | Select-Object GroupId,GroupName,DeviceDisplayName,AadObjectId,AadDeviceId,SerialNumber,OldGroupTag,NewGroupTag,AutopilotId,Status,Message |
      Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
    return
  }

  # ----- call the serial updater -----
  $serials = $serialMap.Keys
  $results = Set-AutopilotGroupTagBySerial -SerialNumber $serials -GroupTag $GroupTag -DryRun:$DryRun -ForceImport:$ForceImport -MaxRetries $MaxRetries -RetryBaseDelaySec $RetryBaseDelaySec

  # ----- attach group/device context and write -----
  $rows = foreach ($r in $results) {
    $ctx = $serialMap[$r.SerialNumber]
    [pscustomobject]@{
      GroupId           = $GroupId
      GroupName         = $GroupName
      DeviceDisplayName = $ctx.DisplayName
      AadObjectId       = $ctx.AadObjectId
      AadDeviceId       = $ctx.AadDeviceId
      SerialNumber      = $r.SerialNumber
      OldGroupTag       = $r.OldGroupTag
      NewGroupTag       = $r.NewGroupTag
      AutopilotId       = $r.AutopilotId
      Status            = $r.Status
      Message           = $r.Message
    }
  }

  $done = @($rows | Where-Object { $_.Status -in 'Updated','WouldUpdate','Imported','WouldImport' }).Count
  $kept = @($rows | Where-Object { $_.Status -eq 'Unchanged' }).Count
  $none = @($rows | Where-Object { $_.Status -eq 'NoAutopilotMatch' }).Count
  $errs = @($rows | Where-Object { $_.Status -eq 'Error' }).Count

  $rows | Sort-Object DeviceDisplayName |
    Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

  Log ("Group devices: {0} | Updated/WouldUpdate/Imported: {1} | Unchanged: {2} | No serial/identity: {3} | Errors: {4}" -f $stubs.Count,$done,$kept,$none,$errs) Cyan
  Log ("CSV: {0}" -f $csv) Cyan

  $rows
}
