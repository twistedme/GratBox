<#
.SYNOPSIS
Add (or sync) Entra group device members from a CSV. GratBox-auth aware.

.DESCRIPTION
Accepts either:
  - A CM export containing 'Microsoft Entra ID Device ID' (deviceId GUIDs), or
  - The Entra portal “Bulk add members” CSV (version:v1.0 + one objectId per line), or
  - A normal CSV with an 'ObjectId' column.

Resolves deviceId -> directory objectId as needed, then adds members that are missing.
With -SyncExact, removes device members that are not present in the CSV.

Outputs a per-row result CSV in reports\Add-GroupMembersFromCsv\.

.PARAMETER CsvPath
Input CSV path.

.PARAMETER GroupId
Target Entra group GUID.

.PARAMETER GroupName
Target Entra group display name (exact match). Use this or -GroupId.

.PARAMETER ObjectIdColumn
If your CSV has objectIds in a column, name it here (default matches Entra bulk header).

.PARAMETER DeviceIdColumn
If your CSV has deviceIds in a column, name it here (default matches your CM export).

.PARAMETER SyncExact
Ensure the group’s DEVICE membership matches the CSV (add + remove). Default is add-only.

.PARAMETER UseDeviceCode, Tenant, Account, BrowserPreference
Auth controls (GratBox private/incognito if available; falls back to Connect-MgGraph).

.PARAMETER OutDir
Optional explicit report folder/file name. Defaults to toolkit reports folder.

.PARAMETER WhatIf
Preview without making changes.

.EXAMPLE
Add-GroupMembersFromCsv -CsvPath .\Wave1.csv -GroupName 'INTUNE-Wave1' -UseDeviceCode

.EXAMPLE
Add-GroupMembersFromCsv -CsvPath .\BulkUpload.csv -GroupId '<group-guid>' -SyncExact -UseDeviceCode
#>
function Add-GroupMembersFromCsv {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact='Medium')]
  param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ })]
    [string]$CsvPath,

    [Parameter(ParameterSetName='ById', Mandatory)]
    [string]$GroupId,

    [Parameter(ParameterSetName='ByName', Mandatory)]
    [string]$GroupName,

    [string]$ObjectIdColumn = 'Member object ID or user principal name [memberObjectIdOrUpn] Required',
    [string]$DeviceIdColumn = 'Microsoft Entra ID Device ID',

    [switch]$SyncExact,

    # Auth (GratBox aware)
    [switch]$UseDeviceCode,
    [string]$Tenant,
    [string]$Account,
    [ValidateSet('edge','chrome','system')]
    [string]$BrowserPreference = 'edge',

    # Output
    [string]$OutDir,

    # Retry
    [int]$MaxRetries = 5,
    [int]$RetryBaseDelaySec = 2
  )

  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'

  # ---- Helpers ----
  $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

  function Invoke-WithRetry {
    param([scriptblock]$Script,[int]$Max=$MaxRetries,[int]$Base=$RetryBaseDelaySec,[string]$Op='operation')
    $n=0; while($n -lt [Math]::Max(1,$Max)) {
      try { return & $Script } catch { $n++; if($n -ge $Max){ throw } ; Start-Sleep -Seconds ([Math]::Min(30,[Math]::Pow(2,$n-1)*$Base)) }
    }
  }

  function Invoke-GratBoxAuth {
  $scopes = @('Directory.Read.All','Group.ReadWrite.All','GroupMember.ReadWrite.All','Device.Read.All')
  if (Get-Command -Name Start-GratBoxPreAuth -ErrorAction SilentlyContinue) {
    $helper = Get-Command Start-GratBoxPreAuth -ErrorAction SilentlyContinue
    $p = @{ Scopes = $scopes }
    if ($Tenant) { $p['Tenant'] = $Tenant }
    if ($UseDeviceCode) {
      if ($helper.Parameters.ContainsKey('DeviceCode'))        { $p['DeviceCode']    = $true }
      elseif ($helper.Parameters.ContainsKey('UseDeviceCode')) { $p['UseDeviceCode'] = $true }
    }
    if ($Account) { $p['Account'] = $Account }
    if ($helper.Parameters.ContainsKey('BrowserPreference') -and $BrowserPreference) { $p['BrowserPreference'] = $BrowserPreference }
    Start-GratBoxPreAuth @p | Out-Null
  } else {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $c = @{ Scopes = $scopes }
    if ($Tenant)       { $c['TenantId']      = $Tenant }
    if ($Account)      { $c['Account']       = $Account }
    if ($UseDeviceCode){ $c['UseDeviceCode'] = $true }
    Connect-MgGraph @c | Out-Null
  }
}


  function Resolve-ReportsPath {
    param([string]$Override)
    if ($Override) {
      $dir = Split-Path -Parent $Override
      if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
      return $Override
    }
    $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $dir = Join-Path $moduleRoot 'reports\Add-GroupMembersFromCsv'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir ("Add-GroupMembersFromCsv-{0}.csv" -f (Get-Date).ToString('yyyyMMdd-HHmmss')))
  }

  function Find-ColumnValue {
    param([hashtable]$Row,[string]$Requested)
    foreach($k in $Row.Keys){ if ($k -eq $Requested -or $k.ToString().Trim().ToLower() -eq $Requested.Trim().ToLower()){ return $Row[$k] } }
    return $null
  }

  function Invoke-GraphGet {
    param([string]$Uri,[hashtable]$Headers)
    Invoke-MgGraphRequest -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop
  }

  function Get-DeviceObjectIdByDeviceId {
    param([string]$DeviceId)
    $headers = @{ 'ConsistencyLevel'='eventual' }
    $didEsc = $DeviceId.Replace("'", "''")
    $uri = "/v1.0/devices?`$select=id,deviceId&`$filter=deviceId eq '$didEsc'&`$count=true"
    try {
      $r = Invoke-GraphGet -Uri $uri -Headers $headers
      if ($r.value -and $r.value.Count -gt 0) { return $r.value[0].id }
    } catch { }
    return $null
  }

  function Resolve-GroupId {
    param([string]$Id,[string]$Name)
    if ($Id) { return $Id }
    $n = $Name.Replace("'","''")
    $r = Invoke-MgGraphRequest -Method GET -Uri "/v1.0/groups?`$select=id,displayName,groupTypes,securityEnabled,membershipRule&`$filter=displayName eq '$n'" -ErrorAction Stop
    if (-not $r.value -or $r.value.Count -eq 0) { throw "Group '$Name' not found." }
    if ($r.value.Count -gt 1) { Write-Warning "Multiple groups named '$Name'. Using the first match (id=$($r.value[0].id))." }
    $g = $r.value[0]
    # guardrail: dynamic groups cannot have direct members managed this way
    if ($g.membershipRule) { throw "Group '$($g.displayName)' is dynamic (has a membershipRule). This function manages direct members only." }
    if (-not $g.securityEnabled) { Write-Warning "Group '$($g.displayName)' is not securityEnabled. Intune assignments typically use Security groups." }
    return $g.id
  }

  function Get-GroupDeviceMemberIds {
    param([string]$Id)
    $ids = @()
    $next = "/v1.0/groups/$Id/members/microsoft.graph.device?`$select=id&`$top=999"
    while ($next) {
      $r = Invoke-MgGraphRequest -Method GET -Uri $next -ErrorAction Stop
      if ($r.value) { $ids += ($r.value | ForEach-Object { $_.id }) }
      $next = $r.'@odata.nextLink'
    }
    return $ids
  }

  function Add-GroupMember {
    param([string]$GroupId,[string]$ObjectId)
    $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$ObjectId" }
    Invoke-WithRetry -Op "Add member $ObjectId" -Script {
      Invoke-MgGraphRequest -Method POST -Uri "/v1.0/groups/$GroupId/members/`$ref" -Body ($body | ConvertTo-Json) -ErrorAction Stop
    } | Out-Null
  }

  function Remove-GroupMember {
    param([string]$GroupId,[string]$ObjectId)
    Invoke-WithRetry -Op "Remove member $ObjectId" -Script {
      Invoke-MgGraphRequest -Method DELETE -Uri "/v1.0/groups/$GroupId/members/$ObjectId/`$ref" -ErrorAction Stop
    } | Out-Null
  }
  # ---- end helpers ----

  Start-GraphAuth
  $gid = Resolve-GroupId -Id $GroupId -Name $GroupName
  $reportPath = Resolve-ReportsPath -Override $OutDir

  # Decide how to read input: portal-style vs CSV with columns
  $firstTwo = Get-Content -LiteralPath $CsvPath -TotalCount 2
  $desiredObjectIds = @()

  if ($firstTwo.Count -gt 0 -and $firstTwo[0].Trim().ToLower().StartsWith('version:')) {
    # Entra portal bulk CSV
    $desiredObjectIds = Get-Content -LiteralPath $CsvPath | Select-Object -Skip 2 | Where-Object { $_ -match $guid } | ForEach-Object { $_.Trim() }
  } else {
    $rows = Import-Csv -LiteralPath $CsvPath
    if (-not $rows -or $rows.Count -eq 0) { throw "The CSV at '$CsvPath' contained no rows." }

    # Case-insensitive lookups
    foreach ($row in $rows) {
      $h=@{}; foreach($p in $row.PSObject.Properties){ $h[$p.Name]=$p.Value }
      $oid = (Find-ColumnValue -Row $h -Requested $ObjectIdColumn) -as [string]
      $did = (Find-ColumnValue -Row $h -Requested $DeviceIdColumn) -as [string]

      if ($oid -and $oid.Trim() -match $guid) {
        $desiredObjectIds += $oid.Trim()
      } elseif ($did -and $did.Trim() -match $guid) {
        $obj = Get-DeviceObjectIdByDeviceId -DeviceId $did.Trim()
        if ($obj) { $desiredObjectIds += $obj }
      }
    }
  }

  $desiredObjectIds = $desiredObjectIds | Sort-Object -Unique
  if (-not $desiredObjectIds -or $desiredObjectIds.Count -eq 0) { throw "No valid objectIds could be resolved from '$CsvPath'." }

  # Current device members
  $currentDeviceIds = Get-GroupDeviceMemberIds -Id $gid

  if ($SyncExact) {
    $toAdd    = Compare-Object -ReferenceObject $currentDeviceIds -DifferenceObject $desiredObjectIds -PassThru | Where-Object { $_ -in $desiredObjectIds }
    $toRemove = Compare-Object -ReferenceObject $desiredObjectIds -DifferenceObject $currentDeviceIds -PassThru | Where-Object { $_ -in $currentDeviceIds }
  } else {
    $toAdd    = Compare-Object -ReferenceObject $currentDeviceIds -DifferenceObject $desiredObjectIds -PassThru | Where-Object { $_ -in $desiredObjectIds }
    $toRemove = @()  # add-only
  }

  # Progress + actions
  $results = New-Object System.Collections.Generic.List[object]
  $totalOps = ($toAdd.Count + $toRemove.Count)
  $done = 0

  foreach ($id in $toAdd) {
    $done++; $pct=[int](($done / [Math]::Max(1,$totalOps)) * 100)
    Write-Progress -Id 1 -Activity "Adding members" -Status "$done of $totalOps" -PercentComplete $pct

    $row = [ordered]@{ Action='Add'; ObjectId=$id; Result='Success'; Error=$null }
    try {
      if ($PSCmdlet.ShouldProcess("Group $gid","Add $id")) { Add-GroupMember -GroupId $gid -ObjectId $id }
    } catch { $row.Result='Error'; $row.Error=$_.Exception.Message }
    $results.Add([pscustomobject]$row) | Out-Null
  }

  foreach ($id in $toRemove) {
    $done++; $pct=[int](($done / [Math]::Max(1,$totalOps)) * 100)
    Write-Progress -Id 1 -Activity "Removing extra members (SyncExact)" -Status "$done of $totalOps" -PercentComplete $pct

    $row = [ordered]@{ Action='Remove'; ObjectId=$id; Result='Success'; Error=$null }
    try {
      if ($PSCmdlet.ShouldProcess("Group $gid","Remove $id")) { Remove-GroupMember -GroupId $gid -ObjectId $id }
    } catch { $row.Result='Error'; $row.Error=$_.Exception.Message }
    $results.Add([pscustomobject]$row) | Out-Null
  }

  # Write report
  $results | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8

  # Summary
  $added  = ($results | Where-Object { $_.Action -eq 'Add'     -and $_.Result -eq 'Success' }).Count
  $rmv    = ($results | Where-Object { $_.Action -eq 'Remove'  -and $_.Result -eq 'Success' }).Count
  $errors = ($results | Where-Object { $_.Result -eq 'Error' }).Count

  Write-Host ("Group: {0} | Desired: {1} | Added: {2} | Removed: {3} | Errors: {4} | Report: {5}" -f $gid,$desiredObjectIds.Count,$added,$rmv,$errors,$reportPath)
}


