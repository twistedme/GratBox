<#  Init-IntuneGraph.ps1  (v10 — interactive by default; DeviceCode+Incognito optional; device-code auto-retry)

Goals
- Keep it simple & fast for techs:
  * Writes a run log to <ToolRoot>\Logs\Init-IntuneGraph.log (EPM-safe)
  * Elevated PowerShell via EPM
  * Minimal modules (Microsoft.Graph.Authentication, WindowsAutoPilotIntune)
  * Default: **interactive login** (no device codes)
  * Default consent path is on (-UseDefaultConsent defaults to $true); pass -UseDefaultConsent:$false to supply custom -Scopes.
  * Optional: **-DeviceCode** with **-PrivateBrowser** opens an **incognito** page for Okta/SSO edge cases
  * Optional: **-MaxWaitMinutes** (default **45**) lets the script keep re-issuing the device-code prompt
    until you finish sign-in (works around the Graph module’s ~120s terminal timeout)

Behavior
- Interactive login: `Connect-MgGraph -Tenant ... -Scopes ...` (no device code)
- Device-code login: Connect-MgGraphWithRetry retries (up to -MaxWaitMinutes) on timeout/pending/expired/declined
- Uses `-ContextScope Process` so each PowerShell window keeps its own auth context

Examples
  .\Init-IntuneGraph.ps1 -Tenant 'Contoso.com'                                  # interactive (default)
  .\Init-IntuneGraph.ps1 -Tenant 'Contoso.com' -DeviceCode                      # device code (prints code in console)
  .\Init-IntuneGraph.ps1 -Tenant 'Contoso.com' -DeviceCode -PrivateBrowser      # device code + open devicelogin in InPrivate
  .\Init-IntuneGraph.ps1 -Tenant 'Contoso.com' -DeviceCode -MaxWaitMinutes 60   # allow up to 60 min for sign-in
  .\Init-IntuneGraph.ps1 -Tenant 'Contoso.com' -UseDefaultConsent:$false -Scopes "User.Read.All,Group.ReadWrite.All"
 
Notes
  Version 1.0.1
#>

[CmdletBinding()]
param(
  [string]$Tenant = $(if ($env:GRATBOX_TENANT) { $env:GRATBOX_TENANT } elseif ($env:AZURE_TENANT_ID) { $env:AZURE_TENANT_ID } else { '' }),
  # Optional: set GRATBOX_TENANT or AZURE_TENANT_ID env var, or pass -Tenant, or you will be prompted.
  [switch]$DeviceCode,
  [switch]$PrivateBrowser,             # implies you want device code + an incognito page
  [object]$Scopes = $null,
  [switch]$UseDefaultConsent = $true,
  [int]$MaxWaitMinutes = 45
)

# --------------------------------------------------------------------
# Tenant resolution (public-friendly: env var > param > prompt)
# --------------------------------------------------------------------
# OPTIONAL (tech convenience): you can hardcode your tenant here if desired:
# $Tenant = 'contoso.com'

if (-not $Tenant -or [string]::IsNullOrWhiteSpace($Tenant)) {
    
  Write-Host "[INFO] To stop this prompt, you can hard-set the tenant in the launcher CMD:" -ForegroundColor DarkGray
  Write-Host "       Edit: PS-SMART-GratBox-EPM-PRIVATE.cmd" -ForegroundColor DarkGray
  Write-Host "       Find: set ""TENANT=""" -ForegroundColor DarkGray
  Write-Host "       Set : set ""TENANT=contoso.com""" -ForegroundColor DarkGray
  Write-Host ""  # spacer
  
  $Tenant = (Read-Host "Enter tenant domain or TenantId GUID (ex: contoso.com or 00000000-0000-0000-0000-000000000000)").Trim()
}

# --------------------------------------------------------------------
# Console timer + pretty log
# --------------------------------------------------------------------
$sw = [Diagnostics.Stopwatch]::StartNew()
function Log([string]$msg, [ConsoleColor]$c='Gray') {
  Write-Host ("[{0,5:n1}s] {1}" -f $sw.Elapsed.TotalSeconds, $msg) -ForegroundColor $c
}

# --------------------------------------------------------------------
# File logger (<ToolRoot>\Logs\Init-IntuneGraph.log)
# --------------------------------------------------------------------
$GratBoxRoot = Split-Path -Parent $PSCommandPath

# --------------------------------------------------------------------
# Add GratBox Scripts folder to session PATH (session-only)
# --------------------------------------------------------------------
$ScriptsPath = Join-Path $GratBoxRoot 'Scripts'

 if (Test-Path $ScriptsPath) {
     if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $ScriptsPath })) {
         $env:PATH = "$ScriptsPath;$env:PATH"
         Write-Host "[INFO] Scripts path added to session PATH: $ScriptsPath"
     }

     Write-Host "[INFO] You can run scripts directly from $ScriptsPath" -ForegroundColor DarkGray
 }

$LogsDir = Join-Path $GratBoxRoot 'Logs'
if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null }
$LogFile = Join-Path $LogsDir 'Init-IntuneGraph.log'

function Write-LogFile {
  param(
    [string]$Message,
    [string]$Level = "INFO"
  )
  $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $entry = "[{0}] [{1}] {2}" -f $timestamp, $Level.ToUpper(), $Message
  try { Add-Content -Path $LogFile -Value $entry -Encoding UTF8 } catch { }
}

Write-LogFile ("Starting Init-IntuneGraph.ps1 v10. Log file: {0}" -f $LogFile)
Write-LogFile ("Startup summary: Tenant={0}, DeviceCode={1}, PrivateBrowser={2}, MaxWaitMinutes={3}" -f $Tenant, $DeviceCode.IsPresent, $PrivateBrowser.IsPresent, $MaxWaitMinutes)

# --------------------------------------------------------------------
# GratBox module bootstrap (safe-if-present)
# --------------------------------------------------------------------
try {
  $GratBoxModules = Join-Path $GratBoxRoot 'modules'
  if ($env:PSModulePath -notlike "*$GratBoxModules*") {
    $env:PSModulePath = "$GratBoxModules;$env:PSModulePath"
  }
  Import-Module GratBox -ErrorAction Stop
  Write-LogFile "GratBox module imported successfully."
} catch {
  Write-LogFile ("GratBox module not imported (safe to ignore): {0}" -f $_.Exception.Message)
}

# --------------------------------------------------------------------
# Elevation check
# --------------------------------------------------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log ("Elevated (local admin): {0}" -f $IsAdmin) 'Yellow'
Write-LogFile ("Elevated (local admin): {0}" -f $IsAdmin)

# --------------------------------------------------------------------
# Minimal modules from local cache (avoid online installs by default)
# --------------------------------------------------------------------
$Local3p = Join-Path $GratBoxRoot 'modules\3p'
if ($env:PSModulePath -notlike "*$Local3p*") { $env:PSModulePath = "$Local3p;$env:PSModulePath" }

function Import-LocalOrThrow {
  param([Parameter(Mandatory)][string]$Name,[string]$LocalRoot=$Local3p,[switch]$AllowOnlineInstall)
  if (Get-Module -ListAvailable -Name $Name) { Import-Module $Name -ErrorAction Stop | Out-Null; return }
  $vendored = Get-ChildItem -Path $LocalRoot -Recurse -Filter "$Name.psd1" -ErrorAction SilentlyContinue |
              Sort-Object FullName -Descending | Select-Object -First 1
  if ($vendored) { Import-Module $vendored.FullName -ErrorAction Stop | Out-Null; return }
  if ($AllowOnlineInstall) {
    try {
      if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
      }
      Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
      Import-Module $Name -ErrorAction Stop | Out-Null; return
    } catch { throw "Failed to install/import module '$Name': $($_.Exception.Message)" }
  }
  throw "Module '$Name' not found. Save it locally with: Save-Module -Name $Name -Path '$Local3p'"
}

Import-LocalOrThrow -Name 'Microsoft.Graph.Authentication'
Import-LocalOrThrow -Name 'WindowsAutoPilotIntune'
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop | Out-Null
Log "Auth module ready." 'Green'
Write-LogFile "Auth module ready."

# --------------------------------------------------------------------
# Resilient device-code connect with auto-retry
# --------------------------------------------------------------------
function Connect-MgGraphWithRetry {
  param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string[]]$Scopes,
    [int]$MaxWaitMinutes = 45
  )
  $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
  while ($true) {
    try {
      Connect-MgGraph -TenantId $TenantId -Scopes $Scopes -UseDeviceCode -NoWelcome -ContextScope Process
      return
    } catch {
      $msg = $_.Exception.Message
      if ((Get-Date) -lt $deadline -and (
            $msg -match 'Authentication timed out after 120 seconds' -or
            $msg -match '\b120\s*seconds\b' -or
            $msg -match 'authorization_pending' -or
            $msg -match 'expired' -or
            $msg -match 'declined'
          )) {
        Write-Host "[INFO] Device code not completed yet or expired; re-issuing..." -ForegroundColor Yellow
        Write-LogFile "Device code expired or pending; re-issuing."
        Start-Sleep -Seconds 3
        continue
      }
      throw
    }
  }
}

# --------------------------------------------------------------------
# Resolve scopes
# --------------------------------------------------------------------
$resolvedScopes = @()
if ($UseDefaultConsent -and (-not $Scopes)) {
  $resolvedScopes = @('https://graph.microsoft.com/.default')
  Log ("Auth scopes: .default (tenant '{0}')" -f $Tenant) 'Cyan'
  Write-LogFile ("Auth scopes: .default (tenant '{0}')" -f $Tenant)
} else {
  if ($null -ne $Scopes) {
    if ($Scopes -is [string]) {
      $resolvedScopes = $Scopes.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    } elseif ($Scopes -is [System.Collections.IEnumerable]) {
      $resolvedScopes = @($Scopes) | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ }
    }
  }
  if ($resolvedScopes.Count -eq 0) {
    $resolvedScopes = @('https://graph.microsoft.com/.default')
    Log ("Auth scopes: .default (tenant '{0}')" -f $Tenant) 'Cyan'
    Write-LogFile ("Auth scopes: .default (tenant '{0}')" -f $Tenant)
  } else {
    Log ("Auth scopes: {0}" -f ($resolvedScopes -join ', ')) 'Cyan'
    Write-LogFile ("Auth scopes: {0}" -f ($resolvedScopes -join ', '))
  }
}

# --------------------------------------------------------------------
# Open devicelogin in private/incognito (hardened)
# --------------------------------------------------------------------
function Open-PrivateBrowser {
  param([string]$Url)

  # Try App Paths (registry), then common install paths, then PATH
  $edgeAppPath1 = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction SilentlyContinue).'(default)'
  $edgeAppPath2 = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction SilentlyContinue).'(default)'
  $chromeAppPath1 = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)'
  $chromeAppPath2 = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)'

  $candidates = @(
    @{ Path = $edgeAppPath1;                                           Args = "-inprivate $Url" },
    @{ Path = $edgeAppPath2;                                           Args = "-inprivate $Url" },
    @{ Path = "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe";      Args = "-inprivate $Url" },
    @{ Path = "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe"; Args = "-inprivate $Url" },
    @{ Path = $chromeAppPath1;                                         Args = "--incognito $Url" },
    @{ Path = $chromeAppPath2;                                         Args = "--incognito $Url" },
    @{ Path = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe";      Args = "--incognito $Url" },
    @{ Path = "$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe"; Args = "--incognito $Url" }
  )

  foreach ($b in $candidates) {
    if ($b.Path -and (Test-Path $b.Path)) {
      try { Start-Process -FilePath $b.Path -ArgumentList $b.Args -WindowStyle Normal; return $true } catch {}
    }
  }

  # PATH resolution fallback
  try {
    $edge = (Get-Command msedge.exe -ErrorAction SilentlyContinue)?.Source
    if ($edge) { Start-Process -FilePath $edge -ArgumentList @('-inprivate', $Url) -WindowStyle Normal; return $true }
  } catch {}
  try {
    $chrome = (Get-Command chrome.exe -ErrorAction SilentlyContinue)?.Source
    if ($chrome) { Start-Process -FilePath $chrome -ArgumentList @('--incognito', $Url) -WindowStyle Normal; return $true }
  } catch {}

  # Last resort (not private) — still opens something if needed
  try { Start-Process $Url | Out-Null; return $false } catch {}
  return $false
}

# --------------------------------------------------------------------
# Connect
# --------------------------------------------------------------------
try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {}

if ($PrivateBrowser) { $DeviceCode = $true }

try {
  if ($DeviceCode) {
    Log "Opening devicelogin page in **private/incognito** (if possible)..." 'Cyan'
    Write-LogFile "Launching private/incognito browser for device-code login."
    $opened = Open-PrivateBrowser -Url 'https://microsoft.com/devicelogin'
    if (-not $opened) {
      try {
        Start-Process 'https://microsoft.com/devicelogin' | Out-Null
        Write-LogFile "Fallback launched devicelogin with system default browser."
      } catch {
        Write-LogFile ("Fallback launch of devicelogin failed: {0}" -f $_.Exception.Message)
        Log "Could not auto-open https://microsoft.com/devicelogin — copy/paste this URL into a browser." 'Yellow'
      }
    } else {
      Write-LogFile "Launched devicelogin in private/incognito successfully."
    }

    Log "Now running device-code flow. A code will appear **in this console**; paste it into the private browser page." 'Cyan'
    Write-LogFile "Waiting for user to complete device-code authentication."
    Connect-MgGraphWithRetry -TenantId $Tenant -Scopes $resolvedScopes -MaxWaitMinutes $MaxWaitMinutes
  } else {
    Log "Connecting to Graph using interactive browser..." 'Cyan'
    Write-LogFile "Connecting to Graph using interactive browser."
    Connect-MgGraph -TenantId $Tenant -Scopes $resolvedScopes -NoWelcome -ContextScope Process
  }
} catch {
  Write-LogFile ("Connect-MgGraph failed: {0}" -f $_.Exception.Message) "ERROR"
  Log "Connect-MgGraph failed. Check the log: $LogFile" 'Red'
  throw
}

# --------------------------------------------------------------------
# Context summary
# --------------------------------------------------------------------
$ctx = Get-MgContext
if (-not $ctx -or -not $ctx.Account) {
  throw "Sign-in did not complete. No Microsoft Graph context present."
}

Log ("Account: {0}" -f $ctx.Account) 'Green'
Log ("Tenant : {0}" -f $ctx.TenantId) 'Green'
Log ("Scopes : {0}" -f ($ctx.Scopes -join ', ')) 'Green'
Write-LogFile ("Authentication complete for {0} in tenant {1}" -f $ctx.Account, $ctx.TenantId)

Log "Ready. Run your Intune/Autopilot/Graph commands." 'Cyan'
Write-LogFile "Init-IntuneGraph.ps1 completed successfully. Ready for Intune/Graph commands."
