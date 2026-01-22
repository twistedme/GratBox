:: PS-SMART-GratBox-EPM-PRIVATE.cmd  (v2.4)
::
:: SUMMARY
:: - Launches Init-IntuneGraph.ps1 using device-code auth and opens the
::   verification page in a private/incognito browser.
:: - Runtime choices: Prefers PowerShell 7 (pwsh.exe), falls back to Windows PowerShell 5.1.
:: - Module path: Temporarily prepends .\modules so GratBox resolves even if PSModulePath is locked down.
::
:: TENANT resolution order:
::   1) arg1 (tenant domain or TenantId GUID)
::   2) GRATBOX_TENANT env var
::   3) AZURE_TENANT_ID env var
::   4) if none set, Init-IntuneGraph.ps1 will prompt
::
:: DEFAULTS
::   MAXWAIT=60  (minutes)
::
:: OVERRIDES
::   PS-SMART-GratBox-EPM-PRIVATE.cmd [tenant] [maxwait]
::   e.g.  PS-SMART-GratBox-EPM-PRIVATE.cmd contoso.com 90

@echo off
setlocal EnableExtensions

title Graph/Intune Admin (SMART via EPM - Incognito Device Code)

rem ---- Faster startup: silence pwsh “new version available” banner
set POWERSHELL_UPDATECHECK=Off

rem ---- Explicit PowerShell paths
set "PS7=C:\Program Files\PowerShell\7\pwsh.exe"
set "PS5=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PS=%PS7%"

rem ---- Script path & working folder
set "ROOT=%~dp0"
set "SCRIPT=%ROOT%Init-IntuneGraph.ps1"

rem ---- Defaults (overridable by args)
rem --------------------------------------------------------------------
rem TENANT (optional)
rem --------------------------------------------------------------------
rem If you set TENANT here, this launcher will always pass it to Init-IntuneGraph.ps1
rem and you will NOT be prompted for a tenant each time.
rem
rem Examples:
rem   set "TENANT=contoso.com"
rem   set "TENANT=00000000-0000-0000-0000-000000000000"
rem
rem Note: You can still override this at runtime:
rem   PS-SMART-GratBox-EPM-PRIVATE.cmd <tenant> [maxwait]
rem --------------------------------------------------------------------
set "TENANT="
set "MAXWAIT=60"

rem ---- Resolve tenant from env vars (if present)
if "%TENANT%"=="" if not "%GRATBOX_TENANT%"=="" set "TENANT=%GRATBOX_TENANT%"
if "%TENANT%"=="" if not "%AZURE_TENANT_ID%"=="" set "TENANT=%AZURE_TENANT_ID%"

rem ---- Overrides from args
if not "%~1"=="" set "TENANT=%~1"
if not "%~2"=="" set "MAXWAIT=%~2"

rem ---- Validate MAXWAIT is numeric (digits only); else reset to default
echo(%MAXWAIT%| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
  echo [WARN] MaxWaitMinutes must be a number. Using default 60.
  set "MAXWAIT=60"
)

rem ---- Clamp range (1..240)
if %MAXWAIT% LSS 1 set "MAXWAIT=60"
if %MAXWAIT% GTR 240 set "MAXWAIT=240"

rem ---- Prefer PS7 if present; else PS5.1
if not exist "%PS7%" set "PS=%PS5%"

rem ---- Basic validation
if not exist "%PS%" (
  echo [ERROR] PowerShell not found:
  echo         "%PS7%"
  echo         "%PS5%"
  pause
  exit /b 1
)
if not exist "%SCRIPT%" (
  echo [ERROR] Script not found: "%SCRIPT%"
  pause
  exit /b 1
)

rem ---- Make local modules discoverable first (GratBox, etc.)
set "PSMODULES=%ROOT%modules"
set "PSModulePath=%PSMODULES%;%PSModulePath%"

rem ---- Show a quick summary (helpful when EPM hides paths)
echo [INFO] Will open devicelogin in a private/incognito window and print the device code in this console.
echo [INFO] PS  : "%PS%"
echo [INFO] Root: "%ROOT%"
echo [INFO] Script: "%SCRIPT%"
if "%TENANT%"=="" (
  echo [INFO] Tenant: not set here - Init-IntuneGraph.ps1 will prompt
  echo [INFO] Tip: To hard-set the tenant in this launcher, edit this file and set:  set "TENANT=contoso.com"
) else (
  echo [INFO] Tenant: %TENANT%
)
echo [INFO] MaxWaitMinutes: %MAXWAIT%
echo.

rem ---- Run: keep the window open so techs can see the code & status
if "%TENANT%"=="" (
  "%PS%" -NoExit -NoProfile -NoLogo -ExecutionPolicy Bypass ^
    -File "%SCRIPT%" -DeviceCode -PrivateBrowser -MaxWaitMinutes %MAXWAIT%
) else (
  "%PS%" -NoExit -NoProfile -NoLogo -ExecutionPolicy Bypass ^
    -File "%SCRIPT%" -Tenant "%TENANT%" -DeviceCode -PrivateBrowser -MaxWaitMinutes %MAXWAIT%
)

endlocal
