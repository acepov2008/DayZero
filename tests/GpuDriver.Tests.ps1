#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for kit\lib\GpuDriver.psm1: the latest NVIDIA / AMD driver, found, downloaded, checked and
# installed by itself. The web, the PC and the installer are replaced by mocks; the sample answers
# have the exact shape NVIDIA's and AMD's sites returned on 2026-11-22.

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $script:SourceKit = Join-Path $repo 'kit'
    $lib = Join-Path $script:SourceKit 'lib'
    foreach ($m in (& (Join-Path $lib 'Modules.ps1'))) { Import-Module (Join-Path $lib $m) -Force -DisableNameChecking }
    $script:Config = Get-DzConfig -KitRoot $script:SourceKit
    $script:Nvidia = @($script:Config.drivers.gpuApps | Where-Object { $_.vendor -eq 'NVIDIA' })[0]
    $script:Amd = @($script:Config.drivers.gpuApps | Where-Object { $_.vendor -eq 'AMD' })[0]
    $script:ProductsXml = '<?xml version="1.0" encoding="UTF-8"?><LookupValueSearch><LookupValues>' +
        '<LookupValue ParentID="127" RequiresProduct="True"><Name>NVIDIA GeForce RTX 4070</Name><Value>1015</Value></LookupValue>' +
        '<LookupValue ParentID="127" RequiresProduct="True"><Name>NVIDIA GeForce RTX 4070 SUPER</Name><Value>1016</Value></LookupValue>' +
        '<LookupValue ParentID="129" RequiresProduct="True"><Name>GeForce RTX 4070 Laptop GPU</Name><Value>1006</Value></LookupValue>' +
        '</LookupValues></LookupValueSearch>'
    $script:LookupJson = '{ "Success" : "1", "IDS" : [{ "downloadInfo": { "Success" : "1", "ID" : "285320", "Name" : "GeForce%20Game%20Ready%20Driver", "Version" : "621.24", "IsBeta" : "0", "IsWHQL" : "1", "DownloadURL" : "https://us.download.nvidia.com/Windows/621.24/621.24-desktop-win10-win11-64bit-international-dch-whql.exe", "DownloadURLFileSize" : "1.04 GB" } }] }'
    $script:AmdHtml = 'x <a href="https://drivers.amd.com/drivers/installer/26.20/whql/amd-software-adrenalin-edition-26.11.2-minimalsetup-261118_web.exe">Download</a> y'
    function New-Ctx {
        param([int]$WindowsVersion = 11)
        $state = New-DzState -Mode 'gaming' -Steps @([ordered]@{ id = 'gpu-nvidia'; title = 'X'; type = 'gpuApp'; group = 'D'; args = @{}; requires = @() })
        $c = New-DzContext -State $state -Config $script:Config -KitRoot $script:SourceKit -Settings ([pscustomobject]@{ buildId = $null })
        $c.System = [pscustomobject]@{ WindowsVersion = $WindowsVersion }
        return $c
    }
}

Describe 'Reading NVIDIA''s answers' {
    It 'reads the product list and finds a card by the name Windows shows' {
        $p = @(ConvertFrom-DzNvidiaProductList -Xml $script:ProductsXml)
        $p.Count | Should -Be 3
        (Find-DzNvidiaProduct -Products $p -GpuName 'NVIDIA GeForce RTX 4070').Pfid | Should -Be '1015'
        (Find-DzNvidiaProduct -Products $p -GpuName 'NVIDIA GeForce RTX 4070 SUPER').Pfid | Should -Be '1016'
        $laptop = Find-DzNvidiaProduct -Products $p -GpuName 'NVIDIA GeForce RTX 4070 Laptop GPU'
        $laptop.Pfid | Should -Be '1006'
        $laptop.Psid | Should -Be '129'
        Find-DzNvidiaProduct -Products $p -GpuName 'NVIDIA GeForce RTX 407' | Should -BeNullOrEmpty
        $withMemory = @(ConvertFrom-DzNvidiaProductList -Xml ('<x><LookupValue ParentID="101"><Name>GeForce GTX 1060</Name><Value>815</Value></LookupValue></x>'))
        (Find-DzNvidiaProduct -Products $withMemory -GpuName 'NVIDIA GeForce GTX 1060 6GB').Pfid | Should -Be '815'
        Find-DzNvidiaProduct -Products $withMemory -GpuName 'NVIDIA GeForce GTX 1060 Ti' | Should -BeNullOrEmpty
        Find-DzNvidiaProduct -Products $p -GpuName 'Microsoft Basic Display Adapter' | Should -BeNullOrEmpty
    }
    It 'reads the newest WHQL driver from the driver service' {
        $o = ConvertFrom-DzNvidiaLookup -Json $script:LookupJson
        $o.Version | Should -Be '621.24'
        $o.Url | Should -Be 'https://us.download.nvidia.com/Windows/621.24/621.24-desktop-win10-win11-64bit-international-dch-whql.exe'
        $o.Name | Should -Be 'GeForce Game Ready Driver'
    }
    It 'refuses a download address off NVIDIA''s download host, a beta, or a failed answer' {
        ConvertFrom-DzNvidiaLookup -Json ($script:LookupJson -replace 'us\.download\.nvidia\.com', 'evil.example') | Should -BeNullOrEmpty
        ConvertFrom-DzNvidiaLookup -Json ($script:LookupJson -replace 'https://us', 'http://us') | Should -BeNullOrEmpty
        ConvertFrom-DzNvidiaLookup -Json ($script:LookupJson -replace '"IsBeta" : "0"', '"IsBeta" : "1"') | Should -BeNullOrEmpty
        ConvertFrom-DzNvidiaLookup -Json '{ "Success" : "0" }' | Should -BeNullOrEmpty
    }
    It 'turns Windows'' driver version into NVIDIA''s and compares versions' {
        ConvertTo-DzNvidiaVersion -DriverVersion '32.0.16.2124' | Should -Be '621.24'
        ConvertTo-DzNvidiaVersion -DriverVersion '32.0.15.6094' | Should -Be '560.94'
        ConvertTo-DzNvidiaVersion -DriverVersion '' | Should -Be ''
        Test-DzVersionAtLeast -Installed '621.24' -Offered '621.24' | Should -BeTrue
        Test-DzVersionAtLeast -Installed '560.94' -Offered '621.24' | Should -BeFalse
        Test-DzVersionAtLeast -Installed '' -Offered '621.24' | Should -BeFalse
        Get-DzNvidiaOsId -WindowsVersion 11 | Should -Be 135
        Get-DzNvidiaOsId -WindowsVersion 10 | Should -Be 57
    }
    It 'finds AMD''s auto-detect installer on its driver page, and nothing else' {
        Find-DzAmdInstallerUrl -Html $script:AmdHtml | Should -Be 'https://drivers.amd.com/drivers/installer/26.20/whql/amd-software-adrenalin-edition-26.11.2-minimalsetup-261118_web.exe'
        Find-DzAmdInstallerUrl -Html 'https://evil.example/amd-software-adrenalin-edition-1-minimalsetup-1_web.exe' | Should -BeNullOrEmpty
        Find-DzAmdInstallerUrl -Html '' | Should -BeNullOrEmpty
    }
}

Describe 'Installing the NVIDIA driver' {
    BeforeEach {
        Mock -ModuleName GpuDriver Get-DzWebString { if ($Url -like '*lookupValueSearch*') { $script:ProductsXml } else { $script:LookupJson } }
        Mock -ModuleName GpuDriver Get-DzNvidiaGpu { [pscustomobject]@{ Name = 'NVIDIA GeForce RTX 4070'; Installed = '560.94' } }
        Mock -ModuleName GpuDriver Save-DzDownload { $Path }
        Mock -ModuleName GpuDriver Test-DzFileSignature { $null }
        Mock -ModuleName GpuDriver Invoke-DzProcess { [pscustomobject]@{ ExitCode = 0; Output = @(); TimedOut = $false } }
        Mock -ModuleName GpuDriver Remove-Item { }
    }
    It 'asks NVIDIA for this card on this Windows, downloads it from NVIDIA and installs it silently' {
        $ctx = New-Ctx -WindowsVersion 11
        $r = Install-DzGpuDriver -Context $ctx -Item $script:Nvidia
        $r.Status | Should -Be 'Done'
        $r.Message | Should -Match '621\.24'
        $ctx.Flags['RestartRecommended'] | Should -BeTrue
        Should -Invoke -ModuleName GpuDriver Get-DzWebString -ParameterFilter { $Url -like '*psid=127&pfid=1015&osID=135*' } -Times 1
        Should -Invoke -ModuleName GpuDriver Save-DzDownload -ParameterFilter { $Url -eq 'https://us.download.nvidia.com/Windows/621.24/621.24-desktop-win10-win11-64bit-international-dch-whql.exe' } -Times 1
        Should -Invoke -ModuleName GpuDriver Test-DzFileSignature -ParameterFilter { $Publisher -eq 'NVIDIA Corporation' } -Times 1
        Should -Invoke -ModuleName GpuDriver Invoke-DzProcess -ParameterFilter { ($Arguments -join ' ') -eq '-s -noreboot' } -Times 1
        @($ctx.State.PSObject.Properties | Where-Object { $_.Name -eq 'followUps' }).Count | Should -Be 0
    }
    It 'uses Windows 10''s driver on Windows 10' {
        [void](Install-DzGpuDriver -Context (New-Ctx -WindowsVersion 10) -Item $script:Nvidia)
        Should -Invoke -ModuleName GpuDriver Get-DzWebString -ParameterFilter { $Url -like '*osID=57*' } -Times 1
    }
    It 'downloads nothing when the newest driver is already there' {
        Mock -ModuleName GpuDriver Get-DzNvidiaGpu { [pscustomobject]@{ Name = 'NVIDIA GeForce RTX 4070'; Installed = '621.24' } }
        $r = Install-DzGpuDriver -Context (New-Ctx) -Item $script:Nvidia
        $r.Status | Should -Be 'Done'
        $r.Message | Should -Match 'already installed'
        Should -Invoke -ModuleName GpuDriver Save-DzDownload -Times 0
    }
    It 'never runs a download that is not signed by NVIDIA, and links to NVIDIA instead' {
        Mock -ModuleName GpuDriver Test-DzFileSignature { "signed by 'CN=Someone Else', expected 'NVIDIA Corporation'" }
        $ctx = New-Ctx
        $r = Install-DzGpuDriver -Context $ctx -Item $script:Nvidia
        $r.Status | Should -Be 'Warn'
        $r.Message | Should -Match 'Someone Else'
        Should -Invoke -ModuleName GpuDriver Invoke-DzProcess -Times 0
        $ctx.State.followUps[0].url | Should -Be 'https://www.nvidia.com/en-us/drivers/'
    }
    It 'links to NVIDIA when the installer fails or the card is not in NVIDIA''s list' {
        Mock -ModuleName GpuDriver Invoke-DzProcess { [pscustomobject]@{ ExitCode = 1; Output = @(); TimedOut = $false } }
        (Install-DzGpuDriver -Context (New-Ctx) -Item $script:Nvidia).Message | Should -Match 'exit code 1'
        Mock -ModuleName GpuDriver Get-DzNvidiaGpu { [pscustomobject]@{ Name = 'NVIDIA Quadro Something'; Installed = '' } }
        $ctx = New-Ctx
        (Install-DzGpuDriver -Context $ctx -Item $script:Nvidia).Status | Should -Be 'Warn'
        @($ctx.State.followUps).Count | Should -Be 1
    }
    It 'skips a PC without an NVIDIA card, and downloads nothing in a dry run' {
        Mock -ModuleName GpuDriver Get-DzNvidiaGpu { }
        (Install-DzGpuDriver -Context (New-Ctx) -Item $script:Nvidia).Status | Should -Be 'Skipped'
        Set-DzDryRun -Enabled $true
        try { (Install-DzGpuDriver -Context (New-Ctx) -Item $script:Nvidia).Message | Should -Match '^\[DRY-RUN\]' }
        finally { Set-DzDryRun -Enabled $false }
        Should -Invoke -ModuleName GpuDriver Get-DzWebString -Times 0
    }
}

Describe 'Installing the AMD driver' {
    BeforeEach {
        Mock -ModuleName GpuDriver Get-DzWebString { $script:AmdHtml }
        Mock -ModuleName GpuDriver Save-DzDownload { $Path }
        Mock -ModuleName GpuDriver Test-DzFileSignature { $null }
        Mock -ModuleName GpuDriver Invoke-DzProcess { [pscustomobject]@{ ExitCode = 0; Output = @(); TimedOut = $false } }
        Mock -ModuleName GpuDriver Remove-Item { }
    }
    It 'gets AMD''s auto-detect installer from amd.com (with the referer AMD wants), checks AMD''s signature, runs it silently' {
        $ctx = New-Ctx
        $r = Install-DzGpuDriver -Context $ctx -Item $script:Amd
        $r.Status | Should -Be 'Done'
        Should -Invoke -ModuleName GpuDriver Save-DzDownload -ParameterFilter { $Url -like 'https://drivers.amd.com/*minimalsetup*' -and $Headers.Referer -eq 'https://www.amd.com/' } -Times 1
        Should -Invoke -ModuleName GpuDriver Test-DzFileSignature -ParameterFilter { $Publisher -eq 'Advanced Micro Devices' } -Times 1
        Should -Invoke -ModuleName GpuDriver Invoke-DzProcess -ParameterFilter { $Arguments[0] -eq '-INSTALL' -and $Arguments[1] -eq '-LOG' } -Times 1
    }
    It 'links to AMD''s page when the installer does not succeed' {
        Mock -ModuleName GpuDriver Invoke-DzProcess { [pscustomobject]@{ ExitCode = -1; Output = @(); TimedOut = $true } }
        $ctx = New-Ctx
        $r = Install-DzGpuDriver -Context $ctx -Item $script:Amd
        $r.Status | Should -Be 'Warn'
        $r.Message | Should -Match 'within an hour'
        $ctx.State.followUps[0].url | Should -Be 'https://www.amd.com/en/support/download/drivers.html'
    }
}

Describe 'Safety of the driver download' {
    It 'only uses the vendors'' own https hosts and always checks the signature before running' {
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:SourceKit 'lib/GpuDriver.psm1')
        # Regex patterns in the module write dots as \. ; read them as plain host names.
        foreach ($m in [regex]::Matches(($src -replace '\\\.', '.'), 'https?://[A-Za-z0-9.-]+')) {
            $m.Value | Should -Match '^https://(www\.nvidia\.com|gfwsl\.geforce\.com|us\.download\.nvidia\.com|international\.download\.nvidia\.com|www\.amd\.com|drivers\.amd\.com)$' -Because $m.Value
        }
        $body = [regex]::Match($src, '(?s)function Install-DzSignedDriverPackage \{.*?\n\}').Value
        $body.IndexOf('Test-DzFileSignature') | Should -BeGreaterThan 0
        $body.IndexOf('Test-DzFileSignature') | Should -BeLessThan $body.IndexOf('Invoke-DzProcess')
    }
}
