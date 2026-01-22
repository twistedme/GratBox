# Scripts folder

How to use (summary)

1 copy the .cmd launch files and Init-IntuneGraph.ps1 to the same folder on your local system.
2 Once copied to your local system make sure to check properties and if unblock is a checkable item check it and click ok. 
3 Right-click a launcher → Run with Endpoint Privilege Management.
4 Copy the device code shown in the console into the private browser page, sign in as yourusername-adm@contoso.com, complete MFA.
5 Verify your credentials with with Get-MgContext.
6 continue on with whatever it was you needed to do with Graph.


ChatGPTS  suggestion from my above summary.
How to use (summary)

Copy the files
Put the .cmd launchers and Init-IntuneGraph.ps1 in the same folder (e.g., <ToolRoot>\). The launchers look for the script next to them.

Unblock once (Windows SmartScreen)copied locally.

Right-click each file → Properties → check Unblock → OK, or

In PowerShell: Unblock-File <ToolRoot>\*

Pick a launcher (right-click → Run with Endpoint Privilege Management)

PS7-GratBox-EPM-PRIVATE.cmd → PowerShell 7, Incognito + Device Code (recommended if SSO/Okta is sticky)

PS5-GratBox-EPM-PRIVATE.cmd → Windows PowerShell 5.1, Incognito + Device Code (for older scripts)

Launch-GratBox.cmd → tries PS7, falls back to PS5.1, Incognito + Device Code

(Optional) PS7-GratBox-EPM.cmd → normal interactive sign-in (no device code/incognito)

Sign in (Incognito + Device Code flow)

The console will print a device code (e.g., ABCD-EFGH)

A private/incognito browser opens at https://microsoft.com/devicelogin

Paste the code, then sign in as yourusername-adm@contoso.com, complete MFA

Verify you’re good to go
In the PowerShell window:

# Check elevation (should be True)
([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Confirm Graph identity/tenant/scopes
Get-MgContext | Select Account, TenantId, Scopes


You should see your *-adm@contoso.com account.

Do your work
Run your Intune/Autopilot/Graph commands (bulk uploads, GroupTag updates, etc.).
The script auto-installs (CurrentUser) and loads:

Microsoft.Graph.Authentication (fast, for Graph)

WindowsAutoPilotIntune (community module)

Notes that help

Why Incognito + Device Code?
It avoids your normal Windows/SSO session (Okta, browser), so you can reliably sign in as the adm account.

Permissions / scopes
The script uses Graph .default by default—i.e., whatever delegated permissions your tenant admin has pre-consented for the Microsoft Graph PowerShell app. Your Intune/Entra roles then control what you can actually do. If you hit “insufficient privileges,” ask for the missing delegated permission to be tenant-consented, or run once with explicit -Scopes to trigger consent.

Keep files together
The launchers use %~dp0 to find Init-IntuneGraph.ps1. If you move the script elsewhere, update the set "SCRIPT=..." line in the .cmd.

Quick troubleshooting

Browser asks for a code but the console didn’t show one
You likely used the non-private launcher and Graph reused a cached token (no code needed). Use a PRIVATE launcher to force device-code and show the code in the console.

Elevated (local admin): False
You didn’t start the launcher with Endpoint Privilege Management. Right-click the .cmd → Run with Endpoint Privilege Management.

AccessDenied / missing permission
Your adm account lacks a tenant-consented delegated permission for that API. Ask for consent to the needed Graph permission(s) for the Graph PowerShell app, or run the script with -Scopes '<Permission1>,<Permission2>' once to trigger the consent prompt.

Modules won’t install
Corporate proxy / PSGallery blocked. Try again or install the modules once from a network that allows PowerShell Gallery, then re-run the launcher.
