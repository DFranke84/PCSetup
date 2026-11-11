# PCSetup: install apps, update them and apply settings. Keep this file ASCII (PowerShell 5.1 reads it as ANSI).
param([switch]$Resume)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:Root = $PSScriptRoot
$script:ResumeRequested = [bool]$Resume
. (Join-Path $Root 'lib\Winget.ps1')
. (Join-Path $Root 'lib\Tweaks.ps1')
. (Join-Path $Root 'lib\Installers.ps1')

# List logic is in C# so hundreds of rows stay instant.
if (-not ('PCRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;

public class PCRow : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    public static event EventHandler SelectionChanged;
    public static bool Suspended;
    public static void RaiseSelectionChanged() { if (SelectionChanged != null) SelectionChanged(null, EventArgs.Empty); }
    void Notify(string n) { if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs(n)); }

    public string Key { get; set; }
    public string Name { get; set; }
    public string Group { get; set; }
    string description; public string Description { get { return description; } set { description = value; Notify("Description"); } }
    public bool Risky { get; set; }
    public bool IsHeader { get; set; }
    public bool CanToggle { get; set; }
    public string HeaderText { get; set; }
    public List<PCRow> Children;
    public string Link { get; set; }
    bool canSelect = true; public bool CanSelect { get { return canSelect; } set { canSelect = value; Notify("CanSelect"); } }
    string method = "winget"; public string Method { get { return method; } set { method = value; Notify("Method"); Notify("Action"); } }
    string btn1 = ""; public string Btn1Text { get { return btn1; } set { btn1 = value; Notify("Btn1Text"); Notify("HasButtons"); } }
    string btn2 = ""; public string Btn2Text { get { return btn2; } set { btn2 = value; Notify("Btn2Text"); Notify("HasButtons"); } }
    string btnTip; public string BtnTip { get { return btnTip; } set { btnTip = value; Notify("BtnTip"); } }
    public bool HasButtons { get { return btn1 != "" || btn2 != ""; } }

    bool selected;
    public bool IsSelected {
        get { return selected; }
        set {
            selected = value; Notify("IsSelected"); Notify("Action");
            if (IsHeader && Children != null) {
                bool was = Suspended; Suspended = true;
                foreach (PCRow c in Children) c.IsSelected = value;
                Suspended = was;
            }
            if (!Suspended) RaiseSelectionChanged();
        }
    }
    public void SetSelectedQuietly(bool value) { if (selected != value) { selected = value; Notify("IsSelected"); } }

    string status; public string Status { get { return status; } set { status = value; Notify("Status"); } }
    string state; public string State { get { return state; } set { state = value; Notify("State"); Notify("Action"); } }
    string installed; public string Installed { get { return installed; } set { installed = value; Notify("Installed"); } }
    string latest; public string Latest { get { return latest; } set { latest = value; Notify("Latest"); } }
    string latestTip; public string LatestTip { get { return latestTip; } set { latestTip = value; Notify("LatestTip"); } }
    string runStatus; public string RunStatus { get { return runStatus; } set { runStatus = value; Notify("RunStatus"); Notify("Action"); } }
    string runNote; public string RunNote { get { return runNote; } set { runNote = value; Notify("RunNote"); } }
    public bool ForUpdate { get; set; }
    bool locked; public bool Locked { get { return locked; } set { locked = value; Notify("Locked"); Notify("Action"); } }
    bool removed; public bool Removed { get { return removed; } set { removed = value; Notify("Removed"); Notify("Action"); } }
    string removeText = ""; public string RemoveText { get { return removeText; } set { removeText = value; Notify("RemoveText"); } }
    string removeTip; public string RemoveTip { get { return removeTip; } set { removeTip = value; Notify("RemoveTip"); } }
    bool highlight; public bool Highlight { get { return highlight; } set { highlight = value; Notify("Highlight"); } }

    public string Action {
        get {
            if (IsHeader) return "";
            if (removed) return "Removed";
            if (!string.IsNullOrEmpty(runStatus)) return runStatus;
            if (ForUpdate) return locked ? "Locked" : (selected ? "Will update" : "Not selected");
            if (state == PCList.Checking) return "Checking...";
            if (state == PCList.Failed) return "Unknown";
            if (state == PCList.Unlisted) return "Not in your list";
            if (state == PCList.Installed) return "Nothing to do";
            if (state == PCList.Update) return "See Updates tab";
            if (!selected) return "Not selected";
            if (method == "manual") return "Manual step";
            if (method == "installer") return "Will run setup";
            return "Will install";
        }
    }
}

public class PCRowList : ObservableCollection<PCRow> {
    public void ReplaceAll(List<PCRow> rows) {
        Items.Clear();
        foreach (PCRow r in rows) Items.Add(r);
        OnPropertyChanged(new PropertyChangedEventArgs("Count"));
        OnPropertyChanged(new PropertyChangedEventArgs("Item[]"));
        OnCollectionChanged(new NotifyCollectionChangedEventArgs(NotifyCollectionChangedAction.Reset));
    }
}

public class PCSummary {
    public int Installed, Update, Missing, Unlisted, Unknown, WouldInstall, WouldSetup, WouldManual, NotSelected, Total, Removed;
}

public static class PCList {
    public const string Checking = "Checking", Failed = "Could not check", Installed = "Already installed", Update = "Needs update", Missing = "Not installed", Unlisted = "Not in your list", RemovedSection = "Removed";
    static readonly string[] Order = { Checking, Failed, Installed, Update, Missing, Unlisted };

    static bool Has(string text, string q) { return text != null && text.IndexOf(q, StringComparison.OrdinalIgnoreCase) >= 0; }

    public static void Rebuild(PCRowList target, IList<PCRow> rows, string search, string state, IList<string> collapsed, bool showRemoved) {
        bool searching = !string.IsNullOrWhiteSpace(search);
        string q = searching ? search.Trim() : "";
        var output = new List<PCRow>();
        foreach (string s in Order) {
            if (!string.IsNullOrEmpty(state) && s != state) continue;
            var matches = new List<PCRow>();
            foreach (PCRow r in rows) {
                if (!r.Removed && r.State == s && (!searching || Has(r.Name, q) || Has(r.Description, q) || Has(r.Group, q))) matches.Add(r);
            }
            if (matches.Count == 0) continue;
            matches.Sort((a, b) => {
                int c = string.Compare(a.Group, b.Group, StringComparison.OrdinalIgnoreCase);
                return c != 0 ? c : string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
            });
            bool open = searching || !collapsed.Contains(s);
            bool all = true;
            foreach (PCRow r in matches) if (!r.IsSelected) { all = false; break; }
            var header = new PCRow { IsHeader = true, Key = s, Name = s, Children = matches, CanToggle = !searching, CanSelect = s != Unlisted && s != Update };
            header.HeaderText = ((char)(open ? 0x25BE : 0x25B8)).ToString() + "  " + s + "  (" + matches.Count + ")";
            header.SetSelectedQuietly(all);
            output.Add(header);
            if (open) output.AddRange(matches);
        }
        if (showRemoved && string.IsNullOrEmpty(state)) {
            var gone = new List<PCRow>();
            foreach (PCRow r in rows) {
                if (r.Removed && (!searching || Has(r.Name, q) || Has(r.Description, q) || Has(r.Group, q))) gone.Add(r);
            }
            if (gone.Count > 0) {
                gone.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
                var header = new PCRow { IsHeader = true, Key = RemovedSection, Name = RemovedSection, Children = gone, CanToggle = false, CanSelect = false };
                header.HeaderText = ((char)0x25BE).ToString() + "  Removed from your list  (" + gone.Count + ")";
                output.Add(header);
                output.AddRange(gone);
            }
        }
        target.ReplaceAll(output);
    }

    public static void SyncHeaders(IEnumerable<PCRow> items) {
        foreach (PCRow h in items) {
            if (!h.IsHeader || h.Children == null) continue;
            bool all = true;
            foreach (PCRow r in h.Children) if (!r.IsSelected) { all = false; break; }
            h.SetSelectedQuietly(all);
        }
    }

    public static PCSummary Summarize(IEnumerable<PCRow> rows) {
        var x = new PCSummary();
        foreach (PCRow r in rows) {
            if (r.Removed) { x.Removed++; continue; }
            x.Total++;
            if (r.State == Installed) x.Installed++;
            else if (r.State == Update) x.Update++;
            else if (r.State == Missing) {
                x.Missing++;
                if (!r.IsSelected) x.NotSelected++;
                else if (r.Method == "manual") x.WouldManual++;
                else if (r.Method == "installer") x.WouldSetup++;
                else x.WouldInstall++;
            }
            else if (r.State == Unlisted) x.Unlisted++;
            else x.Unknown++;
        }
        return x;
    }

    public static int CountSelected(IEnumerable<PCRow> rows) {
        int n = 0; foreach (PCRow r in rows) if (r.IsSelected) n++; return n;
    }
}
'@
}

function Read-JsonFile([string]$RelativePath) {
    # Assign first: in PowerShell 5.1 ConvertFrom-Json emits a JSON array as one object.
    $data = Get-Content -LiteralPath (Join-Path $Root $RelativePath) -Raw -Encoding UTF8 | ConvertFrom-Json
    return $data
}

function Set-RowRemoved($Row, [bool]$Removed) {
    $Row.Removed = $Removed
    if ($Removed) { $Row.SetSelectedQuietly($false); $Row.RemoveText = 'Restore'; $Row.RemoveTip = 'Put this back in your list' }
    else { $Row.RemoveText = [string][char]0x2715; $Row.RemoveTip = 'Remove from your list' }
}

function New-Rows($Items, [switch]$Removable) {
    $list = New-Object 'System.Collections.Generic.List[PCRow]'
    foreach ($i in $Items) {
        $row = New-Object PCRow
        $row.Key = $i.id; $row.Name = $i.name; $row.Group = $i.category
        $row.Description = $i.description; $row.Risky = [bool]$i.risky; $row.Status = ''
        $row.State = [PCList]::Checking; $row.Installed = '...'; $row.Latest = '...'
        if ($i.method) { $row.Method = $i.method }
        $row.Link = $i.link
        Set-RowButtons $row
        if ($Removable) { Set-RowRemoved $row $false }
        $list.Add($row)
    }
    return , $list
}

function Set-RowButtons($Row) {
    if ($Row.Method -eq 'unlisted') { $Row.Btn1Text = 'Add'; $Row.Btn2Text = 'Hide'; return }
    if ($Row.Method -eq 'winget') { $Row.Btn1Text = ''; $Row.Btn2Text = ''; return }
    $Row.Btn1Text = if ($Row.Link) { 'Link' } else { '' }
    $Row.Btn2Text = if ($Row.Method -eq 'todo') { '' } else { 'Setup file' }
}

function Read-UserData {
    $data = @{ hidden = @(); added = @(); installers = @{}; todos = @(); removed = @(); removedSteps = @(); steps = @(); columns = @{} }
    if (Test-Path -LiteralPath $script:UserDataPath) {
        $saved = Get-Content -LiteralPath $script:UserDataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.hidden) { $data.hidden = @($saved.hidden) }
        if ($saved.added) { $data.added = @($saved.added) }
        if ($saved.todos) { $data.todos = @($saved.todos) }
        if ($saved.removed) { $data.removed = @($saved.removed) }
        if ($saved.removedSteps) { $data.removedSteps = @($saved.removedSteps) }
        if ($saved.steps) { $data.steps = @($saved.steps) }
        if ($saved.columns) { foreach ($p in $saved.columns.PSObject.Properties) { $data.columns[$p.Name] = @($p.Value) } }
        if ($saved.installers) { foreach ($p in $saved.installers.PSObject.Properties) { $data.installers[$p.Name] = $p.Value } }
    }
    return $data
}

function Save-UserData {
    ConvertTo-Json -InputObject $script:UserData -Depth 4 | Set-Content -LiteralPath $script:UserDataPath -Encoding UTF8
}

function ConvertTo-StoredPath([string]$Path) {
    # A setup file inside the PCSetup folder is saved relative, so it still works when the USB letter changes.
    $prefix = $script:Root.TrimEnd('\') + '\'
    if ($Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $Path.Substring($prefix.Length) }
    return $Path
}

function ConvertFrom-StoredPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $script:Root $Path
}

function Set-RowInstaller($Row, [string]$Path) {
    $Row.Method = 'installer'
    $Row.BtnTip = $Path
    $script:UserData.installers[$Row.Key] = ConvertTo-StoredPath $Path
}

function Invoke-RowLink($Row) {
    # Only web links are ever opened.
    if ($Row.Link -match '^https?://') { Start-Process $Row.Link }
}

function Select-RowInstaller($Row) {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = "Choose the setup file for $($Row.Name)"
    $dialog.Filter = 'Setup files (*.exe;*.msi)|*.exe;*.msi|All files (*.*)|*.*'
    if ($dialog.ShowDialog()) {
        Set-RowInstaller $Row $dialog.FileName
        Save-UserData
        Update-AppList
        Update-Summary
    }
}

function Add-UnlistedApp($Row) {
    $e = $script:UnlistedEntries[$Row.Key]
    $slug = ($Row.Name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    $isWinget = $e.Source -eq 'winget'
    $app = [pscustomobject]@{ id = $(if ($isWinget) { $e.Id } else { "manual.$slug" }); name = $Row.Name; category = 'Utilities'
        description = 'Added from this PC.'; method = $(if ($isWinget) { 'winget' } else { 'manual' }); detect = $e.Name }
    Add-ProfileItem 'myApps' $app
    $script:Apps = @($script:Apps) + $app
    $script:AppById[$app.id] = $app
    $Row.Key = $app.id; $Row.Group = $app.category; $Row.Description = $app.description
    $Row.Method = $app.method; $Row.CanSelect = $true
    $Row.State = [PCList]::Installed; $Row.Latest = 'Not tracked'
    $Row.IsSelected = $true
    Set-RowButtons $Row
    Set-RowRemoved $Row $false
    Add-ProfileApp $app.id
    Update-AppList
    Update-Summary
}

function Hide-UnlistedApp($Row) {
    $script:UserData.hidden = @($script:UserData.hidden) + $Row.Key
    Save-UserData
    [void]$script:AppRows.Remove($Row)
    Update-AppList
    Update-Summary
}

function Remove-UnlistedRows {
    [void]$script:AppRows.RemoveAll([Predicate[PCRow]] { param($r) $r.Method -eq 'unlisted' })
}

function Add-UnlistedRows($Entries) {
    $ids = @{}; $names = @{}
    foreach ($r in $script:AppRows) {
        $ids[$r.Key] = $true; $names[$r.Name] = $true
        $a = $script:AppById[$r.Key]
        if ($a -and $a.detect) { $names[$a.detect] = $true }
    }
    $found = Get-UnlistedEntries -Entries $Entries -CatalogIds $ids -CatalogNames $names -IgnorePatterns $script:IgnorePatterns -HiddenIds $script:UserData.hidden
    $script:UnlistedEntries = @{}
    foreach ($e in $found) {
        $script:UnlistedEntries[$e.Id] = $e
        $row = New-Object PCRow
        $row.Key = $e.Id; $row.Name = $e.Name; $row.Group = 'Found on this PC'; $row.Description = ''
        $row.Status = ''; $row.Method = 'unlisted'; $row.CanSelect = $false
        $row.Installed = $e.Version; $row.Latest = ''; $row.State = [PCList]::Unlisted
        Set-RowButtons $row
        $script:AppRows.Add($row)
    }
}

function Read-Profile {
    # Everything personal lives in the profile. Without one, PCSetup starts blank.
    $p = $null
    if (Test-Path -LiteralPath $script:ProfilePath) {
        try { $p = Get-Content -LiteralPath $script:ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $p = $null }
    }
    if (-not $p) { $p = New-Object psobject }
    foreach ($name in 'apps', 'tweaks', 'myApps', 'mySteps') {
        if (-not $p.PSObject.Properties[$name]) { Add-Member -InputObject $p -NotePropertyName $name -NotePropertyValue @() }
    }
    if (-not $p.PSObject.Properties['values'] -or -not $p.values) { Add-Member -InputObject $p -NotePropertyName values -NotePropertyValue (New-Object psobject) -Force }
    return $p
}

function Get-DetectPath([string]$Id) {
    # Where to look for an app winget cannot see. Your profile can hold your own location for an app.
    $own = $script:Profile.PSObject.Properties['detectPaths']
    if ($own -and $own.Value -and $own.Value.PSObject.Properties[$Id]) { return [string]$own.Value.PSObject.Properties[$Id].Value }
    $app = $script:AppById[$Id]
    if ($app) { return [string]$app.detectPath }
    return ''
}

function Add-ProfileItem([string]$List, $Item) {
    $script:Profile.$List = @($script:Profile.$List) + $Item
    Save-Profile
}

function Test-PCName([string]$Name) {
    return ($Name -match '^[A-Za-z0-9-]{1,15}$') -and ($Name -notmatch '^\d+$') -and ($Name -notmatch '^-|-$')
}

function Read-TextInput([string]$Prompt, [string]$Default) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    return [Microsoft.VisualBasic.Interaction]::InputBox($Prompt, 'PCSetup', $Default)
}

function Update-PCNameRows {
    foreach ($row in $script:TweakRows) {
        $tweak = Get-TweakById $row.Key
        if ($tweak.type -ne 'pcname') { continue }
        $row.Btn1Text = 'Change name'
        $row.Description = if ($tweak.set) { "New name: $($tweak.set). Takes effect after a restart." } else { 'No name chosen yet. Press Change name.' }
    }
}

function Set-PCNameFromUser($Row) {
    $tweak = Get-TweakById $Row.Key
    if (-not $tweak -or $tweak.type -ne 'pcname') { return }
    $name = ([string](Read-TextInput 'Name for this PC. Use letters, numbers and hyphens, up to 15 characters.' ([string]$tweak.set))).Trim()
    if (-not $name) { return }
    if (-not (Test-PCName $name)) { Show-Notice 'That name will not work. Use letters, numbers and hyphens only, up to 15 characters, and not only numbers.'; return }
    $tweak.set = $name
    Add-Member -InputObject $script:Profile.values -NotePropertyName $tweak.id -NotePropertyValue $name -Force
    Save-Profile
    $Row.Status = ''
    Update-PCNameRows
}

function Save-Profile {
    ConvertTo-Json -InputObject $script:Profile -Depth 4 | Set-Content -LiteralPath $script:ProfilePath -Encoding UTF8
}

function Add-ProfileApp([string]$Id) {
    if (@($script:Profile.apps) -notcontains $Id) { $script:Profile.apps = @($script:Profile.apps) + $Id; Save-Profile }
}

function Save-ProfileApps {
    $ids = @($script:AppRows | Where-Object { $_.IsSelected -and -not $_.Removed -and $_.Method -ne 'unlisted' } | ForEach-Object Key)
    if (-not (Show-Question "Save the $($ids.Count) ticked apps as your profile? This replaces the apps saved in your profile.")) { return }
    $script:Profile.apps = $ids
    Save-Profile
    Add-Log "Profile saved with $($ids.Count) apps."
}

function Save-ProfileTweaks {
    $ids = @($script:TweakRows | Where-Object IsSelected | ForEach-Object Key)
    if (-not (Show-Question "Save the $($ids.Count) ticked settings as your profile? This replaces the settings ticked in your profile.")) { return }
    $script:Profile.tweaks = $ids
    Save-Profile
    Add-Log "Profile saved with $($ids.Count) settings."
}

function Switch-AppRemoved($Row) {
    # Removing only hides the app. It can be brought back with Show removed.
    if ($Row.Removed) {
        Set-RowRemoved $Row $false
        $script:UserData.removed = @($script:UserData.removed | Where-Object { $_ -ne $Row.Key })
    } else {
        Set-RowRemoved $Row $true
        $script:UserData.removed = @($script:UserData.removed) + $Row.Key
    }
    Save-UserData
    Update-AppList
    Update-UpdateList
}

function Get-ColumnHeader([string]$Prefix) {
    if ($Prefix -eq 'A') { return $script:AppHeader }
    return $script:UpdateHeader
}

function Sync-ColumnWidths([string]$Prefix) {
    # Rows follow the heading widths through shared resources.
    $header = Get-ColumnHeader $Prefix
    foreach ($i in 2..5) {
        $width = $header.ColumnDefinitions[$i].Width
        if ($width.IsAbsolute) { $script:RootPanel.Resources["Col$Prefix$i"] = $width }
    }
}

function Set-ColumnWidths([string]$Prefix, $Widths) {
    $list = @($Widths)
    if ($list.Count -ne 4 -or @($list | Where-Object { [double]$_ -lt 40 -or [double]$_ -gt 900 }).Count) { return }
    $header = Get-ColumnHeader $Prefix
    foreach ($i in 2..5) { $header.ColumnDefinitions[$i].Width = New-Object System.Windows.GridLength ([double]$list[$i - 2]) }
    Sync-ColumnWidths $Prefix
}

function Save-ColumnWidths {
    foreach ($prefix in 'A', 'U') {
        $header = Get-ColumnHeader $prefix
        $script:UserData.columns[$prefix] = @(foreach ($i in 2..5) { [Math]::Round($header.ColumnDefinitions[$i].Width.Value) })
    }
    Save-UserData
}

function Find-VisualChild($Parent, [type]$Type) {
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent); $i++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)
        if ($child -is $Type) { return $child }
        $found = Find-VisualChild $child $Type
        if ($found) { return $found }
    }
    return $null
}

function Show-UpdateRow($Row) {
    # Opens the Updates tab with this app highlighted and scrolled into view.
    foreach ($r in $script:UpdateRows) { $r.Highlight = $false }
    $target = $script:UpdateRows | Where-Object Key -eq $Row.Key | Select-Object -First 1
    $script:UpdatesTab.IsSelected = $true
    if (-not $target) { return }
    $target.Highlight = $true
    $script:JumpIndex = $script:UpdateItems.IndexOf($target)
    [void]$script:UpdateList.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Loaded, [Action] {
        try {
            $panel = Find-VisualChild $script:UpdateList ([System.Windows.Controls.VirtualizingStackPanel])
            if ($panel -and $script:JumpIndex -ge 0) { $panel.BringIndexIntoViewPublic($script:JumpIndex) }
        } catch { }
    })
}

function Start-SearchJob([string]$Query) {
    return Start-Job -ArgumentList $Query -ScriptBlock {
        param($q)
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $env:Path += ';' + (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
        winget search --query $q --source winget --count 25 --accept-source-agreements --disable-interactivity | Out-String
    }
}

function Start-AppSearch {
    $query = $script:AddAppName.Text.Trim()
    if (-not $query) { $script:AddAppInfo.Text = 'Type the name of the app first.'; return }
    $script:AddAppSearch.IsEnabled = $false
    $script:AddAppInfo.Text = 'Searching winget...'
    $script:SearchJob = Start-SearchJob $query
    $script:SearchStarted = Get-Date
    if (-not $script:SearchTimer) {
        $script:SearchTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:SearchTimer.Interval = [TimeSpan]::FromMilliseconds(300)
        $script:SearchTimer.Add_Tick({ Invoke-SearchTick })
    }
    $script:SearchTimer.Start()
}

function Invoke-SearchTick {
    if ($script:SearchJob.State -eq 'Running' -and ((Get-Date) - $script:SearchStarted).TotalSeconds -lt 60) { return }
    $script:SearchTimer.Stop()
    $text = ''
    try {
        if ($script:SearchJob.State -eq 'Completed') { $text = (Receive-Job $script:SearchJob -ErrorAction SilentlyContinue | Out-String) } else { Stop-Job $script:SearchJob }
        Remove-Job $script:SearchJob -Force
    } catch { $text = '' }
    Complete-AppSearch $text
}

function Complete-AppSearch([string]$Text) {
    $script:AddAppSearch.IsEnabled = $true
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($e in (ConvertFrom-WingetList -Text $Text)) {
        if (-not $e.Id) { continue }
        $note = if ($script:AppById.ContainsKey($e.Id)) { '   (already in your list)' } else { '' }
        $results.Add([pscustomobject]@{ Id = $e.Id; Name = $e.Name; Display = ('{0,-38} {1,-40} {2}{3}' -f $e.Name, $e.Id, $e.Version, $note) })
    }
    $script:AddAppResults.ItemsSource = $results
    $script:AddAppInfo.Text = if ($results.Count) { "$($results.Count) found. Pick one and press Add selected." }
        else { 'Nothing found in winget. You can add it as a manual app with the button below.' }
}

function Add-CatalogApp($App) {
    $existing = $script:AppRows | Where-Object Key -eq $App.id | Select-Object -First 1
    if ($existing) {
        if ($existing.Removed) { Switch-AppRemoved $existing; $script:AddAppInfo.Text = "$($existing.Name) was removed earlier and is back in your list."; return }
        $script:AddAppInfo.Text = "$($existing.Name) is already in your list."
        return
    }
    Add-ProfileItem 'myApps' $App
    $script:Apps = @($script:Apps) + $App
    $script:AppById[$App.id] = $App
    $row = (New-Rows @($App) -Removable)[0]
    if ($script:LastIndex) {
        $s = Get-AppInstallState -Index $script:LastIndex -Id $App.id -Name $(if ($App.detect) { $App.detect } else { $App.name })
        $row.Installed = $s.Installed; $row.Latest = $s.Latest; $row.LatestTip = $s.Note; $row.State = $s.State
        $row.CanSelect = $s.State -ne [PCList]::Update
    }
    $row.SetSelectedQuietly($true)
    $script:AppRows.Add($row)
    Add-ProfileApp $App.id
    Update-AppList
    Update-UpdateList
    $script:AddAppInfo.Text = "$($App.name) was added to your list under $($App.category) and ticked."
    Add-Log "Added $($App.name) to your list."
}

function Add-WingetApp {
    $pick = $script:AddAppResults.SelectedItem
    if (-not $pick) { $script:AddAppInfo.Text = 'Pick an app in the results first.'; return }
    Add-CatalogApp ([pscustomobject]@{ id = $pick.Id; name = $pick.Name; category = [string]$script:AddAppCategory.SelectedItem
        description = 'Added by you.'; method = 'winget' })
}

function Add-ManualApp {
    $name = $script:AddAppName.Text.Trim()
    if (-not $name) { $script:AddAppInfo.Text = 'Type the name of the app first.'; return }
    $link = $script:AddAppLink.Text.Trim()
    if ($link -and $link -notmatch '^https?://') { $script:AddAppInfo.Text = 'The link must start with http:// or https://'; return }
    $slug = ($name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $slug) { $script:AddAppInfo.Text = 'The name needs at least one letter or number.'; return }
    $app = [pscustomobject]@{ id = "manual.$slug"; name = $name; category = [string]$script:AddAppCategory.SelectedItem
        description = 'Added by you.'; method = 'manual'; link = $link; detect = $name }
    Add-CatalogApp $app
}

function Add-ChecklistStep {
    $text = $script:StepText.Text.Trim()
    if (-not $text) { return }
    $step = [pscustomobject]@{ id = 'custom.' + [guid]::NewGuid().ToString('N').Substring(0, 8); name = $text; category = [string]$script:StepSection.SelectedItem; description = '' }
    Add-ProfileItem 'mySteps' $step
    foreach ($n in (New-Rows @($step) -Removable)) { $script:ChecklistRows.Add($n) }
    $script:StepText.Text = ''
    [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:ChecklistRows).Refresh()
    Update-ChecklistCount
}

function Switch-StepRemoved($Row) {
    if ($Row.Key -like 'todo.*') {
        # An app to-do is simply dropped. It comes back if that app is chosen again.
        $script:UserData.todos = @($script:UserData.todos | Where-Object { "todo.$($_.id)" -ne $Row.Key })
        [void]$script:ChecklistRows.Remove($Row)
    } elseif ($Row.Removed) {
        Set-RowRemoved $Row $false
        $script:UserData.removedSteps = @($script:UserData.removedSteps | Where-Object { $_ -ne $Row.Key })
    } else {
        Set-RowRemoved $Row $true
        $script:UserData.removedSteps = @($script:UserData.removedSteps) + $Row.Key
    }
    Save-UserData
    Save-ChecklistState
    [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:ChecklistRows).Refresh()
}

function New-GroupedView($Rows) {
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($Rows)
    $view.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription 'Group'))
    return , $view
}

function Add-Log([string[]]$Lines) {
    $stamp = '{0:yyyy-MM-dd HH:mm:ss}  ' -f (Get-Date)
    $text = ($Lines | ForEach-Object { $stamp + $_ }) -join "`r`n"
    $script:LogBox.AppendText($text + "`r`n")
    $script:LogBox.ScrollToEnd()
    $dir = Split-Path $script:LogPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    Add-Content -LiteralPath $script:LogPath -Value $text -Encoding UTF8
}

function Show-Question([string]$Text) {
    return [System.Windows.MessageBox]::Show($Text, 'PCSetup', 'YesNo', 'Question') -eq 'Yes'
}

function Show-Notice([string]$Text) {
    [void][System.Windows.MessageBox]::Show($Text, 'PCSetup', 'OK', 'Information')
}

function Update-AppList {
    [PCList]::Rebuild($script:AppItems, $script:AppRows, $script:AppSearch.Text, $script:StateFilter, $script:Collapsed, [bool]$script:ShowRemoved.IsChecked)
    $script:AppListEmpty.Visibility = if ($script:AppItems.Count -eq 0) { 'Visible' } else { 'Collapsed' }
}

function Update-Summary {
    [PCList]::SyncHeaders($script:AppItems)
    $x = [PCList]::Summarize($script:AppRows)
    $script:FilterAll.Content = "All  $($x.Total)"
    $script:FilterInstalled.Content = "Already installed  $($x.Installed)"
    $script:FilterUpdate.Content = "Needs update  $($x.Update)"
    $script:FilterMissing.Content = "Not installed  $($x.Missing)"
    $script:FilterUnlisted.Content = "Not in your list  $($x.Unlisted)"
    $script:ShowRemoved.Content = "Show removed ($($x.Removed))"
    if ($x.Unknown -gt 0 -and $x.Installed + $x.Update + $x.Missing -eq 0) {
        $script:PlanSummary.Text = 'Checking which apps are on this PC...'
    } else {
        $extra = ''
        if ($x.WouldSetup -gt 0) { $extra += " $($x.WouldSetup) would run your setup file," }
        if ($x.WouldManual -gt 0) { $extra += " $($x.WouldManual) added to your Checklist," }
        $script:PlanSummary.Text = "When you press Install: $($x.WouldInstall) will install,$extra $($x.Installed) left as they are, $($x.Update) have updates on the Updates tab, $($x.NotSelected) not selected."
    }
    $busy = Test-RunBusy
    $toInstall = $x.WouldInstall + $x.WouldSetup + $x.WouldManual
    $script:InstallSelected.Content = "Install selected ($toInstall)"
    $script:InstallSelected.IsEnabled = (-not $busy) -and $toInstall -gt 0
    $toUpdate = [PCList]::CountSelected($script:UpdateRows)
    $locked = @($script:UpdateRows | Where-Object Locked).Count
    $script:RunUpdates.Content = "Update selected ($toUpdate)"
    $script:RunUpdates.IsEnabled = (-not $busy) -and $toUpdate -gt 0
    $script:UpdateSummary.Text = "$($script:UpdateRows.Count - $locked) apps have updates, $toUpdate selected, $locked locked."
    $script:TweakCount.Text = "$([PCList]::CountSelected($script:TweakRows)) of $($script:TweakRows.Count) selected"
}

function Set-UpdateRowLock($Row, [bool]$Locked) {
    $Row.Locked = $Locked
    $Row.Btn1Text = if ($Locked) { 'Unlock' } else { 'Lock' }
    $Row.CanSelect = -not $Locked
    if ($Locked) { $Row.IsSelected = $false }
}

function Update-UpdateList {
    # Keeps existing rows so ticks and results survive a re-check.
    $old = @{}; foreach ($r in $script:UpdateRows) { $old[$r.Key] = $r }
    $rows = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($a in $script:AppRows) {
        $hasUpdate = $a.State -eq [PCList]::Update -and $a.Method -eq 'winget' -and -not $a.Removed
        if (-not $hasUpdate -and -not $script:Locks.ContainsKey($a.Key)) { continue }
        $row = $old[$a.Key]
        if (-not $row) { $row = New-Object PCRow; $row.Key = $a.Key; $row.ForUpdate = $true; $row.Status = '' }
        $row.Name = $a.Name; $row.Group = $a.Group; $row.Description = $a.Description
        $row.Installed = $a.Installed; $row.Latest = $a.Latest
        $rows.Add($row); $seen[$a.Key] = $true
    }
    foreach ($id in $script:Locks.Keys) {
        if ($seen.ContainsKey($id)) { continue }
        $row = $old[$id]
        if (-not $row) { $row = New-Object PCRow; $row.Key = $id; $row.ForUpdate = $true; $row.Status = '' }
        $row.Name = $script:Locks[$id]; $row.Installed = '-'; $row.Latest = '-'
        $rows.Add($row)
    }
    foreach ($r in $rows) { Set-UpdateRowLock $r $script:Locks.ContainsKey($r.Key) }
    $sorted = New-Object 'System.Collections.Generic.List[PCRow]'
    foreach ($r in @($rows | Sort-Object Locked, Name)) { $sorted.Add($r) }
    $script:UpdateRows = $sorted
    $script:UpdateItems.ReplaceAll($sorted)
    $script:UpdateListEmpty.Visibility = if ($sorted.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    Update-Summary
}

function Set-UpdateSelection([bool]$Selected) {
    [PCRow]::Suspended = $true
    try { foreach ($r in $script:UpdateRows) { $r.IsSelected = $Selected -and -not $r.Locked } }
    finally { [PCRow]::Suspended = $false }
    Update-Summary
}

function Set-ProfileSelection($Rows, $Keys) {
    # Risky rows are never ticked by a profile; they need an explicit tick.
    $lookup = @{}; foreach ($k in $Keys) { $lookup[$k] = $true }
    [PCRow]::Suspended = $true
    try { foreach ($r in $Rows) { $r.IsSelected = ($lookup.ContainsKey($r.Key) -and -not $r.Risky -and -not $r.Removed) } }
    finally { [PCRow]::Suspended = $false }
    Update-AppList
    Update-Summary
}

function Switch-AppSection([string]$State) {
    if ($script:Collapsed.Contains($State)) { [void]$script:Collapsed.Remove($State) } else { $script:Collapsed.Add($State) }
    Update-AppList
}

function Set-StateFilter([string]$State) {
    $script:StateFilter = $State
    # Choosing a status means you want to see those apps.
    if ($State) { [void]$script:Collapsed.Remove($State) }
    Update-AppList
}

function Complete-InstalledCheck([string]$ListText, [bool]$Checked, [string]$PinText = '') {
    $index = $null; $entries = $null
    $script:Locks = @{}
    $script:LastIndex = $null
    if ($Checked) {
        $entries = ConvertFrom-WingetList -Text $ListText
        $index = New-WingetIndex -Entries $entries
        $script:LastIndex = $index
        $script:Locks = ConvertFrom-WingetPins -Text $PinText
    }
    foreach ($row in $script:AppRows) {
        if ($index) {
            $app = $script:AppById[$row.Key]
            $detect = if ($app -and $app.detect) { $app.detect } else { $row.Name }
            $s = Get-AppInstallState -Index $index -Id $row.Key -Name $detect -DetectPath (Get-DetectPath $row.Key)
            $row.Installed = $s.Installed; $row.Latest = $s.Latest; $row.LatestTip = $s.Note; $row.State = $s.State
            # Updates are chosen on the Updates tab, so the tick box is hidden here.
            $row.CanSelect = $s.State -ne [PCList]::Update
        } else {
            $row.Installed = '?'; $row.Latest = '?'; $row.State = [PCList]::Failed
        }
    }
    if ($index) { Add-UnlistedRows $entries; Sync-ChecklistTodos }
    Update-AppList
    Update-UpdateList
    $script:CheckAgain.IsEnabled = $true
    $script:CheckInfo.Text = if ($Checked) { 'Checked at {0:h:mm tt}.' -f (Get-Date) } else { 'Could not read the installed app list. Is winget working?' }
    if (-not $Checked) { Add-Log 'Could not read the installed app list.' }
    if (-not $Checked -and -not $script:RepairTried) { Request-WingetRepair; return }
    if ($script:LookForSavedRun -and $Checked) { $script:LookForSavedRun = $false; Resume-SavedRun }
}

function Set-SystemInfo {
    $version = Get-WingetVersion
    $wingetText = if ($version) { "winget $version" } else { 'winget not found' }
    $script:SystemInfo.Text = "Windows $(Get-WindowsMajor)   |   $wingetText"
}

function Request-WingetRepair {
    # Offered once per session, so a repair that cannot help does not keep asking.
    $script:RepairTried = $true
    if (Show-Question 'Winget is missing or not working, and PCSetup needs it to install apps. Repair it now? PCSetup uses its offline copy, or downloads winget from Microsoft if there is none.') {
        Start-WingetRepair
    } else { Add-Log 'Winget repair was declined.' }
}

function Start-RepairJob {
    return Start-Job -ArgumentList $script:Root -ScriptBlock {
        param($r)
        . (Join-Path $r 'lib\Winget.ps1')
        . (Join-Path $r 'lib\Installers.ps1')
        Repair-Winget -BootstrapDir (Join-Path $r 'bootstrap') -WorkDir (Join-Path $env:TEMP 'PCSetup-winget')
    }
}

function Start-WingetRepair {
    $script:RunBanner.Visibility = 'Visible'
    $script:StopRun.Visibility = 'Collapsed'
    $script:RunProgress.Visibility = 'Collapsed'
    $script:RunText.Text = 'Repairing winget. This can take a few minutes.'
    $script:CheckAgain.IsEnabled = $false
    Add-Log 'Repairing winget.'
    $script:RepairJob = Start-RepairJob
    $script:RepairStarted = Get-Date
    if (-not $script:RepairTimer) {
        $script:RepairTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:RepairTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:RepairTimer.Add_Tick({ Invoke-RepairTick })
    }
    $script:RepairTimer.Start()
}

function Invoke-RepairTick {
    $job = $script:RepairJob
    if ($job.State -eq 'Running' -and ((Get-Date) - $script:RepairStarted).TotalMinutes -lt 20) { return }
    $script:RepairTimer.Stop()
    $lines = @()
    if ($job.State -eq 'Running') { Stop-Job $job; $lines += 'The repair took too long and was stopped.' }
    else { try { $lines = @(Receive-Job $job | ForEach-Object { [string]$_ }) } catch { $lines += "The repair stopped: $($_.Exception.Message)" } }
    Remove-Job $job -Force
    Complete-WingetRepair $lines
}

function Complete-WingetRepair([string[]]$Lines) {
    $ok = $Lines -contains 'RESULT:OK'
    $shown = @($Lines | Where-Object { $_ -notlike 'RESULT:*' })
    if ($shown.Count) { Add-Log $shown }
    Set-SystemInfo
    if ($ok) {
        $script:RunText.Text = 'Winget repaired.'
        Add-Log 'Winget repaired.'
        Start-InstalledCheck
    } else {
        $script:RunText.Text = 'Winget could not be repaired. Details are on the Log tab.'
        Add-Log 'Winget could not be repaired.'
        $script:CheckAgain.IsEnabled = $true
    }
}

function Test-WingetListText([string]$Text) {
    # An error message from a broken winget is not a list of apps.
    return $Text -match '(?m)^\s*Name\s+Id\s+Version'
}

function Start-InstalledCheck {
    param([switch]$KeepResults)
    Remove-UnlistedRows
    foreach ($r in $script:AppRows) { $r.State = [PCList]::Checking; $r.Installed = '...'; $r.Latest = '...'; $r.LatestTip = $null }
    if (-not $KeepResults) {
        foreach ($r in $script:AppRows) { $r.RunStatus = ''; $r.RunNote = $null }
        foreach ($r in $script:UpdateRows) { $r.RunStatus = ''; $r.RunNote = $null }
    }
    Update-AppList
    Update-Summary
    $script:CheckAgain.IsEnabled = $false
    $script:CheckInfo.Text = 'This can take up to a minute.'
    # Script-scope state, not GetNewClosure: a closure could not see this file's functions.
    $script:CheckJob = Start-CheckJob
    $script:CheckStarted = Get-Date
    $script:CheckTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:CheckTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:CheckTimer.Add_Tick({ Invoke-CheckTick })
    $script:CheckTimer.Start()
}

function Start-CheckJob {
    return Start-Job -ScriptBlock {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $env:Path += ';' + (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
        # A fresh install has not accepted the source terms yet, and winget cannot prompt here.
        (winget list --accept-source-agreements --disable-interactivity | Out-String) + "`n@@PCSETUP-PINS@@`n" + (winget pin list --accept-source-agreements --disable-interactivity | Out-String)
    }
}

function Invoke-CheckTick {
    $done = $script:CheckJob.State -ne 'Running'
    if (-not $done -and ((Get-Date) - $script:CheckStarted).TotalSeconds -lt 300) { return }
    $script:CheckTimer.Stop()
    $text = ''
    # A missing winget makes the job report an error, which must count as a failed check, not a crash.
    try {
        if ($script:CheckJob.State -eq 'Completed') { $text = (Receive-Job $script:CheckJob -ErrorAction SilentlyContinue | Out-String) } else { Stop-Job $script:CheckJob }
        Remove-Job $script:CheckJob -Force
    } catch { $text = '' }
    $parts = $text -split '@@PCSETUP-PINS@@'
    Complete-InstalledCheck -ListText $parts[0] -Checked (Test-WingetListText $parts[0]) -PinText $(if ($parts.Count -gt 1) { $parts[1] } else { '' })
}

function Show-PlannedCommands {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('--- Commands Install selected would use (nothing was run) ---')
    $rows = @($script:AppRows | Where-Object { $_.State -eq [PCList]::Missing -and $_.IsSelected -and $_.Method -eq 'winget' })
    $lines.Add("WOULD INSTALL ($($rows.Count))")
    foreach ($r in $rows) { $lines.Add("  $($r.Name): " + (Get-WingetCommandText -Id $r.Key)) }
    $setup =@($script:AppRows | Where-Object { $_.State -eq [PCList]::Missing -and $_.IsSelected -and $_.Method -eq 'installer' })
    $lines.Add("WOULD RUN YOUR SETUP FILE ($($setup.Count))")
    foreach ($r in $setup) { $lines.Add("  $($r.Name): $($r.BtnTip)") }
    $manual = @($script:AppRows | Where-Object { $_.State -eq [PCList]::Missing -and $_.IsSelected -and $_.Method -eq 'manual' })
    $lines.Add("ADDED TO YOUR CHECKLIST ($($manual.Count))")
    foreach ($r in $manual) { $lines.Add("  $($r.Name): $(if ($r.Link) { $r.Link } else { 'no download link' })") }
    Add-Log $lines.ToArray()
    $script:LogTab.IsSelected = $true
}

function Get-TodoItem($Todo) {
    return [pscustomobject]@{ id = "todo.$($Todo.id)"; name = $Todo.name; category = 'Apps to install yourself'
        description = 'PCSetup cannot install this one for you.'; method = 'todo'; link = $Todo.link }
}

function Add-ChecklistTodos($Rows) {
    $existing = @{}; foreach ($t in @($script:UserData.todos)) { $existing[$t.id] = $true }
    foreach ($r in $Rows) {
        if ($existing.ContainsKey($r.Key)) { continue }
        $todo = [pscustomobject]@{ id = $r.Key; name = $r.Name; link = $r.Link }
        $script:UserData.todos = @($script:UserData.todos) + $todo
        foreach ($n in (New-Rows @(Get-TodoItem $todo) -Removable)) { $script:ChecklistRows.Add($n) }
    }
    Save-UserData
    [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:ChecklistRows).Refresh()
    Update-ChecklistCount
}

function Sync-ChecklistTodos {
    # An app found on the PC no longer needs its to-do.
    $keep = @()
    foreach ($t in @($script:UserData.todos)) {
        $row = $script:AppRows | Where-Object Key -eq $t.id | Select-Object -First 1
        if ($row -and $row.State -eq [PCList]::Installed) {
            [void]$script:ChecklistRows.RemoveAll([Predicate[PCRow]] { param($c) $c.Key -eq "todo.$($t.id)" }.GetNewClosure())
        } else { $keep += $t }
    }
    if ($keep.Count -ne @($script:UserData.todos).Count) {
        $script:UserData.todos = $keep
        Save-UserData
        [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:ChecklistRows).Refresh()
        Update-ChecklistCount
    }
}

function Update-ChecklistCount {
    $active = @($script:ChecklistRows | Where-Object { -not $_.Removed })
    $script:ChecklistCount.Text = "$(@($active | Where-Object IsSelected).Count) of $($active.Count) done"
    $script:ShowRemovedSteps.Content = "Show removed ($($script:ChecklistRows.Count - $active.Count))"
}

function Save-ChecklistState {
    $done = @($script:ChecklistRows | Where-Object IsSelected | ForEach-Object Key)
    ConvertTo-Json -InputObject $done | Set-Content -LiteralPath $script:ChecklistStatePath -Encoding UTF8
    Update-ChecklistCount
}

function Restore-ChecklistState {
    if (Test-Path -LiteralPath $script:ChecklistStatePath) {
        $saved = Get-Content -LiteralPath $script:ChecklistStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $done = @{}; foreach ($k in @($saved)) { $done[$k] = $true }
        [PCRow]::Suspended = $true
        try { foreach ($r in $script:ChecklistRows) { $r.IsSelected = $done.ContainsKey($r.Key) } }
        finally { [PCRow]::Suspended = $false }
    }
    Update-ChecklistCount
}

function Clear-Checklist {
    [PCRow]::Suspended = $true
    try { foreach ($r in $script:ChecklistRows) { $r.IsSelected = $false } }
    finally { [PCRow]::Suspended = $false }
    Save-ChecklistState
}

function Start-TweakPreview {
    $selected = @($script:TweakRows | Where-Object IsSelected)
    foreach ($r in $script:TweakRows) { $r.Status = '' }
    if ($selected.Count -eq 0) { Add-Log 'No settings selected.'; return }
    foreach ($row in $selected) {
        $tweak = $script:Tweaks | Where-Object id -eq $row.Key
        if ($tweak.type -eq 'pcname' -and -not $tweak.set) { $row.Status = 'Choose a name first'; continue }
        $p = Get-TweakPreview -Tweak $tweak
        $row.Status = $p.Status
        Add-Log "$($row.Name): $($p.Detail)"
    }
    Add-Log 'Settings preview finished. Nothing was changed.'
}

function Initialize-TweakRows {
    # Capture-only settings stay out of the list until a capture finds them on your PC.
    $listed = @{}; foreach ($k in @($script:Profile.tweaks)) { $listed[$k] = $true }
    $values = $script:Profile.values
    if ($values) { foreach ($p in $values.PSObject.Properties) { $listed[$p.Name] = $true } }
    foreach ($t in $script:AllTweaks) {
        if ($values -and $values.PSObject.Properties[$t.id]) { $t.set = $values.PSObject.Properties[$t.id].Value }
    }
    $script:Tweaks = @($script:AllTweaks | Where-Object { -not $_.captureOnly -or $listed.ContainsKey($_.id) })
    $script:TweakRows = New-Rows $script:Tweaks
    $script:TweakList.ItemsSource = New-GroupedView $script:TweakRows
    Update-PCNameRows
    $backup = Read-TweakBackup
    foreach ($r in $script:TweakRows) { if ($backup.ContainsKey($r.Key)) { $r.Status = 'Can undo' } }
}

function Get-TweakById([string]$Id) {
    return $script:AllTweaks | Where-Object id -eq $Id | Select-Object -First 1
}

function Request-Restart([string]$Text) {
    if (Show-Question $Text) {
        Add-Log 'Restarting the PC.'
        Invoke-PCRestart
        return $true
    }
    return $false
}

function Start-TweakApply {
    $selected = @($script:TweakRows | Where-Object IsSelected)
    if ($selected.Count -eq 0) { Show-Notice 'Tick the settings to change first.'; return }
    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($row in $selected) {
        $tweak = Get-TweakById $row.Key
        if ($tweak.type -eq 'pcname' -and -not $tweak.set) { $row.Status = 'Choose a name first'; continue }
        $p = Get-TweakPreview -Tweak $tweak
        if ($p.Changes) { $changes.Add($row) } else { $row.Status = 'Already set' }
    }
    if ($changes.Count -eq 0) { Show-Notice 'Those settings are already set.'; return }
    $text = "Change $($changes.Count) settings on this PC? The current values are saved first, so Undo can put them back."
    $risky = @($changes | Where-Object Risky)
    if ($risky.Count) { $text += "`n`nThis lowers security: " + (($risky | ForEach-Object Name) -join ', ') + '.' }
    if (-not (Show-Question $text)) { return }
    $backup = Read-TweakBackup
    $restart = $false
    foreach ($row in $changes) {
        $tweak = Get-TweakById $row.Key
        try {
            # The first backup is kept, so Undo returns to how the PC was before PCSetup.
            $isNew = -not $backup.ContainsKey($row.Key)
            if ($isNew) { $backup[$row.Key] = Get-TweakSnapshot -Tweak $tweak; Save-TweakBackup $backup }
            try { Set-TweakValue -Tweak $tweak -Value $tweak.set }
            catch {
                # Nothing changed, so there is nothing to undo.
                if ($isNew) { [void]$backup.Remove($row.Key); Save-TweakBackup $backup }
                throw
            }
            if ($tweak.type -eq 'pcname') {
                $restart = $true
                $row.Status = 'Changed after restart'
            } elseif ([string](Get-TweakCurrentValue -Tweak $tweak) -eq [string]$tweak.set) {
                $row.Status = 'Changed'
            } else { throw 'The new value did not stick.' }
            Add-Log "$($row.Name): changed to $($tweak.set)."
        } catch {
            $row.Status = 'Failed'
            Add-Log "$($row.Name): failed. $($_.Exception.Message)"
        }
    }
    Add-Log 'Some File Explorer and taskbar changes show after you sign out or restart.'
    if ($restart) { [void](Request-Restart 'The new PC name takes effect after a restart. Restart now?') }
}

function Start-TweakUndo {
    $backup = Read-TweakBackup
    $rows = @($script:TweakRows | Where-Object { $_.IsSelected -and $backup.ContainsKey($_.Key) })
    if ($rows.Count -eq 0) { Show-Notice 'None of the ticked settings have been changed by PCSetup.'; return }
    if (-not (Show-Question "Put $($rows.Count) settings back to how they were before PCSetup changed them?")) { return }
    $restart = $false
    foreach ($row in $rows) {
        $tweak = Get-TweakById $row.Key
        try {
            Restore-TweakValue -Tweak $tweak -Backup $backup[$row.Key]
            [void]$backup.Remove($row.Key)
            Save-TweakBackup $backup
            $row.Status = 'Undone'
            if ($tweak.type -eq 'pcname') { $restart = $true; $row.Status = 'Undone after restart' }
            Add-Log "$($row.Name): put back."
        } catch {
            $row.Status = 'Failed'
            Add-Log "$($row.Name): undo failed. $($_.Exception.Message)"
        }
    }
    if ($restart) { [void](Request-Restart 'The PC name goes back after a restart. Restart now?') }
}

function Start-TweakCapture {
    $found = Get-CapturedTweaks -Tweaks $script:AllTweaks
    if ($found.Count -eq 0) { Show-Notice 'None of the known settings differ from a standard Windows install.'; return }
    $text = "Save $($found.Count) settings from this PC as your profile? This replaces the settings saved in your profile. Nothing on this PC changes."
    if (-not (Show-Question $text)) { return }
    $values = New-Object psobject
    foreach ($f in $found) { Add-Member -InputObject $values -NotePropertyName $f.Id -NotePropertyValue $f.Value }
    $script:Profile.tweaks = @($found | ForEach-Object Id)
    Add-Member -InputObject $script:Profile -NotePropertyName values -NotePropertyValue $values -Force
    ConvertTo-Json -InputObject $script:Profile -Depth 4 | Set-Content -LiteralPath $script:ProfilePath -Encoding UTF8
    Initialize-TweakRows
    Set-ProfileSelection $script:TweakRows $script:Profile.tweaks
    foreach ($r in $script:TweakRows) { if ($found.Id -contains $r.Key) { $r.Status = "Saved: $(($found | Where-Object Id -eq $r.Key).Value)" } }
    Add-Log (@('Captured from this PC:') + @($found | ForEach-Object { "  $($_.Name) = $($_.Value)" }))
}

function Test-RunBusy { return $null -ne $script:Run }

function Set-RunUi {
    $busy = Test-RunBusy
    foreach ($b in $script:ApplyTweaks, $script:UndoTweaks, $script:CaptureTweaks) { $b.IsEnabled = -not $busy }
    $script:CheckAgain.IsEnabled = (-not $busy) -and -not ($script:CheckTimer -and $script:CheckTimer.IsEnabled)
    $shown = if ($busy) { 'Visible' } else { 'Collapsed' }
    $script:StopRun.Visibility = $shown
    $script:RunProgress.Visibility = $shown
    if ($busy) { $script:RunBanner.Visibility = 'Visible'; $script:StopRun.IsEnabled = $true }
    Update-Summary
}

function Get-StepRow($Step) {
    $rows = if ($Step.Kind -in 'upgrade', 'pin', 'unpin') { $script:UpdateRows } else { $script:AppRows }
    foreach ($r in $rows) { if ($r.Key -eq $Step.Key) { return $r } }
    return $null
}

function Set-StepRowStatus($Step, [string]$Status, [string]$Note) {
    $row = Get-StepRow $Step
    if ($row) { $row.RunStatus = $Status; $row.RunNote = $Note }
}

function Start-RunSteps {
    # One step at a time, driven by a timer so the window stays responsive.
    param($Steps, [string]$Title, [bool]$Persist)
    if (Test-RunBusy) { return }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($s in $Steps) { $list.Add($s) }
    $script:Run = @{ Steps = $list; Index = -1; Handle = $null; StepStarted = $null; Title = $Title; Persist = $Persist
        Stop = $false; Done = 0; Failed = 0; Deferred = 0; Restart = $false }
    if ($Persist) { Save-CurrentRun; Set-ResumeAtStartup }
    foreach ($s in $script:Run.Steps) { Set-StepRowStatus $s 'Waiting' $null }
    Add-Log "--- $Title`: $($script:Run.Steps.Count) ---"
    $script:RunProgress.Maximum = $script:Run.Steps.Count
    $script:RunProgress.Value = 0
    Set-RunUi
    if (-not $script:RunTimer) {
        $script:RunTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:RunTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:RunTimer.Add_Tick({ Invoke-RunTick })
    }
    $script:RunTimer.Start()
}

function Save-CurrentRun {
    # Steps not finished yet, including any waiting for a restart.
    $r = $script:Run
    Write-RunState -Title $r.Title -Steps @($r.Steps | Where-Object { $_.Result -in '', 'RestartFirst' })
}

function Invoke-RunTick {
    $r = $script:Run
    if (-not $r) { return }
    try {
        if ($r.Handle) {
            $step = $r.Steps[$r.Index]
            if (-not (Test-StepFinished $r.Handle)) {
                if (((Get-Date) - $r.StepStarted).TotalMinutes -lt $script:StepLimitMinutes) { return }
                Stop-StepProcess $r.Handle
                $r.Handle = $null
                Complete-Step $step ([pscustomobject]@{ Result = 'Failed'; Message = "Stopped after $($script:StepLimitMinutes) minutes." }) ''
                return
            }
            $result = Get-StepResult $r.Handle
            $r.Handle = $null
            Complete-Step $step (Get-StepOutcome -Kind $step.Kind -ExitCode $result.ExitCode) $result.Output
            return
        }
        Start-NextStep
    } catch {
        $r.Handle = $null
        Add-Log "Run problem: $($_.Exception.Message)"
        Complete-Run
    }
}

function Start-NextStep {
    $r = $script:Run
    if ($r.Stop -or $r.Index + 1 -ge $r.Steps.Count) { Complete-Run; return }
    $r.Index++
    $step = $r.Steps[$r.Index]
    $word = Get-StepWord -Kind $step.Kind -Phase running
    $script:RunText.Text = "$word $($r.Index + 1) of $($r.Steps.Count): $($step.Name)"
    $script:RunProgress.Value = $r.Index
    Set-StepRowStatus $step "$word..." $null
    $step.Attempts++
    if ($r.Persist) { Save-CurrentRun }
    Add-Log "$word $($step.Name): $($step.File) $($step.Arguments)"
    try {
        $r.Handle = Start-StepProcess $step
        $r.StepStarted = Get-Date
    } catch {
        Complete-Step $step ([pscustomobject]@{ Result = 'Failed'; Message = "Could not start: $($_.Exception.Message)" }) ''
    }
}

function Complete-Step($Step, $Outcome, [string]$Output) {
    $r = $script:Run
    $Step.Result = $Outcome.Result
    $Step.Note = $Outcome.Message
    $doneWord = Get-StepWord -Kind $Step.Kind -Phase done
    switch ($Outcome.Result) {
        'Done' {
            $r.Done++
            Set-StepRowStatus $Step $doneWord $Outcome.Message
            $row = Get-StepRow $Step
            if ($row -and $Step.Kind -eq 'pin') { $script:Locks[$Step.Key] = $Step.Name; Set-UpdateRowLock $row $true }
            if ($row -and $Step.Kind -eq 'unpin') { [void]$script:Locks.Remove($Step.Key); Set-UpdateRowLock $row $false }
        }
        'NeedsRestart' { $r.Done++; $r.Restart = $true; Set-StepRowStatus $Step 'Restart needed' $Outcome.Message }
        'RestartFirst' { $r.Deferred++; Set-StepRowStatus $Step 'After restart' $Outcome.Message }
        default { $r.Failed++; Set-StepRowStatus $Step 'Failed' $Outcome.Message }
    }
    Add-Log ("$($Step.Name): $($Outcome.Result). $($Outcome.Message)".TrimEnd())
    if ($Outcome.Result -eq 'Failed' -and $Output) { Add-Log @(Get-LastOutputLines -Output $Output | ForEach-Object { "    $_" }) }
    if ($r.Persist) { Save-CurrentRun }
}

function Complete-Run {
    $r = $script:Run
    $script:RunTimer.Stop()
    foreach ($s in $r.Steps) { if ($s.Result -eq '') { $s.Result = 'NotRun'; Set-StepRowStatus $s 'Not run' $null } }
    $notRun = @($r.Steps | Where-Object Result -eq 'NotRun').Count
    $summary = "Finished: $($r.Done) done, $($r.Failed) failed"
    if ($r.Deferred) { $summary += ", $($r.Deferred) waiting for a restart" }
    if ($notRun) { $summary += ", $notRun not run" }
    $script:RunText.Text = "$summary. Details are on the Log tab."
    Add-Log "$($r.Title): $summary."
    $script:Run = $null
    Set-RunUi
    if (-not $r.Persist) { Update-UpdateList; return }

    $waiting = @($r.Steps | Where-Object Result -eq 'RestartFirst')
    if ($waiting.Count) {
        foreach ($s in $waiting) { $s.Attempts = 0 }
        Write-RunState -Title $r.Title -Steps $waiting
        if (Request-Restart "$($waiting.Count) apps need a restart before they can install. Restart now and continue automatically?") { return }
        Clear-ResumeAtStartup
    } else {
        Clear-RunState
        Clear-ResumeAtStartup
        if ($r.Restart -and (Request-Restart 'Some apps need a restart to finish. Restart now?')) { return }
    }
    Start-InstalledCheck -KeepResults
}

function Resume-SavedRun {
    $state = Read-RunState
    if (-not $state) { Clear-RunState; return }
    $count = @($state.steps).Count
    if (-not $script:ResumeRequested -and -not (Show-Question "An earlier run has $count apps left. Continue it now?")) {
        Clear-RunState
        Clear-ResumeAtStartup
        return
    }
    $steps = New-Object System.Collections.Generic.List[object]
    foreach ($s in @($state.steps)) {
        $step = New-RunStep -Key $s.Key -Name $s.Name -Kind $s.Kind -File $s.File -Arguments $s.Arguments
        $step.Attempts = [int]$s.Attempts
        $row = Get-StepRow $step
        if (-not $row) { continue }   # Already updated, or no longer listed.
        if ($step.Kind -in 'install', 'setup' -and $row.State -eq [PCList]::Installed) { continue }
        if ($step.Attempts -ge 2) {
            # The PC restarted twice during this one, so it is not tried again.
            Set-StepRowStatus $step 'Failed' 'The PC restarted while this was running, twice.'
            Add-Log "$($step.Name): skipped. The PC restarted while it was running, twice."
            continue
        }
        $steps.Add($step)
    }
    if ($steps.Count -eq 0) { Clear-RunState; Clear-ResumeAtStartup; return }
    Add-Log "Continuing: $($steps.Count) apps left."
    Start-RunSteps -Steps $steps -Title $state.title -Persist $true
}

function Start-InstallRun {
    $rows = @($script:AppRows | Where-Object { $_.State -eq [PCList]::Missing -and $_.IsSelected })
    if ($rows.Count -eq 0) { return }
    $manual = @($rows | Where-Object Method -eq 'manual')
    $auto = @($rows | Where-Object Method -ne 'manual')
    $setups = @($auto | Where-Object Method -eq 'installer')
    $text = "Install $($auto.Count) apps now?"
    if ($auto.Count -gt $setups.Count) { $text += "`n`nBy pressing Yes you accept each app's license terms. PCSetup passes that acceptance to winget." }
    if ($setups.Count) { $text += "`n`n$($setups.Count) of your setup files may open their own window and need you to click through." }
    if ($manual.Count) { $text += "`n`n$($manual.Count) apps cannot be installed automatically and will be added to your Checklist." }
    if (-not (Show-Question $text)) { return }
    if ($manual.Count) { Add-ChecklistTodos $manual }
    foreach ($r in $manual) { $r.RunStatus = 'On Checklist' }
    if ($auto.Count -eq 0) { $script:ChecklistTab.IsSelected = $true; return }
    $steps = foreach ($r in $auto) {
        if ($r.Method -eq 'installer') { New-SetupStep -Key $r.Key -Name $r.Name -Path $r.BtnTip }
        else { New-WingetStep -Key $r.Key -Name $r.Name -Kind install }
    }
    Start-RunSteps -Steps $steps -Title 'Installing apps' -Persist $true
}

function Start-UpdateRun {
    $rows = @($script:UpdateRows | Where-Object { $_.IsSelected -and -not $_.Locked })
    if ($rows.Count -eq 0) { return }
    $text = "Update $($rows.Count) apps now?`n`nBy pressing Yes you accept each app's license terms. PCSetup passes that acceptance to winget. Close the apps being updated first."
    if (-not (Show-Question $text)) { return }
    $steps = foreach ($r in $rows) { New-WingetStep -Key $r.Key -Name $r.Name -Kind upgrade }
    Start-RunSteps -Steps $steps -Title 'Updating apps' -Persist $true
}

function Switch-UpdateLock($Row) {
    if (Test-RunBusy) { Show-Notice 'Wait for the current run to finish.'; return }
    $kind = if ($Row.Locked) { 'unpin' } else { 'pin' }
    Start-RunSteps -Steps @(New-WingetStep -Key $Row.Key -Name $Row.Name -Kind $kind) -Title ($(if ($Row.Locked) { 'Unlocking' } else { 'Locking' }) + " $($Row.Name)") -Persist $false
}

function New-PCSetupWindow {
    param([string]$DataDir)
    $xaml = Get-Content -LiteralPath (Join-Path $Root 'ui\MainWindow.xaml') -Raw -Encoding UTF8
    $window = [Windows.Markup.XamlReader]::Parse($xaml)
    foreach ($n in 'Tabs', 'SystemInfo', 'AppSearch', 'AppList', 'AppListEmpty', 'PlanSummary', 'CheckInfo', 'ShowCommands', 'InstallSelected', 'CheckAgain', 'LoadProfileApps',
        'FilterAll', 'FilterInstalled', 'FilterUpdate', 'FilterMissing', 'FilterUnlisted', 'TweakList', 'TweakCount', 'PreviewTweaks', 'ApplyTweaks', 'UndoTweaks', 'CaptureTweaks', 'LoadProfileTweaks',
        'LogBox', 'LogTab', 'CheckList', 'ChecklistTab', 'ChecklistCount', 'ChecklistClear',
        'UpdateList', 'UpdateListEmpty', 'UpdateSummary', 'RunUpdates', 'SelectAllUpdates', 'ClearUpdates', 'RunBanner', 'RunText', 'RunProgress', 'StopRun',
        'AppHeader', 'UpdateHeader', 'UpdatesTab', 'ShowRemoved', 'SaveProfileApps', 'SaveProfileTweaks', 'AddAppOpen', 'AddAppPanel', 'AddAppClose', 'AddAppSearch',
        'AddAppCategory', 'AddAppName', 'AddAppAddWinget', 'AddAppResults', 'AddAppAddManual', 'AddAppLink', 'AddAppInfo', 'ShowRemovedSteps', 'StepAdd', 'StepSection', 'StepText') {
        Set-Variable -Scope Script -Name $n -Value $window.FindName($n)
    }

    $os = Get-WindowsMajor
    # A copy shared with someone else starts without a profiles folder.
    $profiles = if ($DataDir) { $DataDir } else { Join-Path $Root 'profiles' }
    if (-not (Test-Path -LiteralPath $profiles)) { [void](New-Item -ItemType Directory -Path $profiles) }
    $script:Run = $null
    $script:Locks = @{}
    $script:LogPath = Join-Path $Root ('logs\pcsetup-{0:yyyy-MM-dd_HHmmss}.log' -f (Get-Date))
    $script:ProfilePath = Join-Path $profiles 'profile.json'
    $script:RunStatePath = Join-Path $profiles 'run-state.json'
    $script:TweakBackupPath = Join-Path $profiles 'settings-backup.json'
    $script:UserDataPath = Join-Path $profiles 'user-data.json'
    $script:UserData = Read-UserData
    $script:IgnorePatterns = @(Read-JsonFile 'data\ignore.json')
    $script:UnlistedEntries = @{}
    $script:Profile = Read-Profile
    $script:Apps = @(Read-JsonFile 'data\apps.json') + @($script:Profile.myApps)
    $script:AllTweaks = @(Read-JsonFile 'data\tweaks.json' | Where-Object { $_.os -contains $os })
    $script:RootPanel = $window.Content
    $script:AppRows = New-Rows $script:Apps -Removable
    foreach ($r in $script:AppRows) { if (@($script:UserData.removed) -contains $r.Key) { Set-RowRemoved $r $true } }
    Initialize-TweakRows
    $script:UpdateRows = New-Object 'System.Collections.Generic.List[PCRow]'
    $script:UpdateItems = New-Object PCRowList
    $script:UpdateList.ItemsSource = $script:UpdateItems
    $script:AppItems = New-Object PCRowList
    $script:StateFilter = ''
    $script:Collapsed = New-Object 'System.Collections.Generic.List[string]'
    $script:Collapsed.Add([PCList]::Installed)   # Starts folded so the apps needing action show first.
    $script:AppList.ItemsSource = $script:AppItems
    $script:AppById = @{}; foreach ($a in $script:Apps) { $script:AppById[$a.id] = $a }
    foreach ($r in $script:AppRows) { if ($script:UserData.installers.ContainsKey($r.Key)) { Set-RowInstaller $r (ConvertFrom-StoredPath $script:UserData.installers[$r.Key]) } }
    # A step in your profile replaces the general step with the same ID.
    $mySteps = @($script:Profile.mySteps)
    $builtInSteps = @(Read-JsonFile 'data\checklist.json' | Where-Object { $mySteps.id -notcontains $_.id })
    $script:ChecklistRows = New-Rows ($builtInSteps + $mySteps + @(@($script:UserData.todos) | ForEach-Object { Get-TodoItem $_ })) -Removable
    foreach ($r in $script:ChecklistRows) { if (@($script:UserData.removedSteps) -contains $r.Key) { Set-RowRemoved $r $true } }
    $script:CheckList.ItemsSource = New-GroupedView $script:ChecklistRows
    $script:ChecklistStatePath = Join-Path $profiles 'checklist-state.json'
    [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:ChecklistRows).Filter = [Predicate[object]] { param($r) (-not $r.Removed) -or [bool]$script:ShowRemovedSteps.IsChecked }
    foreach ($c in @(@($builtInSteps + $mySteps).category | Select-Object -Unique)) { [void]$script:StepSection.Items.Add($c) }
    $script:StepSection.SelectedIndex = 0
    foreach ($c in @($script:Apps.category | Sort-Object -Unique)) { [void]$script:AddAppCategory.Items.Add($c) }
    $script:AddAppCategory.SelectedItem = 'Utilities'
    Restore-ChecklistState

    Add-WingetToPath
    Set-SystemInfo
    $script:RepairTried = $false

    [PCRow]::add_SelectionChanged({ Update-Summary })
    $script:AppSearch.Add_TextChanged({ Update-AppList })
    $script:FilterAll.Add_Checked({ Set-StateFilter '' })
    $script:FilterInstalled.Add_Checked({ Set-StateFilter ([PCList]::Installed) })
    $script:FilterUpdate.Add_Checked({ Set-StateFilter ([PCList]::Update) })
    $script:FilterMissing.Add_Checked({ Set-StateFilter ([PCList]::Missing) })
    $script:FilterUnlisted.Add_Checked({ Set-StateFilter ([PCList]::Unlisted) })
    $script:AppList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
        param($s, $e)
        if ($e.OriginalSource -isnot [System.Windows.Controls.Button]) { return }
        $row = $e.OriginalSource.DataContext
        if ($row.IsHeader) { Switch-AppSection $row.Key; return }
        $unlisted = $row.Method -eq 'unlisted'
        switch ($e.OriginalSource.Tag) {
            '1' { if ($unlisted) { Add-UnlistedApp $row } else { Invoke-RowLink $row } }
            '2' { if ($unlisted) { Hide-UnlistedApp $row } else { Select-RowInstaller $row } }
            '3' { Show-UpdateRow $row }
            '4' { Switch-AppRemoved $row }
        }
    })
    $script:LoadProfileApps.Add_Click({ Set-ProfileSelection $script:AppRows $script:Profile.apps })
    $script:SaveProfileApps.Add_Click({ Save-ProfileApps })
    $script:SaveProfileTweaks.Add_Click({ Save-ProfileTweaks })
    $script:ShowRemoved.Add_Click({ Update-AppList })
    $script:ShowRemovedSteps.Add_Click({ [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:ChecklistRows).Refresh() })
    $script:AddAppOpen.Add_Click({ $script:AddAppPanel.Visibility = 'Visible'; [void]$script:AddAppName.Focus() })
    $script:AddAppClose.Add_Click({ $script:AddAppPanel.Visibility = 'Collapsed' })
    $script:AddAppSearch.Add_Click({ Start-AppSearch })
    $script:AddAppName.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return' -and $script:AddAppSearch.IsEnabled) { Start-AppSearch } })
    $script:AddAppAddWinget.Add_Click({ Add-WingetApp })
    $script:AddAppAddManual.Add_Click({ Add-ManualApp })
    $script:StepAdd.Add_Click({ Add-ChecklistStep })
    $script:StepText.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Add-ChecklistStep } })
    foreach ($prefix in 'A', 'U') {
        if ($script:UserData.columns.ContainsKey($prefix)) { Set-ColumnWidths $prefix $script:UserData.columns[$prefix] }
    }
    $script:AppHeader.AddHandler([System.Windows.Controls.Primitives.Thumb]::DragDeltaEvent, [System.Windows.Controls.Primitives.DragDeltaEventHandler] { Sync-ColumnWidths 'A' })
    $script:UpdateHeader.AddHandler([System.Windows.Controls.Primitives.Thumb]::DragDeltaEvent, [System.Windows.Controls.Primitives.DragDeltaEventHandler] { Sync-ColumnWidths 'U' })
    $script:AppHeader.AddHandler([System.Windows.Controls.Primitives.Thumb]::DragCompletedEvent, [System.Windows.Controls.Primitives.DragCompletedEventHandler] { Sync-ColumnWidths 'A'; Save-ColumnWidths })
    $script:UpdateHeader.AddHandler([System.Windows.Controls.Primitives.Thumb]::DragCompletedEvent, [System.Windows.Controls.Primitives.DragCompletedEventHandler] { Sync-ColumnWidths 'U'; Save-ColumnWidths })
    $script:LoadProfileTweaks.Add_Click({ Set-ProfileSelection $script:TweakRows $script:Profile.tweaks })
    $script:CheckAgain.Add_Click({ Start-InstalledCheck })
    $script:ShowCommands.Add_Click({ Show-PlannedCommands })
    $script:InstallSelected.Add_Click({ Start-InstallRun })
    $script:RunUpdates.Add_Click({ Start-UpdateRun })
    $script:SelectAllUpdates.Add_Click({ Set-UpdateSelection $true })
    $script:ClearUpdates.Add_Click({ Set-UpdateSelection $false })
    $script:StopRun.Add_Click({
        if ($script:Run) { $script:Run.Stop = $true; $script:StopRun.IsEnabled = $false; $script:RunText.Text = 'Stopping after this app...' }
    })
    $script:UpdateList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
        param($s, $e)
        if ($e.OriginalSource -is [System.Windows.Controls.Button]) { Switch-UpdateLock $e.OriginalSource.DataContext }
    })
    $script:PreviewTweaks.Add_Click({ Start-TweakPreview; $script:LogTab.IsSelected = $true })
    $script:ApplyTweaks.Add_Click({ Start-TweakApply })
    $script:UndoTweaks.Add_Click({ Start-TweakUndo })
    $script:CaptureTweaks.Add_Click({ Start-TweakCapture })
    $script:TweakList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
        param($s, $e)
        if ($e.OriginalSource -is [System.Windows.Controls.Button] -and $e.OriginalSource.Tag -eq '1') { Set-PCNameFromUser $e.OriginalSource.DataContext }
    })
    $script:CheckList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
        param($s, $e)
        $source = $e.OriginalSource
        if ($source -is [System.Windows.Controls.Button] -and $source.Tag -eq '1') { Invoke-RowLink $source.DataContext; return }
        if ($source -is [System.Windows.Controls.Button] -and $source.Tag -eq '4') { Switch-StepRemoved $source.DataContext; return }
        Save-ChecklistState
    })
    $script:ChecklistClear.Add_Click({
        $answer = [System.Windows.MessageBox]::Show('Untick every step on the checklist?', 'PCSetup', 'YesNo', 'Question')
        if ($answer -eq 'Yes') { Clear-Checklist }
    })
    $script:LookForSavedRun = Test-Path -LiteralPath $script:RunStatePath
    $window.Add_Loaded({ Start-InstalledCheck })
    $window.Add_Closing({
        param($s, $e)
        if (-not (Test-RunBusy)) { return }
        if (Show-Question 'A run is still going. Close PCSetup anyway? The app being installed will finish by itself, and PCSetup will offer the rest next time you open it.') {
            $script:RunTimer.Stop()
            Clear-ResumeAtStartup
        } else { $e.Cancel = $true }
    })

    # Your saved profile is ticked when PCSetup opens.
    Set-ProfileSelection $script:TweakRows $script:Profile.tweaks
    Set-ProfileSelection $script:AppRows $script:Profile.apps
    return $window
}

# Only show the window when run directly. The tests dot-source this file.
if ($MyInvocation.InvocationName -ne '.') {
    $w = New-PCSetupWindow
    [void]$w.ShowDialog()
}
