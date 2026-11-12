#Requires -Version 5.1
<#
    DayZero - detects what kind of PC this is: Windows version/edition, laptop or desktop,
    GPU vendor(s), PC brand, virtual machine, activation status.

    The small ConvertTo-/Test- helpers are pure (no Windows calls) so they can be unit
    tested; Get-DzSystemInfo and Get-DzActivationStatus query Windows (CIM + registry).
#>

Set-StrictMode -Version 2.0

function ConvertTo-DzBrand {
    <# Normalises the manufacturer string to Dell / Lenovo / HP / ASUS, or 'Other'. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Manufacturer)
    $m = [string]$Manufacturer
    if ($m -match '(?i)\bdell\b|alienware') { return 'Dell' }
    if ($m -match '(?i)lenovo') { return 'Lenovo' }
    if ($m -match '(?i)^hp\b|hewlett[- ]?packard|^hpe?$') { return 'HP' }
    if ($m -match '(?i)asus') { return 'ASUS' }
    return 'Other'
}

function Test-DzVirtualMachine {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$Manufacturer, [AllowNull()][AllowEmptyString()][string]$Model)
    $text = "$Manufacturer $Model"
    return [bool]($text -match '(?i)virtual machine|virtualbox|vmware|qemu|kvm|parallels|xen|hyper-v|bochs|innotek')
}

function Test-DzLaptopChassis {
    <#
        Win32_SystemEnclosure.ChassisTypes values for portable PCs:
        8 Portable, 9 Laptop, 10 Notebook, 11 Hand Held, 12 Docking Station, 14 Sub Notebook,
        18 Expansion Chassis? (no), 30 Tablet, 31 Convertible, 32 Detachable.
        A battery also counts as "laptop" (some firmware reports odd chassis types).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][int[]]$ChassisTypes, [bool]$HasBattery = $false)
    if ($HasBattery) { return $true }
    foreach ($t in @($ChassisTypes)) { if ($t -in @(8, 9, 10, 11, 12, 14, 30, 31, 32)) { return $true } }
    return $false
}

function ConvertTo-DzGpuVendor {
    <# PCI vendor id in a PNP device id: VEN_10DE NVIDIA, VEN_1002 / VEN_1022 AMD, VEN_8086 Intel. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$PnpDeviceId)
    switch -Regex ([string]$PnpDeviceId) {
        '(?i)VEN_10DE' { return 'NVIDIA' }
        '(?i)VEN_(1002|1022)' { return 'AMD' }
        '(?i)VEN_8086' { return 'Intel' }
        default { return $null }
    }
}

function ConvertTo-DzWindowsMajor {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory = $true)][int]$Build)
    if ($Build -ge 22000) { return 11 }
    return 10
}

function Get-DzSystemInfo {
    <# Collects everything DayZero needs to know about this PC. #>
    [CmdletBinding()]
    param()
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $build = 0
    if ($cv -and $cv.PSObject.Properties['CurrentBuild']) { $build = [int]$cv.CurrentBuild }
    $ubr = if ($cv -and $cv.PSObject.Properties['UBR']) { [int]$cv.UBR } else { 0 }
    $displayVersion = if ($cv -and $cv.PSObject.Properties['DisplayVersion']) { [string]$cv.DisplayVersion } else { '' }
    $editionId = if ($cv -and $cv.PSObject.Properties['EditionID']) { [string]$cv.EditionID } else { '' }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $enclosure = @(Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue)
    $battery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
    $video = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue)

    $chassis = @()
    foreach ($e in $enclosure) { foreach ($t in @($e.ChassisTypes)) { $chassis += [int]$t } }
    $manufacturer = if ($cs) { [string]$cs.Manufacturer } else { '' }
    $model = if ($cs) { [string]$cs.Model } else { '' }

    $vendors = New-Object System.Collections.Generic.List[string]
    $gpuNames = New-Object System.Collections.Generic.List[string]
    foreach ($v in $video) {
        $vendor = ConvertTo-DzGpuVendor -PnpDeviceId ([string]$v.PNPDeviceID)
        if ($vendor -and -not $vendors.Contains($vendor)) { $vendors.Add($vendor) }
        if ($v.Name) { $gpuNames.Add([string]$v.Name) }
    }
    $arch = switch -Regex ([string]$env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } 'AMD64' { 'amd64' } default { 'x86' } }
    if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { $arch = 'arm64' }

    $freeGB = $null
    try {
        $sysDrive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID = '{0}'" -f $env:SystemDrive) -ErrorAction Stop
        $freeGB = [math]::Round(([double]$sysDrive.FreeSpace) / 1GB, 1)
    }
    catch { $freeGB = $null }

    return [pscustomobject]@{
        WindowsVersion  = (ConvertTo-DzWindowsMajor -Build $build)
        Build           = $build
        Ubr             = $ubr
        DisplayVersion  = $displayVersion
        EditionId       = $editionId
        Caption         = $(if ($os) { [string]$os.Caption } else { 'Windows' })
        Architecture    = $arch
        Manufacturer    = $manufacturer
        Model           = $model
        Brand           = (ConvertTo-DzBrand -Manufacturer $manufacturer)
        IsVirtualMachine = (Test-DzVirtualMachine -Manufacturer $manufacturer -Model $model)
        IsLaptop        = (Test-DzLaptopChassis -ChassisTypes $chassis -HasBattery ($battery.Count -gt 0))
        GpuVendors      = $vendors.ToArray()
        GpuNames        = $gpuNames.ToArray()
        MemoryGB        = $(if ($cs) { [math]::Round(([double]$cs.TotalPhysicalMemory) / 1GB) } else { $null })
        FreeDiskGB      = $freeGB
    }
}

function Format-DzSystemSummary {
    <# One-line description, e.g. "Windows 11 Pro 25H2 (build 26200.1234) - desktop - NVIDIA - Dell". #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][object]$System)
    $form = if ($System.IsVirtualMachine) { 'virtual machine' } elseif ($System.IsLaptop) { 'laptop' } else { 'desktop' }
    $gpu = if (@($System.GpuVendors).Count -gt 0) { (@($System.GpuVendors) -join ' + ') } else { 'no GPU vendor detected' }
    $ver = ('{0} {1}' -f $System.Caption, $System.DisplayVersion).Trim() -replace '^Microsoft ', ''
    return ('{0} (build {1}.{2}) - {3} - {4} - {5}' -f $ver, $System.Build, $System.Ubr, $form, $gpu, $System.Brand)
}

function ConvertTo-DzLicenseStatusText {
    <# SoftwareLicensingProduct.LicenseStatus values. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$Status)
    switch ($Status) {
        0 { 'Not activated' }
        1 { 'Activated' }
        2 { 'Grace period (out of box)' }
        3 { 'Grace period (out of tolerance)' }
        4 { 'Grace period (non-genuine)' }
        5 { 'Not activated (notification mode)' }
        6 { 'Grace period (extended)' }
        default { "Unknown ($Status)" }
    }
}

function Get-DzActivationStatus {
    <#
        Reads Windows activation from the licensing service (read-only). Also reports the
        product key stored in the firmware (OEM key), if any, and whether its edition matches.
    #>
    [CmdletBinding()]
    param()
    $result = [ordered]@{
        Activated = $false; StatusText = 'Unknown'; Channel = ''; Edition = ''; PartialKey = ''
        FirmwareKeyPresent = $false; FirmwareEdition = ''; Error = $null
    }
    try {
        $windowsAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'
        $products = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID = '$windowsAppId' AND PartialProductKey IS NOT NULL" -ErrorAction Stop)
        $p = $products | Sort-Object -Property LicenseStatus | Where-Object { $_.LicenseStatus -eq 1 } | Select-Object -First 1
        if ($null -eq $p) { $p = $products | Select-Object -First 1 }
        if ($p) {
            $result.Activated = ([int]$p.LicenseStatus -eq 1)
            $result.StatusText = ConvertTo-DzLicenseStatusText -Status ([int]$p.LicenseStatus)
            $result.Channel = [string]$p.ProductKeyChannel
            $result.Edition = [string]$p.Name
            $result.PartialKey = [string]$p.PartialProductKey
        }
        $svc = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace([string]$svc.OA3xOriginalProductKey)) {
            $result.FirmwareKeyPresent = $true
            $result.FirmwareEdition = [string]$svc.OA3xOriginalProductKeyDescription
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Test-DzInternet {
    <# Same check Windows uses (NCSI): fetch Microsoft's connect-test page. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([int]$TimeoutSec = 6)
    try {
        $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return ([string]$r.Content -match 'Microsoft Connect Test')
    }
    catch {
        return $false
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-DzBrand', 'Test-DzVirtualMachine', 'Test-DzLaptopChassis', 'ConvertTo-DzGpuVendor', 'ConvertTo-DzWindowsMajor',
    'Get-DzSystemInfo', 'Format-DzSystemSummary', 'ConvertTo-DzLicenseStatusText', 'Get-DzActivationStatus', 'Test-DzInternet'
)
