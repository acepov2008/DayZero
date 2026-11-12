#Requires -Version 5.1
<#
    DayZero - downloads and signature checks. Used by the wizard (winget fallback, Office
    Deployment Tool, vendor apps) and by the USB builder (offline helpers on the stick).

    Rule: a downloaded installer only runs if its Authenticode signature is valid AND the
    signer is the expected company (e.g. "Microsoft Corporation").
#>

Set-StrictMode -Version 2.0

function Enable-DzTls12 {
    <# Windows PowerShell 5.1 may default to old TLS versions; GitHub and Microsoft need TLS 1.2+. #>
    [CmdletBinding()]
    param()
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    catch { Write-Verbose 'Could not change the TLS setting.' }
}

function Save-DzDownload {
    <# Downloads a file. Returns the path. Throws on failure. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutSec = 1800
    )
    Enable-DzTls12
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $tmp = "$Path.partial"
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest many times slower on 5.1
    try {
        Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
    finally {
        $ProgressPreference = $old
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    return $Path
}

function Test-DzSignerMatch {
    <# Pure check: does a certificate subject belong to the expected publisher? #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][string]$Subject, [Parameter(Mandatory = $true)][string]$Publisher)
    if ([string]::IsNullOrWhiteSpace($Subject)) { return $false }
    # Subjects look like: CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US
    return [bool]($Subject -match ('(^|,\s*)(O|CN)=' + [regex]::Escape($Publisher) + '(,|$)'))
}

function Test-DzFileSignature {
    <#
        Returns $null when the file has a valid Authenticode signature from $Publisher,
        otherwise a short reason. Windows-only (Get-AuthenticodeSignature).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Publisher
    )
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') { return "signature status is $($sig.Status)" }
    $subject = if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' }
    if (-not (Test-DzSignerMatch -Subject $subject -Publisher $Publisher)) { return "signed by '$subject', expected '$Publisher'" }
    return $null
}

function Get-DzFileSha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try { return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}

Export-ModuleMember -Function @('Enable-DzTls12', 'Save-DzDownload', 'Test-DzSignerMatch', 'Test-DzFileSignature', 'Get-DzFileSha256')
