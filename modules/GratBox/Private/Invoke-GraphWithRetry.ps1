function Invoke-GraphWithRetry {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateSet('GET','POST','PATCH','DELETE','PUT')]
    [string]$Method,

    [Parameter(Mandatory)]
    [string]$Uri,

    [hashtable]$Headers,

    [object]$Body,

    [int]$MaxRetries = 5,
    [int]$BaseDelaySec = 2,
    [int]$MaxDelaySec = 60
  )

  $attempt = 0

  # Get access token from current Graph session
  $ctx = Get-MgContext
  if (-not $ctx -or -not $ctx.AccessToken) {
    throw 'No active Microsoft Graph session found.'
  }

  $authHeader = @{
    Authorization = "Bearer $($ctx.AccessToken)"
  }

  if ($Headers) {
    foreach ($key in $Headers.Keys) {
      $authHeader[$key] = $Headers[$key]
    }
  }

  while ($true) {
    $attempt++

    try {
      $params = @{
        Method  = $Method
        Uri     = $Uri
        Headers = $authHeader
      }

      if ($Body -ne $null) {
        $params['Body']        = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $params['ContentType'] = 'application/json'
      }

      return Invoke-RestMethod @params -ErrorAction Stop

    } catch {
      $msg = $_.Exception.Message

      $retryable = $msg -match '429|5\d\d|timeout|temporar|throttl|ServiceUnavailable|GatewayTimeout|BadGateway'

      if ($retryable -and $attempt -lt $MaxRetries) {
        $delay = [Math]::Min(
          $MaxDelaySec,
          $BaseDelaySec * [Math]::Pow(2, ($attempt - 1))
        )

        Start-Sleep -Seconds ([int]$delay)
        continue
      }

      throw
    }
  }
}
