#Requires -Version 5.1
<#
    DayZero builder - "offline helpers": copies of App Installer (winget) and the Office
    Deployment Tool that the builder downloads onto the stick, so a fresh PC can get
    winget even before the Microsoft Store has updated it. All come from Microsoft:

      App Installer + dependencies   github.com/microsoft/winget-cli (latest release)
      Office Deployment Tool         officecdn.microsoft.com (must be signed by Microsoft)

    Also: Test-DzAppCatalog checks every winget id in apps.json with 'winget show'.
#>

Set-StrictMode -Version 2.0

function Get-DzBundleList {
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{ Name = 'App Installer (winget)'; Url = 'https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'; Path = 'winget\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'; ExtractTo = $null; Signer = $null },
        [pscustomobject]@{ Name = 'winget dependencies'; Url = 'https://github.com/microsoft/winget-cli/releases/latest/download/DesktopAppInstaller_Dependencies.zip'; Path = 'winget\DesktopAppInstaller_Dependencies.zip'; ExtractTo = 'winget\deps'; Signer = $null },
        [pscustomobject]@{ Name = 'Office Deployment Tool'; Url = 'https://officecdn.microsoft.com/pr/wsus/setup.exe'; Path = 'odt\setup.exe'; ExtractTo = $null; Signer = 'Microsoft Corporation' }
    )
}

function Save-DzFileWithProgress {
    <# Downloads with WebClient, calling $Progress(bytesSoFar) every ~200 ms so the GUI can repaint. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Path,
        [scriptblock]$Progress
    )
    Enable-DzTls12
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $tmp = "$Path.partial"
    $wc = New-Object System.Net.WebClient
    try {
        $task = $wc.DownloadFileTaskAsync($Url, $tmp)
        while (-not $task.IsCompleted) {
            if ($Progress -and (Test-Path -LiteralPath $tmp)) { & $Progress ((Get-Item -LiteralPath $tmp).Length) }
            Start-Sleep -Milliseconds 200
        }
        if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
    finally {
        $wc.Dispose()
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    return $Path
}

function Save-DzBundle {
    <#
        Downloads every helper into <KitPath>\bundled and writes bundled\bundles.json.
        Returns the list of results; a failed download does not stop the others.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$KitPath,
        [scriptblock]$Log,
        [scriptblock]$Status
    )
    $root = Join-Path $KitPath 'bundled'
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($b in (Get-DzBundleList)) {
        $target = Join-Path $root $b.Path
        try {
            if ($Log) { & $Log "Downloading $($b.Name) from $($b.Url)" }
            $name = $b.Name
            $statusCallback = $Status
            [void](Save-DzFileWithProgress -Url $b.Url -Path $target -Progress {
                    param($bytes) if ($statusCallback) { & $statusCallback ("Downloading {0}: {1:N0} MB" -f $name, ($bytes / 1MB)) }
                }.GetNewClosure())
            if ($b.Signer) {
                $problem = Test-DzFileSignature -Path $target -Publisher $b.Signer
                if ($problem) { Remove-Item -LiteralPath $target -Force; throw "rejected: $problem" }
            }
            $hash = Get-DzFileSha256 -Path $target
            $size = (Get-Item -LiteralPath $target).Length
            if ($b.ExtractTo) {
                $dest = Join-Path $root $b.ExtractTo
                if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
                Expand-Archive -LiteralPath $target -DestinationPath $dest -Force
                Remove-Item -LiteralPath $target -Force
            }
            $results.Add([pscustomobject]@{ name = $b.Name; url = $b.Url; path = $b.Path; sha256 = $hash; bytes = $size; ok = $true; error = $null })
            if ($Log) { & $Log ("  OK, {0:N1} MB, SHA256 {1}" -f ($size / 1MB), $hash) }
        }
        catch {
            $results.Add([pscustomobject]@{ name = $b.Name; url = $b.Url; path = $b.Path; sha256 = $null; bytes = 0; ok = $false; error = $_.Exception.Message })
            if ($Log) { & $Log ("  FAILED: " + $_.Exception.Message) }
        }
    }
    $manifest = [ordered]@{ downloadedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); items = $results.ToArray() }
    [System.IO.File]::WriteAllText((Join-Path $root 'bundles.json'), ($manifest | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    return , $results.ToArray()
}

function Test-DzAppCatalog {
    <#
        Runs 'winget show --id <id> --exact' for every app in apps.json (plus the GPU / PC-brand
        tools in drivers.json when given). Missing ids get a 'winget search' by name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WingetPath,
        [Parameter(Mandatory = $true)][object[]]$Items,
        [scriptblock]$Log
    )
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($i in $Items) {
        $ok = Test-DzWingetPackageExists -WingetPath $WingetPath -Id $i.Id -Source $i.Source
        $hits = @()
        if (-not $ok) { $hits = Search-DzWingetPackage -WingetPath $WingetPath -Name $i.Name -Source $i.Source }
        $out.Add([pscustomobject]@{ Id = $i.Id; Name = $i.Name; Source = $i.Source; Found = $ok; Search = $hits })
        if ($Log) {
            & $Log ("{0} {1} ({2})" -f $(if ($ok) { 'OK     ' } else { 'MISSING' }), $i.Id, $i.Name)
            foreach ($h in $hits) { & $Log "          $h" }
        }
    }
    return , $out.ToArray()
}

function Get-DzCatalogPackageList {
    <# Flattens apps.json (+ drivers.json) into Id / Name / Source items for Test-DzAppCatalog. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $list = New-Object System.Collections.Generic.List[object]
    if ($Config.apps) {
        foreach ($a in @($Config.apps.apps)) {
            $src = [string](Get-DzProperty $a 'source' 'winget')
            $id = if ($src -eq 'msstore') { [string](Get-DzProperty $a 'msstore' '') } else { [string](Get-DzProperty $a 'winget' '') }
            if ($id) { $list.Add([pscustomobject]@{ Id = $id; Name = [string]$a.name; Source = $src }) }
        }
    }
    if ($Config.drivers) {
        foreach ($t in @(Get-DzProperty $Config.drivers 'gpuApps' @()) + @(Get-DzProperty $Config.drivers 'oemTools' @())) {
            $w = [string](Get-DzProperty $t 'winget' '')
            $m = [string](Get-DzProperty $t 'msstore' '')
            if ($w) { $list.Add([pscustomobject]@{ Id = $w; Name = [string]$t.name; Source = 'winget' }) }
            elseif ($m) { $list.Add([pscustomobject]@{ Id = $m; Name = [string]$t.name; Source = 'msstore' }) }
        }
    }
    if ($Config.office) {
        $odt = [string](Get-DzProperty (Get-DzProperty $Config.office 'odt' $null) 'wingetId' '')
        if ($odt) { $list.Add([pscustomobject]@{ Id = $odt; Name = 'Office Deployment Tool'; Source = 'winget' }) }
    }
    return , $list.ToArray()
}

Export-ModuleMember -Function @('Get-DzBundleList', 'Save-DzFileWithProgress', 'Save-DzBundle', 'Test-DzAppCatalog', 'Get-DzCatalogPackageList')
