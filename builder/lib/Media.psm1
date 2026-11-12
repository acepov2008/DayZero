#Requires -Version 5.1
<#
    DayZero - finds Windows installation media (made with the Media Creation Tool or Rufus)
    and reads what is on it: Windows version, build, editions, languages, architecture.
    Windows-only (uses CIM and the built-in DISM PowerShell module). Needs admin rights.
#>

Set-StrictMode -Version 2.0

function Get-DzInstallMediaCandidate {
    <#
        Lists drives (never the running system drive) that contain sources\install.wim,
        install.esd or install.swm. Removable USB sticks report DriveType 2; some USB SSDs
        and "fixed" sticks report 3, so both are included and labelled.
    #>
    [CmdletBinding()]
    param()
    $systemDrive = $env:SystemDrive.TrimEnd('\')
    $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 2 OR DriveType = 3' -ErrorAction SilentlyContinue)
    foreach ($d in $disks) {
        if ($d.DeviceID -ieq $systemDrive) { continue }
        $root = $d.DeviceID + '\'
        $image = $null
        foreach ($name in @('install.wim', 'install.esd', 'install.swm')) {
            $candidate = Join-Path $root ('sources\' + $name)
            if (Test-Path -LiteralPath $candidate) { $image = $candidate; break }
        }
        if (-not $image) { continue }
        $kind = if ($d.DriveType -eq 2) { 'USB' } else { 'Fixed disk' }
        $label = if ([string]::IsNullOrWhiteSpace($d.VolumeName)) { '(no label)' } else { $d.VolumeName }
        $sizeGB = [math]::Round(([double]$d.Size) / 1GB, 1)
        [pscustomobject]@{
            Drive      = $d.DeviceID
            Root       = $root
            Label      = $label
            Kind       = $kind
            FileSystem = $d.FileSystem
            SizeGB     = $sizeGB
            FreeMB     = [math]::Floor(([double]$d.FreeSpace) / 1MB)
            ImagePath  = $image
            HasSetup   = (Test-Path -LiteralPath (Join-Path $root 'setup.exe'))
            HasAnswer  = (Test-Path -LiteralPath (Join-Path $root 'autounattend.xml'))
            Display    = ('{0}  {1}  - {2}, {3} GB, {4}' -f $d.DeviceID, $label, $kind, $sizeGB, $d.FileSystem)
        }
    }
}

function ConvertTo-DzArchitectureName {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)
    switch -Regex ([string]$Value) {
        '^(9|x64|amd64)$' { return 'amd64' }
        '^(12|arm64)$' { return 'arm64' }
        '^(0|x86)$' { return 'x86' }
        default { return 'unknown' }
    }
}

function Get-DzMediaInfo {
    <#
        Reads the image metadata. Returns an object with:
          WindowsVersion (10/11), Build, Version, Architecture, Languages, DefaultLanguage,
          Editions (Index + Name), Error (text when reading failed).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    $result = [ordered]@{
        ImagePath       = $ImagePath
        WindowsVersion  = $null
        Build           = $null
        Version         = $null
        Architecture    = $null
        Languages       = @()
        DefaultLanguage = $null
        Editions        = @()
        Error           = $null
    }
    try {
        $images = @(Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop)
        if ($images.Count -eq 0) { throw 'The image file lists no Windows editions.' }
        $result.Editions = @($images | ForEach-Object { [pscustomobject]@{ Index = $_.ImageIndex; Name = $_.ImageName } })

        $detail = Get-WindowsImage -ImagePath $ImagePath -Index $images[0].ImageIndex -ErrorAction Stop
        $result.Version = [string]$detail.Version
        $parts = $result.Version.Split('.')
        if ($parts.Count -ge 3) {
            $result.Build = [int]$parts[2]
            $result.WindowsVersion = if ($result.Build -ge 22000) { 11 } else { 10 }
        }
        $result.Architecture = ConvertTo-DzArchitectureName -Value $detail.Architecture
        $langs = @($detail.Languages | Where-Object { $_ })
        $result.Languages = $langs
        if ($langs.Count -gt 0) {
            $idx = 0
            try { $idx = [int]$detail.DefaultLanguageIndex } catch { $idx = 0 }
            if ($idx -lt 0 -or $idx -ge $langs.Count) { $idx = 0 }
            $result.DefaultLanguage = $langs[$idx]
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Test-DzMediaHasEdition {
    <# True when the media contains plain Home / plain Pro (not N, Education, Single Language...). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Editions,
        [Parameter(Mandatory = $true)][ValidateSet('home', 'pro')][string]$Edition
    )
    $pattern = if ($Edition -eq 'home') { '^Windows 1[01] Home$' } else { '^Windows 1[01] Pro$' }
    foreach ($e in $Editions) { if ([string]$e.Name -match $pattern) { return $true } }
    return $false
}

function Get-DzThisPcFirmwareEdition {
    <#
        If the PC running the builder has a key in its firmware (OEM / MSDM table), returns
        'Home', 'Pro' or the raw description. Useful when you are reinstalling this same PC.
        Returns $null when there is no firmware key.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        $svc = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($svc.OA3xOriginalProductKey)) { return $null }
        $desc = [string]$svc.OA3xOriginalProductKeyDescription
        if ($desc -match 'CoreSingleLanguage') { return 'Home Single Language' }
        if ($desc -match 'CoreCountrySpecific') { return 'Home (China)' }
        if ($desc -match 'Professional') { return 'Pro' }
        if ($desc -match 'Core') { return 'Home' }
        return $desc
    }
    catch {
        return $null
    }
}

Export-ModuleMember -Function @(
    'Get-DzInstallMediaCandidate', 'ConvertTo-DzArchitectureName', 'Get-DzMediaInfo',
    'Test-DzMediaHasEdition', 'Get-DzThisPcFirmwareEdition'
)
