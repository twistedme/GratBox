function New-EntraSecurityGroup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$DisplayName
    )

    $group = New-MgGroup `
        -DisplayName     $DisplayName `
        -SecurityEnabled `
        -MailEnabled:$false `
        -MailNickname   ([Guid]::NewGuid().ToString())

    return [pscustomobject]@{
        Name = $group.DisplayName
        Id   = $group.Id
    }
}
