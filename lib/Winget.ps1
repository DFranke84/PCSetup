# Winget helpers: reading winget's tables and building its command lines.
# Commands are launched from lib\Installers.ps1.

$script:StateInstalled = 'Already installed'
$script:StateUpdate = 'Needs update'
$script:StateMissing = 'Not installed'

function Get-WingetVersion {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try { return ((& winget --version) | Out-String).Trim() } catch { return $null }
}

function Get-WingetArguments {
    # A blocking pin is the only kind that also stops "winget upgrade --id", which is what Lock promises.
    param([Parameter(Mandatory)][string]$Id, [ValidateSet('install', 'upgrade', 'pin', 'unpin')][string]$Verb = 'install')
    switch ($Verb) {
        'pin' { return "pin add --id $Id -e --blocking --source winget --accept-source-agreements --disable-interactivity" }
        'unpin' { return "pin remove --id $Id -e --source winget --accept-source-agreements --disable-interactivity" }
        default { return "$Verb --id $Id -e --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity" }
    }
}

function Get-WingetCommandText {
    param([Parameter(Mandatory)][string]$Id, [ValidateSet('install', 'upgrade', 'pin', 'unpin')][string]$Verb = 'install')
    return 'winget ' + (Get-WingetArguments -Id $Id -Verb $Verb)
}

function ConvertFrom-WingetPins {
    # Reads "winget pin list" into a table of ID to app name. No pins means no table.
    param([AllowEmptyString()][string]$Text)
    $pins = @{}
    $lines = @($Text -split "`r?`n" | ForEach-Object { ($_ -split "`r")[-1] })
    $headerAt = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*Name\s+Id\s+Version') { $headerAt = $i; break } }
    if ($headerAt -lt 0) { return $pins }
    $idAt = $lines[$headerAt].IndexOf(' Id ') + 1
    $versionAt = $lines[$headerAt].IndexOf(' Version') + 1
    for ($i = $headerAt + 2; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l.Length -le $idAt) { continue }
        $id = $l.Substring($idAt, [Math]::Min($versionAt, $l.Length) - $idAt).Trim()
        if ($id) { $pins[$id] = $l.Substring(0, $idAt).Trim() }
    }
    return $pins
}

function ConvertFrom-WingetList {
    # Reads the fixed-width table from "winget list". Columns are found from the header line,
    # because neighbouring columns can touch (long versions leave only one space).
    param([AllowEmptyString()][string]$Text)
    $lines = @($Text -split "`r?`n" | ForEach-Object { ($_ -split "`r")[-1] })
    $headerAt = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*Name\s+Id\s+Version') { $headerAt = $i; break } }
    if ($headerAt -lt 0) { return @() }
    $h = $lines[$headerAt]
    $idAt = $h.IndexOf(' Id ') + 1
    $versionAt = $h.IndexOf(' Version') + 1
    $availableAt = $h.IndexOf(' Available') + 1
    $sourceAt = $h.IndexOf(' Source') + 1
    $matchAt = $h.IndexOf(' Match') + 1   # "winget search" has this column instead of Available.
    $versionEnd = if ($availableAt -gt 0) { $availableAt } elseif ($matchAt -gt 0) { $matchAt } elseif ($sourceAt -gt 0) { $sourceAt } else { [int]::MaxValue }
    $availableEnd = if ($sourceAt -gt 0) { $sourceAt } else { [int]::MaxValue }

    $cut = {
        param($line, $from, $to)
        if ($from -le 0 -and $from -ne 0) { return '' }
        if ($from -ge $line.Length) { return '' }
        $len = [Math]::Min($to, $line.Length) - $from
        return $line.Substring($from, $len).Trim()
    }
    $result = New-Object System.Collections.Generic.List[object]
    for ($i = $headerAt + 2; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        $result.Add([pscustomobject]@{
            Name      = & $cut $l 0 $idAt
            Id        = & $cut $l $idAt $versionAt
            Version   = & $cut $l $versionAt $versionEnd
            Available = if ($availableAt -gt 0) { & $cut $l $availableAt $availableEnd } else { '' }
            Source    = if ($sourceAt -gt 0) { & $cut $l $sourceAt ([int]::MaxValue) } else { '' }
        })
    }
    return , $result
}

function New-WingetIndex {
    # Lookup tables so hundreds of apps can be checked instantly.
    param($Entries)
    $byId = @{}; $byName = @{}
    foreach ($e in $Entries) {
        if (-not $byId.ContainsKey($e.Id) -or ($e.Available -and -not $byId[$e.Id].Available)) { $byId[$e.Id] = $e }
        # Programs winget has not linked to a package (no Source) can only be found by name.
        if (-not $e.Source) {
            $prefix = ''
            foreach ($word in ($e.Name -split ' ' | Where-Object { $_ })) {
                $prefix = ($prefix + ' ' + $word).Trim()
                if (-not $byName.ContainsKey($prefix)) { $byName[$prefix] = $e }
            }
        }
    }
    return @{ ById = $byId; ByName = $byName }
}

function Get-UnlistedEntries {
    # Programs on this PC that are not in the catalog, without runtimes, Windows packages or hidden ones.
    param($Entries, [hashtable]$CatalogIds, [hashtable]$CatalogNames, [string[]]$IgnorePatterns, $HiddenIds)
    $ignore = [regex]::new(($IgnorePatterns -join '|'), 'IgnoreCase')
    $hidden = @{}; foreach ($h in @($HiddenIds)) { if ($h) { $hidden[$h] = $true } }
    $seen = @{}
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Entries) {
        if ($CatalogIds.ContainsKey($e.Id) -or $hidden.ContainsKey($e.Id) -or $seen.ContainsKey($e.Id)) { continue }
        if ($e.Id -match '^MSIX\\(Microsoft|Windows|MicrosoftWindows|[0-9a-f]{8}-|c5e2524a|NcsiUwpApp|1527c705)' -or $ignore.IsMatch($e.Name)) { continue }
        $prefix = ''; $claimed = $false
        foreach ($word in ($e.Name -split ' ' | Where-Object { $_ })) {
            $prefix = ($prefix + ' ' + $word).Trim()
            if ($CatalogNames.ContainsKey($prefix)) { $claimed = $true; break }
        }
        if ($claimed) { continue }
        $seen[$e.Id] = $true
        $result.Add($e)
    }
    return , $result
}

function Get-AppInstallState {
    param([Parameter(Mandatory)]$Index, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Name, [string]$DetectPath)
    $e = $Index.ById[$Id]
    if ($e) {
        if ($e.Available) { return [pscustomobject]@{ State = $script:StateUpdate; Installed = $e.Version; Latest = $e.Available; Note = $null } }
        return [pscustomobject]@{ State = $script:StateInstalled; Installed = $e.Version; Latest = 'Up to date'; Note = $null }
    }
    $e = $Index.ByName[$Name]
    if ($e) {
        return [pscustomobject]@{ State = $script:StateInstalled; Installed = $e.Version; Latest = 'Not tracked'
            Note = 'Installed, but winget cannot check it for updates. It may update itself.' }
    }
    # Portable and Chocolatey programs are invisible to winget; a known file or folder proves them.
    if ($DetectPath -and (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($DetectPath)))) {
        return [pscustomobject]@{ State = $script:StateInstalled; Installed = 'Found'; Latest = 'Not tracked'
            Note = 'Found on this PC, but it was not installed with winget.' }
    }
    return [pscustomobject]@{ State = $script:StateMissing; Installed = '-'; Latest = '-'; Note = $null }
}
