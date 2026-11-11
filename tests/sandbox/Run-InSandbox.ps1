# End-to-end test on a clean Windows. Started by Run-Sandbox-Test.bat.
# Does REAL installs and setting changes, so it refuses to run anywhere but Windows Sandbox.
if ($env:USERNAME -ne 'WDAGUtilityAccount') {
    Write-Output 'This test only runs inside Windows Sandbox. Nothing was done.'
    exit 2
}

$ErrorActionPreference = 'Stop'
$results = Join-Path $env:USERPROFILE 'Desktop\sandbox-results'
$script:Report = Join-Path $results 'report.txt'
Get-ChildItem -LiteralPath $results -File | Remove-Item -Force
$script:FailCount = 0

function Say([string]$Text) { Add-Content -LiteralPath $script:Report -Value ('{0:HH:mm:ss}  {1}' -f (Get-Date), $Text) -Encoding ASCII }
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { Say "PASS  $Name" } else { Say "FAIL  $Name"; $script:FailCount++ }
}
function Save-Screen([string]$Name) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
        $bmp.Save((Join-Path $results $Name), [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
    } catch { Say "INFO  Could not save screen: $($_.Exception.Message)" }
}
function Invoke-Phase([string]$Name, [scriptblock]$Body) {
    Say "--- $Name"
    try { . $Body } catch {
        Say "FAIL  $Name stopped: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
        $script:FailCount++
    }
}
function Wait-UI([scriptblock]$Until, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $stop = New-Object System.Windows.Threading.DispatcherTimer
        $stop.Interval = [TimeSpan]::FromMilliseconds(200)
        $stop.Tag = $frame
        $stop.Add_Tick({ param($s, $e) $s.Stop(); $s.Tag.Continue = $false })
        $stop.Start()
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    } while (-not (& $Until) -and (Get-Date) -lt $deadline)
}
function Wait-Check { Wait-UI { $script:CheckAgain.IsEnabled } 600 }
function Wait-Run { Wait-UI { -not (Test-RunBusy) } 1500; Wait-Check }
function Get-Row([string]$Key) { return $script:AppRows | Where-Object Key -eq $Key | Select-Object -First 1 }
function Get-UpdRow([string]$Key) { return $script:UpdateRows | Where-Object Key -eq $Key | Select-Object -First 1 }

try {
    Say "Windows build $([Environment]::OSVersion.Version), user $env:USERNAME"
    robocopy (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'C:\PCSetup' /E /NFL /NDL /NJH /NJS /NP /XD .git sandbox-results | Out-Null
    Check 'PCSetup copied into the Sandbox' (Test-Path 'C:\PCSetup\PCSetup.ps1')

    . 'C:\PCSetup\PCSetup.ps1'
    # The window is built but not shown until the last phase. Dialogs are answered here.
    $script:Questions = New-Object System.Collections.Generic.List[string]
    function Show-Question([string]$Text) { $script:Questions.Add($Text); Say "ASKED $($Text -replace '\s+', ' ')"; return $Text -notmatch 'estart' }
    function Show-Notice([string]$Text) { Say "NOTICE $Text" }
    function Invoke-PCRestart { Say 'RESTART requested (not done in this phase)' }

    Say "INFO  Winget before repair: $(Test-WingetWorks)"
    $w = New-PCSetupWindow

    Invoke-Phase 'Winget check and repair through the app' {
        $wasWorking = Test-WingetWorks
        Start-InstalledCheck
        Wait-Check
        if (-not $wasWorking) { Check 'app offered the repair' (@($script:Questions | Where-Object { $_ -like '*Repair it now*' }).Count -eq 1) }
        Wait-UI { -not ($script:RepairTimer -and $script:RepairTimer.IsEnabled) } 1500
        Wait-Check
        Check 'winget works after the check' (Test-WingetWorks)
        Say "INFO  $($script:SystemInfo.Text)"
        Say "INFO  Banner: $($script:RunText.Text)"
        $x = [PCList]::Summarize($script:AppRows)
        Say "INFO  installed $($x.Installed), update $($x.Update), missing $($x.Missing), unknown $($x.Unknown), unlisted $($x.Unlisted)"
        Check 'real app list was read' ($x.Missing -gt 100 -and $x.Unknown -eq 0)
    }
    if (-not (Test-WingetWorks)) { throw 'Winget is not working, so the install phases were skipped.' }

    Invoke-Phase 'Real install, setup file and Checklist' {
        Set-ProfileSelection $script:AppRows @('Notepad++.Notepad++', 'manual.npcap', 'manual.ghostscript')
        Set-RowInstaller (Get-Row 'manual.ghostscript') 'C:\Windows\System32\whoami.exe'
        Update-Summary
        Check 'Install button is ready' ($script:InstallSelected.IsEnabled)
        Start-InstallRun
        Check 'run started' (Test-RunBusy)
        Wait-Run
        Say "INFO  Banner: $($script:RunText.Text)"
        Say "INFO  Notepad++ action: $((Get-Row 'Notepad++.Notepad++').Action) / $((Get-Row 'Notepad++.Notepad++').RunNote)"
        Check 'winget installed Notepad++' ((Get-Row 'Notepad++.Notepad++').State -eq 'Already installed')
        Check 'setup file ran' ((Get-Row 'manual.ghostscript').Action -eq 'Setup finished')
        Check 'Npcap went on the Checklist' (@($script:ChecklistRows | Where-Object Key -eq 'todo.manual.npcap').Count -eq 1)
        Check 'run state was cleaned up' (-not (Test-Path $script:RunStatePath))
    }

    Invoke-Phase 'Real update and lock' {
        $id = '7zip.7zip'
        $text = winget show --id $id -e --versions --source winget --accept-source-agreements --disable-interactivity | Out-String
        $versions = @([regex]::Matches($text, '(?m)^\d+\.\d+\s*$') | ForEach-Object { $_.Value.Trim() })
        Say "INFO  Installing older 7-Zip $($versions[1]); newest is $($versions[0])"
        winget install --id $id -e --version $versions[1] --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
        Start-InstalledCheck
        Wait-Check
        $row = Get-UpdRow $id
        Check 'older app appears on the Updates tab' ($null -ne $row -and $row.Installed -like "$($versions[1])*")
        Switch-UpdateLock $row
        Wait-UI { -not (Test-RunBusy) } 120
        Say "INFO  Lock result: $($row.Action) / $($row.RunNote)"
        Start-InstalledCheck
        Wait-Check
        Say ('INFO  winget pin list: ' + ((winget pin list --disable-interactivity | Out-String) -replace '\s+', ' '))
        $row = Get-UpdRow $id
        Check 'lock is read back from real winget' ($script:Locks.ContainsKey($id) -and $row.Locked -and -not $row.CanSelect)
        winget upgrade --id $id -e --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
        Say ('INFO  Upgrade attempt while locked ended with 0x{0:X8}' -f $LASTEXITCODE)
        Start-InstalledCheck
        Wait-Check
        Check 'locked app did not update' ((Get-Row $id).Installed -like "$($versions[1])*")
        $row = Get-UpdRow $id
        Switch-UpdateLock $row
        Wait-UI { -not (Test-RunBusy) } 120
        Start-InstalledCheck
        Wait-Check
        $row = Get-UpdRow $id
        Check 'unlock is read back from real winget' (-not $script:Locks.ContainsKey($id) -and -not $row.Locked)
        $row.IsSelected = $true
        Start-UpdateRun
        Wait-Run
        Say "INFO  Update result: $((Get-Row $id).Installed), $($row.Action) / $($row.RunNote)"
        Check 'real update reached the newest version' ((Get-Row $id).State -eq 'Already installed' -and $null -eq (Get-UpdRow $id))
    }

    Invoke-Phase 'Real settings: Apply, Undo, Capture' {
        $before = @{}
        foreach ($t in $script:Tweaks) { $before[$t.id] = "$(Get-TweakCurrentValue -Tweak $t)" }
        foreach ($r in $script:TweakRows) { $r.IsSelected = $true }
        Start-TweakApply
        foreach ($r in $script:TweakRows) { Say "INFO  Apply $($r.Key): $($r.Status) (now $(Get-TweakCurrentValue -Tweak (Get-TweakById $r.Key)))" }
        # Windows Sandbox has no power service, so the four power settings cannot be changed there.
        Check 'no setting failed to apply, power settings aside' (@($script:TweakRows | Where-Object { $_.Status -eq 'Failed' -and (Get-TweakById $_.Key).type -ne 'power' }).Count -eq 0)
        Start-TweakUndo
        foreach ($r in $script:TweakRows) { Say "INFO  Undo $($r.Key): $($r.Status)" }
        $different = @($script:Tweaks | Where-Object { "$(Get-TweakCurrentValue -Tweak $_)" -ne $before[$_.id] } | ForEach-Object id)
        Check "Undo put every setting back [$($different -join ', ')]" ($different.Count -eq 0)
        Start-TweakCapture
        Say "INFO  Capture on a clean Windows found: $(@($script:Profile.tweaks) -join ', ')"
    }

    Invoke-Phase 'Real window, Start-PCSetup.bat and resume' {
        $step = New-WingetStep -Key 'WinSCP.WinSCP' -Name 'WinSCP' -Kind install
        Write-RunState -Title 'Sandbox resume' -Steps @($step)
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c C:\PCSetup\Start-PCSetup.bat /resume'
        $window = $null; $deadline = (Get-Date).AddSeconds(120)
        while (-not $window -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            $window = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object MainWindowTitle -eq 'PCSetup' | Select-Object -First 1
        }
        Check 'real window opened from the batch file' ($null -ne $window)
        Start-Sleep -Seconds 5
        Save-Screen 'window-open.png'
        $sawResume = $false; $deadline = (Get-Date).AddSeconds(900)
        while ((Test-Path 'C:\PCSetup\profiles\run-state.json') -and (Get-Date) -lt $deadline) {
            if ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -ErrorAction SilentlyContinue).PCSetupResume) { $sawResume = $true }
            Start-Sleep -Seconds 2
        }
        Check 'resume finished the saved app' (-not (Test-Path 'C:\PCSetup\profiles\run-state.json'))
        Check 'startup entry was set during the run' $sawResume
        Start-Sleep -Seconds 40
        Save-Screen 'window-finished.png'
        $listed = winget list --id WinSCP.WinSCP -e --accept-source-agreements --disable-interactivity | Out-String
        Check 'resumed app is really installed' ($listed -match 'WinSCP\.WinSCP')
        Check 'startup entry was removed afterwards' ($null -eq (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -ErrorAction SilentlyContinue).PCSetupResume)
        if ($window) { Stop-Process -Id $window.Id -Force }
    }
} catch {
    Say "FAIL  Test stopped: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
    $script:FailCount++
} finally {
    if (Test-Path 'C:\PCSetup\logs') { Copy-Item -Path 'C:\PCSetup\logs\*' -Destination $results -Force -ErrorAction SilentlyContinue }
    Say "NOT COVERED: a true restart. Windows Sandbox on Windows 10 is wiped by a restart."
    Say "FINISHED. Failures: $script:FailCount. The Sandbox closes in 20 seconds."
    & shutdown.exe /s /t 20
}
