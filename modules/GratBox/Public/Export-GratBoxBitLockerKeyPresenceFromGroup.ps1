function Export-GratBoxBitLockerKeyPresenceFromGroup {
<#
.SYNOPSIS
Exports BitLocker encryption state and recovery key presence for devices in an Entra ID group.

.DESCRIPTION
This cmdlet is intended to report BitLocker encryption state (from Intune) and
BitLocker recovery key presence (from Entra ID) for devices associated with an
Entra ID group.

At this time, group-based enumeration is not supported when using device-code
authentication due to Microsoft Graph PowerShell limitations. When invoked under
device-code authentication, the cmdlet will exit cleanly with a warning.

If BitLockerKey.Read.All is not granted, recovery key presence would be reported
as Unknown in supported authentication scenarios.

.PARAMETER GroupId
The Entra ID object ID of the group containing device members.

.EXAMPLE
Export-GratBoxBitLockerKeyPresenceFromGroup -GroupId "<group-guid>"
#>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$GroupId
    )

    # -----------------------------
    # INFO messaging
    # -----------------------------
    Write-Host '[INFO] Reading BitLocker recovery keys via Microsoft Graph requires delegated permission BitLockerKey.Read.All.' -ForegroundColor Cyan
    Write-Host '[INFO] If this permission is not approved, recovery key presence will be reported as Unknown.' -ForegroundColor Cyan

    # -----------------------------
    # Guard: group enumeration not supported with device-code auth
    # -----------------------------
    $ctx = Get-MgContext
    if ($ctx -and $ctx.AuthType -eq 'DeviceCode') {
        Write-Warning 'Group-based enumeration is not supported when using device-code authentication due to Microsoft Graph PowerShell limitations.'
        Write-Warning 'No changes have been made. This cmdlet may be extended in the future to support other authentication methods.'
        return
    }

    # -----------------------------
    # Initialize paths and logging
    # -----------------------------
    $logPath = Join-Path (Get-GratBoxPath -Type Logs) 'Export-GratBoxBitLockerKeyPresenceFromGroup.log'
    Write-GratBoxLog -Path $logPath -Message 'Starting BitLocker key presence export'

    $reportRoot = Join-Path (Get-GratBoxPath -Type Reports) 'Export-GratBoxBitLockerKeyPresenceFromGroup'
    if (-not (Test-Path $reportRoot)) {
        New-Item -Path $reportRoot -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $csvPath = Join-Path $reportRoot "BitLockerKeyPresence_${GroupId}_${timestamp}.csv"

    # -----------------------------
    # Placeholder for future non-device-code implementations
    # -----------------------------
    Write-Warning 'This cmdlet is currently a no-op under the active authentication method.'
    Write-Warning 'Group enumeration logic is intentionally disabled to avoid unsupported Graph behavior.'

    Write-GratBoxLog -Path $logPath -Message 'Execution exited due to unsupported authentication mode'
    return
}
