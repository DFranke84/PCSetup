# Running one step at a time: winget commands and your own setup files, plus restart-and-resume.
# Everything that launches a program or restarts the PC is in this file.

$script:StepLimitMinutes = 90
$script:RunOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$script:RunOnceName = 'PCSetupResume'

function New-RunStep {
    param([string]$Key, [string]$Name, [string]$Kind, [string]$File, [string]$Arguments)
    return [pscustomobject]@{ Key = $Key; Name = $Name; Kind = $Kind; File = $File; Arguments = $Arguments; Attempts = 0; Result = ''; Note = '' }
}

function New-WingetStep {
    param([string]$Key, [string]$Name, [ValidateSet('install', 'upgrade', 'pin', 'unpin')][string]$Kind)
    return New-RunStep -Key $Key -Name $Name -Kind $Kind -File 'winget' -Arguments (Get-WingetArguments -Id $Key -Verb $Kind)
}

function New-SetupStep {
    # An .msi can run with a progress bar only. An .exe opens its own normal setup window.
    param([string]$Key, [string]$Name, [string]$Path)
    if ([IO.Path]::GetExtension($Path) -eq '.msi') {
        return New-RunStep -Key $Key -Name $Name -Kind 'setup' -File 'msiexec.exe' -Arguments "/i `"$Path`" /passive /norestart"
    }
    return New-RunStep -Key $Key -Name $Name -Kind 'setup' -File $Path -Arguments ''
}

function Start-StepProcess {
    param($Step)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Step.File
    $info.Arguments = $Step.Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = [System.Diagnostics.Process]::Start($info)
    return @{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() }
}

function Test-StepFinished {
    param($Handle)
    return $Handle.Process.HasExited
}

function Get-StepResult {
    # A program left running by an installer can hold the output open, so the wait is short.
    param($Handle)
    $text = ''
    foreach ($task in $Handle.Out, $Handle.Err) { if ($task.Wait(2000)) { $text += $task.Result } }
    return [pscustomobject]@{ ExitCode = $Handle.Process.ExitCode; Output = $text }
}

function Stop-StepProcess {
    # Includes the installer the step started.
    param($Handle)
    if (-not $Handle.Process.HasExited) { & taskkill.exe /PID $Handle.Process.Id /T /F 2>&1 | Out-Null }
}

function Get-LastOutputLines {
    # Skips winget's progress bars and spinners.
    param([string]$Output, [int]$Count = 10)
    $lines = @($Output -split "[\r\n]+" | Where-Object { $_.Trim() -and $_ -notmatch '^[\s\-\\|/]+$' -and $_ -notmatch '[^\x00-\x7F]{3,}' })
    return @($lines | Select-Object -Last $Count)
}

function Get-StepOutcome {
    # Winget's meanings come from "winget error". 3010 and 1641 are the Windows Installer restart codes.
    param([string]$Kind, [int]$ExitCode)
    $make = { param($r, $m) [pscustomobject]@{ Result = $r; Message = $m } }
    if ($ExitCode -eq 0) { return & $make 'Done' '' }
    if ($ExitCode -in 3010, 1641) { return & $make 'NeedsRestart' 'Restart your PC to finish.' }
    if ($Kind -eq 'setup') {
        if ($ExitCode -eq 1602) { return & $make 'Failed' 'Setup was cancelled.' }
        return & $make 'Failed' "Setup ended with code $ExitCode."
    }
    $hex = '0x{0:X8}' -f $ExitCode
    switch ($hex) {
        '0x8A150109' { return & $make 'NeedsRestart' 'Restart your PC to finish.' }
        '0x8A15010B' { return & $make 'NeedsRestart' 'The installer is restarting your PC.' }
        '0x8A15010A' { return & $make 'RestartFirst' 'Needs a restart before it can install.' }
        '0x8A15002B' { return & $make 'Done' 'No newer version applies to this PC.' }
        '0x8A150061' { return & $make 'Done' 'Already installed.' }
        '0x8A15010D' { return & $make 'Done' 'Already installed.' }
        '0x8A15010E' { return & $make 'Done' 'A newer version is already installed.' }
        '0x8A150062' { return & $make 'Done' 'It was already locked.' }
        '0x8A150063' { return & $make 'Done' 'It was already unlocked.' }
        '0x8A150101' { return & $make 'Failed' 'The app is running. Close it and try again.' }
        '0x8A150103' { return & $make 'Failed' 'A file is in use. Close the app and try again.' }
        '0x8A150102' { return & $make 'Failed' 'Another installation was in progress.' }
        '0x8A150107' { return & $make 'Failed' 'No internet connection.' }
        '0x8A15010C' { return & $make 'Failed' 'The installation was cancelled.' }
    }
    return & $make 'Failed' "Winget ended with code $hex."
}

function Get-StepWord {
    param([string]$Kind, [ValidateSet('running', 'done')][string]$Phase)
    $words = @{
        install = @('Installing', 'Installed'); upgrade = @('Updating', 'Updated'); setup = @('Running setup', 'Setup finished')
        pin = @('Locking', ''); unpin = @('Unlocking', '')
    }
    return $words[$Kind][$(if ($Phase -eq 'running') { 0 } else { 1 })]
}

function Write-RunState {
    param([string]$Title, $Steps)
    $state = @{ title = $Title; steps = @($Steps | Select-Object Key, Name, Kind, File, Arguments, Attempts) }
    ConvertTo-Json -InputObject $state -Depth 4 | Set-Content -LiteralPath $script:RunStatePath -Encoding UTF8
}

function Read-RunState {
    # A damaged file is treated as no saved run.
    if (-not (Test-Path -LiteralPath $script:RunStatePath)) { return $null }
    try {
        $state = Get-Content -LiteralPath $script:RunStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (@($state.steps).Count -eq 0) { return $null }
        return $state
    } catch { return $null }
}

function Clear-RunState {
    if (Test-Path -LiteralPath $script:RunStatePath) { Remove-Item -LiteralPath $script:RunStatePath -Force }
}

function Set-ResumeAtStartup {
    # Windows removes a RunOnce entry when it starts it, so this fires once per restart.
    if (-not (Test-Path -Path $script:RunOncePath)) { [void](New-Item -Path $script:RunOncePath -Force) }
    $command = '"' + (Join-Path $script:Root 'Start-PCSetup.bat') + '" /resume'
    [void](New-ItemProperty -Path $script:RunOncePath -Name $script:RunOnceName -Value $command -PropertyType String -Force)
}

function Clear-ResumeAtStartup {
    Remove-ItemProperty -Path $script:RunOncePath -Name $script:RunOnceName -ErrorAction SilentlyContinue
}

function Invoke-PCRestart {
    & shutdown.exe /r /t 15 /c "PCSetup is restarting this PC."
}

# --- Winget repair for a fresh Windows install

$script:WingetFamily = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
$script:WingetReleaseApi = 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'

function Add-WingetToPath {
    $dir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if (($env:Path -split ';') -notcontains $dir) { $env:Path += ";$dir" }
}

function Test-WingetWorks {
    Add-WingetToPath
    try {
        $text = (& winget --version 2>$null | Out-String).Trim()
        return ($LASTEXITCODE -eq 0 -and $text -match '^v\d')
    } catch { return $false }
}

function Find-WingetPackages {
    # Returns the newest offline files in a folder, or nothing if a required one is missing.
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return $null }
    $newest = { param($filter) Get-ChildItem -LiteralPath $Dir -Filter $filter -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
    $bundle = & $newest '*.msixbundle'
    $deps = & $newest '*Dependencies.zip'
    $license = & $newest '*License1.xml'
    if (-not $bundle -or -not $deps) { return $null }
    return @{ Bundle = $bundle.FullName; Dependencies = $deps.FullName; License = $(if ($license) { $license.FullName }) }
}

function Save-WingetPackages {
    # Downloads the current winget files from Microsoft's release page.
    param([string]$Dir)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'   # The progress display makes large downloads far slower.
    if (-not (Test-Path -LiteralPath $Dir)) { [void](New-Item -ItemType Directory -Path $Dir -Force) }
    $release = Invoke-RestMethod -UseBasicParsing -Uri $script:WingetReleaseApi -Headers @{ 'User-Agent' = 'PCSetup' }
    $assets = @($release.assets | Where-Object { $_.name -like '*.msixbundle' -or $_.name -like '*Dependencies.zip' -or $_.name -like '*License1.xml' })
    if ($assets.Count -lt 3) { throw 'The winget release did not list the expected files.' }
    foreach ($asset in $assets) {
        $target = Join-Path $Dir $asset.name
        if ((Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Length -eq $asset.size) { continue }
        $part = "$target.part"
        Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $part
        if ((Get-Item -LiteralPath $part).Length -ne $asset.size) { throw "$($asset.name) did not download completely." }
        Move-Item -LiteralPath $part -Destination $target -Force
    }
    return $release.tag_name
}

function Get-WingetDependencyPaths {
    # Unpacks the dependency zip and returns the packages for this PC's processor type.
    param([string]$ZipPath, [string]$WorkDir, [string]$Architecture = $env:PROCESSOR_ARCHITECTURE)
    $folder = switch ($Architecture) { 'AMD64' { 'x64' } 'ARM64' { 'arm64' } default { 'x86' } }
    $out = Join-Path $WorkDir 'dependencies'
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $out -Force
    $files = @(Get-ChildItem -LiteralPath (Join-Path $out $folder) -File | Where-Object { $_.Extension -in '.appx', '.msix' } | ForEach-Object FullName)
    if ($files.Count -eq 0) { throw "No $folder packages were found in the dependency zip." }
    return , $files
}

function Invoke-AppxRegister { Add-AppxPackage -RegisterByFamilyName -MainPackage $script:WingetFamily -ErrorAction Stop }

function Invoke-AppxInstall {
    param([string]$Bundle, [string[]]$Dependencies)
    Add-AppxPackage -Path $Bundle -DependencyPath $Dependencies -ForceApplicationShutdown -ErrorAction Stop
}

function Invoke-AppxProvision {
    param([string]$Bundle, [string[]]$Dependencies, [string]$License)
    [void](Add-AppxProvisionedPackage -Online -PackagePath $Bundle -DependencyPackagePath $Dependencies -LicensePath $License -ErrorAction Stop)
    Invoke-AppxRegister
}

function Invoke-WingetSourceReset {
    & winget source reset --force --disable-interactivity 2>&1 | Out-Null
    & winget source update --disable-interactivity 2>&1 | Out-Null
}

function Repair-Winget {
    # Tries the lightest fix first. Writes progress lines and ends with RESULT:OK or RESULT:FAILED.
    param([string]$BootstrapDir, [string]$WorkDir)
    if (Test-WingetWorks) {
        'Winget starts but could not list apps, so its app sources are being reset.'
        Invoke-WingetSourceReset
        'RESULT:OK'
        return
    }
    'Winget is not working. Asking Windows to register it.'
    try { Invoke-AppxRegister } catch { "Registering did not work: $($_.Exception.Message)" }
    if (Test-WingetWorks) { 'Winget is working after registering it.'; 'RESULT:OK'; return }

    $files = Find-WingetPackages -Dir $BootstrapDir
    if ($files) { 'Using the offline copy in the bootstrap folder.' }
    else {
        'There is no offline copy. Downloading winget from Microsoft.'
        try { [void](Save-WingetPackages -Dir $WorkDir); $files = Find-WingetPackages -Dir $WorkDir }
        catch { "The download failed: $($_.Exception.Message)" }
        if (-not $files) { 'RESULT:FAILED'; return }
    }
    if (-not (Test-Path -LiteralPath $WorkDir)) { [void](New-Item -ItemType Directory -Path $WorkDir -Force) }
    try { $deps = Get-WingetDependencyPaths -ZipPath $files.Dependencies -WorkDir $WorkDir }
    catch { "Could not unpack winget's dependencies: $($_.Exception.Message)"; 'RESULT:FAILED'; return }

    try { Invoke-AppxInstall -Bundle $files.Bundle -Dependencies $deps } catch { "Installing for this user did not work: $($_.Exception.Message)" }
    if (-not (Test-WingetWorks) -and $files.License) {
        'Trying a system-wide install.'
        try { Invoke-AppxProvision -Bundle $files.Bundle -Dependencies $deps -License $files.License } catch { "The system-wide install did not work: $($_.Exception.Message)" }
    }
    if (Test-WingetWorks) { 'Winget is installed and working.'; 'RESULT:OK'; return }
    'RESULT:FAILED'
}
