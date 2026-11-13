#Requires -Version 5.1
<#
    DayZero - interface language (English or a language pack from kit\lang\<code>.json).

    A language pack is a JSON file (UTF-8):
        { "code": "ru", "name": "<native name>", "strings": [ ["<English text>", "<translation>"], ... ] }

    (Pairs, not an object: English texts such as "_Close" and "_CLOSE" differ only in case,
    which PowerShell 5.1 cannot keep apart as JSON object keys.)

    The English text is exactly what the program shows. A text with {0}, {1}... is a
    template: it translates both the format string itself and any finished line that fits it
    ("Windows {0} (build {1})" matches "Windows 11 (build 26100)"), so text is translated where
    it is shown and the code that builds it stays in English. Logs are never translated.

    This module is plain ASCII like every script here; the translations live in the JSON.
#>

Set-StrictMode -Version 2.0

$script:Language = 'en'
$script:Packs = @{}

function Import-DzLanguage {
    <# Loads every kit\lang\*.json. Returns the codes that were loaded. A broken file is skipped. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$KitRoot)
    $script:Packs = @{}
    $folder = Join-Path $KitRoot 'lang'
    foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try {
            $data = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $code = ([string]$data.code).ToLowerInvariant()
            if ($code -notmatch '^[a-z]{2}$' -or $code -eq 'en') { continue }
            $exact = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
            $templates = New-Object System.Collections.Generic.List[object]
            foreach ($pair in @($data.strings)) {
                $pair = @($pair)
                if ($pair.Count -lt 2) { continue }
                $key = [string]$pair[0]
                $value = [string]$pair[1]
                if (-not $key -or -not $value) { continue }
                $exact[$key] = $value
                if ($key -match '\{\d+\}') {
                    $pattern = '^' + ([regex]::Replace([regex]::Escape($key), '\\\{(\d+)\}', '(?<g$1>.*?)')) + '$'
                    $templates.Add([pscustomobject]@{ Regex = (New-Object System.Text.RegularExpressions.Regex($pattern)); To = $value; Length = $key.Length })
                }
            }
            $script:Packs[$code] = [pscustomobject]@{
                Code      = $code
                Name      = [string]$data.name
                Exact     = $exact
                # Longest first, so the most specific template wins.
                Templates = @($templates | Sort-Object -Property Length -Descending)
            }
        }
        catch { Write-Verbose ("Language file {0} skipped: {1}" -f $file.Name, $_.Exception.Message) }
    }
    if (-not $script:Packs.ContainsKey($script:Language)) { $script:Language = 'en' }
    return @($script:Packs.Keys | Sort-Object)
}

function Get-DzLanguageList {
    <# English plus every loaded pack, as Code + Name (the name in its own language). #>
    [CmdletBinding()]
    param()
    $list = @([pscustomobject]@{ Code = 'en'; Name = 'English' })
    foreach ($code in @($script:Packs.Keys | Sort-Object)) {
        $name = $script:Packs[$code].Name
        if (-not $name) { $name = $code }
        $list += [pscustomobject]@{ Code = $code; Name = $name }
    }
    return $list
}

function Get-DzLanguage {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:Language
}

function Set-DzLanguage {
    <# Switches the interface language. An unknown code falls back to English. Returns the code in use. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Code)
    $c = ([string]$Code).ToLowerInvariant()
    $script:Language = if ($script:Packs.ContainsKey($c)) { $c } else { 'en' }
    return $script:Language
}

function Get-DzDefaultLanguage {
    <#
        The language to start in: the saved choice when it is valid, otherwise the language
        Windows itself is shown in when there is a pack for it, otherwise English.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Preferred, [string]$UiCulture = [System.Globalization.CultureInfo]::CurrentUICulture.Name)
    $p = ([string]$Preferred).Trim().ToLowerInvariant()
    if ($p -eq 'en' -or $script:Packs.ContainsKey($p)) { return $p }
    $two = ([string]$UiCulture).Split('-')[0].ToLowerInvariant()
    if ($script:Packs.ContainsKey($two)) { return $two }
    return 'en'
}

function Read-DzLanguageChoice {
    <# The language code saved in a small text file, or '' when there is none. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (Test-Path -LiteralPath $Path) {
            $text = ([System.IO.File]::ReadAllText($Path)).Trim().ToLowerInvariant()
            if ($text -match '^[a-z]{2}$') { return $text }
        }
    }
    catch { Write-Verbose 'Could not read the saved language.' }
    return ''
}

function Save-DzLanguageChoice {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][ValidatePattern('^[a-z]{2}$')][string]$Code)
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        [System.IO.File]::WriteAllText($Path, $Code, [System.Text.Encoding]::ASCII)
    }
    catch { Write-Verbose ('Could not save the language: ' + $_.Exception.Message) }
}

function ConvertTo-DzTranslatedLine {
    <#
        One line: exact match, then the same without its bullet/indent, then the templates.
        The values that fill a template are translated the same way (a mode name inside a
        title, a list of tweak names separated by "; "), at most three levels deep.
    #>
    param([string]$Line, [object]$Pack, [int]$Depth = 0)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $Line }
    $found = $null
    if ($Pack.Exact.TryGetValue($Line, [ref]$found)) { return $found }
    $m = [regex]::Match($Line, '^(\s*(?:[\u2022\u26A0\u2713\u2715\-]\s+)?)(.*?)(\s*)$')
    $prefix = $m.Groups[1].Value
    $core = $m.Groups[2].Value
    $suffix = $m.Groups[3].Value
    if (-not $core) { return $Line }
    if ($Pack.Exact.TryGetValue($core, [ref]$found)) { return ($prefix + $found + $suffix) }
    if ($Depth -gt 0 -and $core.IndexOf('; ') -gt 0) {
        $items = foreach ($item in ($core -split '; ')) { ConvertTo-DzTranslatedLine -Line $item -Pack $Pack -Depth ($Depth + 1) }
        return ($prefix + ($items -join '; ') + $suffix)
    }
    if ($Depth -gt 0) {
        # "name (note)": a value with a known note behind it, e.g. "test (temporary password)".
        $tail = [regex]::Match($core, '^(.*?)( \([^()]*\))$')
        $note = $null
        if ($tail.Success -and $Pack.Exact.TryGetValue($tail.Groups[2].Value, [ref]$note)) {
            return ($prefix + (ConvertTo-DzTranslatedLine -Line $tail.Groups[1].Value -Pack $Pack -Depth ($Depth + 1)) + $note + $suffix)
        }
    }
    if ($Depth -ge 3) { return $Line }
    foreach ($t in $Pack.Templates) {
        $hit = $t.Regex.Match($core)
        if (-not $hit.Success) { continue }
        $result = $t.To
        foreach ($name in $t.Regex.GetGroupNames()) {
            if ($name -notmatch '^g\d+$') { continue }
            $value = ConvertTo-DzTranslatedLine -Line $hit.Groups[$name].Value -Pack $Pack -Depth ($Depth + 1)
            $result = $result.Replace('{' + $name.Substring(1) + '}', $value)
        }
        return ($prefix + $result + $suffix)
    }
    return $Line
}

function Get-DzText {
    <#
    .SYNOPSIS
        The text in the current interface language. Anything that is not a known text (or not
        text at all) comes back unchanged, so it is safe to call on every value shown.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][object]$Text)
    if ($Text -isnot [string]) { return $Text }
    if ($script:Language -eq 'en' -or -not $Text) { return $Text }
    $pack = $script:Packs[$script:Language]
    if ($null -eq $pack) { return $Text }
    $found = $null
    if ($pack.Exact.TryGetValue($Text, [ref]$found)) { return $found }
    if ($Text.IndexOf("`n") -lt 0) { return (ConvertTo-DzTranslatedLine -Line $Text -Pack $pack) }
    $parts = [regex]::Split($Text, '(\r?\n)')
    $out = New-Object System.Text.StringBuilder
    foreach ($part in $parts) {
        if ($part -match '^\r?\n$') { [void]$out.Append($part) }
        else { [void]$out.Append((ConvertTo-DzTranslatedLine -Line $part -Pack $pack)) }
    }
    return $out.ToString()
}

function Test-DzTextKnown {
    <# True when a language pack can translate this text (exactly or through a template). For tests. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][string]$Code)
    $pack = $script:Packs[$Code.ToLowerInvariant()]
    if ($null -eq $pack) { return $false }
    if ($pack.Exact.ContainsKey($Text)) { return $true }
    foreach ($line in @($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # Listed as is (a name that stays the same counts), or changed by a template.
        if ($pack.Exact.ContainsKey($line) -or $pack.Exact.ContainsKey($line.Trim())) { continue }
        if ((ConvertTo-DzTranslatedLine -Line $line -Pack $pack) -ceq $line) { return $false }
    }
    return $true
}

Export-ModuleMember -Function @(
    'Import-DzLanguage', 'Get-DzLanguageList', 'Get-DzLanguage', 'Set-DzLanguage', 'Get-DzDefaultLanguage',
    'Read-DzLanguageChoice', 'Save-DzLanguageChoice', 'Get-DzText', 'Test-DzTextKnown'
)
