function Get-GratBoxPath {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Logs','Reports')]
        [string]$Type
    )

    $root = $null

    # Safely detect portable root if defined
    $var = Get-Variable -Name GratBoxRoot -Scope Script -ErrorAction SilentlyContinue
    if ($var -and $var.Value -and (Test-Path $var.Value)) {
        $root = $var.Value
    }
    else {
        # Installed module fallback
        $root = Join-Path $env:LOCALAPPDATA 'GratBox'
    }

    $path = Join-Path $root $Type

    if (-not (Test-Path $path)) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
    }

    return $path
}
