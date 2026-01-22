# Future functions notes

When you build write operations later (e.g., add devices to a group, update Autopilot group tags), just call:

Ensure-GraphPrivate -TenantHint $Tenant -BrowserPref $BrowserPreference -RequiredScopes @(
  'Group.ReadWrite.All',
  'Directory.ReadWrite.All',
  'DeviceManagementServiceConfig.ReadWrite.All'  # e.g., Autopilot/GroupTag updates
)


That keeps the same EPM-safe flow, only elevating when a function actually needs write access.

How you’ll use it going forward

To add a new function, just create:
<ToolRoot>\modules\GratBox\Public\New-Whatever.ps1
with the usual header and:

function New-Whatever {
  [CmdletBinding()]
  param(...)

  Ensure-GraphPrivate -TenantHint $Tenant -BrowserPref $BrowserPreference -RequiredScopes @('...scopes...')
  # your logic...
}
