$script:MaxWaves = 25
# Single source of truth for WaveCount cap. cannot be used directly in ValidateRange

<#
.SYNOPSIS
Creates Entra ID security groups representing migration waves and
generates a CSV report script for Intune device export reporting.

.DESCRIPTION
New-GratBoxMigrationWaveSet prompts for a base group name and number
of migration waves, creates Entra ID security groups for each wave,
and generates a PowerShell script in the GratBox Scripts directory
to export Intune-managed devices from each wave group to CSV.

The generated CSV report script uses static Entra group IDs and is intended to be
run by technicians after devices are assigned to the wave groups.

This command is designed for use with the GratBox EPM-safe toolbox
and does not perform authentication itself.

.PARAMETER BaseName
Base display name used for each migration wave group.
Example:
  IN-DEVICE-CM to Intune Wave

.PARAMETER WaveCount
Number of migration wave groups to create.
Allowed range is 1..25 (see $script:MaxWaves at top of file) (safety guard to prevent accidental huge runs).

.PARAMETER GroupSuffix
Suffix appended to each group name.
Default is "_GROUP".

.PARAMETER ReuseExisting
If specified:
- Existing groups with the same display name are automatically reused (oldest CreatedDateTime).
- If the CSV report script exists, it is automatically updated (canonical behavior).

Without -ReuseExisting:
- If a group exists, the user is prompted to reuse the oldest match or create a duplicate group.
- If the CSV report script exists, the user is prompted to create a timestamped copy or overwrite.

.EXAMPLE
New-GratBoxMigrationWaveSet
Prompts for input interactively and creates migration wave groups.

.EXAMPLE
New-GratBoxMigrationWaveSet -BaseName "IN-DEVICE-CM to Intune Wave" -WaveCount 3
Creates three migration wave groups and generates a CSV report script.

.EXAMPLE
New-GratBoxMigrationWaveSet -BaseName "IN-DEVICE-CM to Intune Wave" -WaveCount 6 -ReuseExisting
Reuses existing groups (if found) and creates only missing waves. Updates the existing CSV report script.

.NOTES
- Version: 1.5.1
- LastUpdated: 2026-01-08
- Entra ID allows duplicate group display names.
- Duplicate-name detection uses Get-MgGroup and is "best effort" (Graph throttling/consistency can cause transient failures).
- If lookup fails for a wave, the command prompts whether to create a new group without duplicate confirmation.
- This command REQUIRES a working Graph auth context; it validates token acquisition before doing work.
#>

function New-GratBoxMigrationWaveSet {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [string]$BaseName,

        # Safety guard: prevents accidental huge wave counts (e.g. 999999)
        [ValidateScript({
            if ($_ -lt 1 -or $_ -gt $script:MaxWaves) {
                throw "WaveCount must be between 1 and $script:MaxWaves. (Safety cap)"
            }
            $true
        })]
        [int]$WaveCount,

        [string]$GroupSuffix = "_GROUP",
        [switch]$ReuseExisting
    )

    if (-not $BaseName) {
        $BaseName = Read-Host "Enter base group name (example: IN-DEVICE-CM to Intune Wave)"
    }

    if (-not $WaveCount) {
        $WaveCount = [int](Read-Host "Enter total number of waves (1-$($script:MaxWaves)). Note: capped at $($script:MaxWaves). See: Get-Help New-GratBoxMigrationWaveSet -Full")
    }

    # ---------------------------------------------------------------------
    # REQUIRED: Graph connection (and working token acquisition)
    # ---------------------------------------------------------------------
    $ctx = $null
    try { $ctx = Get-MgContext -ErrorAction Stop } catch { $ctx = $null }

    if (-not $ctx -or -not $ctx.Account) {
        throw "Not connected to Microsoft Graph. Run Init-IntuneGraph.ps1 (device-code login) or Start-GratBoxOperational, then retry."
    }

    # Context existing isn't enough — verify token acquisition works now.
    try {
        Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/organization?`$top=1" -ErrorAction Stop | Out-Null
    }
    catch {
        throw ("Graph authentication context exists (Get-MgContext), but token acquisition failed in this session. " +
               "Close this PowerShell window and relaunch GratBox (device-code login), then retry. " +
               "Underlying error: {0}" -f $_.Exception.Message)
    }

    # ---------------------------------------------------------------------
    # Best-effort duplicate detection readiness
    # ---------------------------------------------------------------------
    $dupCheckEnabled = $true
    $dupCheckWarned  = $false

    if (-not (Get-Command Get-MgGroup -ErrorAction SilentlyContinue)) {
        try {
            Import-Module Microsoft.Graph.Groups -ErrorAction Stop | Out-Null
        }
        catch {
            $dupCheckEnabled = $false
            Write-Warning "Duplicate-name detection is unavailable (failed to import Microsoft.Graph.Groups). Groups will be created without duplicate checks."
            Write-Warning "Created groups WILL be added to the CSV report script."
        }
    }

    Write-Host "[INFO] Creating migration wave groups..." -ForegroundColor Cyan

    # Holds BOTH reused and newly created groups (must contain Name + Id for script gen)
    $waveGroups = @()

    for ($i = 1; $i -le $WaveCount; $i++) {

        $groupName   = "$BaseName $i$GroupSuffix"
        $useExisting = $null
        $existing    = @()

        # -------------------------------------------------------------
        # Duplicate detection
        # - Retry per-wave (does NOT disable future waves)
        # - Quiet when none exist
        # - If lookup fails for this wave: prompt Y/N to create without duplicate confirmation
        # - If duplicates exist: prefer oldest CreatedDateTime when reusing
        # -------------------------------------------------------------
        if ($dupCheckEnabled) {

            # OData escape single quotes by doubling them
            $escapedName = $groupName -replace "'", "''"

            # More Graph-friendly retry: exponential backoff + jitter
            $maxTries  = 10
            $baseDelay = 3     # seconds
            $maxDelay  = 90    # seconds cap

            $lookupSucceeded = $false
            $existing = @()

            for ($t = 1; $t -le $maxTries; $t++) {
                try {
                    $existing = Get-MgGroup -Filter "displayName eq '$escapedName'" -All `
                        -Property "id,displayName,createdDateTime" -ErrorAction Stop
                    $lookupSucceeded = $true
                    break
                }
                catch {
                    if ($t -eq $maxTries) { break }

                    # exponential: baseDelay * 2^(t-1), capped
                    $delay = [Math]::Min($maxDelay, $baseDelay * [Math]::Pow(2, ($t - 1)))

                    # jitter: +/- up to 30% (randomizes retry timing)
                    $jitterFactor = Get-Random -Minimum 0.7 -Maximum 1.3
                    $sleepSeconds = [int]([Math]::Round($delay * $jitterFactor))

                    Start-Sleep -Seconds $sleepSeconds
                }
            }

            # ---------------------------------------------------------
            # Prompt block: lookup failed (unknown)
            # ---------------------------------------------------------
            if (-not $lookupSucceeded) {

                if (-not $dupCheckWarned) {
                    $dupCheckWarned = $true
                    Write-Warning "Duplicate-name lookup hit a transient failure during this run. Some waves may proceed without duplicate checks."
                }

                Write-Warning "If you choose N, wave $i group '$groupName' is NOT created and will NOT be added to the CSV report script."
                $choice = Read-Host "Lookup failed for wave $i. Create a NEW group without duplicate confirmation? (Y/N) (default: N)"
                $createWithoutConfirmation = ($choice -and $choice.Trim().ToUpper().StartsWith('Y'))

                if (-not $createWithoutConfirmation) {
                    Write-Warning "Skipping wave $i group creation due to lookup failure: '$groupName'."
                    Write-Warning "This group will NOT be added to the CSV report script. Verify groups manually if needed."
                    continue
                }
                else {
                    Write-Warning "Creating without duplicate confirmation. This may create a duplicate display name."
                    # proceed to create
                }
            }
            else {
                $existingList = @($existing)  # force array

                if ($existingList.Count -gt 0) {

                    Write-Warning "Found $($existingList.Count) existing Entra ID group(s) with display name '$groupName'."

                    # Prefer oldest created group (the “original”)
                    $oldest = $existingList | Sort-Object @{
                        Expression = {
                            if ($_.CreatedDateTime) { [datetime]$_.CreatedDateTime }
                            else { [datetime]::MaxValue }
                        }
                    } | Select-Object -First 1

                    if ($ReuseExisting) {
                        $useExisting = $oldest
                        Write-Host "[INFO] Reusing oldest existing group for this wave (Id: $($useExisting.Id))." -ForegroundColor Yellow
                    }
                    else {
                        # -------------------------------------------------
                        # Prompt block: duplicates exist (known)
                        # -------------------------------------------------
                        Write-Warning "If you choose N, a new group will NOT be created and the oldest existing group will be used in the CSV report script."
                        $choice = Read-Host "Group name already exists for wave $i. Create a DUPLICATE group? (Y/N) (default: N)"
                        $createDuplicate = ($choice -and $choice.Trim().ToUpper().StartsWith('Y'))

                        if ($createDuplicate) {
                            Write-Warning "Creating a duplicate display name group. This will create a NEW Entra group object ID (with same display name)."
                            # proceed to create new
                        }
                        else {
                            $useExisting = $oldest
                            Write-Host "[INFO] Using oldest existing group to add to CSV report script (Id: $($useExisting.Id))." -ForegroundColor Yellow
                        }
                    }
                }
                # If Count = 0 => do nothing (no warning)
            }
        }

        # If we decided to reuse, capture it and continue
        if ($useExisting) {
            $waveGroups += [pscustomobject]@{
                Name = $useExisting.DisplayName
                Id   = $useExisting.Id
            }
            continue
        }

        # -------------------------------------------------------------
        # Create new group
        # -------------------------------------------------------------
        if ($PSCmdlet.ShouldProcess($groupName, "Create Entra ID security group")) {

            try {
                $group = New-EntraSecurityGroup -DisplayName $groupName
            }
            catch {
                throw ("Failed to create group '{0}'. Underlying error: {1}" -f $groupName, $_.Exception.Message)
            }

            if (-not $group -or -not $group.Id) {
                throw "Failed to create group '$groupName'. Ensure you are authenticated and have permission to create groups."
            }

            $waveGroups += $group

            $display = $null
            if ($group.PSObject.Properties.Match('Name').Count -gt 0) { $display = $group.Name }
            elseif ($group.PSObject.Properties.Match('DisplayName').Count -gt 0) { $display = $group.DisplayName }
            else { $display = $groupName }

            Write-Host "[OK] $display" -ForegroundColor Green
        }
    }

    if (-not $waveGroups -or $waveGroups.Count -eq 0) {
        throw "No groups were created or reused; CSV report script will not be generated."
    }

    New-GenerateCSVReportScript `
        -BaseName $BaseName `
        -Groups   $waveGroups `
        -ReuseExisting:$ReuseExisting

    Write-Host "[INFO] Migration wave set creation complete." -ForegroundColor Cyan

    return $waveGroups
}
