# Module notes

GratBox patched Public scripts
=================================
Patched on: 2025-10-26 04:56:22 UTC

What changed
------------
1) Robust Device Code auth with your Start-GratBoxPreAuth helper:
   - We only pass Tenant if you actually supplied -Tenant.
   - We detect whether the helper exposes -DeviceCode or -UseDeviceCode before splatting.
   - Fallback to Connect-MgGraph -UseDeviceCode outside the helper path.

2) Strict MDM filtering:
   - managedDevices queries include 'managementAgent' in $select.
   - Commands that support -StrictMdmOnly now log how many were filtered.

3) Reports:
   - Export-IntuneManagedDevicesFromGroup writes to:
     .\Reports\Export-IntuneManagedDevicesFromGroup\IntuneManaged_<GroupName>_<yyyyMMdd-HHmm>[_MDMonly].csv
   - Sync-AutopilotFromCsv writes to:
     .\Reports\Sync-AutopilotFromCsv\Sync-AutopilotFromCsv-<yyyyMMdd-HHmmss>.csv

Files in this zip
-----------------
- Export-IntuneManagedDevicesFromGroup.ps1
- Sync-AutopilotFromCsv.ps1
- Get-AutopilotGroupTagFromGroup.ps1 (patched Ensure-GraphAuth only)
- Set-AutopilotGroupTagFromGroup.ps1 (patched Ensure-GraphAuth only)
- Remove-AutopilotGroupTagFromGroup.ps1 (patched Ensure-GraphAuth only)
- Add-GroupMembersFromCsv.ps1 (patched Ensure-GraphAuth only)

How to install
--------------
1) Back up your existing scripts under Tools\GratBox\modules\GratBox\Public.
2) Copy these PS1 files over the existing ones.
3) Reload the module:
   Remove-Module GratBox -ErrorAction Ignore
   Import-Module .\modules\GratBox\GratBox.psd1 -Force

Quick verification
------------------
- Export-IntuneManagedDevicesFromGroup -GroupId '<GUID>' -StrictMdmOnly
  Expect your original filename pattern and a Strict MDM log line.

- Sync-AutopilotFromCsv -CsvPath '<your CSV>' -ImportGroupTag 'TAG-TEST' -UseDeviceCode -WhatIf
  Expect no 'DeviceCode' parameter errors and a report in Reports\Sync-AutopilotFromCsv\.
