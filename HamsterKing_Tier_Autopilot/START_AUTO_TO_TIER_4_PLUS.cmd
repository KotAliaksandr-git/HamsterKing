@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Hamster King Tier Autopilot - All Tier 1 to Tier 4 Plus

set "APP_DIR=%~dp0"
set "SCRIPT=%APP_DIR%HK_Tier_Autopilot_v1_20.ps1"
set "SETTINGS=%APP_DIR%settings.json"
set "LOG_DIR=%APP_DIR%logs"
set "LAUNCH_LOG=%LOG_DIR%launcher_error.log"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "HK_TARGET=tier4plus"

if not exist "%SCRIPT%" goto :incomplete
if not exist "%SETTINGS%" goto :incomplete
for %%F in ("%SCRIPT%") do if %%~zF LSS 10000 goto :incomplete
for %%F in ("%SETTINGS%") do if %%~zF LSS 10 goto :incomplete
if not exist "%PS_EXE%" goto :no_powershell
cd /d "%APP_DIR%" 2>nul
if errorlevel 1 goto :bad_folder
if not exist "%LOG_DIR%\" mkdir "%LOG_DIR%" >nul 2>&1
if not exist "%LOG_DIR%\" goto :bad_log_folder

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode all -TargetTier "%HK_TARGET%"
set "HK_EXIT=%ERRORLEVEL%"
if "%HK_EXIT%"=="0" (
    endlocal
    exit /b 0
)

>>"%LAUNCH_LOG%" echo [%date% %time%] PowerShell failed. Exit code: %HK_EXIT%. Mode=all TargetTier=%HK_TARGET%
echo.
echo ERROR: Autopilot could not start. PowerShell exit code: %HK_EXIT%.
echo Read the PowerShell error above and send a screenshot together with:
echo "%LAUNCH_LOG%"
echo.
pause
endlocal & exit /b %HK_EXIT%

:incomplete
echo.
echo ERROR: Required program files are missing or incomplete.
echo Use Extract All and do not copy files over an older version.
echo Required files:
echo "%SCRIPT%"
echo "%SETTINGS%"
echo.
pause
endlocal & exit /b 10

:no_powershell
echo.
echo ERROR: Windows PowerShell 5.1 was not found:
echo "%PS_EXE%"
echo.
pause
endlocal & exit /b 11

:bad_folder
echo.
echo ERROR: Cannot open the program folder:
echo "%APP_DIR%"
echo.
pause
endlocal & exit /b 12

:bad_log_folder
echo.
echo ERROR: Cannot create the logs folder:
echo "%LOG_DIR%"
echo Move the extracted program to a writable folder and try again.
echo.
pause
endlocal & exit /b 13
