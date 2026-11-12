#Requires -Version 5.1
<#
    DayZero - answer file (autounattend.xml) generator.

    Pure functions only: no file access, no Windows-only APIs, so the whole module
    can be unit tested on any PowerShell (see tests\Unattend.Tests.ps1).

    SAFETY RULES enforced here (and checked by the tests):
      * The answer file never contains DiskConfiguration, ImageInstall/InstallTo or
        anything else that touches disks. Windows Setup therefore always stops at the
        "Where do you want to install Windows?" page and the user picks the disk.
      * Only documented unattend settings are used. No BypassNRO, no LabConfig, no
        OOBE registry hacks.
      * Passwords are written with PlainText=false. That is base64, NOT encryption.
        The builder warns the user about this.
#>

Set-StrictMode -Version 2.0

$script:NsUnattend = 'urn:schemas-microsoft-com:unattend'
$script:NsWcm = 'http://schemas.microsoft.com/WMIConfig/2002/State'
$script:NsXmlns = 'http://www.w3.org/2000/xmlns/'
$script:PublicKeyToken = '31bf3856ad364e35'

# Microsoft's generic installation keys. They only choose WHICH edition Setup installs;
# they never activate Windows. Activation comes from the PC's firmware key, its digital
# licence, or a key the user owns. Same keys for Windows 10 and Windows 11.
$script:GenericKeys = @{
    home = 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7'
    pro  = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
}

# Elements that must NEVER appear in a DayZero answer file (disk wiping / partitioning).
$script:ForbiddenElements = @(
    'DiskConfiguration', 'Disk', 'CreatePartitions', 'ModifyPartitions', 'WillWipeDisk',
    'ImageInstall', 'InstallTo', 'InstallToAvailablePartition'
)

function Get-DzGenericKey {
    <# Returns Microsoft's generic install key for 'home' or 'pro'. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][ValidateSet('home', 'pro')][string]$Edition)
    return $script:GenericKeys[$Edition]
}

function Get-DzForbiddenUnattendElement {
    <# Names of XML elements DayZero refuses to emit. Used by tests and by a final self-check. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return , $script:ForbiddenElements
}

function ConvertTo-DzUnattendSecret {
    <#
        Encodes a password the way Windows Setup expects when PlainText is false:
        base64( UTF-16LE( password + suffix ) ). The suffix is 'Password' for
        LocalAccount and AutoLogon passwords. This is obfuscation, not encryption.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [string]$Suffix = 'Password'
    )
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($Value + $Suffix)
    return [System.Convert]::ToBase64String($bytes)
}

function Test-DzComputerName {
    <# Returns $null when valid, otherwise a human-readable problem. Blank = random name. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    if ($Name.Length -gt 15) { return 'The computer name can be at most 15 characters.' }
    if ($Name -notmatch '^[A-Za-z0-9-]+$') { return 'The computer name can only use letters A-Z, digits and hyphens (-).' }
    if ($Name -match '^[0-9]+$') { return 'The computer name cannot be only digits.' }
    if ($Name.StartsWith('-') -or $Name.EndsWith('-')) { return 'The computer name cannot start or end with a hyphen.' }
    return $null
}

function Test-DzUserName {
    <# Local account name rules. Returns $null when valid, otherwise the problem. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][AllowNull()][string]$Name,
        [AllowEmptyString()][AllowNull()][string]$ComputerName
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'Enter a user name.' }
    if ($Name.Length -gt 20) { return 'The user name can be at most 20 characters.' }
    if ($Name -ne $Name.Trim()) { return 'The user name cannot start or end with a space.' }
    if ($Name -match '["/\\\[\]:;|=,+*?<>@%&^!]') { return 'The user name cannot contain any of these characters: " / \ [ ] : ; | = , + * ? < > @ % & ^ !' }
    if ($Name -match '^[. ]+$') { return 'The user name cannot be only dots or spaces.' }
    $reserved = @('Administrator', 'Administrators', 'Guest', 'Guests', 'DefaultAccount', 'WDAGUtilityAccount',
        'defaultuser0', 'SYSTEM', 'Users', 'Everyone', 'LocalService', 'NetworkService', 'None')
    foreach ($r in $reserved) {
        if ($Name -ieq $r) { return "'$Name' is a built-in Windows name. Pick another user name." }
    }
    if (-not [string]::IsNullOrWhiteSpace($ComputerName) -and $Name -ieq $ComputerName) {
        return 'The user name and the computer name must be different.'
    }
    return $null
}

function Test-DzProductKey {
    <# Format check only (5x5 characters). Returns $null when the format is valid. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return 'Enter your product key.' }
    if ($Key.Trim().ToUpperInvariant() -notmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') {
        return 'A product key looks like XXXXX-XXXXX-XXXXX-XXXXX-XXXXX.'
    }
    return $null
}

function Test-DzLocaleName {
    <# Culture names such as en-US, fi-FI, sr-Latn-RS. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Name, [string]$What = 'Locale')
    if ([string]::IsNullOrWhiteSpace($Name)) { return "$What is missing." }
    if ($Name -notmatch '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$') { return "$What '$Name' is not a valid language/region name." }
    return $null
}

function Test-DzInputLocale {
    <#
        Keyboard setting(s), e.g. 0409:00000409 or several separated by ';'.
        Input-method (IME) entries look like 0411:{GUID}{GUID}.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'Keyboard layout is missing.' }
    $guid = '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}'
    foreach ($part in $Value.Split(';')) {
        if ($part -notmatch ('^[0-9A-Fa-f]{4}:([0-9A-Fa-f]{8}|' + $guid + $guid + ')$')) {
            return "Keyboard setting '$part' is not in the form 0409:00000409."
        }
    }
    return $null
}

function New-DzBuildId {
    <# Short random id that ties the answer file to the matching DayZero folder on the USB. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $bytes = New-Object byte[] 4
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-DzKitSearchCommand {
    <#
        Builds the cmd.exe one-liners that find the USB by its build marker file.
        Drive letters change between boots, so we search for DayZero\build-<id>.marker.
        - Specialize: copies the kit to %SystemDrive%\DayZero while the USB is attached.
        - FirstLogon: runs the first-sign-in hook from the copy (C: is searched first)
          or, if the specialize copy failed, straight from the USB (which copies it then).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{8}$')][string]$BuildId,
        [string]$KitFolder = 'DayZero'
    )
    $letters = 'D E F G H I J K L M N O P Q R S T U V W X Y Z'
    $marker = $KitFolder + '\build-' + $BuildId + '.marker'
    $specialize = 'cmd.exe /c "for %d in (' + $letters + ') do @if exist %d:\' + $marker +
    ' (call %d:\' + $KitFolder + '\bootstrap\CopyKit.cmd %d: ' + $BuildId + ' & exit /b 0)"'
    $firstLogon = 'cmd.exe /c "for %d in (C ' + $letters + ') do @if exist %d:\' + $marker +
    ' (call %d:\' + $KitFolder + '\bootstrap\FirstLogon.cmd ' + $BuildId + ' & exit /b 0)"'
    return @{ Specialize = $specialize; FirstLogon = $firstLogon }
}

# ---------------------------------------------------------------------------------
# XML helpers (private)
# ---------------------------------------------------------------------------------

function Add-DzElement {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlNode]$Parent,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Text = $null
    )
    $doc = $Parent.OwnerDocument
    if ($null -eq $doc) { $doc = [System.Xml.XmlDocument]$Parent }
    $el = $doc.CreateElement($Name, $script:NsUnattend)
    if ($null -ne $Text) { $el.InnerText = [string]$Text }
    [void]$Parent.AppendChild($el)
    return $el
}

function Add-DzActionAdd {
    param([Parameter(Mandatory = $true)][System.Xml.XmlElement]$Element)
    $attr = $Element.OwnerDocument.CreateAttribute('wcm', 'action', $script:NsWcm)
    $attr.Value = 'add'
    [void]$Element.Attributes.Append($attr)
}

function Add-DzComment {
    param([Parameter(Mandatory = $true)][System.Xml.XmlNode]$Parent, [Parameter(Mandatory = $true)][string]$Text)
    $doc = $Parent.OwnerDocument
    if ($null -eq $doc) { $doc = [System.Xml.XmlDocument]$Parent }
    # '--' is not allowed inside XML comments.
    [void]$Parent.AppendChild($doc.CreateComment(' ' + $Text.Replace('--', '- -') + ' '))
}

function Add-DzComponent {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Settings,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Architecture
    )
    $c = Add-DzElement -Parent $Settings -Name 'component'
    $c.SetAttribute('name', $Name)
    $c.SetAttribute('processorArchitecture', $Architecture)
    $c.SetAttribute('publicKeyToken', $script:PublicKeyToken)
    $c.SetAttribute('language', 'neutral')
    $c.SetAttribute('versionScope', 'nonSxS')
    return $c
}

function Add-DzSecret {
    param([Parameter(Mandatory = $true)][System.Xml.XmlElement]$Parent, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Plain)
    $pw = Add-DzElement -Parent $Parent -Name 'Password'
    [void](Add-DzElement -Parent $pw -Name 'Value' -Text (ConvertTo-DzUnattendSecret -Value $Plain -Suffix 'Password'))
    [void](Add-DzElement -Parent $pw -Name 'PlainText' -Text 'false')
}

function Add-DzInternational {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Component,
        [Parameter(Mandatory = $true)][hashtable]$O,
        [switch]$WinPE
    )
    if ($WinPE) {
        $setupUi = Add-DzElement -Parent $Component -Name 'SetupUILanguage'
        [void](Add-DzElement -Parent $setupUi -Name 'UILanguage' -Text $O.UILanguage)
    }
    [void](Add-DzElement -Parent $Component -Name 'InputLocale' -Text $O.InputLocale)
    [void](Add-DzElement -Parent $Component -Name 'SystemLocale' -Text $O.SystemLocale)
    [void](Add-DzElement -Parent $Component -Name 'UILanguage' -Text $O.UILanguage)
    [void](Add-DzElement -Parent $Component -Name 'UserLocale' -Text $O.UserLocale)
}

# ---------------------------------------------------------------------------------
# Public: build the answer file
# ---------------------------------------------------------------------------------

function New-DzUnattendXml {
    <#
    .SYNOPSIS
        Returns the text of a DayZero autounattend.xml.
    .PARAMETER Options
        Hashtable with:
          Architecture   'amd64' (default) or 'arm64'
          UILanguage     display language, must exist on the install media (e.g. en-US)
          UserLocale     region format (e.g. fi-FI)
          SystemLocale   language for non-Unicode programs (defaults to UserLocale)
          InputLocale    keyboard, e.g. 040b:0000040b
          TimeZone       Windows time zone id, e.g. 'FLE Standard Time'
          Edition        'auto' | 'home' | 'pro' | 'key'
          ProductKey     required when Edition = 'key'
          UserName, Password
          AutoLogon      $true to sign in automatically until the wizard finishes
          AutoLogonCount number of automatic sign-ins (default 10)
          ComputerName   blank = Windows picks a random name
          BuildId        8 hex chars (New-DzBuildId)
          GeneratorVersion  free text for the header comment
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][hashtable]$Options)

    $o = @{
        Architecture     = 'amd64'
        SystemLocale     = $null
        Edition          = 'auto'
        ProductKey       = $null
        AutoLogon        = $true
        AutoLogonCount   = 10
        ComputerName     = ''
        GeneratorVersion = 'dev'
        KitFolder        = 'DayZero'
    }
    foreach ($k in $Options.Keys) { $o[$k] = $Options[$k] }
    if ([string]::IsNullOrWhiteSpace([string]$o.SystemLocale)) { $o.SystemLocale = $o.UserLocale }

    # ---- validate everything up front; refuse to produce a half-valid file -----------
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($req in 'UILanguage', 'UserLocale', 'InputLocale', 'TimeZone', 'UserName', 'BuildId') {
        if (-not $o.ContainsKey($req) -or [string]::IsNullOrWhiteSpace([string]$o[$req])) { $problems.Add("Missing option: $req") }
    }
    if (-not $o.ContainsKey('Password') -or $null -eq $o.Password) { $problems.Add('Missing option: Password') }
    if ($problems.Count -eq 0) {
        foreach ($p in @(
                (Test-DzLocaleName -Name $o.UILanguage -What 'Display language'),
                (Test-DzLocaleName -Name $o.UserLocale -What 'Region format'),
                (Test-DzLocaleName -Name $o.SystemLocale -What 'System locale'),
                (Test-DzInputLocale -Value $o.InputLocale),
                (Test-DzComputerName -Name $o.ComputerName),
                (Test-DzUserName -Name $o.UserName -ComputerName $o.ComputerName))) {
            if ($p) { $problems.Add($p) }
        }
        if ($o.Architecture -notin @('amd64', 'arm64')) { $problems.Add("Unsupported architecture '$($o.Architecture)'.") }
        if ($o.Edition -notin @('auto', 'home', 'pro', 'key')) { $problems.Add("Unknown edition choice '$($o.Edition)'.") }
        if ($o.Edition -eq 'key') {
            $kp = Test-DzProductKey -Key $o.ProductKey
            if ($kp) { $problems.Add($kp) }
        }
        if ([string]$o.BuildId -notmatch '^[0-9a-f]{8}$') { $problems.Add('BuildId must be 8 lowercase hex characters.') }
        if ([string]$o.TimeZone -match '[<>&"]') { $problems.Add('Time zone id contains invalid characters.') }
        if ($o.AutoLogon -and ([int]$o.AutoLogonCount -lt 1 -or [int]$o.AutoLogonCount -gt 50)) { $problems.Add('AutoLogonCount must be 1-50.') }
        if ([string]$o.Password -eq '') { $problems.Add('The password cannot be empty.') }
    }
    if ($problems.Count -gt 0) { throw ('Cannot create the answer file: ' + ($problems -join ' ')) }

    $arch = [string]$o.Architecture
    $computerName = if ([string]::IsNullOrWhiteSpace([string]$o.ComputerName)) { '*' } else { ([string]$o.ComputerName).Trim() }
    $commands = Get-DzKitSearchCommand -BuildId $o.BuildId -KitFolder $o.KitFolder

    # ---- document ------------------------------------------------------------------
    $doc = New-Object System.Xml.XmlDocument
    [void]$doc.AppendChild($doc.CreateXmlDeclaration('1.0', 'utf-8', $null))
    Add-DzComment -Parent $doc -Text ("Generated by DayZero Builder $($o.GeneratorVersion) - build $($o.BuildId).")
    Add-DzComment -Parent $doc -Text 'SAFETY: this file never partitions or wipes disks. Windows Setup will ask you which disk to use.'
    Add-DzComment -Parent $doc -Text 'WARNING: passwords below are base64-encoded, which is NOT encryption. Anyone with this USB can decode them.'

    $root = $doc.CreateElement('unattend', $script:NsUnattend)
    $wcmDecl = $doc.CreateAttribute('xmlns', 'wcm', $script:NsXmlns)
    $wcmDecl.Value = $script:NsWcm
    [void]$root.Attributes.Append($wcmDecl)
    [void]$doc.AppendChild($root)

    # ---- windowsPE: Setup language + edition. No disk settings on purpose. ---------
    $pe = Add-DzElement -Parent $root -Name 'settings'
    $pe.SetAttribute('pass', 'windowsPE')
    $peIntl = Add-DzComponent -Settings $pe -Name 'Microsoft-Windows-International-Core-WinPE' -Architecture $arch
    Add-DzInternational -Component $peIntl -O $o -WinPE

    $peSetup = Add-DzComponent -Settings $pe -Name 'Microsoft-Windows-Setup' -Architecture $arch
    Add-DzComment -Parent $peSetup -Text 'No DiskConfiguration and no ImageInstall/InstallTo: disk selection stays manual.'
    $userData = Add-DzElement -Parent $peSetup -Name 'UserData'
    [void](Add-DzElement -Parent $userData -Name 'AcceptEula' -Text 'true')
    switch ($o.Edition) {
        'auto' {
            Add-DzComment -Parent $userData -Text ('Edition: AUTO. No product key on purpose: Setup reads the PC firmware (OEM) key and installs the ' +
                'matching edition, which then activates by itself. PCs without one get the normal edition picker.')
        }
        'key' {
            Add-DzComment -Parent $userData -Text 'Edition: chosen by the user product key (stored here in plain text).'
            $pk = Add-DzElement -Parent $userData -Name 'ProductKey'
            [void](Add-DzElement -Parent $pk -Name 'Key' -Text (([string]$o.ProductKey).Trim().ToUpperInvariant()))
            [void](Add-DzElement -Parent $pk -Name 'WillShowUI' -Text 'OnError')
        }
        default {
            Add-DzComment -Parent $userData -Text ("Edition: $($o.Edition). Microsoft generic install key: selects the edition, never activates.")
            $pk = Add-DzElement -Parent $userData -Name 'ProductKey'
            [void](Add-DzElement -Parent $pk -Name 'Key' -Text (Get-DzGenericKey -Edition $o.Edition))
            [void](Add-DzElement -Parent $pk -Name 'WillShowUI' -Text 'OnError')
        }
    }

    # ---- specialize: computer name, time zone, copy the kit off the USB ------------
    $sp = Add-DzElement -Parent $root -Name 'settings'
    $sp.SetAttribute('pass', 'specialize')
    $spShell = Add-DzComponent -Settings $sp -Name 'Microsoft-Windows-Shell-Setup' -Architecture $arch
    [void](Add-DzElement -Parent $spShell -Name 'ComputerName' -Text $computerName)
    [void](Add-DzElement -Parent $spShell -Name 'TimeZone' -Text $o.TimeZone)

    $spDeploy = Add-DzComponent -Settings $sp -Name 'Microsoft-Windows-Deployment' -Architecture $arch
    $runSync = Add-DzElement -Parent $spDeploy -Name 'RunSynchronous'
    $cmd = Add-DzElement -Parent $runSync -Name 'RunSynchronousCommand'
    Add-DzActionAdd -Element $cmd
    [void](Add-DzElement -Parent $cmd -Name 'Description' -Text 'DayZero: copy the toolkit from the USB to the new Windows drive')
    [void](Add-DzElement -Parent $cmd -Name 'Order' -Text '1')
    [void](Add-DzElement -Parent $cmd -Name 'Path' -Text $commands.Specialize)

    # ---- oobeSystem: regional settings, local account, skip OOBE screens -----------
    $oobe = Add-DzElement -Parent $root -Name 'settings'
    $oobe.SetAttribute('pass', 'oobeSystem')
    $oobeIntl = Add-DzComponent -Settings $oobe -Name 'Microsoft-Windows-International-Core' -Architecture $arch
    Add-DzInternational -Component $oobeIntl -O $o

    $oobeShell = Add-DzComponent -Settings $oobe -Name 'Microsoft-Windows-Shell-Setup' -Architecture $arch
    if ($o.AutoLogon) {
        Add-DzComment -Parent $oobeShell -Text ('AutoLogon lets the DayZero wizard continue across reboots without typing the password. ' +
            'The wizard switches it off and removes the stored password when it finishes.')
        $al = Add-DzElement -Parent $oobeShell -Name 'AutoLogon'
        Add-DzSecret -Parent $al -Plain ([string]$o.Password)
        [void](Add-DzElement -Parent $al -Name 'Enabled' -Text 'true')
        [void](Add-DzElement -Parent $al -Name 'LogonCount' -Text ([string][int]$o.AutoLogonCount))
        [void](Add-DzElement -Parent $al -Name 'Username' -Text $o.UserName)
    }

    $flc = Add-DzElement -Parent $oobeShell -Name 'FirstLogonCommands'
    $sc = Add-DzElement -Parent $flc -Name 'SynchronousCommand'
    Add-DzActionAdd -Element $sc
    [void](Add-DzElement -Parent $sc -Name 'CommandLine' -Text $commands.FirstLogon)
    [void](Add-DzElement -Parent $sc -Name 'Description' -Text 'DayZero: start the setup wizard')
    [void](Add-DzElement -Parent $sc -Name 'Order' -Text '1')
    [void](Add-DzElement -Parent $sc -Name 'RequiresUserInput' -Text 'false')

    $oobeEl = Add-DzElement -Parent $oobeShell -Name 'OOBE'
    [void](Add-DzElement -Parent $oobeEl -Name 'HideEULAPage' -Text 'true')
    [void](Add-DzElement -Parent $oobeEl -Name 'HideOEMRegistrationScreen' -Text 'true')
    [void](Add-DzElement -Parent $oobeEl -Name 'HideOnlineAccountScreens' -Text 'true')
    [void](Add-DzElement -Parent $oobeEl -Name 'HideWirelessSetupInOOBE' -Text 'true')
    Add-DzComment -Parent $oobeEl -Text 'ProtectYourPC 3 = privacy "Express settings" off. It does not affect Windows Update.'
    [void](Add-DzElement -Parent $oobeEl -Name 'ProtectYourPC' -Text '3')

    $ua = Add-DzElement -Parent $oobeShell -Name 'UserAccounts'
    $las = Add-DzElement -Parent $ua -Name 'LocalAccounts'
    $la = Add-DzElement -Parent $las -Name 'LocalAccount'
    Add-DzActionAdd -Element $la
    Add-DzSecret -Parent $la -Plain ([string]$o.Password)
    [void](Add-DzElement -Parent $la -Name 'DisplayName' -Text $o.UserName)
    [void](Add-DzElement -Parent $la -Name 'Group' -Text 'Administrators')
    [void](Add-DzElement -Parent $la -Name 'Name' -Text $o.UserName)

    # ---- final self-check: never ship a disk-touching answer file -------------------
    foreach ($bad in $script:ForbiddenElements) {
        if ($doc.GetElementsByTagName($bad, $script:NsUnattend).Count -gt 0) {
            throw "Internal safety check failed: answer file contains <$bad>."
        }
    }

    # ---- serialise as UTF-8 (no BOM) -------------------------------------------------
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.IndentChars = '  '
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.NewLineChars = "`r`n"
    $ms = New-Object System.IO.MemoryStream
    $writer = [System.Xml.XmlWriter]::Create($ms, $settings)
    try {
        $doc.Save($writer)
    }
    finally {
        $writer.Dispose()
    }
    $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    $ms.Dispose()
    return $text
}

function Get-DzUnattendPreview {
    <# Same XML with password values masked, for showing on screen. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Xml)
    return [regex]::Replace($Xml, '(<Password>\s*<Value>)[^<]*(</Value>)', '$1(hidden in preview - base64, not encrypted)$2')
}

Export-ModuleMember -Function @(
    'Get-DzGenericKey', 'Get-DzForbiddenUnattendElement', 'ConvertTo-DzUnattendSecret',
    'Test-DzComputerName', 'Test-DzUserName', 'Test-DzProductKey', 'Test-DzLocaleName', 'Test-DzInputLocale',
    'New-DzBuildId', 'Get-DzKitSearchCommand', 'New-DzUnattendXml', 'Get-DzUnattendPreview'
)
