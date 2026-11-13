# DayZero

A USB stick that installs Windows and then sets the PC up for you: think **Ninite + an
unattended Windows installer + a tweak tool**, in a clean monochrome GUI.

> **Status: v0.9.0, all six stages built.** 591 automated tests and static checks pass,
> including a complete dry run of every mode. **It has not run on real Windows yet**: the
> GUI (WPF) and the Windows-only steps can only be tested on Windows. Do the VM test in
> [TESTING.md](TESTING.md) before you use it on a real PC.

## How it works

1. **Make a normal Windows install USB** with Microsoft's
   [Media Creation Tool](https://www.microsoft.com/software-download/windows11) (or Rufus).
2. **Run the DayZero Builder** on any Windows PC. It adds `autounattend.xml` (the answer file
   Windows Setup reads by itself) and the `DayZero\` toolkit to that stick.
3. **Boot the PC from the stick.** Setup runs on its own, **except that it always stops and
   asks which disk to install on.** DayZero never picks, wipes or partitions a disk.
4. **The DayZero wizard starts at the first sign-in.** Pick a mode, tick what you want, and
   it installs and tweaks everything, across restarts, ending with a summary.

## Quick start

1. Make the Windows USB with the Media Creation Tool.
   *Rufus?* Untick its "Windows User Experience" options (they write their own answer file).
2. Get DayZero: in GitHub Desktop **Clone** `acepov2008/DayZero`, or on GitHub use
   **Code > Download ZIP** (then right-click the ZIP > **Properties** > tick **Unblock** before extracting).
3. Double-click **`Build-DayZeroUSB.cmd`** and accept the admin prompt.
4. Pick the stick, fill in your account, region, default mode and clean-up level, press **WRITE TO USB**.
5. Boot the target PC from the stick (boot menu key: often F12, F11, F8 or Esc), pick the disk
   when Setup asks, and let it run.

## The four modes

| | Apps | Mode tweaks |
| --- | --- | --- |
| 🎮 **Gaming** | Chrome, Steam, Epic Games Launcher, Discord, OBS Studio, MSI Afterburner, HWiNFO, WizTree + your graphics card's app | all gaming tweaks (below) |
| 💼 **Office** | Microsoft 365 Apps (Word, Excel, PowerPoint, Outlook, OneNote), Chrome, Acrobat Reader, Spotify, VLC, 7-Zip, Notepad++, Everything, WizTree. *Optional: LibreOffice* | none |
| 🧰 **Everything** | Gaming + Office + PowerToys, VS Code, Windows Terminal (Windows 10), Visual C++ 2015-2022, .NET 10, DirectX runtime. *Optional: .NET 8* | Gaming's |
| 🎛️ **Custom** | You pick every app in the builder (**CHOOSE APPS...**) or on the new PC | the ones you tick |

How much bloat and data collection to remove is a **separate choice**, the clean-up level
(below), so any mode can be combined with any level.

The review screen on the new PC always shows the **whole catalog by category**, with the
mode's apps ticked, so any mode can be adjusted: web browsers (Chrome, Firefox, Opera, Brave,
Edge), messaging (Discord, Telegram, WhatsApp, Viber, Teams), gaming, streaming & monitoring,
music & video, office & documents, compression (**pick one**: 7-Zip or WinRAR), utilities
(WizTree, PowerToys, Everything, Notepad++), AI assistants (Claude, ChatGPT), developer tools
and runtimes. In the builder, clicking a mode card shows exactly what that mode includes.

Every mode also does Windows Update (including drivers), installs drivers from the stick's
`Drivers\` folder, creates a restore point before any tweak, checks activation, and on
Windows 10 reminds you about Extended Security Updates.

Everything is in editable JSON: `kit\config\modes.json`, `apps.json`, `office.json`,
`tweaks.json`, `debloat.json`, `drivers.json`.

## The builder's choices

| Setting | What it does |
| --- | --- |
| **Edition: Auto** *(recommended)* | No product key in the answer file: Setup uses the key in the PC's firmware, installs the matching edition (Home or Pro) and Windows activates itself. PCs without one show Setup's edition picker. |
| **Edition: Home / Pro** | Microsoft's generic install key: picks the edition, **never activates**. |
| **Edition: my product key** | Your key picks the edition and activates. Stored in plain text on the stick. |
| **Password** | Stored in `autounattend.xml` as **base64, which is not encryption**. Use **Generate a temporary password**; Windows asks for a new one after DayZero finishes. |
| **Sign in automatically** | Lets the wizard carry on after restarts. DayZero turns it off and deletes the stored password at the end. |
| **Clean-up level** | Clear, Minimal, Standard *(default)* or Advanced, for any mode; the box below the cards lists what the level changes and removes. |
| **Dry run** | The wizard only logs what it would do. |
| **Offline installers** | Puts App Installer (winget) and Microsoft's Office Deployment Tool on the stick (~250 MB). |
| **Microsoft 365 plan** | Personal/Family, Business or Enterprise. You activate by signing in. |
| **Check the app list** | Runs `winget show` for every package id on your PC (read-only). |

## The wizard

Mode picker (big animated cards; arrows or 1-4, Enter) → review (your PC, switches, app
checkboxes) → progress (step list with ○ ✓ ✕, thin progress bar, live log on **L**) →
summary (activation status, **Retry failed steps**, download links, Finish). Restarts are
announced with a countdown and the wizard picks up where it left off. You can pause, or close
the window; it continues at the next sign-in.

## Clean-up levels (from Chris Titus Tech's WinUtil)

The four buttons of [WinUtil](https://github.com/ChrisTitusTech/winutil)'s tweaks tab, as a
choice in the builder. Each level also does everything the levels above it do. On the new PC
the level is pre-selected on the review screen, and picking another one there re-ticks its
switches, like WinUtil's preset buttons; every switch can still be changed by hand.

| Level | Changes | Removes |
| --- | --- | --- |
| **Clear** | nothing | nothing |
| **Minimal** | telemetry off (lowest level the edition allows, no ad ID, no tailored experiences, DiagTrack and Error Reporting services off), background services trimmed, no promoted apps, no programs from the firmware (WPBT) | third-party promo apps: Candy Crush, TikTok, Netflix/Disney+/Prime links, Facebook, Instagram, LinkedIn... |
| **Standard** *(default)* | + activity history, location and Delivery Optimization sharing off, "End task" on the taskbar, generic folder views, temp files and superseded update files cleaned | + Clipchamp, News, Weather, Bing Search, Copilot, Microsoft 365 hub, Solitaire, Get Help, Feedback Hub, Power Automate, To Do, Dev Home, Tips, Cortana, Skype... |
| **Advanced** | + Copilot hidden, Recall snapshots and Notepad AI off, Widgets off, no Bing results in Start, classic right-click menu | + OneDrive, new Outlook, preinstalled Teams (kept if you install Teams), Phone Link, Movies & TV, Maps, Family Safety |

Where DayZero differs from WinUtil, on purpose (full list in `debloat.json` > `winutil`):

* **Defender's sample submission stays on** (WinUtil's Telemetry turns it off): DayZero never weakens Defender.
* **Internet Connection Sharing stays on** (WinUtil's Services disables it): it would break Mobile hotspot.
* **Disk clean-up keeps updates uninstallable** (no `/ResetBase`), and skips `cleanmgr`, which waits for a click.
* **Calculator, Clock, Sticky Notes, Sound Recorder and Quick Assist are kept** (WinUtil's default AppX list removes them).
* **Policies instead of hacks**: Widgets and Windows AI are turned off with documented Group Policy
  settings; no file-permission trick on the Store's database, no undocumented Start menu flag.

## Tweaks and undo

Every tweak in `tweaks.json` says **what** it changes and **why**. The old value (registry
value, service start type, environment variable) is saved to `C:\DayZero\backup\tweaks.json`
before anything changes, and

```
C:\DayZero\DayZero.cmd -Undo
```

puts every tweak back and reinstalls removed apps. If no restore point can be made, no tweak
or removal runs. DayZero **never** touches Windows Update, Microsoft Defender, the firewall or
the Store's services or settings (enforced in code, not just in the JSON), and runs no scripts
from the JSON. No placebo "registry boosters".

Mode tweaks:

| Tweak | Gaming | Office | Notes |
| --- | :-: | :-: | --- |
| Game Mode on | ✅ | | |
| Hardware-accelerated GPU scheduling | ✅ | | real GPUs only; restart |
| Mouse acceleration off | ✅ | | sign out |
| Store apps not running in the background | ✅ | | desktop programs unaffected |
| Launchers and chat apps don't auto-start | ✅ | | same switch as Task Manager |
| Ultimate/High performance power plan | ✅ desktops | | **laptops: off by default, battery warning** |
| Memory Integrity / VBS off | optional, off | | **security trade-off warning** |
| Xbox Game Bar off | optional, off | | warning |

The Microsoft Store, Calculator, Photos, Notepad, Paint, Snipping Tool, winget, Windows
Security, Xbox/Game Pass parts and app frameworks are never removed, whatever the level.

## Drivers and Windows Update

1. **`Drivers\` on the stick** (optional, put `.inf` driver folders there): installed first with
   `pnputil`, so a network driver can come from the stick.
2. **Windows Update** through the API built into Windows: software and driver updates Windows
   would install by itself, restarting and continuing until nothing is left.
3. **Graphics card app**: Intel Driver & Support Assistant via winget. NVIDIA App and AMD
   Adrenalin aren't published through winget, so the summary has a button that opens their
   official download pages (Windows Update has already installed a working driver).
4. **PC-brand tool** (ticked when the brand is recognised, never in a VM): Dell Command |
   Update and HP Support Assistant via winget, Lenovo Vantage and MyASUS from the Microsoft Store.

## Apps and winget

Every winget id was checked against Microsoft's winget-pkgs repository, and the wizard checks
again (`winget show`) right before installing. If an id disappears it runs `winget search` and
puts the results in the log instead of guessing. If winget isn't ready on a fresh PC, DayZero
re-registers App Installer, waits for the Store, then uses the copy on the stick, then downloads
it from Microsoft. Spotify and Discord install as your user without admin rights.

## Activation

Legitimate only: if Windows isn't activated and the PC's firmware holds a key for the
installed edition, DayZero installs that key and activates online; otherwise it asks Microsoft
once (digital licence). The summary shows the result. No activators or bypass scripts, ever.

## Safety summary

* No disk selection, partitioning or wiping in the answer file (a test fails the build otherwise).
* Only documented answer-file settings; no BypassNRO or other OOBE hacks.
* Passwords in the answer file are base64 (warned about); temporary-password option.
* Restore point before tweaks; every tweak recorded and reversible; dry-run mode.
* Windows Update, Defender, the firewall and the Store are never reconfigured, at any clean-up level.
* Downloads come only from Microsoft or the vendor; installers must be signed by them.

## What is on the stick

```
autounattend.xml          the answer file (an existing one is renamed to autounattend.backup-*.xml)
DayZero-README.txt        plain-text explanation + security notes
DayZero\                  the toolkit, copied to C:\DayZero during setup
DayZero\Drivers\          optional: extra .inf drivers (kept when you rebuild)
DayZero\Logs\             logs from the builder and from every PC set up with this stick
DayZero\bundled\          offline installers (winget, Office Deployment Tool), if ticked
```

On the new PC: `C:\DayZero\Logs\engine-*.log` (every step), `C:\DayZero\state.json`
(progress), `C:\DayZero\backup\` (what `-Undo` uses).

## Repository layout

```
Build-DayZeroUSB.cmd      builder launcher (asks for admin; execution policy bypassed for that process only)
builder\                  builder GUI + modules (Unattend.psm1 = answer-file generator, Bundles.psm1 = offline installers)
kit\                      everything copied to the stick and then to C:\DayZero
  DayZero.cmd / .ps1      wizard launcher / wizard (-DryRun, -Resume, -Reset, -Undo, /console)
  bootstrap\              scripts the answer file runs during setup and at first sign-in
  config\                 the JSON files that define modes, apps, tweaks, debloat, drivers, Office
  lib\                    modules: Core, State, Engine, Plan, System, Config, Winget, Office, Tweaks,
                          Debloat, Undo, WindowsUpdate, Drivers, Steps.* and Ui
  ui\                     Theme.xaml (monochrome) and Wizard.xaml
tests\                    Pester tests + static checks
tools\                    Invoke-DzChecks.ps1, New-DzTestIso.ps1, Test-DzAppIds.ps1
```

## Tech and development

Windows PowerShell 5.1 + WPF/XAML: built into every Windows 10/11, nothing to install, every
file readable. The engine runs in a background runspace so the window never freezes, and
saves its progress after every step.

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
.\tools\Invoke-DzChecks.ps1
```

The checks run on PowerShell 5.1 and 7 (also on Linux). They cover the answer file, the
engine (resume, restarts, retries), plans, winget flows, Office config, tweaks with a fake
registry (apply and undo), debloat safety, Windows Update with mocked COM, a full dry run of
every mode, and static checks: PowerShell 5.1 compatibility, CRLF batch files, and every
control, resource and animation target in the XAML.

See [CHANGELOG.md](CHANGELOG.md) for what each stage added.

## Credits

The clean-up levels are modelled on the presets of Chris Titus Tech's
[WinUtil](https://github.com/ChrisTitusTech/winutil) (MIT licence); DayZero's code is its own.
See `THIRD-PARTY-NOTICES.md`.
