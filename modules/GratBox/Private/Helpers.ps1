# Private helpers for the GratBox module.
# Internal-only functions (not exported).
# Responsibilities:
# - Private/incognito browser launch
# - Graph authentication enforcement
# - Auth retry and scope elevation
# Private helper: Get-GratBoxRoot.ps1
# Purpose: Resolve the GratBox "workspace" directory for reports/logs/imports
# Handles both portable toolkit mode and PSGallery module mode

function Get-GratBoxRoot {
  <#
  .SYNOPSIS
  Resolves the GratBox workspace directory for reports, logs, and imports.
  
  .DESCRIPTION
  Resolution order:
  1. GRATBOX_ROOT environment variable (user override)
  2. Toolkit mode: Parent of modules folder (C:\Tools\GratBox)
  3. PSGallery mode: User's Documents folder (~/GratBox)
  4. Fallback: Current working directory
  
  Creates the directory if it doesn't exist.
  
  .EXAMPLE
  $root = Get-GratBoxRoot
  $reportsDir = Join-Path $root 'reports\MyFunction'
  #>
  [CmdletBinding()]
  param()
  
  # Priority 1: User override via environment variable
  if ($env:GRATBOX_ROOT) {
    if (Test-Path $env:GRATBOX_ROOT) {
      return (Resolve-Path $env:GRATBOX_ROOT).Path
    }
  }
  
  # Priority 2: Toolkit mode (portable installation)
  # Detect if module is running from C:\Tools\GratBox\modules\GratBox
  try {
    $mod = Get-Module GratBox -ErrorAction SilentlyContinue
    if ($mod -and $mod.ModuleBase) {
      # Check if we're in a "modules" folder structure
      # C:\Tools\GratBox\modules\GratBox → C:\Tools\GratBox
      $moduleDir = $mod.ModuleBase
      $modulesDir = Split-Path -Parent $moduleDir
      
      # If parent folder is named "modules", assume toolkit mode
      if ((Split-Path -Leaf $modulesDir) -eq 'modules') {
        $toolkitRoot = Split-Path -Parent $modulesDir
        
        # Verify this looks like a toolkit installation
        $launchers = @(
          'Launch-GratBox.cmd',
          'Init-IntuneGraph.ps1'
        )
        
        $hasLaunchers = $launchers | ForEach-Object {
          Test-Path (Join-Path $toolkitRoot $_)
        } | Where-Object { $_ -eq $true }
        
        if ($hasLaunchers.Count -ge 1) {
          return $toolkitRoot
        }
      }
    }
  } catch { }
  
  # Priority 3: PSGallery mode (module installed in standard location)
  # Use Documents/GratBox as workspace
  try {
    $documentsPath = [Environment]::GetFolderPath('MyDocuments')
    if ($documentsPath) {
      $gratboxWorkspace = Join-Path $documentsPath 'GratBox'
      
      # Create workspace structure if it doesn't exist
      if (-not (Test-Path $gratboxWorkspace)) {
        Write-Verbose "[Get-GratBoxRoot] Creating GratBox workspace: $gratboxWorkspace"
        New-Item -ItemType Directory -Path $gratboxWorkspace -Force | Out-Null
        
        # Create standard subfolders
        @('Logs','Reports','Scripts','Imports') | ForEach-Object {
          $subDir = Join-Path $gratboxWorkspace $_
          if (-not (Test-Path $subDir)) {
            New-Item -ItemType Directory -Path $subDir -Force | Out-Null
          }
        }
      }
      
      return $gratboxWorkspace
    }
  } catch { }
  
  # Priority 4: Fallback to current directory
  try {
    return (Get-Location).Path
  } catch {
    return $PWD.Path
  }
}

function Start-PrivateBrowser {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Url,
    [ValidateSet('edge','chrome')][string]$Pref='edge'
  )

  # Launch a URL in an InPrivate/Incognito browser (best effort).
  # Order: App Paths → common install paths → PATH → non-private fallback.
  
  $candidates = @()

  if ($Pref -eq 'edge') {
    try {
      $ap1 = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction SilentlyContinue).'(default)'
      $ap2 = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction SilentlyContinue).'(default)'
      if ($ap1) { $candidates += $ap1 }
      if ($ap2) { $candidates += $ap2 }
    } catch {}
    $candidates += @(
      "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
      "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe"
    )
  } else {
    try {
      $ap1 = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)'
      $ap2 = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)'
      if ($ap1) { $candidates += $ap1 }
      if ($ap2) { $candidates += $ap2 }
    } catch {}
    $candidates += @(
      "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
      "$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe"
    )
  }

  foreach ($p in $candidates | Where-Object { $_ -and (Test-Path $_) }) {
    try {
      if ($Pref -eq 'edge') {
        Start-Process -FilePath $p -ArgumentList @('-inprivate', $Url) -WindowStyle Normal -ErrorAction Stop | Out-Null
      } else {
        Start-Process -FilePath $p -ArgumentList @('--incognito', $Url) -WindowStyle Normal -ErrorAction Stop | Out-Null
      }
      return $true
    } catch {}
  }

  # PATH resolution fallback
  try {
    if ($Pref -eq 'edge') {
      $edge = (Get-Command 'msedge.exe' -ErrorAction SilentlyContinue)?.Source
      if ($edge) { Start-Process -FilePath $edge -ArgumentList @('-inprivate', $Url) -WindowStyle Normal; return $true }
    } else {
      $chrome = (Get-Command 'chrome.exe' -ErrorAction SilentlyContinue)?.Source
      if ($chrome) { Start-Process -FilePath $chrome -ArgumentList @('--incognito', $Url) -WindowStyle Normal; return $true }
    }
  } catch {}

  # Last resort (not private), but at least something opens
  try { Start-Process $Url -ErrorAction SilentlyContinue | Out-Null } catch {}
  return $false
}
# Ensure-GraphPrivate
# Ensures a valid Microsoft Graph authentication context with required scopes.
# Behavior:
# - Reuses existing Graph context if account, tenant, and scopes are valid
# - Otherwise opens an InPrivate/Incognito browser and initiates device-code sign-in
# - Tenant resolution order: -TenantHint → env vars → interactive prompt
function Ensure-GraphPrivate {
  [CmdletBinding()]
  param(
    [string[]]$RequiredScopes = @(
    'Group.Read.All',
    'Directory.Read.All',
    'DeviceManagementManagedDevices.Read.All'
    ),
    
    # Tenant hint for device-code authentication.
    # Leave blank to resolve via env vars or interactive prompt.
    
    [string]  $TenantHint     = '',   # example tenant hint (domain or TenantId GUID)
    
    [ValidateSet('edge','chrome')]
    [string]$BrowserPref = 'edge',

    # Optional enforcement knobs (default: not enforced)
    [string]$RequireUpnRegex,        # e.g. '.*-adm@contoso\.com$'
    [string]$RequireTenantId         # e.g. '00000000-0000-0000-0000-000000000000'
  )

  # Reuse only if account/tenant/scopes are OK
  $ctx = $null
  try { $ctx = Get-MgContext } catch {}
  if ($ctx -and $ctx.Account) {
    $ok = $true

    if ($RequireUpnRegex) {
      if ($ctx.Account -notmatch $RequireUpnRegex) { $ok = $false }
    }

    if ($RequireTenantId) {
      if ($ctx.TenantId -ne $RequireTenantId) { $ok = $false }
    }

    if ($RequiredScopes -and $ctx.Scopes) {
      $missing = @()
      foreach ($s in $RequiredScopes) {
        if ($ctx.Scopes -notcontains $s) { $missing += $s }
      }
      if ($missing.Count -gt 0) { $ok = $false }
    }

    if ($ok) { return }  # everything looks good: do nothing (no browser)
  }

  # Otherwise, initiate device-code sign-in using a private/incognito browser
  Write-Host "[INFO] No suitable Graph token. Opening Device Code sign-in in an InPrivate/Incognito window..." -ForegroundColor Yellow
  Start-PrivateBrowser -Url "https://microsoft.com/devicelogin" -Pref $BrowserPref | Out-Null

  # Resolve tenant if not supplied (portable / public-safe)
if ([string]::IsNullOrWhiteSpace($TenantHint)) {
    if ($env:GRATBOX_TENANT) {
        $TenantHint = $env:GRATBOX_TENANT
    }
    elseif ($env:AZURE_TENANT_ID) {
        $TenantHint = $env:AZURE_TENANT_ID
    }
    else {
        $TenantHint = (Read-Host "Enter tenant domain or TenantId GUID").Trim()
    }
}

  Connect-MgGraph -NoWelcome -UseDeviceCode `
    -TenantId $TenantHint `
    -Scopes   $RequiredScopes `
    -ContextScope Process
}

# Invoke-WithAuthRetry
# Executes a script block and retries authentication if Graph auth errors occur.
# Intended to wrap internal calls that may require additional scopes.
function Invoke-WithAuthRetry {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][scriptblock]$Script,
    [string]$TenantHint = $(if ($env:GRATBOX_TENANT) { $env:GRATBOX_TENANT } elseif ($env:AZURE_TENANT_ID) { $env:AZURE_TENANT_ID } else { '' }),
    [ValidateSet('edge','chrome')][string]$BrowserPref = 'edge',
    [string]$RequireUpnRegex,
    [string]$RequireTenantId,
    [string[]]$RequiredScopes = @()    # optional: pass through when a call needs extra scopes
  )
  try {
    & $Script
  } catch {
    $msg = $_.Exception.Message
    if ($msg -match 'DeviceCodeCredential|AADSTS|login required|invalid_grant|authorization') {
      Ensure-GraphPrivate -TenantHint $TenantHint -BrowserPref $BrowserPref `
        -RequireUpnRegex $RequireUpnRegex -RequireTenantId $RequireTenantId `
        -RequiredScopes  $RequiredScopes
      & $Script
    } else {
      throw
    }
  }
}