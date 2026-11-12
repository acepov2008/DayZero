#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Repository-wide static checks. They catch the mistakes that would otherwise only show
# up on a real Windows PC: encoding problems on PowerShell 5.1, broken batch files,
# XAML that references missing controls or theme resources, and 5.1-incompatible code.

BeforeDiscovery {
    $repo = Split-Path -Parent $PSScriptRoot
    $script:PsFiles = @(Get-ChildItem -Path $repo -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|TestResults)[\\/]' } |
            ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($repo.Length + 1) } })
    $script:CmdFiles = @(Get-ChildItem -Path $repo -Recurse -File -Include '*.cmd', '*.bat' |
            ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($repo.Length + 1) } })
    $script:XamlFiles = @(Get-ChildItem -Path $repo -Recurse -File -Filter '*.xaml' |
            ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($repo.Length + 1) } })
    $script:JsonFiles = @(Get-ChildItem -Path $repo -Recurse -File -Filter '*.json' |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|TestResults)[\\/]' } |
            ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($repo.Length + 1) } })
    # Script -> the XAML files whose x:Name elements it uses through $ui / $names.
    $script:ScriptXamlPairs = @(
        @{ Script = 'builder/Builder.ps1'; Xaml = @('builder/Builder.xaml', 'builder/PreviewWindow.xaml') },
        @{ Script = 'kit/DayZero.ps1'; Xaml = @('kit/ui/Wizard.xaml') }
    )
}

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    function Get-XamlName {
        param([string[]]$Paths)
        $names = New-Object System.Collections.Generic.HashSet[string]
        foreach ($p in $Paths) {
            $doc = New-Object System.Xml.XmlDocument
            $doc.Load((Join-Path $repo $p))
            foreach ($n in @($doc.SelectNodes('//*'))) {
                $v = $n.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
                if ($v) { [void]$names.Add($v) }
            }
        }
        return , $names
    }
    function Get-ThemeKey {
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load((Join-Path $repo 'kit/ui/Theme.xaml'))
        $keys = New-Object System.Collections.Generic.HashSet[string]
        foreach ($n in @($doc.SelectNodes('//*'))) {
            $v = $n.GetAttribute('Key', 'http://schemas.microsoft.com/winfx/2006/xaml')
            if ($v) { [void]$keys.Add($v) }
        }
        return , $keys
    }
}

Describe 'PowerShell files run on Windows PowerShell 5.1' {
    It '<Name> is plain ASCII (5.1 misreads UTF-8 without a BOM)' -ForEach $script:PsFiles {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
    It '<Name> has no "$name?" inside strings (PowerShell reads that as a variable called name?)' -ForEach $script:PsFiles {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $bad = @($tokens | Where-Object { $_.Kind -eq 'StringExpandable' -or $_.Kind -eq 'HereStringExpandable' } |
                ForEach-Object { $_.NestedTokens } | Where-Object { $_ -and $_.Kind -eq 'Variable' -and $_.Text -match '\?$' -and $_.Text -ne '$?' })
        @($bad).Count | Should -Be 0 -Because (($bad | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Text)" }) -join ', ')
    }
    It '<Name> parses without syntax errors' -ForEach $script:PsFiles {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0 -Because (@($errors) -join '; ')
    }
}

Describe 'PSScriptAnalyzer (PowerShell 5.1 compatibility profile)' {
    It 'reports no warnings or errors' -Skip:(-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        $settings = Join-Path $repo 'tools/PSScriptAnalyzerSettings.psd1'
        # tests\ is left out: Pester's own commands are not part of the 5.1 profile.
        $results = @(foreach ($dir in 'builder', 'kit', 'tools') {
                Invoke-ScriptAnalyzer -Path (Join-Path $repo $dir) -Recurse -Settings $settings
            })
        $report = ($results | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName, $_.Line, $_.RuleName, $_.Message }) -join [Environment]::NewLine
        $results.Count | Should -Be 0 -Because $report
    }
}

Describe 'Batch files' {
    It '<Name> uses CRLF line endings only' -ForEach $script:CmdFiles {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 10) { ($i -gt 0 -and $bytes[$i - 1] -eq 13) | Should -BeTrue -Because "byte $i is a bare LF" }
        }
    }
    It '<Name> is plain ASCII' -ForEach $script:CmdFiles {
        @([System.IO.File]::ReadAllBytes($Path) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
    It 'git stores <Name> byte-for-byte (text attribute unset, so CRLF survives)' -ForEach $script:CmdFiles -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        # Checks the attribute git actually applies, so a later "* text=auto" line cannot silently win.
        $attr = & git -C $repo check-attr text -- $Name 2>$null
        $attr | Should -Match ': text: unset$'
    }
}

Describe 'XAML' {
    It '<Name> is well-formed XML' -ForEach $script:XamlFiles {
        { $d = New-Object System.Xml.XmlDocument; $d.Load($Path) } | Should -Not -Throw
    }
    It '<Name> has no x:Class or event attributes (PowerShell wires events in code)' -ForEach $script:XamlFiles {
        $text = Get-Content -Raw -LiteralPath $Path
        $text | Should -Not -Match 'x:Class='
        $text | Should -Not -Match '\s(Click|Checked|Unchecked|Loaded|SelectionChanged|TextChanged|KeyDown|PreviewKeyDown|MouseDown)="'
    }
    It '<Name> only uses theme resources that exist' -ForEach $script:XamlFiles {
        $keys = Get-ThemeKey
        $text = Get-Content -Raw -LiteralPath $Path
        # Keys defined in the file itself (e.g. Window.Resources) count too.
        foreach ($m in [regex]::Matches($text, 'x:Key="([^"]+)"')) { [void]$keys.Add($m.Groups[1].Value) }
        $used = [regex]::Matches($text, '\{(?:Static|Dynamic)Resource\s+([A-Za-z][A-Za-z0-9]*)\}') | ForEach-Object { $_.Groups[1].Value }
        foreach ($k in $used) { $keys.Contains($k) | Should -BeTrue -Because "resource '$k' is used in $Name" }
    }
    It '<Name>: every TargetName and BeginStoryboardName points at an x:Name in the same file' -ForEach $script:XamlFiles {
        $text = Get-Content -Raw -LiteralPath $Path
        $names = @([regex]::Matches($text, 'x:Name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        foreach ($m in [regex]::Matches($text, '(?:Storyboard\.TargetName|TargetName|BeginStoryboardName)="([^"]+)"')) {
            $names | Should -Contain $m.Groups[1].Value -Because "$Name refers to '$($m.Groups[1].Value)'"
        }
    }
    It '<Name> starts no animation from ControlTemplate.Triggers EventTriggers (they fire before hidden templates exist)' -ForEach $script:XamlFiles {
        # Found on real Windows: a Loaded EventTrigger in ControlTemplate.Triggers looked up its
        # TargetName ("Shine") before the template of a hidden ProgressBar existed and crashed
        # ShowDialog. Put such EventTriggers on the animated element itself instead.
        $text = Get-Content -Raw -LiteralPath $Path
        foreach ($block in [regex]::Matches($text, '(?s)<ControlTemplate\.Triggers>.*?</ControlTemplate\.Triggers>')) {
            $block.Value | Should -Not -Match '<EventTrigger' -Because "$Name has an EventTrigger in ControlTemplate.Triggers"
        }
        foreach ($block in [regex]::Matches($text, '(?s)<DataTemplate\.Triggers>.*?</DataTemplate\.Triggers>')) {
            $block.Value | Should -Not -Match '<EventTrigger' -Because "$Name has an EventTrigger in DataTemplate.Triggers"
        }
    }
    It 'Theme.xaml defines every resource before it is used (WPF StaticResource rule)' {
        $text = Get-Content -Raw -LiteralPath (Join-Path $repo 'kit/ui/Theme.xaml')
        $text = [regex]::Replace($text, '(?s)<!--.*?-->', { param($m) ' ' * $m.Value.Length })   # comments are not uses
        $defined = @{}
        foreach ($m in [regex]::Matches($text, 'x:Key="([^"]+)"')) { if (-not $defined.ContainsKey($m.Groups[1].Value)) { $defined[$m.Groups[1].Value] = $m.Index } }
        foreach ($m in [regex]::Matches($text, '\{StaticResource\s+([A-Za-z][A-Za-z0-9]*)\}')) {
            $key = $m.Groups[1].Value
            $defined.ContainsKey($key) | Should -BeTrue -Because "'$key' is used in Theme.xaml"
            $defined[$key] | Should -BeLessThan $m.Index -Because "'$key' must be defined above its first use"
        }
    }
    It 'scripts only use theme resources that exist' {
        $keys = Get-ThemeKey
        foreach ($f in @(Get-ChildItem -Path (Join-Path $repo 'builder'), (Join-Path $repo 'kit') -Recurse -Include '*.ps1', '*.psm1')) {
            $text = Get-Content -Raw -LiteralPath $f.FullName
            foreach ($m in [regex]::Matches($text, "'(Dz[A-Z][A-Za-z]+)'")) {
                $keys.Contains($m.Groups[1].Value) | Should -BeTrue -Because "'$($m.Groups[1].Value)' is used in $($f.Name)"
            }
        }
    }
    It '<Script> only uses controls that exist in its XAML' -ForEach $script:ScriptXamlPairs {
        $names = Get-XamlName -Paths $Xaml
        $text = Get-Content -Raw -LiteralPath (Join-Path $repo $Script)
        $ignore = @('ContainsKey', 'Keys', 'Values', 'Count', 'Add', 'Remove', 'Clone')
        $used = [regex]::Matches($text, '\$(?:script:)?(?:ui|names)\.([A-Za-z][A-Za-z0-9]*)') |
            ForEach-Object { $_.Groups[1].Value } | Where-Object { $ignore -notcontains $_ } | Sort-Object -Unique
        @($used).Count | Should -BeGreaterThan 0
        foreach ($u in $used) { $names.Contains($u) | Should -BeTrue -Because "$Script uses `$ui.$u" }
    }
}

if ($script:JsonFiles.Count -gt 0) {
    Describe 'JSON' {
        It '<Name> parses' -ForEach $script:JsonFiles {
            { [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json } | Should -Not -Throw
        }
    }
}
