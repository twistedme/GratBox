@{
    RootModule        = 'GratBox.psm1'
    ModuleVersion     = '1.0.0'  # Semantic versioning for PSGallery
    GUID              = 'b598d04f-4387-4fbb-bc57-43d675f778a7'
    
    Author            = 'Your Name'  # Update this
    CompanyName       = 'Community'
    Copyright         = '(c) 2025 GratBox Contributors. MIT License.'
    
    Description       = @'
GratBox (Graph Administrator Toolbox) is an EPM-safe PowerShell toolkit for Microsoft Graph, 
Intune, Entra ID, and Windows Autopilot administration. Designed specifically for Configuration 
Manager to Intune migration workflows with built-in safety mechanisms, reviewable CSV outputs, 
and support for air-gapped/offline environments via vendored dependencies.

Key Features:
• EPM-safe architecture (no persistent admin rights required)
• Device-code authentication with incognito browser support
• CSV-first workflows for auditability
• Built-in retry logic and error handling
• Portable installation mode (vendored dependencies in 3p/ folder)
• Identity drift handling for reimage scenarios
• Migration wave management with bulk operations
'@
    
    PowerShellVersion = '5.1'
    
    # PSGallery standard: list dependencies (users install from PSGallery)
    # For portable mode, Install-GratBoxPortable.ps1 vendors these to 3p/
    RequiredModules   = @(
        @{ ModuleName = 'Microsoft.Graph.Authentication'; ModuleVersion = '2.0.0' },
        @{ ModuleName = 'Microsoft.Graph.Groups';         ModuleVersion = '2.0.0' },
        @{ ModuleName = 'Microsoft.Graph.DeviceManagement.Enrollment'; ModuleVersion = '2.0.0' }
    )
    
    # WindowsAutoPilotIntune is optional but recommended
    # (PSGallery doesn't enforce optional dependencies cleanly, document in README)
    
    # Export all public functions (GratBox.psm1 handles this dynamically)
    FunctionsToExport = @(
        'Add-GroupMembersFromCsv',
        'Convert-EntraDeviceIdCsvToGroupBulkImportCsv',
        'Export-AutopilotGroupTagFromGroup',
        'Export-IntuneManagedDevicesFromGroup',
        'Export-GratBoxBitLockerKeyPresenceFromGroup',
        'Get-AutopilotGroupTagFromGroup',
        'Get-GratBox3pStatus',
        'Import-AutopilotFromCsv',
        'New-GratBoxMigrationWaveSet',
        'Remove-AutopilotGroupTagFromGroup',
        'Set-AutopilotFromCsv',
        'Set-AutopilotGroupTagBySerial',
        'Set-AutopilotGroupTagFromCsv',
        'Set-AutopilotGroupTagFromGroup',
        'Start-GratBoxPreAuth',
        'Update-GratBox3p'
    )
    
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    
    PrivateData       = @{
        PSData = @{
            Tags         = @(
                'Intune',
                'Graph',
                'Autopilot',
                'EntraID',
                'AzureAD',
                'Migration',
                'ConfigMgr',
                'SCCM',
                'DeviceManagement',
                'Admin',
                'Enterprise',
                'EPM'
            )
            
            LicenseUri   = 'https://github.com/your-org/GratBox/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/your-org/GratBox'
            IconUri      = 'https://raw.githubusercontent.com/your-org/GratBox/main/docs/icon.png'
            
            ReleaseNotes = @'
## Version 1.0.0 (Initial Release)

### Features
- 18 public functions for Graph/Intune/Autopilot administration
- EPM-safe architecture with device-code authentication
- Portable installation mode with vendored dependencies
- CSV-first workflows for auditability and safety
- Built-in retry logic with exponential backoff
- Identity drift handling for reimage scenarios
- Migration wave management with bulk operations

### Functions
- Device inventory and export (Intune, Autopilot, Entra)
- Group membership management (CSV bulk import/export)
- Autopilot Group Tag management (set, update, clear)
- Migration wave group creation with CSV report generation
- 3p module management (status check, updates)

### Requirements
- PowerShell 5.1 or later (PowerShell 7 recommended)
- Microsoft.Graph.Authentication 2.0+
- Intune/Entra admin permissions
- Optional: WindowsAutoPilotIntune module

### Installation Modes
- Standard: `Install-Module GratBox` (PSGallery)
- Portable: Download release + run `Install-GratBoxPortable.ps1`

### Documentation
- GitHub: https://github.com/your-org/GratBox
- Wiki: https://github.com/your-org/GratBox/wiki
- Issues: https://github.com/your-org/GratBox/issues
'@
        }
    }
    HelpInfoURI       = ''  # Portable: disable Update-Help online lookup
}