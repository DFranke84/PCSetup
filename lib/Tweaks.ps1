# Settings helpers: read, change, undo and capture.
# Everything that changes a Windows setting is in this file.

function Get-WindowsMajor {
    if ([Environment]::OSVersion.Version.Build -ge 22000) { return '11' }
    return '10'
}

function Get-PowerValue {
    # Reads the plugged-in value of a power setting from the active plan.
    param([Parameter(Mandatory)][string]$Subgroup, [Parameter(Mandatory)][string]$Setting)
    $text = (powercfg /q SCHEME_CURRENT $Subgroup $Setting | Out-String)
    $m = [regex]::Match($text, 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)')
    if ($m.Success) { return [Convert]::ToInt32($m.Groups[1].Value, 16) }
    return $null
}

function Get-TweakCurrentValue {
    param([Parameter(Mandatory)]$Tweak)
    switch ($Tweak.type) {
        'power' { return Get-PowerValue -Subgroup $Tweak.subgroup -Setting $Tweak.setting }
        'pcname' { return $env:COMPUTERNAME }
        default {
            try { return (Get-ItemProperty -Path $Tweak.path -Name $Tweak.value -ErrorAction Stop).($Tweak.value) }
            catch { return $null }
        }
    }
}

function Get-TweakTarget {
    param([Parameter(Mandatory)]$Tweak)
    switch ($Tweak.type) {
        'power' { return "Power setting $($Tweak.subgroup)\$($Tweak.setting)" }
        'pcname' { return 'PC name' }
        default { return "$($Tweak.path)\$($Tweak.value)" }
    }
}

function Get-TweakPreview {
    # Returns what applying this tweak would do on this PC.
    param([Parameter(Mandatory)]$Tweak)
    $current = Get-TweakCurrentValue -Tweak $Tweak
    $shown = if ($null -eq $current) { "not set (Windows default $($Tweak.default))" } else { "$current" }
    $target = Get-TweakTarget -Tweak $Tweak
    if ($null -ne $current -and [string]$current -eq [string]$Tweak.set) {
        return [pscustomobject]@{ Changes = $false; Status = 'Already set'; Detail = "$target is already $($Tweak.set)" }
    }
    return [pscustomobject]@{ Changes = $true; Status = 'Would change'; Detail = "$target would change from $shown to $($Tweak.set)" }
}

function Get-TweakSnapshot {
    # What Undo needs to put a setting back exactly, including "was not set at all".
    param([Parameter(Mandatory)]$Tweak)
    if ($Tweak.type -eq 'registry') {
        $key = Get-Item -Path $Tweak.path -ErrorAction SilentlyContinue
        if ($key -and ($key.GetValueNames() -contains $Tweak.value)) {
            return @{ existed = $true; value = $key.GetValue($Tweak.value); kind = $key.GetValueKind($Tweak.value).ToString() }
        }
        return @{ existed = $false; value = $null; kind = '' }
    }
    $value = Get-TweakCurrentValue -Tweak $Tweak
    return @{ existed = ($null -ne $value); value = $value; kind = '' }
}

function Set-RegistryValue {
    param($Tweak, $Value, [string]$Kind)
    if (-not $Kind) { $Kind = if ($Value -is [string]) { 'String' } else { 'DWord' } }
    if (-not (Test-Path -Path $Tweak.path)) { [void](New-Item -Path $Tweak.path -Force) }
    [void](New-ItemProperty -Path $Tweak.path -Name $Tweak.value -Value $Value -PropertyType $Kind -Force)
}

function Invoke-PowerWrite {
    param([string]$Subgroup, [string]$Setting, [int]$Value)
    $said = (& powercfg.exe /setacvalueindex SCHEME_CURRENT $Subgroup $Setting $Value 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "powercfg could not change $Setting. $said" }
    $said = (& powercfg.exe /setactive SCHEME_CURRENT 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "powercfg could not activate the power plan. $said" }
}

function Invoke-PCRename {
    param([string]$Name)
    Rename-Computer -NewName $Name -Force -ErrorAction Stop -WarningAction SilentlyContinue
}

function Set-TweakValue {
    param([Parameter(Mandatory)]$Tweak, $Value, [string]$Kind)
    switch ($Tweak.type) {
        'power' { Invoke-PowerWrite -Subgroup $Tweak.subgroup -Setting $Tweak.setting -Value $Value }
        'pcname' { Invoke-PCRename -Name $Value }
        default { Set-RegistryValue -Tweak $Tweak -Value $Value -Kind $Kind }
    }
}

function Restore-TweakValue {
    param([Parameter(Mandatory)]$Tweak, [Parameter(Mandatory)]$Backup)
    if ($Backup.existed) { Set-TweakValue -Tweak $Tweak -Value $Backup.value -Kind $Backup.kind; return }
    if ($Tweak.type -eq 'registry') { Remove-ItemProperty -Path $Tweak.path -Name $Tweak.value -ErrorAction Stop; return }
    if ($Tweak.type -eq 'power') { Set-TweakValue -Tweak $Tweak -Value $Tweak.default; return }
    throw 'The original value is not known.'
}

function Read-TweakBackup {
    $backup = @{}
    if (Test-Path -LiteralPath $script:TweakBackupPath) {
        $saved = Get-Content -LiteralPath $script:TweakBackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) { $backup[$p.Name] = @{ existed = [bool]$p.Value.existed; value = $p.Value.value; kind = [string]$p.Value.kind } }
    }
    return $backup
}

function Save-TweakBackup {
    param([hashtable]$Backup)
    ConvertTo-Json -InputObject $Backup -Depth 4 | Set-Content -LiteralPath $script:TweakBackupPath -Encoding UTF8
}

function Get-CapturedTweaks {
    # This PC's value for every setting that differs from the Windows default.
    param($Tweaks)
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($t in $Tweaks) {
        $current = Get-TweakCurrentValue -Tweak $t
        if ($null -eq $current -or [string]$current -eq [string]$t.default) { continue }
        $found.Add([pscustomobject]@{ Id = $t.id; Name = $t.name; Value = $current })
    }
    return , $found
}
