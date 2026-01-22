<#
.SYNOPSIS
Ensures Graph authentication is established before running GratBox commands.

.DESCRIPTION
Public helper function that establishes a valid Microsoft Graph authentication
context with required scopes. This is the recommended entry point for GratBox
functions that require Graph API access.

Behavior:
- Checks for existing valid Graph context
- If missing or insufficient, triggers device-code authentication
- Opens verification page in incognito/private browser
- Waits for user to complete authentication

Designed to be called at the start of GratBox Public functions that need Graph access.

.PARAMETER Scopes
Array of Graph API scopes required for the operation.
Default: https://graph.microsoft.com/.default (uses tenant-consented permissions)

.PARAMETER Tenant
Tenant domain or TenantId GUID.
Resolved via environment variables (GRATBOX_TENANT, AZURE_TENANT_ID) if not provided.

.PARAMETER BrowserPreference
Browser to use for device-code verification page ('edge' or 'chrome').
Default: 'edge'

.EXAMPLE
Start-GratBoxPreAuth -Scopes @('Group.Read.All','Device.Read.All')

.EXAMPLE
Start-GratBoxPreAuth -Scopes @('Group.ReadWrite.All') -Tenant 'contoso.com' -BrowserPreference 'chrome'

.NOTES
Uses Ensure-GraphPrivate helper to handle authentication flow.
Supports both toolkit and PSGallery installation modes.
#>

function Start-GratBoxPreAuth {
 # Ensures a valid Graph auth context is present for GratBox usage.
  [CmdletBinding()]
  param(
    [string[]]$Scopes = @('https://graph.microsoft.com/.default'),

    # Tenant domain or TenantId GUID.
    # Resolved via env vars or prompt if not supplied.
    [string]$Tenant = $(if ($env:GRATBOX_TENANT) {
                          $env:GRATBOX_TENANT
                        } elseif ($env:AZURE_TENANT_ID) {
                          $env:AZURE_TENANT_ID
                        } else {
                          ''
                        }),

    [ValidateSet('edge','chrome')]
    [string]$BrowserPreference = 'edge'
  )

  if ([string]::IsNullOrWhiteSpace($Tenant)) {
    $Tenant = (Read-Host "Enter tenant domain or TenantId GUID").Trim()
  }

  # Always let the private helper handle InPrivate/Incognito + device-code auth
  # Delegate auth enforcement (private/incognito device-code if required)
  Ensure-GraphPrivate -RequiredScopes $Scopes -TenantHint $Tenant -BrowserPref $BrowserPreference
}
