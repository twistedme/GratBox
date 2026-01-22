<# Private helper: Connect-GraphPrivateSession.ps1
    Purpose: Ensure a valid Graph context with the required scopes.
    Notes:
      - No prompts here; we assume you launched Init-IntuneGraph.ps1 already.
      - We keep a shim (Ensure-GraphPrivate) for backward compatibility, but do NOT export it.
#>

function Connect-GraphPrivateSession {
  [CmdletBinding()]
  param(
    [string[]]$RequiredScopes = @(),
    [string]$TenantHint = '',
    [ValidateSet('edge','chrome')][string]$BrowserPref = 'edge'
  )

  try {
    $ctx = Get-MgContext
  } catch {
    throw "Microsoft.Graph module/context not available. Run Init-IntuneGraph.ps1 first."
  }

  if (-not $ctx -or -not $ctx.Account) {
    throw "No Graph sign-in found. Launch Init-IntuneGraph.ps1 (or connect with Connect-MgGraph) and retry."
  }

  if (-not $RequiredScopes -or $RequiredScopes.Count -eq 0) {
    return  # nothing specific required
  }

  $haveAll = $true
  foreach ($need in $RequiredScopes) {
    if ($ctx.Scopes -notcontains $need -and $ctx.Scopes -notcontains "https://graph.microsoft.com/$need") {
      $haveAll = $false; break
    }
  }
  if (-not $haveAll) {
    # We don't auto-login here to keep this a "no-prompt helper".
    throw ("Current Graph token is missing one or more required scopes: {0}. " +
           "Open an elevated EPM window and run Init-IntuneGraph.ps1, or Connect-MgGraph with the needed scopes.") -f ($RequiredScopes -join ', ')
  }
}