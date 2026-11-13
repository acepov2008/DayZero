#Requires -Version 5.1
<#
    DayZero - small WPF helpers shared by the USB builder and the setup wizard.
    PowerShell 5.1 + WPF only; nothing to install.
#>

Set-StrictMode -Version 2.0

$script:NsXaml = 'http://schemas.microsoft.com/winfx/2006/xaml'
# Element -> @{ property = @{ O = English text; T = what was shown } }, so the language can be switched back and forth.
$script:Translated = $null

function Get-DzUiText {
    <# Get-DzText when the language module is loaded (it always is in the GUIs); the text itself otherwise. #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][object]$Text)
    if (Get-Command -Name 'Get-DzText' -ErrorAction SilentlyContinue) { return (Get-DzText $Text) }
    return $Text
}

function Get-DzTranslatedValue {
    <#
        The text to show for one property of one element. Remembers the English original: when
        the property still holds what was shown last time, it is translated again from that
        original (language switched); when the code has put something new there, that is the
        new original.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][object]$Element, [Parameter(Mandatory = $true)][string]$Name, [AllowNull()][AllowEmptyString()][string]$Current)
    if ([string]::IsNullOrEmpty($Current)) { return $Current }
    if ($null -eq $script:Translated) { $script:Translated = New-Object 'System.Runtime.CompilerServices.ConditionalWeakTable[object,object]' }
    $record = $null
    if (-not $script:Translated.TryGetValue($Element, [ref]$record)) {
        $record = @{}
        $script:Translated.Add($Element, $record)
    }
    $previous = $record[$Name]
    $original = if ($previous -and $Current -ceq [string]$previous.T) { [string]$previous.O } else { $Current }
    $shown = [string](Get-DzUiText $original)
    $record[$Name] = @{ O = $original; T = $shown }
    return $shown
}

function Update-DzTranslation {
    <#
        Puts every fixed text of a window (and everything inside it) into the current language:
        window title, text blocks and their runs, button / check box / radio captions, expander
        headers and tooltips. Text boxes and list items are left alone. Call it after loading
        the XAML and again after the language changes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Root)
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $e = $stack.Pop()
        # One element that cannot be translated must never stop the window from opening.
        try { Update-DzTranslatedElement -Element $e -Stack $stack } catch { Write-Verbose ('Translation skipped an element: ' + $_.Exception.Message) }
    }
}

function Update-DzTranslatedElement {
    <# Translates one element and pushes its children. Used by Update-DzTranslation. #>
    [CmdletBinding()]
    param([AllowNull()][object]$Element, [Parameter(Mandatory = $true)][object]$Stack)
    $e = $Element
    $stack = $Stack
    foreach ($once in 1) {
        if ($e -isnot [System.Windows.DependencyObject]) { continue }
        if ($e -is [System.Windows.Controls.Primitives.TextBoxBase] -or $e -is [System.Windows.Controls.PasswordBox]) { continue }
        if ($e -is [System.Windows.Window] -and $e.Title) { $e.Title = Get-DzTranslatedValue -Element $e -Name 'Title' -Current $e.Title }
        if ($e -is [System.Windows.FrameworkElement] -and $e.ToolTip -is [string]) { $e.ToolTip = Get-DzTranslatedValue -Element $e -Name 'ToolTip' -Current $e.ToolTip }
        if ($e -is [System.Windows.Controls.TextBlock]) {
            $runs = @($e.Inlines | Where-Object { $_ -is [System.Windows.Documents.Run] })
            if ($e.Inlines.Count -le 1) { if ($e.Text) { $e.Text = Get-DzTranslatedValue -Element $e -Name 'Text' -Current $e.Text } }
            else { foreach ($r in $runs) { if ($r.Text -and $r.Text.Trim()) { $r.Text = Get-DzTranslatedValue -Element $r -Name 'Text' -Current $r.Text } } }
            continue
        }
        if ($e -is [System.Windows.Controls.HeaderedContentControl] -and $e.Header -is [string]) { $e.Header = Get-DzTranslatedValue -Element $e -Name 'Header' -Current $e.Header }
        if ($e -is [System.Windows.Controls.ContentControl] -and $e.Content -is [string]) { $e.Content = Get-DzTranslatedValue -Element $e -Name 'Content' -Current $e.Content }
        if ($e -is [System.Windows.Controls.ItemsControl]) { continue }
        # The cast picks the overload; without it PowerShell may find two that fit.
        $children = if ($e -is [System.Windows.FrameworkElement]) { [System.Windows.LogicalTreeHelper]::GetChildren([System.Windows.FrameworkElement]$e) }
        elseif ($e -is [System.Windows.FrameworkContentElement]) { [System.Windows.LogicalTreeHelper]::GetChildren([System.Windows.FrameworkContentElement]$e) }
        else { [System.Windows.LogicalTreeHelper]::GetChildren([System.Windows.DependencyObject]$e) }
        foreach ($child in $children) { $stack.Push($child) }
    }
}

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
    $Text = [string](Get-DzUiText $Text)
    $Title = [string](Get-DzUiText $Title)
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

function Get-DzResource {
    <# A theme resource (brush, style, font) from Application.Resources. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Key)
    return [System.Windows.Application]::Current.FindResource($Key)
}

function New-DzChoiceControl {
    <#
        One review item as a CheckBox, or a RadioButton when it belongs to a pick-one group,
        showing its title, description and (yellow) warning. Tag = the item.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Item, [string]$RadioGroup = 'dz')
    $exclusive = [bool]($Item.PSObject.Properties['Exclusive'] -and $Item.Exclusive)
    if ($exclusive) {
        $c = New-Object System.Windows.Controls.RadioButton
        $c.GroupName = $RadioGroup
    }
    else { $c = New-Object System.Windows.Controls.CheckBox }
    $c.IsChecked = [bool]$Item.Checked
    $c.Tag = $Item
    $c.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
    $title = if ($Item.PSObject.Properties['Title'] -and $Item.Title) { [string]$Item.Title } else { [string]$Item.Name }
    $panel = New-Object System.Windows.Controls.StackPanel
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = [string](Get-DzUiText $title)
    $t.FontWeight = [System.Windows.FontWeights]::SemiBold
    $t.TextWrapping = [System.Windows.TextWrapping]::Wrap
    [void]$panel.Children.Add($t)
    if ($Item.PSObject.Properties['Description'] -and $Item.Description) {
        $d = New-Object System.Windows.Controls.TextBlock
        $d.Text = [string](Get-DzUiText ([string]$Item.Description))
        $d.FontSize = 11.5
        $d.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $d.Foreground = Get-DzResource 'DzMuted'
        [void]$panel.Children.Add($d)
    }
    if ($Item.PSObject.Properties['Warning'] -and $Item.Warning) {
        $w = New-Object System.Windows.Controls.TextBlock
        $w.Text = ([string][char]0x26A0) + ' ' + [string](Get-DzUiText ([string]$Item.Warning))
        $w.FontSize = 11.5
        $w.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $w.Foreground = Get-DzResource 'DzYellow'
        $w.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
        [void]$panel.Children.Add($w)
    }
    $c.Content = $panel
    [System.Windows.Automation.AutomationProperties]::SetName($c, $title)
    return $c
}

function Add-DzChoiceGroup {
    <#
        Adds one block per group (header + its items) to a panel, in the order the items come.
        GroupWidth makes the blocks flow in columns inside a WrapPanel. Returns the controls.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Panel,
        [AllowEmptyCollection()][object[]]$Items = @(),
        [double]$GroupWidth = 0,
        [string]$RadioPrefix = 'dz'
    )
    $controls = New-Object System.Collections.Generic.List[object]
    $order = New-Object System.Collections.Generic.List[string]
    foreach ($i in $Items) { $g = [string]$i.Group; if (-not $order.Contains($g)) { $order.Add($g) } }
    foreach ($g in $order) {
        $box = New-Object System.Windows.Controls.StackPanel
        if ($GroupWidth -gt 0) { $box.Width = $GroupWidth }
        $box.Margin = New-Object System.Windows.Thickness(0, 0, 18, 14)
        $h = New-Object System.Windows.Controls.TextBlock
        $h.Text = ([string](Get-DzUiText $g)).ToUpper()
        $h.FontSize = 11
        $h.FontWeight = [System.Windows.FontWeights]::Bold
        $h.Foreground = Get-DzResource 'DzCyan'
        [void]$box.Children.Add($h)
        foreach ($i in @($Items | Where-Object { [string]$_.Group -eq $g })) {
            $groupId = if ($i.PSObject.Properties['GroupId']) { [string]$i.GroupId } else { $g }
            $c = New-DzChoiceControl -Item $i -RadioGroup ("{0}-{1}" -f $RadioPrefix, $groupId)
            [void]$box.Children.Add($c)
            $controls.Add($c)
        }
        [void]$Panel.Children.Add($box)
    }
    return $controls.ToArray()
}

function Enable-DzLevelPreset {
    <#
        Clean-up level radios act like WinUtil's preset buttons: picking one re-ticks the
        level-owned switches (Set-DzReviewLevel decides which); everything else stays as it is.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Controls = @())
    $all = @($Controls)
    foreach ($c in $all) {
        if (-not ($c -is [System.Windows.Controls.RadioButton]) -or [string]$c.Tag.Kind -ne 'debloat') { continue }
        $c.Add_Checked({
                param($src)
                $items = @($all | ForEach-Object { $_.Tag } | Where-Object { $_.Kind -in @('debloat', 'tweak', 'removal') })
                Set-DzReviewLevel -Options $items -LevelId ([string]$src.Tag.Id)
                foreach ($x in $all) {
                    if ($x.Tag.PSObject.Properties['LevelOwned'] -and $x.Tag.LevelOwned) { $x.IsChecked = [bool]$x.Tag.Checked }
                }
            }.GetNewClosure())
    }
}

function Update-DzChoiceItem {
    <# Copies each control's ticked state back into its item (Tag). #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Controls = @())
    foreach ($c in $Controls) { $c.Tag.Checked = ($c.IsChecked -eq $true) }
}

Export-ModuleMember -Function @(
    'Get-DzUiText', 'Get-DzTranslatedValue', 'Update-DzTranslation', 'Update-DzTranslatedElement', 'Initialize-DzWpf', 'Import-DzXaml', 'Initialize-DzTheme', 'Get-DzNamedElement', 'Show-DzMessage', 'Invoke-DzUiRefresh',
    'Get-DzResource', 'New-DzChoiceControl', 'Add-DzChoiceGroup', 'Enable-DzLevelPreset', 'Update-DzChoiceItem'
)
