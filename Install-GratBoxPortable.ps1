<#
.SYNOPSIS
Installs GratBox in portable mode with vendored dependencies.

.DESCRIPTION
Creates a self-contained GratBox installation at the specified path.
Downloads and vendors all required Graph modules to the 3p/ folder.
Unblocks files and sets up EPM launchers.

Ideal for:
- Offline/air-gapped environments
- Environments where PSGallery is blocked
- Users without admin rights to install modules
- Fast cold-start performance (no online module resolution)

.PARAMETER InstallPath
Installation directory (default: C:\Tools\GratBox)

.PARAMETER SkipModuleDownload
Skip downloading 3p modules (use existing modules if present)

.PARAMETER SetEnvironmentVariables
Set GRATBOX_ROOT environment variable (CurrentUser scope)

.PARAMETER Force
Overwrite existing installation

.EXAMPLE
.\Install-GratBoxPortable.ps1

.EXAMPLE
.\Install-GratBoxPortable.ps1 -InstallPath D:\AdminTools\GratBox -SetEnvironmentVariables

.EXAMPLE
# Offline install (pre-downloaded release ZIP)
.\Install-GratBoxPortable.ps1 -SkipModuleDownload
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallPath = 'C:\Tools\GratBox',
    
    [switch]$SkipModuleDownload,
    
    [switch]$SetEnvironmentVariables,
    
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Helper functions ---
function Write-Step {
    param([string]$Message)
    Write-Host "`n[STEP] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  ⚠ $Message" -ForegroundColor Yellow
}

function Test-Elevation {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-VendoredModule {
    param(
        [string]$ModuleName,
        [string]$DestinationPath
    )
    
    Write-Host "  → Downloading $ModuleName from PSGallery..." -ForegroundColor Gray
    
    $tempPath = Join-Path $env:TEMP "GratBox-Download-$ModuleName"
    
    if (Test-Path $tempPath) {
        Remove-Item $tempPath -Recurse -Force
    }
    
    try {
        # Ensure NuGet provider is available
        $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue
        if (-not $nuget) {
            Write-Host "  → Installing NuGet provider..." -ForegroundColor Gray
            Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
        }
        
        Save-Module -Name $ModuleName `
                    -Path $tempPath `
                    -Repository PSGallery `
                    -Force `
                    -ErrorAction Stop
        
        $downloadedModule = Get-ChildItem $tempPath -Directory | Select-Object -First 1
        
        if (-not $downloadedModule) {
            throw "Module download failed: $ModuleName"
        }
        
        $finalPath = Join-Path $DestinationPath $ModuleName
        
        if (Test-Path $finalPath) {
            Remove-Item $finalPath -Recurse -Force
        }
        
        Move-Item $downloadedModule.FullName $finalPath
        
        Write-Success "$ModuleName installed"
        
    } catch {
        Write-Warn "Failed to download $ModuleName : $($_.Exception.Message)"
        throw
    } finally {
        if (Test-Path $tempPath) {
            Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Main installation logic ---

Write-Host @"

╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║   GratBox Portable Installation                               ║
║   Graph Administrator Toolbox for CM → Intune Migrations      ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan

# Check if path exists
if ((Test-Path $InstallPath) -and -not $Force) {
    throw "Installation path already exists: $InstallPath`nUse -Force to overwrite."
}

# Check elevation
$isAdmin = Test-Elevation
if ($isAdmin) {
    Write-Warn "Running as administrator. GratBox is designed for standard user + EPM."
    Write-Warn "Consider running as a standard user if EPM is available."
}

Write-Step "Creating folder structure at: $InstallPath"

# Create base directories
$folders = @(
    $InstallPath,
    (Join-Path $InstallPath 'modules'),
    (Join-Path $InstallPath 'modules\3p'),
    (Join-Path $InstallPath 'modules\GratBox'),
    (Join-Path $InstallPath 'modules\GratBox\Public'),
    (Join-Path $InstallPath 'modules\GratBox\Private'),
    (Join-Path $InstallPath 'Logs'),
    (Join-Path $InstallPath 'Scripts'),
    (Join-Path $InstallPath 'Imports'),
    (Join-Path $InstallPath 'reports')
)

foreach ($folder in $folders) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
}

Write-Success "Folder structure created"

# Copy module files from current location
Write-Step "Copying GratBox module files"

$sourceRoot = $PSScriptRoot

if (Test-Path (Join-Path $sourceRoot 'modules\GratBox')) {
    # Running from repo/dev structure
    $sourceGratBox = Join-Path $sourceRoot 'modules\GratBox'
    $destGratBox   = Join-Path $InstallPath 'modules\GratBox'
    
    Copy-Item "$sourceGratBox\*" $destGratBox -Recurse -Force
    Write-Success "Module files copied"
} else {
    Write-Warn "GratBox source files not found in expected location."
    Write-Warn "You may need to manually copy module files to: $InstallPath\modules\GratBox"
}

# Copy launchers
Write-Step "Setting up EPM launchers"

$launchers = @(
    'PS-SMART-GratBox-EPM-PRIVATE.cmd',
    'PS-SMART-GratBox-Maintenance.cmd',
    'Init-IntuneGraph.ps1',
    'Init-GratBoxMaintenance.ps1'
)

foreach ($launcher in $launchers) {
    $source = Join-Path $sourceRoot $launcher
    if (Test-Path $source) {
        Copy-Item $source $InstallPath -Force
        Write-Success "$launcher installed"
    } else {
        Write-Warn "$launcher not found in source: $source"
    }
}

# Download and vendor 3p modules
if (-not $SkipModuleDownload) {
    Write-Step "Downloading and vendoring 3p modules"
    
    $requiredModules = @(
        'Microsoft.Graph.Authentication',
        'Microsoft.Graph.Groups',
        'Microsoft.Graph.Intune',
        'Microsoft.Graph.DeviceManagement.Enrollment',
        'WindowsAutoPilotIntune'
    )
    
    $threePPath = Join-Path $InstallPath 'modules\3p'
    
    foreach ($moduleName in $requiredModules) {
        try {
            Install-VendoredModule -ModuleName $moduleName -DestinationPath $threePPath
        } catch {
            Write-Warn "Could not vendor $moduleName - you may need to install it manually"
        }
    }
    
    Write-Success "3p modules vendored"
} else {
    Write-Warn "Skipped module download (-SkipModuleDownload specified)"
}

# Unblock files
Write-Step "Unblocking downloaded files"

try {
    Get-ChildItem -Path $InstallPath -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
    Write-Success "Files unblocked"
} catch {
    Write-Warn "Could not unblock some files: $($_.Exception.Message)"
}

# Set environment variables
if ($SetEnvironmentVariables) {
    Write-Step "Setting environment variables"
    
    try {
        [Environment]::SetEnvironmentVariable('GRATBOX_ROOT', $InstallPath, 'User')
        Write-Success "GRATBOX_ROOT = $InstallPath (CurrentUser)"
    } catch {
        Write-Warn "Could not set environment variable: $($_.Exception.Message)"
    }
}

# Final summary
Write-Host @"

╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║   ✓ Installation Complete                                     ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝

Installation Path: $InstallPath

Next Steps:

1. Launch GratBox:
   → Right-click: PS-SMART-GratBox-EPM-PRIVATE.cmd
   → Select: "Run with Endpoint Privilege Management"

2. Authenticate:
   → Device code will appear in the console
   → Private browser opens automatically
   → Sign in with your admin account

3. Start using GratBox commands:
   → Export-IntuneManagedDevicesFromGroup
   → Set-AutopilotGroupTagBySerial
   → New-GratBoxMigrationWaveSet
   → (See Get-Command -Module GratBox for all commands)

4. Documentation:
   → GitHub: https://github.com/your-org/GratBox
   → Wiki: https://github.com/your-org/GratBox/wiki

"@ -ForegroundColor Cyan

if (-not $isAdmin) {
    Write-Host "Tip: For best results, configure your EPM policy to elevate:" -ForegroundColor Yellow
    Write-Host "     $InstallPath\PS-SMART-GratBox-EPM-PRIVATE.cmd" -ForegroundColor Yellow
}