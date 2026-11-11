@echo off
rem Copies PCSetup to a USB drive so it can run on a freshly installed PC.
rem Files in X:\PCSetup are added or updated. Nothing is deleted.
rem Usage: Copy-To-USB.bat [drive letter] [share]
rem "share" leaves out your profile, so the copy starts blank for someone else.
setlocal
set "DRIVE=%~1"
set "SHARE=%~2"
if defined DRIVE goto :have_drive
echo Drives on this PC:
powershell -NoProfile -Command "Get-CimInstance Win32_LogicalDisk | ForEach-Object { '  {0}  {1,-20} {2,8:N0} GB free' -f $_.DeviceID, $_.VolumeName, ($_.FreeSpace/1GB) }"
echo.
set /p "DRIVE=Copy to which drive letter? "
:have_drive
if not defined DRIVE goto :no_drive
set "DRIVE=%DRIVE:~0,1%"
if /i "%DRIVE%:"=="%~d0" (
  echo PCSetup is already on %DRIVE%:. Choose a different drive.
  goto :failed
)
if not exist "%DRIVE%:\" goto :no_drive
if not exist "%~dp0bootstrap\*.msixbundle" echo Note: there is no offline winget copy, so a PC without winget will need internet.
if "%~1"=="" set /p "SHARE=Is this copy for someone else? Type Y to leave out your personal profile, or press Enter to include it: "
set "SKIP="
set "FOLDER=PCSetup"
if /i "%SHARE%"=="share" set "SHARE=Y"
if /i "%SHARE%"=="Y" (
  set "SKIP=profiles"
  set "FOLDER=PCSetup-Shared"
  echo Leaving out your personal profile.
)
set "TARGET=%DRIVE%:\%FOLDER%"
echo Copying to %TARGET% ...
robocopy "%~dp0." "%TARGET%" /E /R:1 /W:1 /NFL /NDL /NP /NJH /XD ".git" "logs" "tests" "sandbox-results" %SKIP% /XF "Copy-To-USB.bat" ".gitignore" "run-state.json" "checklist-state.json" "settings-backup.json"
if %errorlevel% geq 8 (
  echo The copy did not finish. Check that the drive has enough space.
  goto :failed
)
echo.
echo Done. On the new PC, open %TARGET% and double-click Start-PCSetup.bat.
if "%~1"=="" pause
exit /b 0
:no_drive
echo That drive was not found.
:failed
if "%~1"=="" pause
exit /b 1
