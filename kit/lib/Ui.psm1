#Requires -Version 5.1
<#
    DayZero - small WPF helpers shared by the USB builder and the setup wizard.
    PowerShell 5.1 + WPF only; nothing to install.
#>

Set-StrictMode -Version 2.0

$script:NsXaml = 'http://schemas.microsoft.com/winfx/2006/xaml'

function Initialize-DzWpf {
    <# Loads the WPF assemblies. Safe to call more than once. #>
    [CmdletBinding()]
    param()
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
}

function Import-DzXaml {
    <# Loads a XAML file (UTF-8) and returns the root object (Window, ResourceDictionary, ...). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "XAML file not found: $Path" }
    $reader = [System.Xml.XmlReader]::Create($Path)
    try {
        return [System.Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        $reader.Close()
    }
}

function Initialize-DzTheme {
    <#
        Puts the theme dictionary into Application.Resources so {StaticResource} lookups in
        every window resolve. Creates the WPF Application object if there is none yet
        (there can only be one per PowerShell process, so an existing one is reused).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ThemePath)
    Initialize-DzWpf
    $app = [System.Windows.Application]::Current
    if ($null -eq $app) {
        $app = New-Object System.Windows.Application
        $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    }
    $theme = Import-DzXaml -Path $ThemePath
    $app.Resources.MergedDictionaries.Clear()
    $app.Resources.MergedDictionaries.Add($theme)
    return $app
}

function Get-DzNamedElement {
    <#
        Returns a hashtable of every element with an x:Name in the XAML file, looked up on
        the loaded root. Lets scripts write $ui.WriteButton instead of FindName calls.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][object]$Root,
        [Parameter(Mandatory = $true)][string]$XamlPath
    )
    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($XamlPath)
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('x', $script:NsXaml)
    $map = @{}
    foreach ($node in @($xml.SelectNodes('//*[@x:Name]', $ns))) {
        $name = $node.GetAttribute('Name', $script:NsXaml)
        $element = $Root.FindName($name)
        if ($null -ne $element) { $map[$name] = $element }
    }
    return $map
}

function Show-DzMessage {
    <# Simple message box. Kind: Info, Warning, Error, Question. Returns 'Yes'/'No'/'OK'. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Title = 'DayZero',
        [ValidateSet('Info', 'Warning', 'Error', 'Question')][string]$Kind = 'Info',
        [object]$Owner = $null
    )
    Initialize-DzWpf
    $buttons = [System.Windows.MessageBoxButton]::OK
    $icon = [System.Windows.MessageBoxImage]::Information
    switch ($Kind) {
        'Warning' { $icon = [System.Windows.MessageBoxImage]::Warning }
        'Error' { $icon = [System.Windows.MessageBoxImage]::Error }
        'Question' { $icon = [System.Windows.MessageBoxImage]::Question; $buttons = [System.Windows.MessageBoxButton]::YesNo }
    }
    if ($null -ne $Owner) {
        $r = [System.Windows.MessageBox]::Show($Owner, $Text, $Title, $buttons, $icon)
    }
    else {
        $r = [System.Windows.MessageBox]::Show($Text, $Title, $buttons, $icon)
    }
    return [string]$r
}

function Invoke-DzUiRefresh {
    <# Lets WPF repaint (e.g. a status line) before a blocking operation starts. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Element)
    $Element.Dispatcher.Invoke([System.Action] {}, [System.Windows.Threading.DispatcherPriority]::Render)
}

Export-ModuleMember -Function @('Initialize-DzWpf', 'Import-DzXaml', 'Initialize-DzTheme', 'Get-DzNamedElement', 'Show-DzMessage', 'Invoke-DzUiRefresh')
