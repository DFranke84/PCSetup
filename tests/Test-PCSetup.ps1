# Headless checks. Run with: powershell -STA -NoProfile -ExecutionPolicy Bypass -File tests\Test-PCSetup.ps1 [imageDir]
# Never shows a window, installs anything, restarts the PC or changes a real setting.
# Uses a made-up profile from tests\fixtures, so your own profile is never read or changed.
# Installs use a fake launcher. Registry writes use a throwaway key that is removed at the end.
param([string]$ImageDir)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'PCSetup.ps1')

$script:Failed = 0
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Output "PASS  $Name" } else { Write-Output "FAIL  $Name"; $script:Failed++ }
}

# --- The real launcher, with harmless commands only
$h = Start-StepProcess (New-RunStep -Key k -Name n -Kind setup -File 'cmd.exe' -Arguments '/c echo hello& exit 3010')
while (-not (Test-StepFinished $h)) { Start-Sleep -Milliseconds 50 }
$res = Get-StepResult $h
Check 'real launcher returns exit code and output' ($res.ExitCode -eq 3010 -and $res.Output -like '*hello*')
$h = Start-StepProcess (New-RunStep -Key k -Name n -Kind upgrade -File 'winget' -Arguments '--version')
while (-not (Test-StepFinished $h)) { Start-Sleep -Milliseconds 50 }
$res = Get-StepResult $h
Check 'real launcher can start winget' ($res.ExitCode -eq 0 -and $res.Output -like 'v*')
$h = Start-StepProcess (New-RunStep -Key k -Name n -Kind setup -File 'ping.exe' -Arguments '-n 30 127.0.0.1')
Check 'long step reports unfinished' (-not (Test-StepFinished $h))
Stop-StepProcess $h
Start-Sleep -Milliseconds 500
Check 'a stuck step can be stopped' (Test-StepFinished $h)
$threw = $false
try { [void](Start-StepProcess (New-RunStep -Key k -Name n -Kind setup -File 'C:\does\not\exist.exe' -Arguments '')) } catch { $threw = $true }
Check 'missing setup file is an error' $threw
Check 'real winget check works here' (Test-WingetWorks)

# --- From here nothing can launch, restart, power-change or rename for real
$script:RealPower = ${function:Get-PowerValue}
$script:FakePower = 600
$script:Launched = New-Object System.Collections.Generic.List[object]
$script:Codes = @{}; $script:HoldOpen = $false; $script:StopCalls = 0; $script:RestartCalls = 0; $script:CheckRuns = 0
$script:PowerWrites = New-Object System.Collections.Generic.List[object]; $script:Renames = New-Object System.Collections.Generic.List[string]
$script:Questions = New-Object System.Collections.Generic.List[string]; $script:NoPattern = '^$'
function Start-StepProcess($Step) {
    if ($Step.Key -eq 'Test.Throw') { throw 'cannot start' }
    $script:Launched.Add($Step)
    return @{ Code = $(if ($script:Codes.ContainsKey($Step.Key)) { $script:Codes[$Step.Key] } else { 0 }) }
}
function Test-StepFinished($Handle) { return -not $script:HoldOpen }
function Get-StepResult($Handle) { return [pscustomobject]@{ ExitCode = $Handle.Code; Output = "first line`nfake failure detail" } }
function Stop-StepProcess($Handle) { $script:StopCalls++ }
function Invoke-PCRestart { $script:RestartCalls++ }
function Invoke-PowerWrite([string]$Subgroup, [string]$Setting, [int]$Value) { $script:PowerWrites.Add($Value); $script:FakePower = $Value }
function Invoke-PCRename([string]$Name) { $script:Renames.Add($Name) }
function Get-PowerValue([string]$Subgroup, [string]$Setting) {
    if ($Subgroup -eq 'SUB_TEST') { return $script:FakePower }
    return & $script:RealPower -Subgroup $Subgroup -Setting $Setting
}
function Show-Question([string]$Text) { $script:Questions.Add($Text); return $Text -notmatch $script:NoPattern }
function Show-Notice([string]$Text) { $script:Questions.Add($Text) }
$script:TypedText = ''
function Read-TextInput([string]$Prompt, [string]$Default) { return $script:TypedText }
function Read-SavedProfile { return Get-Content -LiteralPath $script:ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json }
$script:WingetOk = $false; $script:FixAt = ''; $script:RepairCalls = New-Object System.Collections.Generic.List[string]; $script:FailAt = ''
$script:LastDeps = $null; $script:LastLicense = ''; $script:DownloadTo = ''
function Test-WingetWorks { return $script:WingetOk }
function Invoke-RepairFake([string]$Name) {
    $script:RepairCalls.Add($Name)
    if ($script:FailAt -eq $Name) { throw "$Name refused" }
    if ($script:FixAt -eq $Name) { $script:WingetOk = $true }
}
function Invoke-AppxRegister { Invoke-RepairFake 'register' }
function Invoke-AppxInstall([string]$Bundle, [string[]]$Dependencies) { $script:LastDeps = $Dependencies; Invoke-RepairFake 'install' }
function Invoke-AppxProvision([string]$Bundle, [string[]]$Dependencies, [string]$License) { $script:LastLicense = $License; Invoke-RepairFake 'provision' }
function Invoke-WingetSourceReset { Invoke-RepairFake 'sources' }
function Save-WingetPackages([string]$Dir) {
    Invoke-RepairFake 'download'
    [void](New-Item -ItemType Directory -Path $Dir -Force)
    Copy-Item -Path (Join-Path $script:OfflineFixture '*') -Destination $Dir -Force
    return 'v0'
}
function Wait-UI([scriptblock]$Until, [int]$Seconds = 150) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $stop = New-Object System.Windows.Threading.DispatcherTimer
        $stop.Interval = [TimeSpan]::FromMilliseconds(100)
        $stop.Tag = $frame
        $stop.Add_Tick({ param($s, $e) $s.Stop(); $s.Tag.Continue = $false })
        $stop.Start()
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    } while (-not (& $Until) -and (Get-Date) -lt $deadline)
}

# --- Parser, using lines recorded from real winget output
$text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\winget-list.txt'), [Text.Encoding]::UTF8)
$entries = ConvertFrom-WingetList -Text $text
$index = New-WingetIndex -Entries $entries
function State($id, $name) { Get-AppInstallState -Index $index -Id $id -Name $name }
$a = State '7zip.7zip' '7-Zip'
Check 'update found with both versions' ($a.State -eq 'Needs update' -and $a.Installed -eq '25.01' -and $a.Latest -eq '26.06')
$a = State 'Valve.Steam' 'Steam'
Check 'up-to-date app' ($a.State -eq 'Already installed' -and $a.Latest -eq 'Up to date')
$a = State 'Anaconda.Miniconda3' 'Miniconda3'
Check 'columns that touch are split correctly' ($a.Installed -eq 'py310_24.5.0-0' -and $a.Latest -eq 'py314_26.9.4-0')
$a = State 'Zoom.Zoom.EXE' 'Zoom'
Check 'versions containing spaces' ($a.Installed -eq '5.13.7 (12602)' -and $a.Latest -eq '7.2.5 (51704)')
$a = State 'Google.Chrome' 'Google Chrome'
Check 'unlinked app found by name, marked not tracked' ($a.State -eq 'Already installed' -and $a.Latest -eq 'Not tracked' -and $a.Installed -like '156.*')
$a = State 'Example.Missing' 'Example Missing'
Check 'missing app' ($a.State -eq 'Not installed' -and $a.Installed -eq '-')
$fake = "Name         Id            Version Available Source`n-----------------------------------------------------`nSteam Link   Valve.Link    1.0               winget"
$i2 = New-WingetIndex -Entries (ConvertFrom-WingetList -Text $fake)
Check 'a linked app does not match another app by name' ((Get-AppInstallState -Index $i2 -Id 'Valve.Steam' -Name 'Steam').State -eq 'Not installed')
Check 'text with no table parses to nothing' (@(ConvertFrom-WingetList -Text 'No installed package found').Count -eq 0)
Check 'install command is exact' ((Get-WingetCommandText -Id 'VideoLAN.VLC') -eq 'winget install --id VideoLAN.VLC -e --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity')
Check 'update command is exact' ((Get-WingetCommandText -Id 'VideoLAN.VLC' -Verb upgrade) -like 'winget upgrade --id VideoLAN.VLC -e *')

# --- Window with the real catalog and a live winget check
$realProfiles = Join-Path $root 'profiles'
function Get-FolderPrint([string]$Dir) { if (Test-Path $Dir) { return (Get-ChildItem -LiteralPath $Dir -File | Sort-Object Name | ForEach-Object { $_.Name + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ';' }; return '' }
$realProfilesBefore = Get-FolderPrint $realProfiles
$dataDir = Join-Path $env:TEMP 'pcsetup-test-data'
if (Test-Path $dataDir) { Remove-Item -LiteralPath $dataDir -Recurse -Force }
[void](New-Item -ItemType Directory -Path $dataDir)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\sample-profile.json') -Destination (Join-Path $dataDir 'profile.json')
$w = New-PCSetupWindow -DataDir $dataDir
$script:UserDataPath = Join-Path $env:TEMP 'pcsetup-test-user.json'
if (Test-Path $script:UserDataPath) { Remove-Item $script:UserDataPath }
$script:LogPath = Join-Path $env:TEMP 'pcsetup-test-logs\test.log'
$script:RunStatePath = Join-Path $env:TEMP 'pcsetup-test-run.json'
$script:TweakBackupPath = Join-Path $env:TEMP 'pcsetup-test-backup.json'
$realProfilePath = $script:ProfilePath
$script:ProfilePath = Join-Path $env:TEMP 'pcsetup-test-profile.json'
$script:RunOncePath = 'HKCU:\Software\PCSetupTest\RunOnce'
foreach ($p in $script:RunStatePath, $script:TweakBackupPath, $script:ProfilePath) { if (Test-Path $p) { Remove-Item $p } }
$realRunOnceBefore = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -ErrorAction SilentlyContinue).PCSetupResume
$realProfileHash = (Get-FileHash -LiteralPath $realProfilePath).Hash
$realSettingsBefore = @($script:AllTweaks | ForEach-Object { "$($_.id)=$(Get-TweakCurrentValue -Tweak $_)" }) -join ';'
Write-Output "      catalog: $($script:AppRows.Count) apps, $(@($script:AppRows | Where-Object Method -eq 'manual').Count) non-winget"
Check 'window builds with the full catalog' ($script:AppRows.Count -gt 100)
Check 'every app has a unique ID' (@($script:Apps.id | Sort-Object -Unique).Count -eq $script:Apps.Count)
Check 'every app has a description' (@($script:Apps | Where-Object { -not $_.description }).Count -eq 0)
Check 'exactly 7 categories' (@($script:Apps.category | Sort-Object -Unique).Count -eq 7)
Check 'checklist has steps' ($script:ChecklistRows.Count -gt 10)
Check 'your own step replaces the general one with the same ID' (@($script:ChecklistRows.Key | Sort-Object -Unique).Count -eq $script:ChecklistRows.Count -and ($script:ChecklistRows | Where-Object Key -eq 'step-09').Name -eq 'Pair Bluetooth headphones')
$sharedText = (Get-ChildItem (Join-Path $root 'data') -Filter *.json | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
Check 'shared lists hold no addresses or private folders' ($sharedText -notmatch '\b(192\.168|10\.\d{1,3}|172\.(1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b|[A-Za-z0-9]@[A-Za-z0-9]|\"[D-Z]:')
$sharedPaths = @((Read-JsonFile 'data\apps.json') | Where-Object detectPath | ForEach-Object detectPath)
Check 'shared apps only look in standard folders' (@($sharedPaths | Where-Object { $_ -notmatch '^(C:\\Program Files|%SystemRoot%|%ProgramData%|%APPDATA%)' }).Count -eq 0)
$keepPath = $script:ProfilePath
$script:ProfilePath = Join-Path $env:TEMP 'pcsetup-no-such-profile.json'
$blank = Read-Profile
$script:ProfilePath = $keepPath
Check 'a new person starts with a blank profile' (@($blank.apps).Count -eq 0 -and @($blank.tweaks).Count -eq 0 -and @($blank.myApps).Count -eq 0 -and @($blank.mySteps).Count -eq 0 -and $null -ne $blank.values)
$safe = @($script:TweakRows | Where-Object { -not $_.Risky -and $script:Profile.tweaks -contains $_.Key }).Count
Check 'window builds with the settings for this Windows version' ($script:TweakRows.Count -ge 13 -and $safe -ge 12)
Set-ProfileSelection $script:TweakRows $script:Profile.tweaks
Check 'profile ticks safe settings' ([PCList]::CountSelected($script:TweakRows) -eq $safe)
Check 'profile never ticks risky setting' (-not ($script:TweakRows | Where-Object Key -eq 'uac-no-prompt').IsSelected)
Set-ProfileSelection $script:AppRows $script:Profile.apps
Check 'profile ticks your current apps' ([PCList]::CountSelected($script:AppRows) -eq $script:Profile.apps.Count)
Check 'old-list apps stay unticked' (-not ($script:AppRows | Where-Object Key -eq 'RARLab.WinRAR').IsSelected)
Start-InstalledCheck
Check 'check disables its button while running' (-not $script:CheckAgain.IsEnabled)
Wait-UI { $script:CheckAgain.IsEnabled }
Check 'live check finishes' ($script:CheckAgain.IsEnabled)
Check 'every app got a status' (@($script:AppRows | Where-Object { $_.State -notin 'Already installed', 'Needs update', 'Not installed', 'Not in your list' }).Count -eq 0)
$profileIds = @{}; foreach ($k in $script:Profile.apps) { $profileIds[$k] = $true }
$np = $script:AppRows | Where-Object Key -eq 'manual.npcap'
Check 'Npcap is listed and ticked by your profile' ($np.IsSelected -and $np.Btn1Text -eq 'Link')
$found = @($script:AppRows | Where-Object Method -eq 'unlisted')
Write-Output ("      not in list ($($found.Count)): " + (($found | ForEach-Object Name) -join ' | '))
if ($found.Count) {
    $first = $found[0]; $firstName = $first.Name
    Add-UnlistedApp $first
    Check 'Add moves an app into your list' ($first.State -eq 'Already installed' -and $first.Method -ne 'unlisted' -and $first.IsSelected -and @($script:Profile.myApps | Where-Object name -eq $firstName).Count -eq 1)
    Check 'added app is saved' (@((Read-SavedProfile).myApps | Where-Object name -eq $firstName).Count -eq 1)
    if ($found.Count -gt 1) {
        $second = $found[1]; $secondKey = $second.Key
        Hide-UnlistedApp $second
        Check 'Hide removes it and remembers' (-not ($script:AppRows -contains $second) -and (Read-UserData).hidden -contains $secondKey)
    }
}
$manual = @($script:AppRows | Where-Object Method -eq 'manual')[0]
$manual.State = 'Not installed'; $manual.IsSelected = $true
Check 'manual app shows Manual step' ($manual.Action -eq 'Manual step')
Set-RowInstaller $manual 'E:\Installers\example.exe'
Check 'setup file changes the action' ($manual.Action -eq 'Will run setup')
Save-UserData
Check 'setup file is saved' ((Read-UserData).installers[$manual.Key] -eq 'E:\Installers\example.exe')
$script:SampleRow = $manual
$live = [PCList]::Summarize($script:AppRows)
Write-Output "      live: installed $($live.Installed), update $($live.Update), missing $($live.Missing)"
$script:RealItems = $script:AppItems.Count
Check 'Updates tab lists every winget update' ($script:UpdateRows.Count -eq @($script:AppRows | Where-Object { $_.State -eq 'Needs update' -and $_.Method -eq 'winget' }).Count)
Check 'nothing is ticked for update by default' ([PCList]::CountSelected($script:UpdateRows) -eq 0 -and -not $script:RunUpdates.IsEnabled)
Check 'ticked app needing update stays off the Install run' (@($script:AppRows | Where-Object { $_.State -eq 'Needs update' -and $_.Action -ne 'See Updates tab' }).Count -eq 0)
Write-Output "      $($script:UpdateSummary.Text)"

function Save-Tab($Content, [int]$Tab, [string]$Path) {
    $size = New-Object System.Windows.Size 940, 660
    $script:Tabs.SelectedIndex = $Tab
    for ($k = 0; $k -lt 2; $k++) {
        $Content.Measure($size); $Content.Arrange((New-Object System.Windows.Rect $size)); $Content.UpdateLayout()
        Wait-UI { $true } 1
    }
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap 940, 660, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($Content)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create($Path); $enc.Save($fs); $fs.Close()
}
$content = $w.Content
if ($ImageDir) {
    $w.Content = $null
    Set-UpdateSelection $true
    Save-Tab $content 1 (Join-Path $ImageDir 'pcsetup-updates.png')
    Set-UpdateSelection $false
    Save-Tab $content 2 (Join-Path $ImageDir 'pcsetup-settings.png')
    $script:Tabs.SelectedIndex = 0
}

$click = [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent
$script:PreviewTweaks.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click))
Check 'Preview changes fills status' (@($script:TweakRows | Where-Object { $_.IsSelected -and -not $_.Status }).Count -eq 0)
Write-Output ('      settings: ' + (($script:TweakRows | Where-Object IsSelected | ForEach-Object { "$($_.Key)=$($_.Status)" }) -join '; '))

$script:ChecklistStatePath = Join-Path $env:TEMP 'pcsetup-test-state.json'
$script:ChecklistRows[0].IsSelected = $true; $script:ChecklistRows[2].IsSelected = $true
Save-ChecklistState
$script:ChecklistRows[0].IsSelected = $false; $script:ChecklistRows[2].IsSelected = $false
Restore-ChecklistState
Check 'checklist ticks survive a restart' ($script:ChecklistRows[0].IsSelected -and $script:ChecklistRows[2].IsSelected -and -not $script:ChecklistRows[1].IsSelected)
Check 'checklist count text' ($script:ChecklistCount.Text -eq "2 of $($script:ChecklistRows.Count) done")
Clear-Checklist
Check 'untick all clears checklist' ([PCList]::CountSelected($script:ChecklistRows) -eq 0)
Remove-Item -LiteralPath $script:ChecklistStatePath
$script:ShowCommands.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click))
Check 'Show exact commands lists installs only' ($script:LogBox.Text -like '*WOULD INSTALL*' -and $script:LogBox.Text -notlike '*WOULD UPDATE*')
Check 'log says nothing was run' ($script:LogBox.Text -like '*nothing was run*')
Check 'log lists setup files and checklist items' ($script:LogBox.Text -like '*WOULD RUN YOUR SETUP FILE*E:\Installers\example.exe*ADDED TO YOUR CHECKLIST*')
$fakeEntries = @([pscustomobject]@{ Name = 'Cool Tool 1.0'; Id = 'Cool.Tool'; Version = '1.0'; Available = ''; Source = 'winget' }, [pscustomobject]@{ Name = 'Microsoft Visual C++ 2015 Redistributable'; Id = 'ARP\X'; Version = '1'; Available = ''; Source = '' }, [pscustomobject]@{ Name = 'Known App 2'; Id = 'ARP\Y'; Version = '2'; Available = ''; Source = '' }, [pscustomobject]@{ Name = 'Hidden App'; Id = 'Hide.Me'; Version = '3'; Available = ''; Source = 'winget' })
$u = Get-UnlistedEntries -Entries $fakeEntries -CatalogIds @{} -CatalogNames @{ 'Known App' = $true } -IgnorePatterns $script:IgnorePatterns -HiddenIds @('Hide.Me')
Check 'unlisted scan filters runtimes, known and hidden apps' ($u.Count -eq 1 -and $u[0].Id -eq 'Cool.Tool')

# --- Columns, removing, saving the profile, adding apps and steps
Set-ColumnWidths 'A' @(120, 150, 110, 130)
Check 'column widths reach the rows' ($script:RootPanel.Resources['ColA3'].Value -eq 150 -and $script:AppHeader.ColumnDefinitions[3].Width.Value -eq 150)
Save-ColumnWidths
Check 'column widths are saved' ((Read-UserData).columns['A'][1] -eq 150 -and (Read-UserData).columns['U'].Count -eq 4)
Set-ColumnWidths 'A' @(5, 150, 110, 130)
Check 'a damaged saved width is ignored' ($script:RootPanel.Resources['ColA2'].Value -eq 120)
$upd = $script:AppRows | Where-Object { $_.State -eq 'Needs update' -and $_.Method -eq 'winget' } | Select-Object -First 1
Check 'apps needing an update have no tick box on Install' (-not $upd.CanSelect -and @($script:AppItems | Where-Object { $_.IsHeader -and $_.Key -eq 'Needs update' })[0].CanSelect -eq $false)
Show-UpdateRow $upd
Check 'See Updates tab opens Updates with the app highlighted' ($script:UpdatesTab.IsSelected -and ($script:UpdateRows | Where-Object Key -eq $upd.Key).Highlight -and @($script:UpdateRows | Where-Object Highlight).Count -eq 1)
$script:Tabs.SelectedIndex = 0

$gone = $script:AppRows | Where-Object { $_.State -eq 'Not installed' -and $_.Method -eq 'winget' } | Select-Object -First 1
$gone.IsSelected = $true
$totalBefore = [PCList]::Summarize($script:AppRows).Total
Switch-AppRemoved $gone
Check 'Remove hides the app and unticks it' ($gone.Removed -and -not $gone.IsSelected -and $gone.Action -eq 'Removed' -and -not ($script:AppItems -contains $gone))
Check 'removed app leaves the counts' ([PCList]::Summarize($script:AppRows).Total -eq $totalBefore - 1 -and $script:ShowRemoved.Content -eq 'Show removed (1)')
Check 'removal is saved' ((Read-UserData).removed -contains $gone.Key)
Set-ProfileSelection $script:AppRows $script:Profile.apps
Check 'a profile does not tick a removed app' (-not $gone.IsSelected)
$script:ShowRemoved.IsChecked = $true; Update-AppList
Check 'Show removed lists it with Restore' (($script:AppItems -contains $gone) -and $gone.RemoveText -eq 'Restore' -and @($script:AppItems | Where-Object { $_.IsHeader -and $_.Key -eq 'Removed' }).Count -eq 1)
if ($ImageDir) { $script:AddAppPanel.Visibility = 'Visible'; Save-Tab $content 0 (Join-Path $ImageDir 'pcsetup-install.png'); $script:AddAppPanel.Visibility = 'Collapsed' }
Switch-AppRemoved $gone
Check 'Restore brings it back' (-not $gone.Removed -and (Read-UserData).removed -notcontains $gone.Key -and [PCList]::Summarize($script:AppRows).Total -eq $totalBefore)
$script:ShowRemoved.IsChecked = $false; Update-AppList

$script:NoPattern = '^$'
$tickedBefore = @($script:AppRows | Where-Object { $_.IsSelected -and $_.Method -ne 'unlisted' }).Count
$drop = $script:AppRows | Where-Object { $_.IsSelected -and $_.State -eq 'Not installed' } | Select-Object -First 1
$drop.IsSelected = $false
$script:SaveProfileApps.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click))
$savedProfile = Get-Content -LiteralPath $script:ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
Check 'Save my profile stores the ticked apps' (@($savedProfile.apps).Count -eq $tickedBefore - 1 -and $savedProfile.apps -notcontains $drop.Key)
$drop.IsSelected = $true
$script:LoadProfileApps.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click))
Check 'Load my profile returns to the saved ticks' (-not $drop.IsSelected)
($script:TweakRows | Where-Object Key -eq 'show-hidden-files').IsSelected = $false
Save-ProfileTweaks
Check 'Save my profile stores the ticked settings' ((Get-Content -LiteralPath $script:ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json).tweaks -notcontains 'show-hidden-files')

$searchText = @('Name            Id                  Version Match', '-------------------------------------------------',
    ('{0,-16}{1,-20}{2,-8}{3}' -f 'Fake Tool', 'Fake.Tool', '1.2.3', 'Tag: fake'), ('{0,-16}{1,-20}{2,-8}' -f '7-Zip', '7zip.7zip', '26.06')) -join "`n"
Complete-AppSearch $searchText
$items = @($script:AddAppResults.ItemsSource)
Check 'winget search results are read' ($items.Count -eq 2 -and $items[0].Id -eq 'Fake.Tool' -and $items[0].Display -like '*1.2.3*' -and $items[0].Display -notlike '*Tag*')
Check 'results flag apps already in your list' ($items[1].Display -like '*already in your list*')
Add-WingetApp
Check 'Add selected needs a pick' ($script:AddAppInfo.Text -like 'Pick an app*')
$script:AddAppResults.SelectedIndex = 0
$script:AddAppCategory.SelectedItem = 'Media'
Add-WingetApp
$new = $script:AppRows | Where-Object Key -eq 'Fake.Tool'
Check 'picked app joins your list, ticked' ($new.Name -eq 'Fake Tool' -and $new.Group -eq 'Media' -and $new.IsSelected -and $new.State -eq 'Not installed' -and $new.Action -eq 'Will install')
Check 'added app is saved to the list and profile' (@((Read-SavedProfile).myApps | Where-Object id -eq 'Fake.Tool').Count -eq 1 -and $script:Profile.apps -contains 'Fake.Tool')
$countBefore = $script:AppRows.Count
Add-WingetApp
Check 'the same app is not added twice' ($script:AppRows.Count -eq $countBefore -and $script:AddAppInfo.Text -like '*already in your list*')
Complete-AppSearch 'No package found matching input criteria.'
Check 'no results points to the manual option' (@($script:AddAppResults.ItemsSource).Count -eq 0 -and $script:AddAppInfo.Text -like 'Nothing found*')
$script:AddAppName.Text = 'My Tool 2'; $script:AddAppLink.Text = 'ftp://bad'
Add-ManualApp
Check 'a link must be a web address' ($script:AppRows.Count -eq $countBefore -and $script:AddAppInfo.Text -like 'The link must*')
$script:AddAppLink.Text = 'https://example.com/tool'
Add-ManualApp
$man = $script:AppRows | Where-Object Key -eq 'manual.my-tool-2'
Check 'manual app joins your list with its link' ($man.Method -eq 'manual' -and $man.Btn1Text -eq 'Link' -and $man.Btn2Text -eq 'Setup file' -and $man.Action -eq 'Manual step')
function Start-SearchJob([string]$Query) { return Start-Job -ArgumentList $Query -ScriptBlock { param($q) "Name      Id        Version Match`n----------------------------------`n$q App  Some.Id   2.0" } }
$script:AddAppName.Text = 'Echo'
$script:AddAppSearch.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click))
Check 'search disables its button while running' (-not $script:AddAppSearch.IsEnabled)
Wait-UI { $script:AddAppSearch.IsEnabled } 30
Check 'Search button fills the results' (@($script:AddAppResults.ItemsSource).Count -eq 1 -and @($script:AddAppResults.ItemsSource)[0].Id -eq 'Some.Id')

$stepsBefore = $script:ChecklistRows.Count
$script:StepText.Text = 'Set up the printer'
$script:StepSection.SelectedItem = 'Hardware'
$script:StepAdd.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click))
$step = $script:ChecklistRows[$script:ChecklistRows.Count - 1]
Check 'Add step adds it to its section' ($script:ChecklistRows.Count -eq $stepsBefore + 1 -and $step.Name -eq 'Set up the printer' -and $step.Group -eq 'Hardware' -and $script:StepText.Text -eq '')
Check 'added step is saved' (@((Read-SavedProfile).mySteps | Where-Object name -eq 'Set up the printer').Count -eq 1)
$stepView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:ChecklistRows)
Switch-StepRemoved $step
Check 'removed step is hidden and not counted' ($stepView.Count -eq $stepsBefore -and $script:ChecklistCount.Text -eq "0 of $stepsBefore done" -and $script:ShowRemovedSteps.Content -eq 'Show removed (1)')
Check 'step removal is saved' ((Read-UserData).removedSteps -contains $step.Key)
$script:ShowRemovedSteps.IsChecked = $true; $stepView.Refresh()
Check 'Show removed lists the step with Restore' ($stepView.Count -eq $stepsBefore + 1 -and $step.RemoveText -eq 'Restore')
if ($ImageDir) { Save-Tab $content 3 (Join-Path $ImageDir 'pcsetup-checklist.png'); $script:Tabs.SelectedIndex = 0 }
Switch-StepRemoved $step
Check 'a restored step counts again' ($script:ChecklistCount.Text -eq "0 of $($stepsBefore + 1) done")
$script:ShowRemovedSteps.IsChecked = $false; $stepView.Refresh()
if (Test-Path $script:ChecklistStatePath) { Remove-Item -LiteralPath $script:ChecklistStatePath }

$nameRow = $script:TweakRows | Where-Object Key -eq 'pc-name'
$nameTweak = Get-TweakById 'pc-name'
Check 'your PC name comes from your profile' ($nameTweak.set -eq $script:Profile.values.'pc-name' -and $nameRow.Name -eq 'Name this PC' -and $nameRow.Description -like "New name: $($nameTweak.set).*" -and $nameRow.Btn1Text -eq 'Change name')
$bad = @('', '123', 'has space', 'waytoolongforapcname', '-edge', 'a_b') | Where-Object { Test-PCName $_ }
Check 'PC name rules' ($bad.Count -eq 0 -and (Test-PCName 'DEN-PC2') -and (Test-PCName 'a'))
$oldName = $nameTweak.set
$script:Questions.Clear(); $script:TypedText = 'bad name!'
Set-PCNameFromUser $nameRow
Check 'a name that will not work is refused' ($nameTweak.set -eq $oldName -and $script:Questions[0] -like 'That name will not work*')
$script:TypedText = 'NEWBOX'
$button = New-Object System.Windows.Controls.Button
$button.Tag = '1'; $button.DataContext = $nameRow
$script:TweakList.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click, $button))
Check 'Change name saves the new name to the profile' ($nameTweak.set -eq 'NEWBOX' -and (Read-SavedProfile).values.'pc-name' -eq 'NEWBOX' -and $nameRow.Description -like 'New name: NEWBOX.*')
$nameTweak.set = ''; Update-PCNameRows
$nameRow.IsSelected = $true
Start-TweakPreview
Check 'without a name the setting is skipped' ($nameRow.Status -eq 'Choose a name first' -and $nameRow.Description -like 'No name chosen yet*')
$before = $script:Renames.Count
$script:NoPattern = '^$'
foreach ($r in $script:TweakRows) { $r.SetSelectedQuietly($r.Key -eq 'pc-name') }
Start-TweakApply
Check 'Apply never renames the PC without a name' ($script:Renames.Count -eq $before -and $nameRow.Status -eq 'Choose a name first')
$nameTweak.set = $oldName; Update-PCNameRows

# --- A PC without winget: the check must fail cleanly, not crash (found by the Sandbox test)
$realCheckJob = ${function:Start-CheckJob}
function Start-CheckJob { return Start-Job -ScriptBlock { (no-such-command-pcsetup list | Out-String) + "`n@@PCSETUP-PINS@@`n" } }
$script:RepairTried = $true
Start-InstalledCheck
Wait-UI { $script:CheckAgain.IsEnabled } 60
Check 'missing winget ends the check cleanly' ($script:CheckAgain.IsEnabled -and $script:CheckInfo.Text -like 'Could not read*' -and @($script:AppRows | Where-Object State -ne 'Could not check').Count -eq 0)
${function:Start-CheckJob} = $realCheckJob

# --- Result codes
$cases = @(
    @('install', 0, 'Done'), @('install', 3010, 'NeedsRestart'), @('install', 1641, 'NeedsRestart'),
    @('install', 0x8A150109, 'NeedsRestart'), @('install', 0x8A15010B, 'NeedsRestart'), @('install', 0x8A15010A, 'RestartFirst'),
    @('upgrade', 0x8A15002B, 'Done'), @('install', 0x8A150061, 'Done'), @('pin', 0x8A150062, 'Done'), @('unpin', 0x8A150063, 'Done'),
    @('upgrade', 0x8A150101, 'Failed'), @('install', 12345, 'Failed'), @('setup', 0, 'Done'), @('setup', 3010, 'NeedsRestart'), @('setup', 1602, 'Failed'), @('setup', 0x8A15010A, 'Failed'))
$bad = @($cases | Where-Object { (Get-StepOutcome -Kind $_[0] -ExitCode $_[1]).Result -ne $_[2] })
Check 'every result code means what winget says' ($bad.Count -eq 0)
Check 'pin text with no table has no locks' ((ConvertFrom-WingetPins -Text 'There are no pins configured.').Count -eq 0)
Check 'lock command is a blocking pin' ((Get-WingetCommandText -Id 'A.B' -Verb pin) -eq 'winget pin add --id A.B -e --blocking --source winget --accept-source-agreements --disable-interactivity')
Check 'unlock command is exact' ((Get-WingetCommandText -Id 'A.B' -Verb unpin) -eq 'winget pin remove --id A.B -e --source winget --accept-source-agreements --disable-interactivity')
$s = New-SetupStep -Key k -Name n -Path 'F:\My Apps\a.msi'
Check 'msi setup runs through msiexec with restart held back' ($s.File -eq 'msiexec.exe' -and $s.Arguments -eq '/i "F:\My Apps\a.msi" /passive /norestart')
Check 'exe setup runs itself' ((New-SetupStep -Key k -Name n -Path 'F:\a.exe').File -eq 'F:\a.exe')

# --- Install and update runs through the fake launcher
function Start-InstalledCheck { param([switch]$KeepResults) $script:CheckRuns++ }
$runItems = @('Test.A', 'Test.Fail', 'Test.Throw', 'Test.Later', 'Test.Up1', 'Test.Up2', 'Test.Lock', 'Test.Done') | ForEach-Object { [pscustomobject]@{ id = $_; name = $_; category = 'Utilities'; description = 'x'; risky = $false } }
$runItems = @($runItems) + [pscustomobject]@{ id = 'manual.y'; name = 'Setup App'; category = 'Games'; description = 'x'; method = 'manual'; link = 'https://example.com/y'; risky = $false }
$runItems = @($runItems) + [pscustomobject]@{ id = 'manual.z'; name = 'Hand App'; category = 'Games'; description = 'x'; method = 'manual'; link = 'https://example.com/z'; risky = $false }
$script:AppRows = New-Rows $runItems
$script:UserData = @{ hidden = @(); added = @(); installers = @{}; todos = @() }
$script:UpdateRows.Clear()
$row = { param($k) $script:AppRows | Where-Object Key -eq $k | Select-Object -First 1 }
$updRow = { param($k) $script:UpdateRows | Where-Object Key -eq $k | Select-Object -First 1 }
Set-RowInstaller (& $row 'manual.y') 'F:\setups\y.exe'
$listText = @('Name          Id           Version Available Source', '-------------------------------------------------------') + @(
    ('{0,-14}{1,-13}{2,-8}{3,-10}winget' -f 'Up1', 'Test.Up1', '1.0', '2.0'), ('{0,-14}{1,-13}{2,-8}{3,-10}winget' -f 'Up2', 'Test.Up2', '1.0', '2.0'),
    ('{0,-14}{1,-13}{2,-8}{3,-10}winget' -f 'Lock', 'Test.Lock', '1.0', '2.0'), ('{0,-14}{1,-13}{2,-8}{3,-10}winget' -f 'Done', 'Test.Done', '1.0', ''))
$pinText = "Name   Id         Version Source Pin type`n-----------------------------------------`nLock   Test.Lock  1.0     winget Blocking`nOther  Test.Other 3.0     winget Blocking"
$reset = { Complete-InstalledCheck -ListText ($listText -join "`n") -Checked $true -PinText $pinText; $script:Launched.Clear(); $script:Questions.Clear(); foreach ($r in $script:AppRows) { $r.RunStatus = '' }; $script:Codes = @{} }
& $reset
Check 'pin list is read' ($script:Locks.Count -eq 2 -and $script:Locks['Test.Lock'] -eq 'Lock')
Check 'updates list has updates and locks' ($script:UpdateRows.Count -eq 4)
Check 'locked apps sort last' (($script:UpdateRows[2].Locked -and $script:UpdateRows[3].Locked) -and -not $script:UpdateRows[0].Locked)
$l = & $updRow 'Test.Lock'
Check 'locked app cannot be ticked' ($l.Locked -and -not $l.CanSelect -and $l.Action -eq 'Locked' -and $l.Btn1Text -eq 'Unlock')
Check 'pin outside your list still shows' ((& $updRow 'Test.Other').Name -eq 'Other')

foreach ($k in 'Test.A', 'Test.Fail', 'Test.Throw', 'manual.y', 'manual.z') { (& $row $k).IsSelected = $true }
(& $row 'Test.Up1').IsSelected = $true
Check 'Install button counts the run' ($script:InstallSelected.Content -eq 'Install selected (5)' -and $script:InstallSelected.IsEnabled)
$script:NoPattern = '^Install'
$script:InstallSelected.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click))
Check 'answering No starts nothing' (-not (Test-RunBusy) -and $script:Launched.Count -eq 0 -and $script:ChecklistRows.Where({ $_.Key -eq 'todo.manual.z' }).Count -eq 0)
$script:Questions.Clear()
$script:NoPattern = 'restart'
$script:Codes = @{ 'Test.Fail' = 0x8A150101; 'manual.y' = 3010 }
$before = $script:CheckRuns
$script:InstallSelected.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click))
Check 'license notice comes before the run' ($script:Questions[0] -like '*accept each app*license*')
Check 'run banner shows' ($script:RunBanner.Visibility -eq 'Visible')
Check 'Install is disabled during a run' (-not $script:InstallSelected.IsEnabled)
Wait-UI { -not (Test-RunBusy) } 30
Check 'run finishes' (-not (Test-RunBusy))
Check 'failure does not stop the rest' ((& $row 'manual.y').Action -eq 'Restart needed' -and (& $row 'Test.A').Action -eq 'Installed' -and (& $row 'Test.Fail').Action -eq 'Failed')
Check 'a step that cannot start is a failure' ((& $row 'Test.Throw').Action -eq 'Failed' -and (& $row 'Test.Throw').RunNote -like 'Could not start*')
Check 'failure reason is readable' ((& $row 'Test.Fail').RunNote -eq 'The app is running. Close it and try again.')
Check 'failure detail reaches the log' ($script:LogBox.Text -like '*fake failure detail*')
$a = $script:Launched | Where-Object Key -eq 'Test.A'
Check 'install arguments are exact' ($a.File -eq 'winget' -and $a.Arguments -eq 'install --id Test.A -e --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity')
Check 'setup file runs' (($script:Launched | Where-Object Key -eq 'manual.y').File -eq 'F:\setups\y.exe')
Check 'unticked and update apps are not run' (@($script:Launched | Where-Object { $_.Key -in 'Test.Up1', 'Test.Later' }).Count -eq 0)
Check 'manual app goes on the Checklist' (@($script:ChecklistRows | Where-Object Key -eq 'todo.manual.z').Count -eq 1 -and (& $row 'manual.z').Action -eq 'On Checklist')
Check 'Checklist item has its link' (@($script:ChecklistRows | Where-Object Key -eq 'todo.manual.z')[0].Btn1Text -eq 'Link')
Check 'finished run clears its saved state' (-not (Test-Path $script:RunStatePath))
Check 'finished run clears startup entry' ($null -eq (Get-ItemProperty $script:RunOncePath -ErrorAction SilentlyContinue).PCSetupResume)
Check 'restart is offered, declining is respected' ($script:Questions[-1] -like '*restart*' -and $script:RestartCalls -eq 0)
Check 'apps are re-checked after a run' ($script:CheckRuns -eq $before + 1)
Check 'banner keeps the result' ($script:RunText.Text -like 'Finished: 2 done, 2 failed*' -and $script:RunBanner.Visibility -eq 'Visible')
(& $row 'manual.z').State = 'Already installed'
Sync-ChecklistTodos
Check 'installed manual app leaves the Checklist' (@($script:ChecklistRows | Where-Object Key -eq 'todo.manual.z').Count -eq 0 -and @($script:UserData.todos).Count -eq 0)

& $reset
foreach ($r in $script:AppRows) { $r.SetSelectedQuietly($false) }
(& $row 'Test.Later').IsSelected = $true
(& $row 'Test.A').IsSelected = $true
$script:NoPattern = '^$'
$script:Codes = @{ 'Test.Later' = 0x8A15010A }
$before = $script:CheckRuns
Start-InstallRun
Wait-UI { -not (Test-RunBusy) } 30
Check 'restart-first app waits, restart happens after approval' ($script:RestartCalls -eq 1 -and (& $row 'Test.Later').Action -eq 'After restart')
$state = Read-RunState
Check 'only the waiting app is saved' (@($state.steps).Count -eq 1 -and $state.steps[0].Key -eq 'Test.Later' -and $state.steps[0].Attempts -eq 0)
Check 'startup entry stays for the restart' ((Get-ItemProperty $script:RunOncePath).PCSetupResume -like '"*Start-PCSetup.bat" /resume')
Check 'no re-check when restarting' ($script:CheckRuns -eq $before)
& $reset
$script:ResumeRequested = $true
Resume-SavedRun
Wait-UI { -not (Test-RunBusy) } 30
Check 'resume after restart continues without asking' ($script:Launched.Count -eq 1 -and $script:Launched[0].Key -eq 'Test.Later' -and $script:Questions.Count -eq 0)
Check 'resume finishes and cleans up' (-not (Test-Path $script:RunStatePath) -and $null -eq (Get-ItemProperty $script:RunOncePath -ErrorAction SilentlyContinue).PCSetupResume)

& $reset
$script:ResumeRequested = $false
$s1 = New-WingetStep -Key 'Test.A' -Name 'Test.A' -Kind install; $s1.Attempts = 1
$s2 = New-WingetStep -Key 'Test.Fail' -Name 'Test.Fail' -Kind install; $s2.Attempts = 2
$s3 = New-WingetStep -Key 'Test.Done' -Name 'Test.Done' -Kind install
Write-RunState -Title 'x' -Steps @($s1, $s2, $s3)
Resume-SavedRun
Wait-UI { -not (Test-RunBusy) } 30
Check 'opening PCSetup offers an unfinished run' ($script:Questions[0] -like '*3 apps left*')
Check 'interrupted app is retried once' ($script:Launched.Count -eq 1 -and $script:Launched[0].Key -eq 'Test.A')
Check 'app that keeps restarting the PC is not retried' ((& $row 'Test.Fail').Action -eq 'Failed' -and (& $row 'Test.Fail').RunNote -like '*twice*')
Write-RunState -Title 'x' -Steps @($s1)
$script:NoPattern = 'Continue'
$script:Launched.Clear()
Resume-SavedRun
Check 'declining a saved run discards it' ($script:Launched.Count -eq 0 -and -not (Test-Path $script:RunStatePath))
$script:NoPattern = '^$'
Set-Content -LiteralPath $script:RunStatePath -Value 'not json'
Check 'damaged run file counts as no run' ($null -eq (Read-RunState))
Clear-RunState

& $reset
$script:HoldOpen = $true
$sa = New-WingetStep -Key 'Test.A' -Name 'Test.A' -Kind install; $sb = New-WingetStep -Key 'Test.Later' -Name 'Test.Later' -Kind install
Start-RunSteps -Steps @($sa, $sb) -Title 'hold' -Persist $true
Wait-UI { $script:Run.Handle } 10
$state = Read-RunState
Check 'run is saved while going, in case of a sudden restart' (@($state.steps).Count -eq 2 -and $state.steps[0].Attempts -eq 1 -and (Get-ItemProperty $script:RunOncePath).PCSetupResume)
$script:StopRun.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click))
$script:HoldOpen = $false
Wait-UI { -not (Test-RunBusy) } 30
Check 'Stop finishes the current app and skips the rest' ($script:Launched.Count -eq 1 -and (& $row 'Test.Later').Action -eq 'Not run' -and -not (Test-Path $script:RunStatePath))

& $reset
$script:HoldOpen = $true
$script:StepLimitMinutes = 0
Start-RunSteps -Steps @(New-WingetStep -Key 'Test.A' -Name 'Test.A' -Kind install) -Title 'limit' -Persist $true
Wait-UI { -not (Test-RunBusy) } 30
Check 'a step past its time limit is stopped and failed' ($script:StopCalls -eq 1 -and (& $row 'Test.A').Action -eq 'Failed')
$script:StepLimitMinutes = 90; $script:HoldOpen = $false

& $reset
Set-UpdateSelection $true
Check 'Select all skips locked apps' ([PCList]::CountSelected($script:UpdateRows) -eq 2 -and $script:RunUpdates.Content -eq 'Update selected (2)')
(& $updRow 'Test.Up2').IsSelected = $false
$script:Codes = @{ 'Test.Up1' = 0x8A15002B }
$script:RunUpdates.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click))
Wait-UI { -not (Test-RunBusy) } 30
Check 'only ticked apps update' ($script:Launched.Count -eq 1 -and $script:Launched[0].Arguments -eq 'upgrade --id Test.Up1 -e --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity')
Check 'update result shows' ((& $updRow 'Test.Up1').Action -eq 'Updated' -and (& $updRow 'Test.Up1').RunNote -like 'No newer*')
& $reset
$before = $script:CheckRuns
$u2 = & $updRow 'Test.Up2'
$button = New-Object System.Windows.Controls.Button
$button.DataContext = $u2
$script:UpdateList.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click, $button))
Check 'Lock button starts a lock' ($null -ne $script:Run)
Wait-UI { -not (Test-RunBusy) } 30
Check 'Lock uses a blocking pin' ($script:Launched[0].Arguments -like 'pin add --id Test.Up2 *--blocking*')
Check 'locked row updates' ((& $updRow 'Test.Up2').Locked -and (& $updRow 'Test.Up2').Action -eq 'Locked' -and $script:Locks.ContainsKey('Test.Up2'))
Check 'locking does not save a run or re-check' (-not (Test-Path $script:RunStatePath) -and $script:CheckRuns -eq $before)
Switch-UpdateLock (& $updRow 'Test.Up2')
Wait-UI { -not (Test-RunBusy) } 30
Check 'Unlock removes the pin' ($script:Launched[1].Arguments -like 'pin remove --id Test.Up2 *' -and -not (& $updRow 'Test.Up2').Locked -and (& $updRow 'Test.Up2').CanSelect)

# --- Winget repair, with the Windows install commands replaced
$work = Join-Path $env:TEMP 'pcsetup-test-repair'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
$script:OfflineFixture = Join-Path $work 'offline'
[void](New-Item -ItemType Directory -Path (Join-Path $script:OfflineFixture 'zip\x64') -Force)
[void](New-Item -ItemType Directory -Path (Join-Path $script:OfflineFixture 'zip\x86') -Force)
Set-Content (Join-Path $script:OfflineFixture 'zip\x64\vclibs.appx') 'x'; Set-Content (Join-Path $script:OfflineFixture 'zip\x64\xaml.appx') 'x'; Set-Content (Join-Path $script:OfflineFixture 'zip\x86\other.appx') 'x'
Compress-Archive -Path (Join-Path $script:OfflineFixture 'zip\*') -DestinationPath (Join-Path $script:OfflineFixture 'DesktopAppInstaller_Dependencies.zip')
Remove-Item (Join-Path $script:OfflineFixture 'zip') -Recurse -Force
Set-Content (Join-Path $script:OfflineFixture 'winget.msixbundle') 'x'; Set-Content (Join-Path $script:OfflineFixture 'abc_License1.xml') 'x'
$runRepair = {
    param($ok, $fix, $fail, $boot)
    $script:WingetOk = $ok; $script:FixAt = $fix; $script:FailAt = $fail; $script:RepairCalls.Clear()
    $wd = Join-Path $work 'wd'; if (Test-Path $wd) { Remove-Item $wd -Recurse -Force }
    return @(Repair-Winget -BootstrapDir $boot -WorkDir $wd)
}
$out = & $runRepair $true '' '' $script:OfflineFixture
Check 'working winget only resets its sources' (($script:RepairCalls -join ',') -eq 'sources' -and $out[-1] -eq 'RESULT:OK')
$out = & $runRepair $false 'register' '' $script:OfflineFixture
Check 'registering is tried first and is enough when it works' (($script:RepairCalls -join ',') -eq 'register' -and $out[-1] -eq 'RESULT:OK')
$out = & $runRepair $false 'install' 'register' $script:OfflineFixture
Check 'offline copy installs when registering fails' (($script:RepairCalls -join ',') -eq 'register,install' -and $out[-1] -eq 'RESULT:OK')
Check 'only packages for this processor are used' (@($script:LastDeps).Count -eq 2 -and @($script:LastDeps | Where-Object { $_ -like '*other.appx' }).Count -eq 0 -and (Test-Path $script:LastDeps[0]))
$out = & $runRepair $false 'provision' 'install' $script:OfflineFixture
Check 'system-wide install is the last resort, with its license' (($script:RepairCalls -join ',') -eq 'register,install,provision' -and $script:LastLicense -like '*abc_License1.xml' -and $out[-1] -eq 'RESULT:OK')
$out = & $runRepair $false 'install' '' (Join-Path $work 'no-such-folder')
Check 'no offline copy downloads instead' (($script:RepairCalls -join ',') -eq 'register,download,install' -and $out[-1] -eq 'RESULT:OK')
$out = & $runRepair $false '' 'download' (Join-Path $work 'no-such-folder')
Check 'failed download reports failure without installing' (($script:RepairCalls -join ',') -eq 'register,download' -and $out[-1] -eq 'RESULT:FAILED' -and ($out -join ' ') -like '*download failed*')
$out = & $runRepair $false '' '' $script:OfflineFixture
Check 'nothing working reports failure' ($out[-1] -eq 'RESULT:FAILED')
Check 'an error message does not count as an app list' (-not (Test-WingetListText 'Failed when opening source(s); try the source reset command'))
Check 'a real table counts as an app list' (Test-WingetListText ($listText -join "`n"))

$script:RepairJobBody = { 'Repair step one'; 'RESULT:OK' }
function Start-RepairJob { return Start-Job -ScriptBlock $script:RepairJobBody }
$script:Questions.Clear(); $script:RepairTried = $false; $script:NoPattern = 'Repair it now'
Complete-InstalledCheck -ListText '' -Checked $false
Check 'broken winget offers a repair, No starts nothing' ($script:Questions[0] -like '*Repair it now*' -and -not ($script:RepairTimer -and $script:RepairTimer.IsEnabled))
Complete-InstalledCheck -ListText '' -Checked $false
Check 'the repair is offered once per session' ($script:Questions.Count -eq 1)
$script:Questions.Clear(); $script:RepairTried = $false; $script:NoPattern = '^$'
$before = $script:CheckRuns
Complete-InstalledCheck -ListText '' -Checked $false
Check 'repair shows in the banner' ($script:RunText.Text -like 'Repairing winget*' -and $script:RunBanner.Visibility -eq 'Visible' -and $script:StopRun.Visibility -eq 'Collapsed')
Wait-UI { -not $script:RepairTimer.IsEnabled } 30
Check 'successful repair re-checks apps' ($script:CheckRuns -eq $before + 1 -and $script:RunText.Text -eq 'Winget repaired.')
Check 'repair steps reach the log' ($script:LogBox.Text -like '*Repair step one*' -and $script:LogBox.Text -notlike '*RESULT:*')
$script:RepairJobBody = { 'Nope'; 'RESULT:FAILED' }
$script:RepairTried = $false; $before = $script:CheckRuns
Complete-InstalledCheck -ListText '' -Checked $false
Wait-UI { -not $script:RepairTimer.IsEnabled } 30
Check 'failed repair says so and allows Check again' ($script:RunText.Text -like 'Winget could not be repaired*' -and $script:CheckRuns -eq $before -and $script:CheckAgain.IsEnabled)
Remove-Item $work -Recurse -Force

# --- Setup files inside the PCSetup folder survive a new USB drive letter
$probe = & $row 'manual.y'
$inside = Join-Path $script:Root 'setups\z.exe'
Set-RowInstaller $probe $inside
Check 'setup file inside PCSetup is saved relative' ($script:UserData.installers['manual.y'] -eq 'setups\z.exe' -and $probe.BtnTip -eq $inside)
Check 'relative setup path resolves from the current folder' ((ConvertFrom-StoredPath 'setups\z.exe') -eq $inside)
Set-RowInstaller $probe '\\NAS\Setups\z.exe'
Check 'setup file outside PCSetup keeps its full path' ($script:UserData.installers['manual.y'] -eq '\\NAS\Setups\z.exe' -and (ConvertFrom-StoredPath '\\NAS\Setups\z.exe') -eq '\\NAS\Setups\z.exe')

# --- Settings on a throwaway registry key
$key = 'HKCU:\Software\PCSetupTest\Tweaks'
[void](New-Item -Path $key -Force)
[void](New-ItemProperty -Path $key -Name Number -Value 5 -PropertyType DWord)
[void](New-ItemProperty -Path $key -Name Text -Value 'old' -PropertyType String)
[void](New-ItemProperty -Path $key -Name Same -Value 1 -PropertyType DWord)
$mk = { param($id, $value, $set) [pscustomobject]@{ id = $id; name = $id; category = 'System'; description = 'x'; type = 'registry'; path = $key; value = $value; set = $set; default = 9; os = @('10'); risky = $false } }
$fakeTweaks = @((& $mk 't-number' 'Number' 1), (& $mk 't-new' 'Added' 7), (& $mk 't-text' 'Text' 'new'), (& $mk 't-same' 'Same' 1))
$badTweak = & $mk 't-bad' 'X' 1; $badTweak.path = 'Registry::HKEY_NOPE\X'
$risky = & $mk 't-risky' 'Risk' 1; $risky.risky = $true
$power = [pscustomobject]@{ id = 't-power'; name = 't-power'; category = 'System'; description = 'x'; type = 'power'; subgroup = 'SUB_TEST'; setting = 'S'; set = 1800; default = 600; os = @('10'); risky = $false }
$name = [pscustomobject]@{ id = 't-name'; name = 't-name'; category = 'System'; description = 'x'; type = 'pcname'; set = 'TESTNAME'; default = ''; os = @('10'); risky = $false }
$script:AllTweaks = @($fakeTweaks) + $badTweak + $risky + $power + $name
Initialize-TweakRows
$tRow = { param($k) $script:TweakRows | Where-Object Key -eq $k | Select-Object -First 1 }
$reg = { param($v) (Get-ItemProperty -Path $key -Name $v -ErrorAction SilentlyContinue).$v }
Check 'capture-only flag does not hide normal settings' ($script:TweakRows.Count -eq 8)
foreach ($r in $script:TweakRows) { $r.IsSelected = $true }
$script:Questions.Clear()
$script:NoPattern = '^Change'
$script:ApplyTweaks.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click))
Check 'answering No changes nothing' ((& $reg 'Number') -eq 5 -and -not (Test-Path $script:TweakBackupPath))
Check 'risky setting is called out before applying' ($script:Questions[0] -like '*lowers security: t-risky*')
$script:NoPattern = 'restart'
$script:ApplyTweaks.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click))
Check 'registry values change' ((& $reg 'Number') -eq 1 -and (& $reg 'Added') -eq 7 -and (& $reg 'Text') -eq 'new' -and (& $reg 'Risk') -eq 1)
Check 'statuses show results' ((& $tRow 't-number').Status -eq 'Changed' -and (& $tRow 't-same').Status -eq 'Already set')
Check 'a failed setting does not stop the rest' ((& $tRow 't-bad').Status -eq 'Failed' -and (& $tRow 't-power').Status -eq 'Changed')
Check 'power uses the setting' ($script:PowerWrites[-1] -eq 1800)
Check 'PC name change waits for restart' ($script:Renames[-1] -eq 'TESTNAME' -and (& $tRow 't-name').Status -eq 'Changed after restart')
$saved = Read-TweakBackup
Check 'old values are backed up' ($saved['t-number'].value -eq 5 -and $saved['t-number'].kind -eq 'DWord' -and -not $saved['t-new'].existed -and $saved['t-text'].value -eq 'old' -and $saved['t-power'].value -eq 600)
Check 'unchanged settings have no backup' (-not $saved.ContainsKey('t-same'))
($script:AllTweaks | Where-Object id -eq 't-number').set = 2
$script:ApplyTweaks.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click))
Check 'a second Apply keeps the original backup' ((& $reg 'Number') -eq 2 -and (Read-TweakBackup)['t-number'].value -eq 5)
$script:UndoTweaks.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click))
Check 'Undo restores numbers and text' ((& $reg 'Number') -eq 5 -and (& $reg 'Text') -eq 'old')
Check 'Undo keeps the original value type' ((Get-Item $key).GetValueKind('Number') -eq 'DWord' -and (Get-Item $key).GetValueKind('Text') -eq 'String')
Check 'Undo removes a value that was not there' ($null -eq (& $reg 'Added') -and $null -eq (& $reg 'Risk'))
Check 'Undo restores power and PC name' ($script:FakePower -eq 600 -and $script:Renames[-1] -eq $env:COMPUTERNAME -and (& $tRow 't-name').Status -eq 'Undone after restart')
Check 'Undo clears its backups' ((Read-TweakBackup).Count -eq 0)
Check 'no real restart was requested' ($script:RestartCalls -eq 1)
$script:NoPattern = '^$'

# --- Capture reads the real settings but writes only to a temporary profile
$script:AllTweaks = @(Read-JsonFile 'data\tweaks.json' | Where-Object { $_.os -contains (Get-WindowsMajor) })
Set-Content -LiteralPath $script:ProfilePath -Value (Get-Content -LiteralPath $realProfilePath -Raw) -Encoding UTF8
$script:Profile = Get-Content -LiteralPath $script:ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:CaptureTweaks.RaiseEvent((New-Object System.Windows.RoutedEventArgs $click))
$cap = Get-Content -LiteralPath $script:ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Output ('      captured: ' + (($cap.tweaks | ForEach-Object { "$_=$($cap.values.$_)" }) -join '; '))
Check 'capture saves settings and values' (@($cap.tweaks).Count -gt 5 -and @($cap.values.PSObject.Properties).Count -eq @($cap.tweaks).Count)
Check 'capture keeps your apps' (@($cap.apps).Count -eq @((Get-Content -LiteralPath $realProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json).apps).Count)
Check 'captured settings are shown and ticked' (@($script:TweakRows | Where-Object IsSelected).Count -gt 0 -and $script:TweakRows.Count -eq @($cap.tweaks).Count + @($script:AllTweaks | Where-Object { -not $_.captureOnly -and $cap.tweaks -notcontains $_.id }).Count)
Check 'captured risky setting stays unticked' (@($script:TweakRows | Where-Object { $_.Risky -and $_.IsSelected }).Count -eq 0)

# --- Nothing real changed
$script:AllTweaks = @(Read-JsonFile 'data\tweaks.json' | Where-Object { $_.os -contains (Get-WindowsMajor) })
$realSettingsAfter = @($script:AllTweaks | ForEach-Object { "$($_.id)=$(Get-TweakCurrentValue -Tweak $_)" }) -join ';'
Check 'real PC settings are unchanged' ($realSettingsAfter -eq $realSettingsBefore)
Check 'real startup entry is untouched' ($realRunOnceBefore -eq (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -ErrorAction SilentlyContinue).PCSetupResume)
Check 'sample profile is unchanged' ($realProfileHash -eq (Get-FileHash -LiteralPath $realProfilePath).Hash)
Check 'your own profiles folder is untouched' ($realProfilesBefore -eq (Get-FolderPrint $realProfiles))
$batText = cmd /c "`"$root\tests\sandbox\Run-Sandbox-Test.bat`" nostart" | Out-String
$wsbPath = Join-Path $env:TEMP 'PCSetup-Test.wsb'
$wsb = [xml](Get-Content -LiteralPath $wsbPath -Raw)
Check 'Sandbox test finds its own folder' ($wsb.Configuration.MappedFolders.MappedFolder[0].HostFolder -eq $root -and $wsb.Configuration.LogonCommand.Command -like "*Desktop\$(Split-Path $root -Leaf)\tests\sandbox\Run-InSandbox.ps1")
Remove-Item -LiteralPath $wsbPath
Remove-Item -LiteralPath $dataDir -Recurse -Force
Remove-Item -Path 'HKCU:\Software\PCSetupTest' -Recurse -Force
foreach ($p in $script:UserDataPath, $script:TweakBackupPath, $script:ProfilePath, (Split-Path $script:LogPath -Parent)) { if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force } }

$code = Get-ChildItem -Path $root -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notlike '*\tests\*' }
$writers = $code | Select-String -Pattern 'Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Process\]::Start|shutdown\.exe|powercfg\.exe|Rename-Computer'
Check 'only the two helper files can change the PC' (@($writers | Where-Object { $_.Filename -notin 'Tweaks.ps1', 'Installers.ps1' }).Count -eq 0)
$nonAscii = Get-ChildItem -Path $root -Recurse -Filter *.ps1 | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '[^\x00-\x7F]' }
Check 'scripts are ASCII for PowerShell 5.1' (@($nonAscii).Count -eq 0)

# --- Scale: 1,000 made-up apps
$cats = 'Internet', 'Utilities', 'Media', 'Games', 'Developer', 'Hardware'
$items = 1..1000 | ForEach-Object { [pscustomobject]@{ id = "Test.App$_"; name = ('Test App {0:000}' -f $_); category = $cats[$_ % 6]; description = 'Made-up entry for the large-list test.'; risky = $false } }
$script:AppRows = New-Rows $items
$lines = @('Name          Id           Version Available Source', '-------------------------------------------------------')
foreach ($n in 1..1000) {
    if ($n % 10 -lt 6) { $lines += ('{0,-14}{1,-13}{2,-8}{3,-10}winget' -f "App$n", "Test.App$n", '1.0', $(if ($n % 10 -lt 2) { '2.0' } else { '' })) }
}
$t = Measure-Command { Complete-InstalledCheck -ListText ($lines -join "`n") -Checked $true }
Check "1,000 apps check in under 5s ($([int]$t.TotalMilliseconds) ms)" ($t.TotalSeconds -lt 5)
$x = [PCList]::Summarize($script:AppRows)
Check "sorted into 400 installed, 200 update, 400 missing ($($x.Installed)/$($x.Update)/$($x.Missing))" ($x.Installed -eq 400 -and $x.Update -eq 200 -and $x.Missing -eq 400)
$t = Measure-Command { $script:AppRows.ForEach({ }) ; Set-ProfileSelection $script:AppRows ($items | ForEach-Object id) }
Check "select all 1,000 in under 2s ($([int]$t.TotalMilliseconds) ms)" ($t.TotalSeconds -lt 2)
$t = Measure-Command { $script:AppSearch.Text = 'App 77' }
Check "search 1,000 in under 300 ms ($([int]$t.TotalMilliseconds) ms)" ($t.TotalMilliseconds -lt 300)
Check 'search opens folded sections' (@($script:AppItems | Where-Object { -not $_.IsHeader -and $_.State -eq 'Already installed' }).Count -gt 0)
$script:AppSearch.Text = ''
[void]$script:Collapsed.Remove('Already installed'); $script:Collapsed.Add('Already installed'); Update-AppList
Check 'folded section hides its rows' (@($script:AppItems | Where-Object { -not $_.IsHeader -and $_.State -eq 'Already installed' }).Count -eq 0)
Switch-AppSection 'Already installed'
Check 'unfolding shows its rows' (@($script:AppItems | Where-Object { -not $_.IsHeader -and $_.State -eq 'Already installed' }).Count -eq 400)
Switch-AppSection 'Already installed'
$script:FilterMissing.IsChecked = $true
Check 'status filter shows only that status' (@($script:AppItems | Where-Object { -not $_.IsHeader }).Count -eq 400 -and @($script:AppItems | Where-Object { -not $_.IsHeader -and $_.State -ne 'Not installed' }).Count -eq 0)
$header = $script:AppItems | Where-Object IsHeader | Select-Object -First 1
$header.IsSelected = $false
$x = [PCList]::Summarize($script:AppRows)
Check 'section tick box clears that section only' ($x.WouldInstall -eq 0 -and $x.Update -eq 200 -and $x.NotSelected -eq 400)
Check 'summary states the plan' ($script:PlanSummary.Text -eq 'When you press Install: 0 will install, 400 left as they are, 200 have updates on the Updates tab, 400 not selected.')
Check 'updates list handles 200 updates' ($script:UpdateRows.Count -eq 200)
$header.IsSelected = $true
$script:FilterAll.IsChecked = $true
Check 'chip shows live count' ($script:FilterUpdate.Content -eq 'Needs update  200')

if ($ImageDir) {
    Save-Tab $content 0 (Join-Path $ImageDir 'pcsetup-large.png')
    Write-Output 'Images written.'
}

Write-Output "Failed: $script:Failed"
exit $script:Failed
