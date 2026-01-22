:: PS-SMART-GratBox-MAINTENANCE.cmd  (v1.1)
::
:: SUMMARY
:: - Launches PowerShell in **GratBox Maintenance Mode** (no Graph auth).
:: - Intended for checking/updating vendored modules under the GratBox root.
:: - Prefers PowerShell 7 (pwsh.exe); falls back to Windows PowerShell 5.1.
:: - Prepends "%~dp0modules" to PSModulePath so GratBox resolves reliably.
::
:: REQUIREMENTS
:: - This CMD should live in the GratBox root folder, next to:
::     Init-GratBoxMaintenance.ps1
::
:: TIPS
:: - Run as administrator (EPM or standard elevation) for best results.
:: - In maintenance mode you can run:
::     Get-GratBox3pStatus
::     Update-GratBox3p -Latest
:: - When done, run:
::     Start-GratBoxOperational

@echo off
setlocal EnableExtensions

title Graph/Intune Admin (SMART - Maintenance)

rem ---- Faster startup: silence pwsh “new version available” banner
set POWERSHELL_UPDATECHECK=Off

rem ---- Explicit PowerShell paths
set "PS7=C:\Program Files\PowerShell\7\pwsh.exe"
set "PS5=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PS=%PS7%"

rem ---- Script path & working folder (portable)
set "ROOT=%~dp0"
set "SCRIPT=%ROOT%Init-GratBoxMaintenance.ps1"

rem ---- Prefer PS7 if present; else PS5.1
if not exist "%PS7%" set "PS=%PS5%"

rem ---- Validation
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

rem ---- Elevation hint (non-blocking)
net session >nul 2>&1
if errorlevel 1 (
  echo [WARN] Not running elevated. Right-click and "Run as administrator" if updates fail.
)

rem ---- Make local modules discoverable first
set "PSMODULES=%ROOT%modules"
set "PSModulePath=%PSMODULES%;%PSModulePath%"

rem ---- Show a quick summary
echo [INFO] GratBox MAINTENANCE MODE (no Graph auth).
echo [INFO] PS     : "%PS%"
echo [INFO] Root   : "%ROOT%"
echo [INFO] Script : "%SCRIPT%"
echo.

rem ---- Run: keep the window open so techs can see output
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit ^
  -File "%SCRIPT%"

endlocal
