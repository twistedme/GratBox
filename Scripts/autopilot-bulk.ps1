<# =======================================================================
Autopilot Bulk Update + Import
- Updates Group Tag (and Assigned User) for existing Autopilot devices.
- If Serial not found, imports device using Hardware Hash with Group Tag
  (and Assigned User) and continues.

Usage examples:
  .\autopilot-bulk.ps1
  .\autopilot-bulk.ps1 -DeviceCode
  .\autopilot-bulk.ps1 -CsvPath "C:\Temp\Autopilot-Bulk.csv" -Delimiter ';' -DeviceCode
  .\autopilot-bulk.ps1 -DeviceCode -TenantId "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" -Account "admin@contoso.com"
  .\autopilot-bulk.ps1 -DryRun   # prints what it would do, makes no changes

CSV columns (case-insensitive):
  "Device Serial Number", "Windows Product ID", "Hardware Hash", "Group Tag", "Assigned User"

Requires:
  - Microsoft.Graph
  - Microsoft.Graph.DeviceManagement.Enrollment
  - WindowsAutoPilotIntune
======================================================================= #>

param(
    [string]$CsvPath   = '',
    [switch]$DeviceCode,
    [string]$TenantId,
    [string]$Account,
    [string]$Delimiter = ',',
    [switch]$DryRun
)

# --- CSV path resolution (portable)
# If -CsvPath is not supplied, default to a file next to this script.
if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $CsvPath = Join-Path $PSScriptRoot 'Autopilot_TAG-SHARED.csv'
}
if (-not (Test-Path $CsvPath)) {
    throw "CSV not found: '$CsvPath'. Provide -CsvPath or place 'Autopilot_TAG-SHARED.csv' in: $PSScriptRoot"
}


# --- Safety & UX
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

function Write-Info($msg)  { Write-Host $msg -ForegroundColor Cyan }
function Write-Good($msg)  { Write-Host $msg -ForegroundColor Green }
function Write-Bad($msg)   { Write-Host $msg -ForegroundColor Red }
function Write-Warn($msg)  { Write-Warning $msg }

# --- Ensure required modules
$needed = @(
  'Microsoft.Graph',
  'Microsoft.Graph.DeviceManagement.Enrollment',
  'WindowsAutoPilotIntune'
)
foreach ($m in $needed) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Info "Installing missing module: $m"
        Install-Module -Name $m -Force -Scope CurrentUser
    }
}
Import-Module Microsoft.Graph -ErrorAction Stop
Import-Module Microsoft.Graph.DeviceManagement.Enrollment -ErrorAction Stop
Import-Module WindowsAutoPilotIntune -ErrorAction Stop

# --- Scopes required
$scopes = @(
    'Group.ReadWrite.All',
    'Device.ReadWrite.All',
    'DeviceManagementManagedDevices.ReadWrite.All',
    'DeviceManagementServiceConfig.ReadWrite.All',
    'GroupMember.ReadWrite.All'
)

# --- Robust connect helper (interactive → device-code fallback)
function Connect-GraphSafe {
    param([string[]]$Scopes, [switch]$UseDeviceCode, [string]$TenantId, [string]$Account)

    # If already connected with usable scopes, keep it
    try {
        $ctx = Get-MgContext -ErrorAction Stop
        if ($ctx.Account -and $ctx.Scopes) {
            $needed = [System.Linq.Enumerable]::ToArray($Scopes)
            $have   = [System.Linq.Enumerable]::ToArray($ctx.Scopes)
            $ok = $true
            foreach ($s in $needed) { if ($have -notcontains $s) { $ok = $false; break } }
            if ($ok) {
                Write-Good "Already connected as $($ctx.Account)."
                return
            }
        }
    } catch { }

    $common = @{
        Scopes      = ($Scopes -join ' ')
        NoWelcome   = $true
        ErrorAction = 'Stop'
    }
    if ($TenantId) { $common.TenantId = $TenantId }
    if ($Account)  { $common.Account  = $Account }

    if ($UseDeviceCode) {
        Write-Info "Connecting to Microsoft Graph (device code)..."
        Connect-MgGraph @common -UseDeviceCode
        return
    }

    try {
        Write-Info "Connecting to Microsoft Graph (interactive)..."
        Connect-MgGraph @common
    } catch {
        $msg = $_.Exception.Message
        Write-Warn "Interactive auth failed ($msg). Retrying with device code..."
        Connect-MgGraph @common -UseDeviceCode
    }
}

# --- Connect now
Connect-GraphSafe -Scopes $scopes -UseDeviceCode:$DeviceCode -TenantId $TenantId -Account $Account

# --- Verify connection; abort if not connected
try {
    $ctx = Get-MgContext -ErrorAction Stop
    if (-not $ctx.Account) { throw "Not connected to Microsoft Graph." }
    Write-Good "Connected to Graph as $($ctx.Account) in tenant $($ctx.TenantId)."
} catch {
    Write-Bad $_
    Write-Host "Aborting before any changes. (Updated: 0 | Newly queued imports: 0 | Skipped: 0)"
    return
}

# --- Load CSV
if (-not (Test-Path -LiteralPath $CsvPath)) {
    Write-Bad "CSV not found: $CsvPath"
    return
}
Write-Info "Loading CSV: $CsvPath (Delimiter: '$Delimiter')"
$rows = Import-Csv -Path $CsvPath -Delimiter $Delimiter
if (-not $rows -or $rows.Count -eq 0) {
    Write-Bad "CSV appears empty."
    return
}

# --- Helpers
function Get-Field {
    param($row, [string[]]$names)
    foreach ($n in $names) {
        $prop = $row.PSObject.Properties.Match($n)
        if ($prop.Count -gt 0) {
            $val = $row.$n
            if ($null -ne $val -and "$val".Trim() -ne '') { return "$val" }
        }
    }
    return $null
}
function Normalize([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    return ($s.Trim().Trim(',').Trim('"'))
}

# --- Work state
$newImports = New-Object System.Collections.Generic.List[hashtable]
[int]$updated = 0
[int]$skipped = 0
[int]$toImport = 0
[int]$rowIndex = 0

# --- Iterate rows
foreach ($row in $rows) {
    $rowIndex++
    Write-Progress -Activity "Processing CSV" -Status "Row $rowIndex of $($rows.Count)" -PercentComplete ([int](($rowIndex/$rows.Count)*100))

    $serial       = Normalize (Get-Field $row @('Device Serial Number','Serial Number','Serial'))
    $productKey   = Normalize (Get-Field $row @('Windows Product ID','ProductKey','Product Key'))
    $hwHashString = Get-Field $row @('Hardware Hash','Hardwarehash','HardwareHash','Hardware_Hash')
    $groupTag     = Normalize (Get-Field $row @('Group Tag','GroupTag','Group_Tag'))
    $assignedUser = Normalize (Get-Field $row @('Assigned User','AssignedUser','UserPrincipalName','UPN'))

    if (-not $serial -and -not $hwHashString) {
        Write-Warn "Skipping row $rowIndex: neither Serial nor Hardware Hash present."
        $skipped++
        continue
    }

    # Try to find existing Autopilot device by serial
    $ap = $null
    if ($serial) {
        try {
            $candidates = Get-AutopilotDevice -serial $serial -ErrorAction SilentlyContinue
            if ($candidates) {
                $ap = $candidates | Where-Object { $_.serialNumber -eq $serial } | Select-Object -First 1
            }
        } catch {
            Write-Warn "Lookup failed for serial '$serial': $($_.Exception.Message)"
        }
    }

    if ($ap) {
        Write-Info "Updating Group Tag for $serial → '$groupTag'" + ($(if($assignedUser){" and user '$assignedUser'"}else{""}))
        if ($DryRun) { Write-Host "DRY RUN: Would update Autopilot device $serial" -ForegroundColor DarkYellow; $updated++; continue }

        # Prefer Graph action (updateDeviceProperties), fall back to Set-AutopilotDevice
        try {
            $body = @{ groupTag = $groupTag }
            if ($assignedUser) { $body.userPrincipalName = $assignedUser }

            Update-MgDeviceManagementWindowsAutopilotDeviceIdentityDeviceProperty `
                -WindowsAutopilotDeviceIdentityId $ap.id `
                -BodyParameter $body `
                -ErrorAction Stop

            $updated++
            Write-Good "OK: $serial updated."
        } catch {
            Write-Warn "Primary update path failed for $serial: $($_.Exception.Message) — trying fallback."
            try {
                if ($assignedUser) {
                    Set-AutopilotDevice -Id $ap.id -GroupTag $groupTag -UserPrincipalName $assignedUser -ErrorAction Stop
                } else {
                    Set-AutopilotDevice -Id $ap.id -GroupTag $groupTag -ErrorAction Stop
                }
                $updated++
                Write-Good "OK (fallback): $serial updated."
            } catch {
                Write-Warn "Failed to update existing device $serial. $($_.Exception.Message)"
                $skipped++
            }
        }
    }
    else {
        # No existing device: queue an import (requires hardware hash)
        if (-not $hwHashString) {
            Write-Warn "No existing device for serial '$serial' and no Hardware Hash provided. Skipping."
            $skipped++
            continue
        }

        # Convert base64 hardware hash to byte[]
        [byte[]]$hwBytes = $null
        try {
            # Hardware Hash column often contains commas; ensure CSV quoted the entire string.
            $hwBytes = [System.Convert]::FromBase64String(($hwHashString -replace '\s',''))
        } catch {
            Write-Warn "Invalid Hardware Hash (base64) for serial '$serial'. Skipping. ($($_.Exception.Message))"
            $skipped++
            continue
        }

        $toImport++
        if ($DryRun) {
            Write-Host "DRY RUN: Would import NEW device serial='$serial' groupTag='$groupTag' user='$assignedUser'" -ForegroundColor DarkYellow
            continue
        }

        Write-Info "Queuing import for serial '$serial' with groupTag '$groupTag'" + ($(if($assignedUser){" and user '$assignedUser'"}else{""}))

        $importObj = @{
            '@odata.type'                 = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
            serialNumber                  = $serial
            productKey                    = $productKey
            hardwareIdentifier            = $hwBytes
            groupTag                      = $groupTag
            assignedUserPrincipalName     = $assignedUser
        }
        [void]$newImports.Add($importObj)
    }
}

# --- Submit imports (batch) if any
if (-not $DryRun -and $newImports.Count -gt 0) {
    Write-Info "Submitting $($newImports.Count) device(s) for Autopilot import (Graph batch)..."
    $batchOk = $true
    try {
        Import-MgDeviceManagementImportedWindowsAutopilotDeviceIdentity -BodyParameter @{
            importedWindowsAutopilotDeviceIdentities = $newImports
        } | Out-Null
        Write-Good "Import submitted."
    } catch {
        $batchOk = $false
        Write-Warn "Graph batch import failed: $($_.Exception.Message) — trying per-device fallback."
    }

    if (-not $batchOk) {
        foreach ($obj in $newImports) {
            try {
                Add-AutopilotImportedDevice `
                    -SerialNumber $obj.serialNumber `
                    -HardwareIdentifier $obj.hardwareIdentifier `
                    -GroupTag $obj.groupTag `
                    -AssignedUser $obj.assignedUserPrincipalName `
                    -ProductKey $obj.productKey `
                    -ErrorAction Stop | Out-Null
                Write-Good "Imported: $($obj.serialNumber)"
            } catch {
                Write-Warn "Failed to import $($obj.serialNumber): $($_.Exception.Message)"
                $skipped++
            }
        }
    }

    Write-Info "You can track import status with: Get-AutopilotImportedDevice"
}

Write-Host ""
Write-Host "Done." -ForegroundColor Cyan
Write-Host ("Updated: {0}  |  Newly queued imports: {1}  |  Skipped: {2}" -f $updated, $newImports.Count, $skipped) -ForegroundColor Cyan