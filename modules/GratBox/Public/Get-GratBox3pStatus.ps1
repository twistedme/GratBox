<#
.SYNOPSIS
Check the status of vendored 3p modules in the GratBox toolkit.

.DESCRIPTION
Scans the modules/3p/ folder for installed third-party modules and compares
their versions against the latest available versions on PSGallery.

Reports the installation status for each module:
- OK: Installed version matches latest PSGallery version
- Outdated: Newer version available on PSGallery
- NotInstalled: Module manifest missing or unreadable
- NotFound: Module not found on PSGallery

.EXAMPLE
Get-GratBox3pStatus

.EXAMPLE
Get-GratBox3pStatus | Where-Object Status -eq 'Outdated'

.OUTPUTS
PSCustomObject with properties: Name, Installed, Latest, Status

.NOTES
Requires internet access to query PSGallery.
#>
function Get-GratBox3pStatus {
    [CmdletBinding()]
    param ()

# GratBox module root (…\modules\GratBox)
$graphAdminModuleRoot = Split-Path -Parent $PSScriptRoot

# GratBox modules root (…\modules)
$modulesRoot = Split-Path -Parent $graphAdminModuleRoot

# 3p modules path (…\modules\3p)
$threePPath = Join-Path $modulesRoot '3p'

if (-not (Test-Path $threePPath)) {
    throw "3p module path not found: $threePPath"
}

    if (-not (Test-Path $threePPath)) {
        throw "3p module path not found: $threePPath"
    }

    $results = @()

    foreach ($moduleDir in Get-ChildItem -Path $threePPath -Directory) {

        $installedVersion = $null
        $latestVersion    = $null
        $status           = 'Unknown'

        # Detect installed version
        $psd1 = Get-ChildItem $moduleDir.FullName -Recurse -Filter '*.psd1' |
                Select-Object -First 1

        if ($psd1) {
            try {
                $data = Import-PowerShellDataFile $psd1.FullName
                $installedVersion = $data.ModuleVersion
            } catch {
                $installedVersion = 'Unreadable'
            }
        } else {
            $installedVersion = 'Missing'
        }

        # Query PSGallery for latest version
        try {
            $gallery = Find-Module -Name $moduleDir.Name -Repository PSGallery -ErrorAction Stop
            $latestVersion = $gallery.Version
        } catch {
            $latestVersion = 'NotFound'
        }

        # Compare
        if ($installedVersion -eq 'Missing') {
            $status = 'NotInstalled'
        }
        elseif ($installedVersion -eq $latestVersion) {
            $status = 'OK'
        }
        elseif ($installedVersion -and $latestVersion -and
                [version]$installedVersion -lt [version]$latestVersion) {
            $status = 'Outdated'
        }

        $results += [pscustomobject]@{
            Name      = $moduleDir.Name
            Installed = $installedVersion
            Latest    = $latestVersion
            Status    = $status
        }
    }

    $results | Sort-Object Status, Name
}
