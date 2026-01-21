\## v3.3



\### Added

\- Export-GratBoxBitLockerKeyPresenceFromGroup cmdlet for validating BitLocker status

&nbsp; across single devices or Entra ID device groups

\- Get-GratBoxPath helper for consistent portable vs installed path resolution

\- Write-GratBoxLog helper for lightweight, consistent logging



\### Improved

\- Release-ready comment-based help for BitLocker export cmdlet

\- Clear INFO messaging when BitLocker Graph permissions are unavailable



\### Notes

\- BitLocker recovery key visibility requires delegated Microsoft Graph permission

&nbsp; BitLockerKey.Read.All approved for the Microsoft Graph PowerShell application.

\- When unavailable, recovery key status is reported as `Unknown` without blocking execution.



