# DayZero

A USB-stick toolkit that installs Windows and then sets the PC up for you. Think
Ninite + an unattended Windows installer + a tweak tool, wrapped in a neon synthwave GUI.

> **Status: stage 2 of 6.** USB builder, answer file, install-time bootstrap and the setup
> wizard (mode picker, review, progress with live log, summary with retry, resume after
> restarts) work. Apps, tweaks and drivers plug in over the next stages.
> Test in a virtual machine first; see [TESTING.md](TESTING.md).

## How it works

1. **You make a normal Windows install USB** with Microsoft's
   [Media Creation Tool](https://www.microsoft.com/software-download/windows11) or Rufus.
   DayZero does not create bootable media.
2. **The DayZero Builder** (runs on any Windows PC) adds two things to that stick:
   * `autounattend.xml`: the answer file Windows Setup reads automatically
   * `DayZero\`: the toolkit
3. **You boot the target PC from the stick.** Setup runs on its own, **except that it always
   stops and asks you which disk to install on.** DayZero never picks, wipes or
   partitions a disk.
4. **At the first sign-in the DayZero wizard starts**: pick a mode, review the apps and
   options, then watch it work through its steps. It keeps going across restarts and ends
   with a summary (activation status, "Retry failed steps").

## Quick start

1. Make the Windows USB with the Media Creation Tool.
   *Using Rufus?* Untick all of its "Windows User Experience" options, because they write
   their own answer file. The builder keeps a backup of any existing one, but you don't want two.
2. Get DayZero onto your PC: in GitHub Desktop, **Clone** `acepov2008/DayZero`, or on
   GitHub use **Code > Download ZIP**. If you use the ZIP, right-click it, choose
   **Properties**, tick **Unblock**, then extract it.
3. Double-click **`Build-DayZeroUSB.cmd`** and accept the admin prompt.
4. Pick the stick, fill in your account, region and default mode, then press **WRITE TO USB**.
5. Boot the target PC from the stick (the boot menu key is often F12, F11, F8 or Esc).
   Choose the disk when Setup asks, and everything else runs by itself.

## The builder's choices, explained

| Setting | What it does |
| --- | --- |
| **Edition: Auto** *(recommended)* | No product key in the answer file. Setup uses the key built into the PC's firmware, installs the matching edition (Home or Pro), and Windows activates by itself. PCs without one show Setup's edition picker. |
| **Edition: Home / Pro** | Uses Microsoft's generic install key for that edition. It chooses the edition but **never activates**. Activation happens only if the PC has a licence for that edition. |
| **Edition: my product key** | Your key picks the edition and activates it. It is stored in plain text on the stick. |
| **Password** | Stored in `autounattend.xml` as **base64, which is not encryption**. Use **Generate a temporary password** and Windows asks for a new one after DayZero finishes. |
| **Sign in automatically** | Lets the wizard continue after restarts. DayZero switches it off and deletes the stored password when it finishes. |
| **Dry run** | The wizard only logs what it would do. |

DayZero only uses legitimate activation: the PC's firmware key, its digital licence, or a key
you own. No activators or licence-bypass scripts, ever.

## What is on the stick

```
autounattend.xml          answer file (an existing one is renamed to autounattend.backup-*.xml)
DayZero-README.txt        plain-text explanation + security notes
DayZero\                  the toolkit, copied to C:\DayZero during setup
DayZero\Drivers\          optional: drop extra .inf drivers here (kept when you rebuild)
DayZero\Logs\             logs from the builder and from every PC set up with this stick
```

## Repository layout

```
Build-DayZeroUSB.cmd      starts the builder (UAC + execution-policy bypass for that process only)
builder\                  builder GUI + modules (Unattend.psm1 = answer-file generator)
kit\                      everything copied to the stick and then to C:\DayZero
  DayZero.cmd / .ps1      wizard launcher / wizard
  config\                 modes.json (and from later stages apps, tweaks, ...)
  bootstrap\              install-time scripts called by the answer file
  lib\                    modules: Core (logs, dry run), State (state.json), Engine (step
                          runner, restarts, background runspace), Plan, System (PC detection),
                          Config, Steps.* (the steps), Session (cleanup), Ui (WPF helpers)
  ui\Theme.xaml           the neon synthwave theme, shared by builder and wizard
tests\                    Pester tests + static checks
tools\                    Invoke-DzChecks.ps1 (run all checks), New-DzTestIso.ps1 (VM testing)
```

## Tech

Windows PowerShell 5.1 + WPF/XAML, which is built into every Windows 10/11, so there's nothing to
install. Every file is readable text. Settings, app lists and tweaks live in JSON files
(from stage 3).

## Developing

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
.\tools\Invoke-DzChecks.ps1
```

The checks run on Windows PowerShell 5.1 and PowerShell 7 (also on Linux). Besides the unit
tests, they verify that every script is 5.1-compatible, every batch file has CRLF line
endings, and every control and theme resource a script uses really exists in the XAML.

## Roadmap

1. ~~USB builder + answer file~~ ✅
2. ~~Wizard GUI: mode picker, progress screen with live log, summary with "retry failed steps", resume after reboots~~ ✅
3. App engine: winget (with bundled fallback), Microsoft 365 via the Office Deployment Tool
4. Tweaks and debloat per mode: all reversible and documented in JSON, restore point first
5. Drivers: Windows Update, the `Drivers\` folder, GPU vendor app, PC-brand update tool
6. Design polish
