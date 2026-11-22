#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The builder's language, region and time-zone drop-downs follow the builder's language button,
# not the language Windows itself is in. The functions are taken from builder\Builder.ps1.

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Repo 'kit/lib/Lang.psm1') -Force
    [void](Import-DzLanguage -KitRoot (Join-Path $script:Repo 'kit'))
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Repo 'builder/Builder.ps1'), [ref]$null, [ref]$null)
    foreach ($name in 'Get-CultureLabel', 'Get-CultureItem', 'Get-RegionItemList', 'Get-TimeZoneLabel', 'Get-TimeZoneItemList', 'Update-ListLanguage', 'Select-ComboValue', 'New-ListItem') {
        $f = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        . ([scriptblock]::Create($f.Extent.Text))
    }
    $script:NewCombo = { param($items, $picked) $c = [pscustomobject]@{ ItemsSource = $items; SelectedItem = $null; SelectedValue = $picked }; $c }
}

Describe 'Language and region lists' {
    AfterEach { [void](Set-DzLanguage -Code 'en') }
    It 'uses English names in English, whatever language Windows is in' {
        [void](Set-DzLanguage -Code 'en')
        (Get-CultureItem -Name 'ru-RU').Label | Should -Be 'Russian (Russia)  (ru-RU)'
        (Get-CultureItem -Name 'de-DE').Label | Should -Be 'German (Germany)  (de-DE)'
        @(Get-RegionItemList | Where-Object { $_.Value -eq 'fr-FR' })[0].Label | Should -Be 'French (France)  (fr-FR)'
    }
    It 'uses the names Windows gives in Russian, and always shows the code' {
        [void](Set-DzLanguage -Code 'ru')
        $c = [System.Globalization.CultureInfo]::GetCultureInfo('ru-RU')
        (Get-CultureItem -Name 'ru-RU').Label | Should -Be ('{0}  (ru-RU)' -f $c.DisplayName)
    }
    It 'renames the entries after the language button, keeps the same ones and the pick' {
        [void](Set-DzLanguage -Code 'ru')
        $items = @((Get-CultureItem -Name 'en-US'), (Get-CultureItem -Name 'ru-RU'), [pscustomobject]@{ Label = "This PC's keyboard (x)"; Value = 'xx-custom' })
        $combo = & $script:NewCombo $items 'ru-RU'
        [void](Set-DzLanguage -Code 'en')
        Update-ListLanguage -Combo $combo -Kind culture
        @($combo.ItemsSource).Count | Should -Be 3
        @($combo.ItemsSource)[1].Label | Should -Be 'Russian (Russia)  (ru-RU)'
        @($combo.ItemsSource)[2].Label | Should -Be "This PC's keyboard (x)"
        $combo.SelectedItem.Value | Should -Be 'ru-RU'
    }
    It 'keeps every time zone and the picked one' {
        $zones = @(Get-TimeZoneItemList)
        if ($zones.Count -eq 0) { Set-ItResult -Skipped -Because 'no time zones on this machine'; return }
        $pick = $zones[0].Value
        $combo = & $script:NewCombo $zones $pick
        Update-ListLanguage -Combo $combo -Kind timezone
        @($combo.ItemsSource).Count | Should -Be $zones.Count
        $combo.SelectedItem.Value | Should -Be $pick
    }
}
