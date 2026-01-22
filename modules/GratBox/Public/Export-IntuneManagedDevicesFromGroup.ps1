<#
Script: Export-IntuneManagedDevicesFromGroup.ps1
Purpose: Export a CSV of devices in a target Entra ID group that are Intune-managed
         (from /deviceManagement/managedDevices), intersected with the group’s members.

Auth behavior:
- Reuses any existing Microsoft Graph token (no prompts).
- If no reusable token is present (or the first call fails due to auth), the script
  opens Device Code sign-in in an InPrivate/Incognito browser window and connects
  with the required scopes, then retries once.

Parameters
----------
-GroupId <string>           (Required)
    Entra ID ObjectId (GUID) of the target device group.
    Example: -GroupId "cd2d8c7a-1ade-4c11-8adf-51d8cc22fc0b"

-GroupName <string>         (Optional)
    Friendly name to stamp into the CSV. If omitted, the script resolves the group’s DisplayName.
    Note: This does not affect which devices are returned; it’s cosmetic for the report.

-OutPath <string>           (Optional)
    If omitted, a timestamped file is created under:
      <toolRoot>\reports\Export-IntuneManagedDevicesFromGroup\IntuneManaged_<GroupName or GroupId>_<yyyyMMdd-HHmm>[ _MDMonly].csv

-StrictMdmOnly              (Switch, Optional)
    Filters the results to devices whose ManagementAgent includes "mdm"
    (e.g., mdm, configurationManagerClientMdm, easMdm).

-Tenant <string>            (Optional; default: "contoso.com")
    Tenant hint used ONLY if an interactive Device Code sign-in is needed.

-BrowserPreference <edge|chrome>   (Optional; default: edge)
    Which browser to launch in private mode for Device Code sign-in if needed:
      edge   → launches msedge.exe with --inprivate
      chrome → launches chrome.exe with --incognito

Output
------
CSV with the following columns:
  GroupId, GroupName, DisplayName, Id (Entra device objectId), DeviceId (azureADDeviceId),
  OperatingSystem, OSVersion, ManagementAgent, EnrolledDateTime, LastCheckinDateTime,
  ComplianceState, SerialNumber

Typical Usage
-------------
1) Open your elevated Graph window via your EPM launcher (Device Code in private browser).
2) In that same window, run:
   Export-IntuneManagedDevicesFromGroup -GroupId "<GUID>" -GroupName "<Name>" -StrictMdmOnly

Notes
-----
- The script never disconnects or alters tenant/scopes if a valid token already exists.
- On the first API call, if the token is invalid/expired, the script triggers private Device Code sign-in
  and retries exactly once.
#>

# --- Ensure helpers are available even if this file is dot-sourced directly ---
# (Harmless when imported via the module; helpers already loaded there.)
if (-not (Get-Command Ensure-GraphPrivate -ErrorAction SilentlyContinue)) {
  try {
    # When this file runs, $PSScriptRoot = ...\modules\GratBox\Public
    $moduleDir = Split-Path -Parent $PSScriptRoot              # ...\modules\GratBox
    $helpers   = Join-Path $moduleDir 'Private\Helpers.ps1'    # ...\modules\GratBox\Private\Helpers.ps1
    if (Test-Path $helpers) { . $helpers }
  } catch { }
}

function Export-IntuneManagedDevicesFromGroup {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$GroupId,
    [string]$GroupName,
    [string]$OutPath,
    [switch]$StrictMdmOnly,                 # optional: keep only rows whose ManagementAgent includes "mdm"
    [string]$Tenant = '',          # tenant hint for sign-in
    [ValidateSet('edge','chrome')][string]$BrowserPreference = 'edge'  # which private window to prefer
  )
  # ===================== default OutPath =====================
  # If -OutPath is not provided, write a timestamped report under:
  #   <toolRoot>\reports\Export-IntuneManagedDevicesFromGroup\
  #
  # Tool root resolution order:
  #   1) GRATBOX_ROOT env var (optional)
  #   2) inferred from the loaded module location
  #   3) current working directory (last resort)

  if (-not $PSBoundParameters.ContainsKey('OutPath') -or [string]::IsNullOrWhiteSpace($OutPath)) {

    $toolRoot = Get-GratBoxRoot
    if (-not $toolRoot) { $toolRoot = (Get-Location).Path }

    $reportsDir = Join-Path $toolRoot 'reports\Export-IntuneManagedDevicesFromGroup'
    if (-not (Test-Path $reportsDir)) {
      try { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null } catch {}
    }

    $safeName = if ($GroupName) { ($GroupName -replace '[^\w\-. ]','_') } else { $GroupId }
    if (-not $safeName) { $safeName = 'Group' }

    $stamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $suffix = if ($StrictMdmOnly) { "_MDMonly" } else { "" }
    $file   = "IntuneManaged_{0}_{1}{2}.csv" -f $safeName, $stamp, $suffix

    $OutPath = Join-Path $reportsDir $file
  }

  Write-Host "Output will be saved to: $OutPath" -ForegroundColor Cyan
  # ================== end default OutPath ====================
  # ===================== main flow =====================

  # 0) Make sure we have a token (if not, do private device-code sign-in)
  Ensure-GraphPrivate -TenantHint $Tenant -BrowserPref $BrowserPreference

  # 1) Resolve group/display name (with auth-retry guard to avoid non-private prompts)
  $grp = Invoke-WithAuthRetry -TenantHint $Tenant -BrowserPref $BrowserPreference -Script {
    Get-MgGroup -GroupId $GroupId -Property 'displayName' -ErrorAction Stop
  }

  if (-not $GroupName) { $GroupName = $grp.DisplayName }

  Write-Host "Group: $GroupName ($GroupId)"
  Write-Host "Output: $OutPath"

  # 2) Group device members (need Azure AD deviceId)
  $stubs = if (Get-Command Get-MgGroupTransitiveMemberAsDevice -ErrorAction SilentlyContinue) {
    Get-MgGroupTransitiveMemberAsDevice -GroupId $GroupId -All -Property "id,displayName,deviceId" -ErrorAction Stop
  } else {
    Get-MgGroupTransitiveMember -GroupId $GroupId -All -Property "id,displayName,deviceId" -ErrorAction Stop |
      Where-Object { $_.'@odata.type' -eq '#microsoft.graph.device' }
  }

  if (-not $stubs) {
    Write-Host "No device members found."
    @() | Select-Object GroupId,GroupName,DisplayName,Id,DeviceId,OperatingSystem,OSVersion,ManagementAgent,EnrolledDateTime,LastCheckinDateTime,ComplianceState,SerialNumber |
      Export-Csv -Path $OutPath -NoTypeInformation -Encoding UTF8
    return
  }

  # Some stubs can miss deviceId; fill gaps by reading those devices once
  $needDeviceId = $stubs | Where-Object { -not $_.deviceId }
  if ($needDeviceId) {
    foreach ($s in $needDeviceId) {
      try {
        $d = Get-MgDevice -DeviceId $s.Id -Property 'deviceId' -ErrorAction Stop
        $s | Add-Member -NotePropertyName deviceId -NotePropertyValue $d.deviceId -Force
      } catch {
        Write-Warning "Could not read deviceId for object $($s.Id): $($_.Exception.Message)"
      }
    }
  }

  # Map azureADDeviceId (lowercased) -> {ObjectId, Name}
  $map = @{}
  $groupIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($s in $stubs) {
    if ($s.deviceId) {
      $lower = $s.deviceId.ToString().ToLower()
      $map[$lower] = @{ ObjectId = $s.Id; DisplayName = $s.DisplayName }
      [void]$groupIds.Add($lower)
    }
  }

# 3) Pull Intune managed devices (v1.0)
$select = 'id,azureADDeviceId,deviceName,operatingSystem,osVersion,managementAgent,enrolledDateTime,lastSyncDateTime,complianceState,serialNumber'
$uri    = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=$select&`$top=200"
$allManaged = @()

while ($uri) {
  # Ensure we get a PSObject so StrictMode-safe property access works
  $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop

  # Collect items whether 'value' exists or not
  $items = ($resp.PSObject.Properties['value'] | Select-Object -Expand Value -ErrorAction SilentlyContinue)
  if ($items) { $allManaged += $items }

  # StrictMode-safe nextLink: becomes $null on last page and the while() naturally exits
  $uri = ($resp.PSObject.Properties['@odata.nextLink'] | Select-Object -Expand Value -ErrorAction SilentlyContinue)
}

  # 4) Intersect managed devices with the group’s deviceIds
  $matching = foreach ($m in $allManaged) {
    $aadId = ($m.azureADDeviceId | ForEach-Object { $_.ToString().ToLower() })
    if ($aadId -and $groupIds.Contains($aadId)) {
      $fromMap = $map[$aadId]
      [PSCustomObject]@{
        GroupId               = $GroupId
        GroupName             = $GroupName
        DisplayName           = $fromMap.DisplayName
        Id                    = $fromMap.ObjectId
        DeviceId              = $m.azureADDeviceId
        OperatingSystem       = $m.operatingSystem
        OSVersion             = $m.osVersion
        ManagementAgent       = $m.managementAgent
        EnrolledDateTime      = $m.enrolledDateTime
        LastCheckinDateTime   = $m.lastSyncDateTime
        ComplianceState       = $m.complianceState
        SerialNumber          = $m.serialNumber
      }
    }
  }

  # Optional strict MDM filter (keeps any agent that includes "mdm")
  if ($StrictMdmOnly) {
    $matching = $matching | Where-Object { $_.ManagementAgent -match '(?i)mdm' }
  }

  # 5) Export
  $matching | Sort-Object DisplayName | Export-Csv -Path $OutPath -NoTypeInformation -Encoding UTF8
  Write-Host ("Group devices: {0} | Intune-managed (after filter): {1} | CSV: {2}" -f $stubs.Count, ($matching | Measure-Object).Count, $OutPath)
}
