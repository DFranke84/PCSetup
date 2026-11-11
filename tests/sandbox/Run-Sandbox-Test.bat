@echo off
rem Runs the end-to-end test on a clean Windows inside Windows Sandbox.
rem It does real installs and setting changes, but only inside the Sandbox.
rem The report is written to the sandbox-results folder. "nostart" only writes the Sandbox file.
setlocal
for %%I in ("%~dp0..\..") do set "APP=%%~fI"
for %%I in ("%APP%") do set "LEAF=%%~nxI"
if not exist "%APP%\sandbox-results" mkdir "%APP%\sandbox-results"
set "WSB=%TEMP%\PCSetup-Test.wsb"
> "%WSB%" echo ^<Configuration^>
>> "%WSB%" echo   ^<VGpu^>Disable^</VGpu^>
>> "%WSB%" echo   ^<Networking^>Default^</Networking^>
>> "%WSB%" echo   ^<MappedFolders^>
>> "%WSB%" echo     ^<MappedFolder^>^<HostFolder^>%APP%^</HostFolder^>^<ReadOnly^>true^</ReadOnly^>^</MappedFolder^>
>> "%WSB%" echo     ^<MappedFolder^>^<HostFolder^>%APP%\sandbox-results^</HostFolder^>^<ReadOnly^>false^</ReadOnly^>^</MappedFolder^>
>> "%WSB%" echo   ^</MappedFolders^>
>> "%WSB%" echo   ^<LogonCommand^>
>> "%WSB%" echo     ^<Command^>powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File C:\Users\WDAGUtilityAccount\Desktop\%LEAF%\tests\sandbox\Run-InSandbox.ps1^</Command^>
>> "%WSB%" echo   ^</LogonCommand^>
>> "%WSB%" echo ^</Configuration^>
if /i "%~1"=="nostart" exit /b 0
if not exist "%SystemRoot%\System32\WindowsSandbox.exe" (
  echo Windows Sandbox is not turned on. Turn it on under "Turn Windows features on or off", restart, and run this again.
  pause
  exit /b 1
)
start "" "%WSB%"
