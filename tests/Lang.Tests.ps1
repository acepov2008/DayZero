#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for kit\lib\Lang.psm1 and the language packs in kit\lang: the translation rules, and
# that the Russian pack covers every text the two windows, the configs and the scripts show.

BeforeDiscovery {
    $repo = Split-Path -Parent $PSScriptRoot
    # Names and brands that are the same in every language.
    $same = @('DAYZERO', 'DayZero', 'Windows 11', 'Windows 10', 'Language: English')
    $need = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
    $add = {
        param($text, $source)
        if ($null -eq $text) { return }
        $t = [string]$text
        if ($t -notmatch '[A-Za-z]{2}' -or $same -ccontains $t -or $need.ContainsKey($t)) { return }
        $need[$t] = $source
    }
    foreach ($f in @(Get-ChildItem -Path (Join-Path $repo 'builder'), (Join-Path $repo 'kit/ui') -Filter '*.xaml' -File | Where-Object { $_.Name -ne 'Theme.xaml' })) {
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load($f.FullName)
        foreach ($n in @($doc.SelectNodes('//*'))) {
            foreach ($a in @('Text', 'Content', 'ToolTip', 'Header', 'Title')) {
                $v = $n.GetAttribute($a)
                if ($v -and -not $v.StartsWith('{')) { & $add $v $f.Name }
            }
        }
    }
    $json = { param($name) Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repo "kit/config/$name.json") | ConvertFrom-Json }
    foreach ($m in (& $json 'modes').modes) {
        foreach ($k in 'title', 'tagline', 'description') { & $add $m.$k 'modes.json' }
        foreach ($h in @($m.highlights)) { & $add $h 'modes.json' }
    }
    $apps = & $json 'apps'
    foreach ($c in $apps.categories) { & $add $c.title 'apps.json' }
    foreach ($a in $apps.apps) { if ($a.PSObject.Properties['description']) { & $add $a.description 'apps.json' } }
    foreach ($t in (& $json 'tweaks').tweaks) { foreach ($k in 'title', 'what', 'warning', 'laptopWarning') { if ($t.PSObject.Properties[$k]) { & $add $t.$k 'tweaks.json' } } }
    $debloat = & $json 'debloat'
    foreach ($l in $debloat.levels) { foreach ($k in 'title', 'tagline', 'description') { & $add $l.$k 'debloat.json' } }
    foreach ($r in $debloat.optionalRemovals) { foreach ($k in 'title', 'what', 'warning') { if ($r.PSObject.Properties[$k]) { & $add $r.$k 'debloat.json' } } }
    $drivers = & $json 'drivers'
    foreach ($k in 'gpuApps', 'oemTools') { foreach ($x in @($drivers.$k)) { if ($x.PSObject.Properties['what']) { & $add $x.what 'drivers.json' } } }
    foreach ($f in 'builder/Builder.ps1', 'kit/DayZero.ps1', 'kit/lib/Ui.psm1') {
        $code = Get-Content -Raw -LiteralPath (Join-Path $repo $f)
        foreach ($m in [regex]::Matches($code, "(?:Get-DzText \`$?\(?|New-ListItem -Label |Show-DzMessage -Text |Set-BuilderStatus -Text )'((?:[^']|'')+)'")) { & $add ($m.Groups[1].Value -replace "''", "'") $f }
        foreach ($m in [regex]::Matches($code, '(?:Get-DzText \$?\(?|New-ListItem -Label )"([^"$`]+)"')) { & $add $m.Groups[1].Value $f }
    }
    $script:NeededTexts = @($need.GetEnumerator() | ForEach-Object { @{ Text = $_.Key; Source = $_.Value; Short = $(if ($_.Key.Length -gt 60) { $_.Key.Substring(0, 60) + '...' } else { $_.Key }) -replace "`n", ' ' } })
    $script:GuiScripts = @('builder/Builder.ps1', 'kit/DayZero.ps1') | ForEach-Object { @{ Script = $_ } }
}

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Repo 'kit/lib/Lang.psm1') -Force
    [void](Import-DzLanguage -KitRoot (Join-Path $script:Repo 'kit'))
    $script:Bullet = [string][char]0x2022
    $script:RuFile = Join-Path $script:Repo 'kit/lang/ru.json'
    $script:Ru = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:RuFile | ConvertFrom-Json
}

Describe 'Language choice' {
    AfterEach { [void](Set-DzLanguage -Code 'en') }
    It 'offers English and Russian, each named in its own language' {
        $list = @(Get-DzLanguageList)
        ($list | ForEach-Object { $_.Code }) | Should -Be @('en', 'ru')
        $list[0].Name | Should -Be 'English'
        $list[1].Name | Should -Match '^[\u0400-\u04FF]+$'
    }
    It 'falls back to English for an unknown language' {
        Set-DzLanguage -Code 'xx' | Should -Be 'en'
        Set-DzLanguage -Code 'RU' | Should -Be 'ru'
        Set-DzLanguage -Code '' | Should -Be 'en'
    }
    It 'starts in the saved language, else the language Windows is shown in, else English' {
        Get-DzDefaultLanguage -Preferred 'ru' -UiCulture 'en-US' | Should -Be 'ru'
        Get-DzDefaultLanguage -Preferred 'en' -UiCulture 'ru-RU' | Should -Be 'en'
        Get-DzDefaultLanguage -Preferred '' -UiCulture 'ru-RU' | Should -Be 'ru'
        Get-DzDefaultLanguage -Preferred '' -UiCulture 'de-DE' | Should -Be 'en'
        Get-DzDefaultLanguage -Preferred 'zz' -UiCulture 'en-GB' | Should -Be 'en'
    }
    It 'remembers the choice in a small file' {
        $f = Join-Path $TestDrive 'sub/language.txt'
        Read-DzLanguageChoice -Path $f | Should -Be ''
        Save-DzLanguageChoice -Path $f -Code 'ru'
        Read-DzLanguageChoice -Path $f | Should -Be 'ru'
        Set-Content -LiteralPath $f -Value '..\evil'
        Read-DzLanguageChoice -Path $f | Should -Be ''
    }
}

Describe 'Get-DzText' {
    AfterEach { [void](Set-DzLanguage -Code 'en') }
    It 'returns the text unchanged in English, and passes non-text through' {
        Get-DzText 'Ready.' | Should -Be 'Ready.'
        Get-DzText $null | Should -BeNullOrEmpty
        Get-DzText 42 | Should -Be 42
        [void](Set-DzLanguage -Code 'ru')
        Get-DzText 42 | Should -Be 42
        Get-DzText '' | Should -Be ''
    }
    It 'translates a known text and leaves an unknown one alone' {
        [void](Set-DzLanguage -Code 'ru')
        Get-DzText 'Ready.' | Should -Not -Be 'Ready.'
        Get-DzText 'Ready.' | Should -Match '[\u0400-\u04FF]'
        Get-DzText 'C:\Users\Someone\file.iso' | Should -Be 'C:\Users\Someone\file.iso'
        Get-DzText 'Google Chrome' | Should -Be 'Google Chrome'
    }
    It 'keeps texts apart that differ only in upper and lower case' {
        [void](Set-DzLanguage -Code 'ru')
        (Get-DzText '_Close') | Should -Not -BeExactly (Get-DzText '_CLOSE')
    }
    It 'fills a template from a finished line and keeps the values' {
        [void](Set-DzLanguage -Code 'ru')
        $t = Get-DzText 'Copying Windows to the USB stick: 3.1 of 6.2 GB, 9 MB/s (50%)'
        $t | Should -Match '[\u0400-\u04FF]'
        $t | Should -Match '3\.1' ; $t | Should -Match '6\.2' ; $t | Should -Match '\(50%\)'
        $t | Should -Not -Match 'Copying|\{0\}'
    }
    It 'translates the format string itself, placeholders intact' {
        [void](Set-DzLanguage -Code 'ru')
        Get-DzText 'WHAT {0} DOES' | Should -Match '\{0\}'
        Get-DzText 'WHAT {0} DOES' | Should -Not -Match 'WHAT'
    }
    It 'translates the values inside a template, lists and notes included' {
        [void](Set-DzLanguage -Code 'ru')
        $line = Get-DzText "$($script:Bullet) Tweaks: Turn on Game Mode; High-performance power plan (off on laptops)"
        $line | Should -Match ('^' + [regex]::Escape($script:Bullet) + ' ')
        $line | Should -Not -Match '[A-Za-z]{4,}'
        Get-DzText 'Standard - Recommended' | Should -Not -Match 'Standard|Recommended'
        Get-DzText 'Account: test (temporary password)' | Should -Match 'test'
        Get-DzText 'Account: test (temporary password)' | Should -Not -Match 'temporary'
        Get-DzText 'Default mode: gaming, clean-up level: standard (DRY RUN)' | Should -Not -Match 'gaming|standard|DRY'
    }
    It 'translates every line of a message and keeps bullets, indents and blank lines' {
        [void](Set-DzLanguage -Code 'ru')
        $out = Get-DzText "Please fix these first:`n`n - Enter a password.`n - Pick a time zone."
        $lines = $out -split "`n"
        $lines.Count | Should -Be 4
        $lines[1] | Should -Be ''
        $lines[2] | Should -Match '^ - [\u0400-\u04FF]'
        $out | Should -Not -Match 'password|Pick'
    }
    It 'translates step titles built from an app name' {
        [void](Set-DzLanguage -Code 'ru')
        Get-DzText 'Install Google Chrome' | Should -Match 'Google Chrome$'
        Get-DzText 'Install Google Chrome' | Should -Not -Match 'Install'
        Get-DzText 'Remove preinstalled apps (Standard clean-up)' | Should -Not -Match '[A-Za-z]{4,}'
    }
    It 'keeps the progress bar working: status lines are matched in English before they are translated' {
        [void](Set-DzLanguage -Code 'ru')
        Import-Module (Join-Path $script:Repo 'builder/lib/WinMedia.psm1') -Force
        $english = 'Unpacking Windows 11 Pro (4 of 4; this is the slow part) (35.0%)'
        Get-DzBuildProgress -Text $english | Should -BeGreaterThan 42
        Get-DzText $english | Should -Not -Match 'Unpacking'
        $setter = [regex]::Match((Get-Content -Raw (Join-Path $script:Repo 'builder/Builder.ps1')), '(?s)function Set-BuilderStatus \{.*?\n\}').Value
        $setter | Should -Match 'Get-DzBuildProgress -Text \$Text'
    }
}

Describe 'Switching the language of a window that is already open' {
    BeforeAll { Import-Module (Join-Path $script:Repo 'kit/lib/Ui.psm1') -Force }
    AfterEach { [void](Set-DzLanguage -Code 'en') }
    It 'translates from the remembered English text each time, so switching back and forth works' {
        $button = New-Object object
        [void](Set-DzLanguage -Code 'ru')
        $ru = Get-DzTranslatedValue -Element $button -Name 'Content' -Current '_Close'
        $ru | Should -Match '[\u0400-\u04FF]'
        [void](Set-DzLanguage -Code 'en')
        Get-DzTranslatedValue -Element $button -Name 'Content' -Current $ru | Should -Be '_Close'
        [void](Set-DzLanguage -Code 'ru')
        Get-DzTranslatedValue -Element $button -Name 'Content' -Current '_Close' | Should -Be $ru
    }
    It 'takes a text the code has put there since as the new original' {
        $label = New-Object object
        [void](Set-DzLanguage -Code 'ru')
        [void](Get-DzTranslatedValue -Element $label -Name 'Text' -Current 'Ready.')
        $second = Get-DzTranslatedValue -Element $label -Name 'Text' -Current 'Cancelled.'
        $second | Should -Be (Get-DzText 'Cancelled.')
        [void](Set-DzLanguage -Code 'en')
        Get-DzTranslatedValue -Element $label -Name 'Text' -Current $second | Should -Be 'Cancelled.'
    }
    It 'keeps separate properties and separate elements apart, and ignores empty text' {
        $a = New-Object object
        $b = New-Object object
        [void](Set-DzLanguage -Code 'ru')
        $t1 = Get-DzTranslatedValue -Element $a -Name 'Content' -Current 'Refresh'
        $t2 = Get-DzTranslatedValue -Element $a -Name 'ToolTip' -Current 'Look for USB sticks again'
        [void](Get-DzTranslatedValue -Element $b -Name 'Content' -Current 'Log')
        [void](Set-DzLanguage -Code 'en')
        Get-DzTranslatedValue -Element $a -Name 'Content' -Current $t1 | Should -Be 'Refresh'
        Get-DzTranslatedValue -Element $a -Name 'ToolTip' -Current $t2 | Should -Be 'Look for USB sticks again'
        Get-DzTranslatedValue -Element $b -Name 'Content' -Current '' | Should -Be ''
    }
}

Describe 'Russian language pack' {
    It 'is valid JSON with code, name and pairs of text' {
        $script:Ru.code | Should -Be 'ru'
        $script:Ru.name | Should -Not -BeNullOrEmpty
        @($script:Ru.strings).Count | Should -BeGreaterThan 400
        foreach ($p in @($script:Ru.strings)) { @($p).Count | Should -Be 2 }
    }
    It 'has no English text twice' {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($p in @($script:Ru.strings)) { $seen.Add([string]$p[0]) | Should -BeTrue -Because "'$($p[0])' is listed twice" }
    }
    It 'keeps every placeholder, and adds none' {
        foreach ($p in @($script:Ru.strings)) {
            $en = @([regex]::Matches([string]$p[0], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
            $ru = @([regex]::Matches([string]$p[1], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
            ($ru -join ',') | Should -Be ($en -join ',') -Because "placeholders of '$($p[0])'"
        }
    }
    It 'keeps file names, commands and registry values that appear in the English text' {
        foreach ($p in @($script:Ru.strings)) {
            foreach ($m in [regex]::Matches([string]$p[0], 'autounattend\.xml|DayZero\.cmd -Undo|[A-Za-z]+Enabled = \d|config\\[a-z]+\.json|install2?\.(?:swm|wim|esd)|bootx64\.efi')) {
                ([string]$p[1]).Contains($m.Value) | Should -BeTrue -Because "'$($m.Value)' must stay in the translation of '$($p[0])'"
            }
        }
    }
    It 'translates: <Short>  (<Source>)' -ForEach $script:NeededTexts {
        Test-DzTextKnown -Text $Text -Code 'ru' | Should -BeTrue
    }
}

Describe 'Scripts show their texts through the language module' {
    It '<Script> assigns no fixed English text to a control directly' -ForEach $script:GuiScripts {
        $code = Get-Content -Raw -LiteralPath (Join-Path $script:Repo $Script)
        $direct = [regex]::Matches($code, '(?m)^\s*(?:\$script:ui|\$ui)\.(\w+)\.(?:Text|Content) = [''"][^''"]*[A-Za-z]{3}') |
            Where-Object { @('FolderText', 'IsoPathText', 'LogText') -notcontains $_.Groups[1].Value }
        @($direct | ForEach-Object { $_.Value.Trim() }) | Should -BeNullOrEmpty
    }
    It 'the wizard loads the language before it builds the window, and logs stay English' {
        $code = Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'kit/DayZero.ps1')
        $code.IndexOf('Import-DzLanguage') | Should -BeLessThan $code.IndexOf('Import-DzXaml -Path $xamlPath')
        $code | Should -Not -Match 'Write-DzLog[^\r\n]*Get-DzText'
        (Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'kit/lib/Modules.ps1')) | Should -Match "'Lang\.psm1'"
    }
    It 'the builder hands its language to the wizard in settings.json' {
        (Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'builder/Builder.ps1')) | Should -Match 'appLanguage\s+= \(Get-DzLanguage\)'
        (Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'kit/DayZero.ps1')) | Should -Match "Properties\['appLanguage'\]"
    }
}
