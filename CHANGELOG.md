## v0.1.0

First public GitHub release (portable toolkit).

### Added
- Portable toolkit layout (launchers, Scripts, modules, docs)
- Export-GratBoxBitLockerKeyPresenceFromGroup cmdlet (currently gated under device-code auth)
- Get-GratBoxPath helper for consistent portable path resolution
- Write-GratBoxLog helper for lightweight, consistent logging

### Notes
- BitLocker recovery key visibility via Graph requires delegated permission `BitLockerKey.Read.All`
  (admin consent for the Microsoft Graph PowerShell first-party application).
- Some Microsoft Graph behaviors are limited under delegated device-code authentication. Where applicable,
  cmdlets will warn and exit cleanly rather than producing partial/incorrect results.




