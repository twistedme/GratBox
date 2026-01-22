# Private helper: Invoke-GratBoxAuth.ps1
# Purpose: Unified authentication entry point for all GratBox Public functions
# Location: modules\GratBox\Private\Invoke-GratBoxAuth.ps1

function Invoke-GratBoxAuth {
  <#
  .SYNOPSIS
  Ensures Microsoft Graph authentication for GratBox functions.
  
  .DESCRIPTION
  Single entry point for all auth-related logic in GratBox Public functions.
  Replaces the repetitive Start-GraphAuth pattern across multiple functions.
  
  Behavior:
  - If Start-GratBoxPreAuth is available, uses it (device-code + incognito flow)
  - Otherwise falls back to Connect-MgGraph
  - Handles parameter name variations (DeviceCode vs UseDeviceCode)
  
  .PARAMETER Scopes
  Array of required Graph API scopes
  
  .PARAMETER Tenant
  Tenant domain or TenantId GUID (optional)
  
  .PARAMETER Account
  UPN to use for authentication (optional)
  
  .PARAMETER UseDeviceCode
  Force device-code authentication flow
  
  .PARAMETER BrowserPreference
  Browser to use for private/incognito mode ('edge' or 'chrome')
  
  .EXAMPLE
  Invoke-GratBoxAuth -Scopes @('Group.Read.All','Device.Read.All')
  
  .EXAMPLE
  Invoke-GratBoxAuth -Scopes @('Group.ReadWrite.All') -UseDeviceCode -Tenant 'contoso.com'
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string[]]$Scopes,
    
    [string]$Tenant,
    
    [string]$Account,
    
    [switch]$UseDeviceCode,
    
    [ValidateSet('edge','chrome','system')]
    [string]$BrowserPreference = 'edge'
  )
  
  # Try Start-GratBoxPreAuth first (preferred GratBox flow)
  if (Get-Command -Name Start-GratBoxPreAuth -ErrorAction SilentlyContinue) {
    
    $preAuthCmd = Get-Command Start-GratBoxPreAuth -ErrorAction SilentlyContinue
    $params = @{ Scopes = $Scopes }
    
    # Add optional parameters if provided
    if ($Tenant) {
      $params['Tenant'] = $Tenant
    }
    
    # Handle DeviceCode parameter name variations
    if ($UseDeviceCode) {
      if ($preAuthCmd.Parameters.ContainsKey('DeviceCode')) {
        $params['DeviceCode'] = $true
      } elseif ($preAuthCmd.Parameters.ContainsKey('UseDeviceCode')) {
        $params['UseDeviceCode'] = $true
      }
    }
    
    if ($Account) {
      $params['Account'] = $Account
    }
    
    # Add BrowserPreference if supported
    if ($preAuthCmd.Parameters.ContainsKey('BrowserPreference') -and $BrowserPreference) {
      $params['BrowserPreference'] = $BrowserPreference
    }
    
    try {
      Start-GratBoxPreAuth @params | Out-Null
      return
    } catch {
      Write-Warning "[Invoke-GratBoxAuth] Start-GratBoxPreAuth failed: $($_.Exception.Message)"
      Write-Warning "[Invoke-GratBoxAuth] Falling back to Connect-MgGraph..."
    }
  }
  
  # Fallback: Direct Connect-MgGraph call
  try {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
  } catch {
    throw "Microsoft.Graph.Authentication module not available. Install it with: Install-Module Microsoft.Graph.Authentication"
  }
  
  $connectParams = @{
    Scopes    = $Scopes
    NoWelcome = $true
  }
  
  if ($Tenant) {
    $connectParams['TenantId'] = $Tenant
  }
  
  if ($Account) {
    $connectParams['Account'] = $Account
  }
  
  if ($UseDeviceCode) {
    $connectParams['UseDeviceCode'] = $true
  }
  
  Connect-MgGraph @connectParams | Out-Null
}