# Launchers and wave/report workflow

================================================================================
README — Export-IntuneManagedDevicesFromGroup
================================================================================

PURPOSE
-------
Export a CSV of devices in a target Entra ID *device group* that are known to
Intune (Microsoft Endpoint Manager) and, optionally, restrict to those managed
via the Intune **MDM channel**.

The script intersects:
  • Entra group members  (directory devices)
  • Intune managedDevices (Intune inventory)
…then writes a CSV.

It does NOT list non-Intune devices (source is Intune’s managedDevices).


PREREQUISITES
-------------
• You have the launcher: 
  <ToolRoot>\Launch-GratBox.cmd
• Your tenant: contoso.com
• Your Intune delegated scopes (admin-consented). The EPM launcher already
  sets these via .default, including:
  DeviceManagementManagedDevices.Read.All (or ReadWrite.All), Group.Read.All,
  Directory.Read.All, etc.


AUTH BEHAVIOR (no surprises)
----------------------------
1) Reuse existing Graph token if present (no prompts).
2) If there’s no reusable token, the script opens the device-code sign-in page
   in **InPrivate/Incognito** (Edge preferred, Chrome fallback), then runs
   Connect-MgGraph -UseDeviceCode (tenant = contoso.com).
3) If the first Graph call fails due to an expired token, it will trigger the
   same private device-code sign-in and retry once.


QUICK START — RUN ORDER (KEEPING EPM FLOW INTACT)
-------------------------------------------------
1) Launch the elevated Graph window using EPM:
   • Right-click: <ToolRoot>\Launch-GratBox.cmd
   • Choose BeyondTrust “Run Elevated”, provide reason
   • Complete the device-code flow in the private browser (Okta prompts, etc.)
   • Wait for: “Ready. Run your Intune/Autopilot/Graph commands.”

2) In that same window, load the exporter function (dot-source):
   Set-Location <ToolRoot>
   Remove-Item function:Export-IntuneManagedDevicesFromGroup -ErrorAction SilentlyContinue
   . .\Export-IntuneManagedDevicesFromGroup.ps1

   NOTE: Dot-sourcing loads the function; it does NOT prompt. You’ll be prompted
   for GroupId only when you CALL the function without providing -GroupId.

3) Call it (pick ONE of the following patterns):

   A) Prompted for GroupId; GroupName auto-fills; return **MDM-only** rows
      Export-IntuneManagedDevicesFromGroup -StrictMdmOnly

   B) No prompts (explicit group), return all Intune-tracked rows (any agent)
      Export-IntuneManagedDevicesFromGroup -GroupId "<GUID>" -GroupName "<Name>"

   C) No prompts (explicit group), return **MDM-only** rows
      Export-IntuneManagedDevicesFromGroup -GroupId "<GUID>" -GroupName "<Name>" -StrictMdmOnly

   Tip: If you only know the display name, you can run B/C with -GroupId "<Name>";
        the script will resolve it to the ObjectId. (A malformed GUID is caught.)


WHERE TO GET THE GROUP ID / NAME
--------------------------------
In Entra admin portal:
  • Go to Groups → your device group → copy the **Object ID** (GUID) and **Name**.

PowerShell helpers:
  # Exact name → Id
  Get-MgGroup -Filter "displayName eq 'Your Group Name'" -Property "id,displayName" |
    Select-Object Id,DisplayName

  # Fuzzy search (top 5)
  Get-MgGroup -Search '"Your Group Name"' -ConsistencyLevel eventual -Top 5 |
    Select-Object Id,DisplayName


OUTPUT
------
CSV columns:
  GroupId, GroupName, DisplayName, Id (Entra device objectId),
  DeviceId (azureADDeviceId), OperatingSystem, OSVersion, ManagementAgent,
  EnrolledDateTime, LastCheckinDateTime, ComplianceState, SerialNumber

Default file name (if -OutPath not provided):
  IntuneManaged_<GroupName-or-GroupId>_<yyyyMMdd-HHmm>.csv


“MDM-ONLY” SWITCH — WHAT IT MEANS
---------------------------------
-StrictMdmOnly keeps only rows whose ManagementAgent includes “mdm”, i.e. Intune MDM channel:
  • mdm                                 → Intune MDM
  • configurationManagerClientMdm       → Co-managed (ConfigMgr + Intune MDM)
  • easMdm                              → EAS + Intune MDM
EXCLUDES:
  • configurationManagerClient          → ConfigMgr-only (no Intune MDM)
  • eas                                 → Exchange ActiveSync only
  • jamf, intuneClient (legacy), unknown, etc.


COMMON TASKS
------------
• Verify the function you’re about to run is the one from disk:
  Get-Command Export-IntuneManagedDevicesFromGroup | Format-List Name,Source

• Clean reset of the current session (before testing a fresh load):
  Disconnect-MgGraph -ErrorAction SilentlyContinue
  Remove-Item function:Export-IntuneManagedDevicesFromGroup -ErrorAction SilentlyContinue
  Get-Module Microsoft.Graph* | Remove-Module -Force -ErrorAction SilentlyContinue

• Validate GUID format (8-4-4-4-12) — built into the script; if invalid, the
  script will resolve by name or throw a friendly error.


TROUBLESHOOTING
---------------
“Invalid object identifier”:
  • The pasted GroupId isn’t a valid GUID (missed dash or wrong segment). Recopy
    from Entra or just pass the display name; the script resolves it.

A non-private browser popped up:
  • You probably ran a different Connect-MgGraph elsewhere. This script opens
    device-code in InPrivate/Incognito only when needed. Close the other window,
    or rely on your EPM launcher first, then run the exporter.

“No valid Graph token/scopes”:
  • Launch the EPM .cmd again to get a fresh private device-code sign-in, then
    re-run the exporter.

Empty CSV:
  • The group may have no members with matching Intune azureADDeviceId, or the
    devices are not present in Intune managedDevices. Try without -StrictMdmOnly
    to see all Intune-tracked agents; check names/Ids in Entra vs Intune.

Counts differ from a dynamic rule using deviceManagementAppId:
  • That rule engine uses AAD device properties. The exporter uses Intune
    managedDevices (definitive for Intune inventory). Devices not present in
    Intune (or without a matching azureADDeviceId) won’t appear in this CSV.


ONE-LINER (LOAD + RUN)
----------------------
From <ToolRoot> after EPM login:
  Remove-Item function:Export-IntuneManagedDevicesFromGroup -ErrorAction SilentlyContinue
  . .\Export-IntuneManagedDevicesFromGroup.ps1
  Export-IntuneManagedDevicesFromGroup -GroupId "<GUID>" -GroupName "<Name>" -StrictMdmOnly


CONTACT / NOTES
---------------
• Keep this README with the scripts in <ToolRoot>.
• If behavior changes after a reboot, re-run the EPM .cmd to refresh the token.
• The script never disconnects or alters tenant/scopes if a usable token exists.
