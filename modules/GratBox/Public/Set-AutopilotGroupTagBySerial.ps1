<#
 Set-AutopilotGroupTagBySerial.ps1
 Update the Windows Autopilot "Group tag" for one or more serial numbers.

 EXAMPLES
   Set-AutopilotGroupTagBySerial -SerialNumber 'PF4A6E7B' -GroupTag 'TAG-USER' -DryRun
   Set-AutopilotGroupTagBySerial -SerialNumber 'PF4A6E7B','ABC123456' -GroupTag 'TAG-SHARED'
#>

function Set-AutopilotGroupTagBySerial {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('Serial','SN')]
    [string[]]$SerialNumber,

    [Parameter(Mandatory)]
    [string]$GroupTag,

    [switch]$DryRun,
    [switch]$ForceImport,

    [int]$MaxRetries = 5,
    [int]$RetryBaseDelaySec = 5
  )

  begin {
    # ----- helpers -----
    $sw = [Diagnostics.Stopwatch]::StartNew()
    function Log([string]$msg,[ConsoleColor]$c='Gray'){ Write-Host ("[{0,5:n1}s] {1}" -f $sw.Elapsed.TotalSeconds,$msg) -ForegroundColor $c }

    # Try to use approved-verb helper (no-op if already signed-in)
    if (Get-Command Connect-GraphPrivateSession -ErrorAction SilentlyContinue) {
      Connect-GraphPrivateSession -RequiredScopes @(
        'DeviceManagementManagedDevices.Read.All',
        'DeviceManagementServiceConfig.ReadWrite.All',
        'Directory.Read.All'
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
            $backoffD = [double]$RetryBaseDelaySec * [Math]::Pow(2, ($attempt - 1))
            if ($backoffD -gt 60) { $backoffD = 60 }
            $sec = [int][Math]::Ceiling($backoffD)
            Log ("WARNING: Graph call failed (attempt {0}/{1}): {2} → retrying in {3}s" -f $attempt,$MaxRetries,$msg,$sec) Yellow
            Start-Sleep -Seconds $sec
            continue
          }
          throw
        }
      }
    }

    # ----- report path (works module or dot-sourced) -----
    $root = $null
    $mod = Get-Module GratBox -ErrorAction SilentlyContinue
    if ($mod -and $mod.ModuleBase) { try { $root = Split-Path -Parent (Split-Path -Parent $mod.ModuleBase) } catch {} }
    if (-not $root) {
      $thisFile = $MyInvocation.MyCommand.Path
      if ($thisFile) { try { $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $thisFile)) } catch {} }
    }
    if (-not $root) { try { $root = (Get-Location).Path } catch { $root = (Get-Location).Path } }

    $reportsDir = Join-Path $root 'reports\Set-AutopilotGroupTagBySerial'
    if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $csv   = Join-Path $reportsDir ("AutoPilotGroupTag_BySerial_{0}.csv" -f $stamp)
    Log ("CSV: {0}" -f $csv) Cyan

    # Preload WAI if available
    $hasWai = $false
    try { Import-Module WindowsAutoPilotIntune -ErrorAction SilentlyContinue | Out-Null; $hasWai = (Get-Command Get-AutopilotDevice -ErrorAction SilentlyContinue) -ne $null } catch {}
    $out  = New-Object System.Collections.Generic.List[object]
  }

  process {
    foreach ($sn in $SerialNumber) {
      $row = [ordered]@{
        SerialNumber = $sn
        OldGroupTag  = $null
        NewGroupTag  = $GroupTag
        AutopilotId  = $null
        Status       = $null
        Message      = $null
      }

      # (1) Prefer WindowsAutoPilotIntune path (proved to work in your tenant)
      if ($hasWai) {
        try {
          $ap = Get-AutopilotDevice -serial $sn -ErrorAction Stop | Select-Object -First 1
          if ($ap) {
            $row.AutopilotId = $ap.id
            # Try to pick up current tag if present
            try { $row.OldGroupTag = $ap.groupTag } catch {}
            if ($row.OldGroupTag -eq $GroupTag) {
              $row.Status  = 'Unchanged'
              $row.Message = 'Already set to target groupTag.'
            } elseif ($DryRun) {
              $row.Status  = 'WouldUpdate'
              $row.Message = 'DryRun: would call Set-AutopilotDevice.'
            } else {
              Set-AutopilotDevice -id $ap.id -groupTag $GroupTag -ErrorAction Stop
              $row.Status  = 'Updated'
              $row.Message = 'Updated via WindowsAutoPilotIntune.'
            }
            $out.Add([pscustomobject]$row) | Out-Null
            continue
          }
        } catch {
          # If WAI path explodes, we’ll try Graph next
          $row.Message = "WAI path failed: $($_.Exception.Message)"
        }
      }

      # (2) Graph: find Autopilot identity by serial (filtered)
      $apObj = $null
      try {
        $flt  = "serialNumber eq '$sn'"
        $uri  = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$select=id,serialNumber,groupTag&`$filter=$([uri]::EscapeDataString($flt))"
        $resp = Invoke-GraphWithRetry -Method GET -Uri $uri -PSObject -Headers @{ 'ConsistencyLevel' = 'eventual' }
        $apObj = $resp.value | Select-Object -First 1
      } catch {
        $row.Status  = 'Error'
        $row.Message = "Autopilot lookup failed: $($_.Exception.Message)"
        $out.Add([pscustomobject]$row) | Out-Null
        continue
      }

      if (-not $apObj) {
        if ($ForceImport) {
          if ($DryRun) {
            $row.Status  = 'WouldImport'
            $row.Message = 'DryRun: would submit import to set groupTag by serial.'
          } else {
            try {
              $payload = @{
                importedWindowsAutopilotDeviceIdentities = @(
                  @{ '@odata.type' = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'; serialNumber = $sn; groupTag = $GroupTag }
                )
              }
              Invoke-GraphWithRetry -Method POST -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/import' -Body $payload | Out-Null
              $row.Status  = 'Imported'
              $row.Message = 'Submitted import to set groupTag by serial.'
            } catch {
              $row.Status  = 'Error'
              $row.Message = "Autopilot import failed: $($_.Exception.Message)"
            }
          }
        } else {
          $row.Status  = 'NoAutopilotMatch'
          $row.Message = 'No Autopilot identity found for this serial.'
        }
        $out.Add([pscustomobject]$row) | Out-Null
        continue
      }

      $row.AutopilotId = $apObj.id
      $row.OldGroupTag = $apObj.groupTag

      if ($row.OldGroupTag -eq $GroupTag) {
        $row.Status  = 'Unchanged'
        $row.Message = 'Already set to target groupTag.'
        $out.Add([pscustomobject]$row) | Out-Null
        continue
      }

      if ($DryRun) {
        $row.Status  = 'WouldUpdate'
        $row.Message = 'DryRun: would call updateDeviceProperties.'
        $out.Add([pscustomobject]$row) | Out-Null
        continue
      }

      # (3) Graph update
      try {
        $uUri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($row.AutopilotId)/updateDeviceProperties"
        $body = @{ userPrincipalName=$null; addressableUserName=$null; groupTag=$GroupTag }
        Invoke-GraphWithRetry -Method POST -Uri $uUri -Body $body | Out-Null
        $row.Status  = 'Updated'
        $row.Message = 'Updated via updateDeviceProperties.'
      } catch {
        # Optional import fallback if requested
        if ($ForceImport) {
          try {
            $payload = @{
              importedWindowsAutopilotDeviceIdentities = @(
                @{ '@odata.type' = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'; serialNumber = $sn; groupTag = $GroupTag }
              )
            }
            Invoke-GraphWithRetry -Method POST -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/import' -Body $payload | Out-Null
            $row.Status  = 'Imported'
            $row.Message = 'Submitted import to set groupTag by serial.'
          } catch {
            $row.Status  = 'Error'
            $row.Message = "Autopilot import failed: $($_.Exception.Message)"
          }
        } else {
          $row.Status  = 'Error'
          $row.Message = "updateDeviceProperties failed: $($_.Exception.Message)"
        }
      }

      $out.Add([pscustomobject]$row) | Out-Null
    } # foreach
  } # process

  end {
    $out | Sort-Object SerialNumber |
      Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
    $out
  }
}
