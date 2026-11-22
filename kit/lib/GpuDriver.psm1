#Requires -Version 5.1
<#
    DayZero - the latest graphics driver, downloaded and installed by itself (NVIDIA and AMD).

    NVIDIA: the card's name (Win32_VideoController) is looked up in NVIDIA's own product list
      (www.nvidia.com/Download/API/lookupValueSearch.aspx), then NVIDIA's driver service (the one
      nvidia.com's driver search uses, gfwsl.geforce.com) names the newest WHQL Game Ready driver
      for that card and Windows version. The package comes from us.download.nvidia.com, must be
      signed by "NVIDIA Corporation", and is installed silently (-s -noreboot). Skipped when that
      version or a newer one is already installed.
    AMD: the auto-detect installer named on www.amd.com's driver page (it picks the right driver
      for the card) comes from drivers.amd.com, must be signed by "Advanced Micro Devices", and is
      run silently (-INSTALL, AMD's documented command line).

    Rules: only these official hosts, only https, only a valid signature from the vendor. Anything
    that does not work out leaves the official download page as a button on the summary screen
    (Windows Update has already installed a working driver by then); nothing is guessed.
#>

Set-StrictMode -Version 2.0

$script:NvidiaProductsUrl = 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3'
$script:NvidiaLookupUrl = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid={0}&pfid={1}&osID={2}&languageCode=1033&isWHQL=1&dch=1&sort1=0&numberOfResults=1'
$script:NvidiaDriverUrlPattern = '^https://(us|international)\.download\.nvidia\.com/Windows/[0-9.]+/[A-Za-z0-9._-]+\.exe$'
$script:AmdPageUrl = 'https://www.amd.com/en/support/download/drivers.html'
$script:AmdInstallerPattern = 'https://drivers\.amd\.com/drivers/installer/[0-9.]+/whql/amd-software-adrenalin-edition-[0-9.]+-minimalsetup-[0-9]+_web\.exe'
$script:BrowserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) DayZero'

# ------------------------------------------------------------------------------------
# NVIDIA: pure helpers (tested without a network)
# ------------------------------------------------------------------------------------

function ConvertFrom-DzNvidiaProductList {
    <# NVIDIA's product list (XML) -> Name, Pfid (product id), Psid (series id). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Xml)
    $doc = New-Object System.Xml.XmlDocument
    $doc.XmlResolver = $null
    $doc.LoadXml($Xml)
    foreach ($n in @($doc.SelectNodes('//LookupValue'))) {
        $name = [string]$n.Name
        $pfid = [string]$n.Value
        $psid = [string]$n.GetAttribute('ParentID')
        if ($name -and $pfid -match '^\d+$' -and $psid -match '^\d+$') { [pscustomobject]@{ Name = $name.Trim(); Pfid = $pfid; Psid = $psid } }
    }
}

function ConvertTo-DzGpuNameKey {
    <# 'NVIDIA GeForce RTX 4070  Laptop GPU' -> 'geforce rtx 4070 laptop gpu' (NVIDIA's list writes it either way). #>
    [OutputType([string])]
    param([AllowEmptyString()][string]$Name)
    $k = ([string]$Name -replace '\(R\)|\(TM\)|[^A-Za-z0-9 ]', ' ').ToLowerInvariant()
    $k = ($k -replace '\s+', ' ').Trim()
    return ($k -replace '^nvidia ', '')
}

function Find-DzNvidiaProduct {
    <# The product-list entry for a card name as Windows shows it, or $null. Exact name match only. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Products, [Parameter(Mandatory = $true)][string]$GpuName)
    $key = ConvertTo-DzGpuNameKey -Name $GpuName
    if (-not $key) { return $null }
    $hit = @($Products | Where-Object { (ConvertTo-DzGpuNameKey -Name $_.Name) -eq $key }) | Select-Object -First 1
    # Windows may add the memory size ('GeForce GTX 1060 6GB'); NVIDIA's list does not.
    if ($null -eq $hit -and $key -match ' \d+gb$') {
        $short = $key -replace ' \d+gb$', ''
        $hit = @($Products | Where-Object { (ConvertTo-DzGpuNameKey -Name $_.Name) -eq $short }) | Select-Object -First 1
    }
    return $hit
}

function ConvertFrom-DzNvidiaLookup {
    <# NVIDIA's driver-service answer (JSON) -> Version, Url, Name; $null when it offers nothing usable. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Json)
    $data = $Json | ConvertFrom-Json
    if ([string]$data.Success -ne '1') { return $null }
    $info = @($data.IDS)[0].downloadInfo
    if ($null -eq $info) { return $null }
    $url = [string]$info.DownloadURL
    $version = [string]$info.Version
    if ($url -notmatch $script:NvidiaDriverUrlPattern -or $version -notmatch '^\d{3}\.\d{2}$') { return $null }
    if ([string]$info.IsWHQL -ne '1' -or [string]$info.IsBeta -eq '1') { return $null }
    return [pscustomobject]@{ Version = $version; Url = $url; Name = [System.Uri]::UnescapeDataString([string]$info.Name); FileSize = [string]$info.DownloadURLFileSize }
}

function ConvertTo-DzNvidiaVersion {
    <# Windows' driver version '32.0.16.2124' -> NVIDIA's '621.24' (the last five digits), or ''. #>
    [OutputType([string])]
    param([AllowEmptyString()][string]$DriverVersion)
    $digits = (([string]$DriverVersion -split '\.') | Select-Object -Last 2) -join ''
    if ($digits -notmatch '^\d{5,}$') { return '' }
    $five = $digits.Substring($digits.Length - 5)
    return ('{0}.{1}' -f $five.Substring(0, 3), $five.Substring(3))
}

function Test-DzVersionAtLeast {
    [OutputType([bool])]
    param([AllowEmptyString()][string]$Installed, [Parameter(Mandatory = $true)][string]$Offered)
    $a = $null; $b = $null
    if (-not [version]::TryParse($Installed, [ref]$a) -or -not [version]::TryParse($Offered, [ref]$b)) { return $false }
    return ($a -ge $b)
}

function Get-DzNvidiaOsId {
    <# NVIDIA's operating-system id: 135 = Windows 11, 57 = Windows 10 64-bit. #>
    [OutputType([int])]
    param([int]$WindowsVersion)
    if ($WindowsVersion -ge 11) { return 135 }
    return 57
}

function Find-DzAmdInstallerUrl {
    <# The auto-detect installer named on AMD's driver page, or $null. #>
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Html)
    $m = [regex]::Matches($Html, $script:AmdInstallerPattern)
    if ($m.Count -eq 0) { return $null }
    return (@($m | ForEach-Object { $_.Value } | Sort-Object -Unique -Descending))[0]
}

# ------------------------------------------------------------------------------------
# Network and the PC (replaced by mocks in the tests)
# ------------------------------------------------------------------------------------

function Get-DzWebString {
    <# A web page or API answer as text. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Url, [hashtable]$Headers = @{})
    Enable-DzTls12
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60 -UserAgent $script:BrowserAgent -Headers $Headers -ErrorAction Stop
    return [string]$r.Content
}

function Get-DzNvidiaGpu {
    <# NVIDIA cards in this PC: Name and the NVIDIA version of the driver they have now. #>
    [CmdletBinding()]
    param()
    foreach ($v in @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue)) {
        if ([string]$v.PNPDeviceID -match '(?i)VEN_10DE') {
            [pscustomobject]@{ Name = [string]$v.Name; Installed = (ConvertTo-DzNvidiaVersion -DriverVersion ([string]$v.DriverVersion)) }
        }
    }
}

function Get-DzDriverDownloadFolder {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $base = if ($env:SystemDrive) { Join-Path $env:SystemDrive 'DayZero' } else { [System.IO.Path]::GetTempPath() }
    return (Join-Path $base 'downloads')
}

# ------------------------------------------------------------------------------------
# Installing
# ------------------------------------------------------------------------------------

function Add-DzDriverFallback {
    <# The official download page on the summary screen, with the reason in the step's message. #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][object]$Item, [Parameter(Mandatory = $true)][string]$Reason)
    $page = [string](Get-DzProperty $Item 'page' '')
    if ($page) { Add-DzFollowUp -Context $Context -Title ("Download the {0}" -f $Item.name) -Url $page }
    return (New-DzStepResult -Status Warn -Message ("{0} The summary has a button for the official download page. Windows Update already installed a working driver." -f $Reason))
}

function Install-DzSignedDriverPackage {
    <# Downloads, checks the signature, runs silently. Returns $null on success, else the reason. #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Publisher,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [hashtable]$Headers = @{}
    )
    $file = Join-Path (Get-DzDriverDownloadFolder -Context $Context) ([System.IO.Path]::GetFileName(([System.Uri]$Url).AbsolutePath))
    Write-DzLog "Downloading $Url"
    try { [void](Save-DzDownload -Url $Url -Path $file -TimeoutSec 3600 -Headers $Headers -UserAgent $script:BrowserAgent) }
    catch { return "The download failed ($($_.Exception.Message))." }
    $problem = Test-DzFileSignature -Path $file -Publisher $Publisher
    if ($problem) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        return "The download was not used: $problem."
    }
    Write-DzLog "Signed by $Publisher; installing silently: $([System.IO.Path]::GetFileName($file)) $($Arguments -join ' ')"
    $r = Invoke-DzProcess -FilePath $file -Arguments $Arguments -TimeoutSec 3600
    if ($r.TimedOut) { return 'The installer did not finish within an hour.' }
    if ($r.ExitCode -ne 0) { return "The installer ended with exit code $($r.ExitCode)." }
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    $Context.Flags['RestartRecommended'] = $true
    return $null
}

function Install-DzNvidiaDriver {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][object]$Item)
    if (Test-DzDryRun) { return (New-DzStepResult -Status Done -Message '[DRY-RUN] would look up, download and silently install the latest NVIDIA Game Ready driver for this card.') }
    $gpus = @(Get-DzNvidiaGpu)
    if ($gpus.Count -eq 0) { return (New-DzStepResult -Status Skipped -Message 'No NVIDIA graphics card found.') }
    $gpu = $gpus[0]
    try { $products = @(ConvertFrom-DzNvidiaProductList -Xml (Get-DzWebString -Url $script:NvidiaProductsUrl)) }
    catch { return (Add-DzDriverFallback -Context $Context -Item $Item -Reason "NVIDIA's product list could not be read ($($_.Exception.Message)).") }
    $product = Find-DzNvidiaProduct -Products $products -GpuName $gpu.Name
    if ($null -eq $product) { return (Add-DzDriverFallback -Context $Context -Item $Item -Reason "NVIDIA's driver list does not name '$($gpu.Name)'.") }
    $winVer = if ($Context.System) { [int]$Context.System.WindowsVersion } else { 11 }
    $lookup = $script:NvidiaLookupUrl -f $product.Psid, $product.Pfid, (Get-DzNvidiaOsId -WindowsVersion $winVer)
    try { $offer = ConvertFrom-DzNvidiaLookup -Json (Get-DzWebString -Url $lookup) }
    catch { return (Add-DzDriverFallback -Context $Context -Item $Item -Reason "NVIDIA's driver service could not be reached ($($_.Exception.Message)).") }
    if ($null -eq $offer) { return (Add-DzDriverFallback -Context $Context -Item $Item -Reason "NVIDIA offers no WHQL driver for '$($gpu.Name)' on Windows $winVer.") }
    Write-DzLog "NVIDIA: $($gpu.Name) has driver $($gpu.Installed); newest is $($offer.Version) ($($offer.FileSize))."
    if (Test-DzVersionAtLeast -Installed $gpu.Installed -Offered $offer.Version) {
        return (New-DzStepResult -Status Done -Message ("The newest NVIDIA driver ({0}) is already installed." -f $gpu.Installed))
    }
    $problem = Install-DzSignedDriverPackage -Context $Context -Url $offer.Url -Publisher 'NVIDIA Corporation' -Arguments @('-s', '-noreboot')
    if ($problem) { return (Add-DzDriverFallback -Context $Context -Item $Item -Reason "NVIDIA driver $($offer.Version): $problem") }
    return (New-DzStepResult -Status Done -Message ("Installed the NVIDIA Game Ready driver {0} for the {1}. A restart finishes it." -f $offer.Version, $gpu.Name))
}

function Install-DzAmdDriver {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][object]$Item)
    if (Test-DzDryRun) { return (New-DzStepResult -Status Done -Message "[DRY-RUN] would download AMD's auto-detect installer and silently install the latest AMD driver.") }
    try { $url = Find-DzAmdInstallerUrl -Html (Get-DzWebString -Url $script:AmdPageUrl) }
    catch { return (Add-DzDriverFallback -Context $Context -Item $Item -Reason "AMD's driver page could not be read ($($_.Exception.Message)).") }
    if (-not $url) { return (Add-DzDriverFallback -Context $Context -Item $Item -Reason "AMD's driver page names no auto-detect installer.") }
    $log = Join-Path (Get-DzDriverDownloadFolder -Context $Context) 'amd-install.log'
    # AMD only hands out its installer to visitors coming from amd.com.
    $problem = Install-DzSignedDriverPackage -Context $Context -Url $url -Publisher 'Advanced Micro Devices' -Arguments @('-INSTALL', '-LOG', $log) -Headers @{ Referer = 'https://www.amd.com/' }
    if ($problem) { return (Add-DzDriverFallback -Context $Context -Item $Item -Reason "AMD Software: $problem") }
    return (New-DzStepResult -Status Done -Message ("Installed the latest AMD driver with AMD's installer ({0}). A restart finishes it." -f [System.IO.Path]::GetFileName($url)))
}

function Install-DzGpuDriver {
    <# drivers.json gpuApps entry with "driver": "nvidia" or "amd". #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][object]$Item)
    switch ([string](Get-DzProperty $Item 'driver' '')) {
        'nvidia' { return (Install-DzNvidiaDriver -Context $Context -Item $Item) }
        'amd' { return (Install-DzAmdDriver -Context $Context -Item $Item) }
    }
    return (New-DzStepResult -Status Failed -Message "Unknown driver kind for $($Item.name).")
}

Export-ModuleMember -Function @(
    'ConvertFrom-DzNvidiaProductList', 'ConvertTo-DzGpuNameKey', 'Find-DzNvidiaProduct', 'ConvertFrom-DzNvidiaLookup', 'ConvertTo-DzNvidiaVersion',
    'Test-DzVersionAtLeast', 'Get-DzNvidiaOsId', 'Find-DzAmdInstallerUrl', 'Get-DzWebString', 'Get-DzNvidiaGpu',
    'Install-DzNvidiaDriver', 'Install-DzAmdDriver', 'Install-DzGpuDriver'
)
