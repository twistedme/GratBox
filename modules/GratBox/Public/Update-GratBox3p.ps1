<#
.SYNOPSIS
Update vendored 3p modules in the GratBox toolkit.

.DESCRIPTION
Downloads the latest version of specified third-party modules from PSGallery
and replaces the existing vendored copies in modules/3p/.

Designed for GratBox maintenance mode. Use this to keep vendored dependencies
current without requiring users to have PSGallery access.

.PARAMETER Name
Name of specific module to update. If omitted, prompts for all modules.

.PARAMETER Latest
Update to the latest version from PSGallery (required).

.PARAMETER WhatIf
Preview which modules would be updated without making changes.

.EXAMPLE
Update-GratBox3p -Latest

.EXAMPLE
Update-GratBox3p -Name 'Microsoft.Graph.Authentication' -Latest

.EXAMPLE
Update-GratBox3p -Latest -WhatIf

.NOTES
- Run from GratBox maintenance mode (PS-SMART-GratBox-Maintenance.cmd)
- Requires elevated permissions (EPM or admin)
- Requires internet access to PSGallery
- Module must not be loaded during update (restart session after update)
#>
function Update-GratBox3p {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [string]$Name,
        [switch]$Latest
    )

    if (-not $Latest) {
        throw "Only -Latest is currently supported."
    }

    # Resolve paths
    $graphAdminModuleRoot = Split-Path -Parent $PSScriptRoot
    $modulesRoot          = Split-Path -Parent $graphAdminModuleRoot
    $threePPath           = Join-Path $modulesRoot '3p'

    if (-not (Test-Path $threePPath)) {
        throw "3p module path not found: $threePPath"
    }

    # Determine target modules
    $targets = if ($Name) {
        Get-ChildItem $threePPath -Directory | Where-Object { $_.Name -eq $Name }
    } else {
        Get-ChildItem $threePPath -Directory
    }

    if (-not $targets) {
        throw "No matching 3p modules found."
    }

    foreach ($moduleDir in $targets) {

        $moduleName = $moduleDir.Name

        Write-Host "Checking $moduleName..." -ForegroundColor Cyan

        # Skip if module is currently loaded
        if (Get-Module -Name $moduleName) {
            Write-Warning "$moduleName is currently loaded. Restart session before updating."
            continue
        }

        try {
            $gallery = Find-Module -Name $moduleName -Repository PSGallery -ErrorAction Stop
        } catch {
            Write-Warning "Could not find $moduleName in PSGallery."
            continue
        }

        $latestVersion = $gallery.Version.ToString()

        # Detect installed version
        $psd1 = Get-ChildItem $moduleDir.FullName -Recurse -Filter '*.psd1' | Select-Object -First 1
        $installedVersion = if ($psd1) {
            (Import-PowerShellDataFile $psd1.FullName).ModuleVersion
        } else {
            'Unknown'
        }

        if ($installedVersion -eq $latestVersion) {
            Write-Host "$moduleName is already up to date ($installedVersion)" -ForegroundColor DarkGray
            continue
        }

        if ($PSCmdlet.ShouldProcess(
                "$moduleName",
                "Update from $installedVersion to $latestVersion"
            )) {

            $tempPath = Join-Path $env:TEMP "GratBox-3p-$moduleName"

            if (Test-Path $tempPath) {
                Remove-Item $tempPath -Recurse -Force
            }

            Write-Host "Downloading $moduleName $latestVersion..." -ForegroundColor Yellow

            Save-Module -Name $moduleName `
                        -Repository PSGallery `
                        -Path $tempPath `
                        -RequiredVersion $latestVersion `
                        -Force

            $downloaded = Join-Path $tempPath $moduleName

            if (-not (Test-Path $downloaded)) {
                throw "Download failed for $moduleName"
            }

            Write-Host "Updating $moduleName..." -ForegroundColor Yellow

            Remove-Item $moduleDir.FullName -Recurse -Force
            Move-Item $downloaded $moduleDir.FullName

            Remove-Item $tempPath -Recurse -Force

            Write-Host "$moduleName updated to $latestVersion" -ForegroundColor Green
        }
    }

    Write-Host "`n[INFO] Updates complete. Restart the GratBox session to use updated modules." -ForegroundColor Cyan
}
