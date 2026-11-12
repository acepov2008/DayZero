# PSScriptAnalyzer settings for DayZero.
# Main goal: catch anything that would not run on Windows PowerShell 5.1, which is the only
# PowerShell guaranteed to exist on a freshly installed Windows 10/11.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The answer file needs the password as text (it is base64-encoded into the XML).
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        # GUI tools: state-changing helpers are driven by buttons, not by -WhatIf.
        'PSUseShouldProcessForStateChangingFunctions',
        # Function names such as Get-DzSettings read naturally in plural.
        'PSUseSingularNouns'
    )
    Rules        = @{
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
        PSUseCompatibleTypes    = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}
