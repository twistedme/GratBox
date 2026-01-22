# Export-IntuneManagedDevicesFromGroup examples

These are **example** commands to generate CSV exports for devices in an Entra ID group.

> Notes
> - Replace `<GroupId>` with the Entra ID **group object ID**.
> - Replace `<GroupName>` with the Entra ID **display name** (used for output naming).
> - Most users won’t run these manually if they use the auto-generated **CSV report script** created by `New-GratBoxMigrationWaveSet` (or your wave-set generator).

## Single group export

```powershell
export-intuneManagedDevicesFromGroup `
  -GroupId   "<GroupId>" `
  -GroupName "<GroupName>" `
  -StrictMdMOnly
```

## Example: wave groups

```powershell
export-intuneManagedDevicesFromGroup -GroupId "<GroupId-Wave1>" -GroupName "Example Wave 1_GROUP" -StrictMdMOnly
export-intuneManagedDevicesFromGroup -GroupId "<GroupId-Wave2>" -GroupName "Example Wave 2_GROUP" -StrictMdMOnly
export-intuneManagedDevicesFromGroup -GroupId "<GroupId-Wave3>" -GroupName "Example Wave 3_GROUP" -StrictMdMOnly
```
