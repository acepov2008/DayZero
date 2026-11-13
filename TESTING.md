# Testing DayZero safely

**Always test in a virtual machine before using a DayZero stick on real hardware.** A VM
costs nothing to break, and you can roll it back with a snapshot in seconds.

DayZero was built with automated tests that run anywhere, but its GUI (WPF) and its
Windows-only steps have **not yet run on real Windows**. The checklist below is the first
real test. Recommended order:

1. Automated checks (section 1). They must all pass.
2. On your own PC: start the builder (`Build-DayZeroUSB.cmd`), then try the wizard in dry-run
   mode (section 3c). Both only look at your PC and change nothing.
3. A dry-run install in a VM, then a real install in a VM (sections 2-4).
4. Real hardware, after a backup (section 6).

## 1. Automated checks (any PC)

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
.\tools\Invoke-DzChecks.ps1
```

These test the answer-file generator (no disk settings, passwords encoded, edition keys, ...)
and the USB writer, and statically check every script, batch file and XAML file. They cannot
run the GUI or Windows Setup. That is what the VM test is for.

## 2. Build a test ISO (VMs can't easily use a USB stick)

1. Download a Windows ISO with the [Media Creation Tool](https://www.microsoft.com/software-download/windows11)
   (choose **ISO file**).
2. Start `Build-DayZeroUSB.cmd`, choose **Folder (to test in a virtual machine)**, pick an
   **empty** folder and press **EXPORT TO FOLDER**.
   Tip: tick **Dry run** for your first test.
3. Pack the folder into an ISO:
   ```powershell
   .\tools\New-DzTestIso.ps1 -SourceFolder C:\DayZeroTest\export
   ```
   This creates `DayZero-test.iso` next to the folder.

Windows Setup looks for `autounattend.xml` on every CD/DVD and removable drive, and DayZero
finds its folder by the build marker file, so a second virtual DVD drive behaves like the stick.

## 3a. Hyper-V (Windows Pro/Enterprise)

1. **New > Virtual Machine**: **Generation 2**, 4096 MB RAM or more (untick Dynamic Memory),
   network **Default Switch**, new 64 GB disk, "Install an operating system later".
2. **Settings**:
   * **Security**: Secure Boot on (template "Microsoft Windows"), **Enable Trusted Platform Module**.
   * **Processor**: 2 or more.
   * **SCSI Controller > DVD Drive**: add **two** DVD drives. Put the Windows ISO in the first
     and `DayZero-test.iso` in the second.
   * **Firmware**: move the first DVD drive to the top of the boot order.
3. **Checkpoint the VM now** ("blank").
4. Start it and **press a key** when it says "Press any key to boot from CD or DVD".

## 3b. VirtualBox 7.1 or newer

1. **New**: pick the Windows ISO, type Windows 11 (64-bit), and **tick "Skip Unattended
   Installation"**. VirtualBox's own unattended install would fight with DayZero's.
   The Windows 11 template enables EFI, Secure Boot and TPM 2.0. Give it 4096 MB RAM,
   2 CPUs and a 64 GB disk.
2. **Settings > Storage**: add a second optical drive to the SATA controller and insert
   `DayZero-test.iso`.
3. **Take a snapshot** ("blank"), then start the VM.

## 3c. Try the wizard on your own PC (dry run, no VM needed)

The wizard can run on any Windows 10/11 PC in dry-run mode: it detects the PC and walks
through its plan, but every change is only logged as `[DRY-RUN] would: ...`.

```
kit\DayZero.cmd -DryRun
```

It keeps its progress in `kit\state.json`. Add `-Reset` to start again at the mode picker.

## 4. Checklist

Write down the Windows **build number** you tested (`winver` after install). Microsoft keeps
changing OOBE, so results can differ between builds.

**During Windows Setup**
- [ ] No language/keyboard page and no licence page.
- [ ] **Setup stops at "Where do you want to install Windows?"** This is the critical safety
      check. For extra confidence, add a second virtual disk and confirm Setup does not
      choose or wipe anything by itself.
- [ ] Edition: with **Auto** in a VM (VMs have no firmware key) Setup shows the product-key /
      edition page. Pick "I don't have a product key" and an edition. With **Home** or
      **Pro**, that edition installs without asking.

**During OOBE (the blue "first-run" screens)**
- [ ] No region, keyboard, network, Microsoft-account or privacy screens. Try once with the
      VM network **connected** and once **disconnected**.
- [ ] Windows signs in automatically as your account (if auto sign-in was on).

**After the first sign-in**
- [ ] The DayZero wizard appears with the builder's default mode selected ("BUILDER DEFAULT").
- [ ] Computer name, time zone, keyboard and region formats match the builder.
- [ ] `C:\DayZero` exists. `C:\DayZero\Logs` has `copykit.log`, `firstlogon.log` and `wizard-*.log`.

**Wizard (stage 2)**
- [ ] Mode picker: arrow keys and 1 - 4 switch modes, Enter continues, the mouse works too.
- [ ] Review page: "YOUR PC" shows the right Windows version, laptop/desktop and graphics card.
      On a laptop the yellow laptop note appears. Esc goes back, Enter starts.
- [ ] Progress page: the step list fills in (pending, running, done), the bar moves, and
      **L** opens the live log. `C:\DayZero\Logs\engine-*.log` has the same lines.
- [ ] Unplug the VM's network before starting: "Connect to the internet" waits, then fails
      after 10 minutes. Reconnect, press **Retry failed steps** and it turns green.
- [ ] Press **Pause after this step**: the summary says PAUSED and **CONTINUE** carries on.
- [ ] Close the window mid-run: it asks first, pauses, and the wizard resumes at the next sign-in.
- [ ] Restart the VM mid-run: after the automatic sign-in the wizard opens straight on the
      progress page and continues (finished steps are not repeated).
- [ ] Summary page: activation status is shown (VMs normally show "Not activated").

**Apps (stage 3)**
- [ ] "Get winget ready" finishes (look for `winget v1.x ready (...)` in the engine log and how
      it got there: already installed, re-registered, from the USB stick, or downloaded).
- [ ] Every app step ends green or with a clear message. Run `winget list` afterwards.
- [ ] Spotify and Discord install (they run as your user without admin rights; the log says
      "as the signed-in user").
- [ ] Office / Everything: "Install Microsoft 365 Apps" takes 10-30 minutes, then Word, Excel,
      PowerPoint, Outlook and OneNote are in Start, and nothing else (no Access/Publisher/Teams).
      `C:\DayZero\Logs\office-configuration.xml` shows the exact configuration used.
- [ ] Dry run: app steps say "[DRY-RUN] id checked; would install ..." (winget show still runs).
- [ ] Offline test: build the stick with "Put offline installers on the stick", then in the VM
      remove App Installer first (`Get-AppxPackage Microsoft.DesktopAppInstaller | Remove-AppxPackage`)
      and check that the log says winget came "from the USB stick".
- [ ] In the builder, "Check the app list with winget" reports every id as found.
- [ ] Builder: clicking each mode card updates "What this mode includes"; Custom shows
      **CHOOSE APPS...**, and the picks (e.g. Telegram, WinRAR, Claude) appear pre-ticked on
      the new PC's review screen.
- [ ] Builder: each CLEAN-UP LEVEL card updates "What this level does"; the level you pick is
      pre-selected on the new PC's review screen ("Clean-up level").
- [ ] Review screen: picking Minimal / Standard / Advanced / Clear re-ticks the switches under
      "Privacy and clean-up" (like WinUtil's preset buttons) and leaves the mode's tweaks alone.
- [ ] After a Standard run: Settings > Privacy & security > Location is off; Settings > System >
      For developers > End task is on; `sc qc DiagTrack` shows DISABLED; Clipchamp and News are
      gone, Calculator and Sticky Notes are still there.
- [ ] After an Advanced run: right-click in Explorer shows the full classic menu (after signing
      out); OneDrive is uninstalled; Mobile hotspot still works (Settings > Network & internet).
- [ ] `DayZero.cmd -Undo` after a Standard run: DiagTrack is Automatic again
      (`sc qc DiagTrack`), location is allowed again, removed apps reinstall from the Store.
- [ ] Review screen: compression allows only one of 7-Zip / WinRAR / None; WhatsApp installs
      from the Microsoft Store; Telegram, Claude, Spotify and Discord install for the signed-in
      user (they appear in that user's Start menu).

**Tweaks and debloat (stage 4)**
- [ ] "Create a restore point" is green, and Start > "Create a restore point" > System Restore
      lists "DayZero: before tweaks".
- [ ] Review page in Gaming mode: "High-performance power plan" is ticked on a desktop and
      unticked with a battery warning on a laptop; "Memory Integrity and VBS" and "Xbox Game Bar"
      are unticked with warnings; "Remove OneDrive" is unticked.
- [ ] After the run: Settings > Gaming > Game Mode is on; Control Panel > Mouse > Pointer
      Options > Enhance pointer precision is off (after sign-out); `powercfg /getactivescheme`
      shows Ultimate or High performance (desktop); typing in Start shows no web results;
      Widgets are gone (Windows 11).
- [ ] Debloat: Clipchamp, News, Solitaire and friends are gone; the Microsoft Store,
      Calculator and Photos are still there.
- [ ] `C:\DayZero\backup\tweaks.json` and `apps.json` list what changed.
- [ ] Run `C:\DayZero\DayZero.cmd -Undo`: it lists what it will put back, then restores the
      settings and reinstalls the removed apps. Restart and re-check the items above.
- [ ] Make the restore point fail (Group Policy "Turn off System Restore", or a VM without
      shadow copies): every tweak and removal step fails with "No restore point yet".
- [ ] "Check Windows activation": in a VM it says "Not activated yet" (expected). On a PC with
      a firmware key and the matching edition it ends "Activated".

**Drivers and Windows Update (stage 5)**
- [ ] Put a driver folder with `.inf` files in the stick's `DayZero\Drivers\` (any small driver,
      e.g. a VirtIO or a USB-serial driver for a VM). "Install drivers from the USB stick" runs
      pnputil and `pnputil /enum-drivers` lists it. With an empty folder the step is skipped.
- [ ] "Windows Update (including drivers)" installs updates, asks for a restart (overlay with
      countdown), signs back in and continues until Windows Update shows nothing left.
      The engine log lists every update ("found: ...", "succeeded: ...").
- [ ] "Final Windows Update check" never restarts by itself; the summary says "Restart the PC
      once you are done" if something still needs it.
- [ ] In a VM: no graphics-card app and no PC-brand tool steps (expected).
- [ ] On real hardware: NVIDIA/AMD show "Open download pages" on the summary, which opens the
      official page in your normal browser; Intel DSA installs by itself. The PC-brand tool
      (Dell/Lenovo/HP/ASUS) installs when ticked.

**Design (monochrome theme)**
- [ ] Builder and wizard: charcoal background, white title, gray text, a thin gray line under
      the header. No colourful glows anywhere.
- [ ] Mode cards show monochrome icons (controller, briefcase, grid, gear), not colour emoji.
      Hover lightens the border; the selected card has a white border; keyboard focus a light
      gray one.
- [ ] Primary buttons (WRITE TO USB, START) are solid white with dark text and stay readable on hover.
- [ ] The progress bar is a thin white line with a faint moving sheen; step icons are
      single-colour symbols; pages fade/slide in when you switch.
- [ ] Dark theme everywhere: drop-down lists, scroll bars, check boxes and tooltips are dark
      and readable (no white boxes).
- [ ] Windows "Narrator" (Ctrl+Win+Enter) reads the mode cards as "GAMING mode: ...".

If something looks wrong or a window doesn't open, run the launcher with `/console`, then
send the error and the files in `Logs\` along.

**Automated end-to-end dry run.** `tests\DryRun.Tests.ps1` runs the complete Gaming, Office
and Everything plans through the real engine with every function that could change the PC
replaced by one that throws; it proves a dry run walks the whole plan and changes nothing.
- [ ] Press **FINISH**. Afterwards the task `\DayZero\DayZero` is gone, `C:\Windows\Panther\unattend.xml`
      is gone, and after a restart Windows asks for the password instead of signing in.
- [ ] Windows 10 only: FINISH shows the Extended Security Updates reminder with a working
      "Open Windows Update settings" button.
- [ ] With a **temporary password**: after Finish and a restart, Windows asks you to set a new password.
- [ ] With **Dry run** on: the yellow DRY RUN badge shows, and the logs contain only
      `[DRY-RUN] would: ...` for changes. (After a dry run, automatic sign-in stays on; the
      wizard just closes itself at each sign-in.)

Note: on the test ISO the "USB" is read-only, so logs are not copied back to it. That is
expected. A real USB stick gets them in `DayZero\Logs\`.

## 5. When something goes wrong

| Where | What it tells you |
| --- | --- |
| `C:\Windows\Panther\setupact.log`, `setuperr.log` | Windows Setup itself, including answer-file errors |
| `C:\Windows\Panther\UnattendGC\setupact.log` | the specialize / OOBE passes |
| `C:\DayZero\Logs\copykit.log` | copying the toolkit off the stick |
| `C:\DayZero\Logs\firstlogon.log` | first sign-in, scheduled task |
| `C:\DayZero\Logs\wizard-*.log` | the wizard window |
| `C:\DayZero\Logs\engine-*.log` | every step the wizard ran (the main log) |
| `C:\DayZero\state.json` | progress: chosen mode, options and each step's status |
| `C:\DayZero\backup\*.json` | every tweak's old values and every removed app (used by `-Undo`) |
| `%TEMP%\DayZero-builder-error.log` | builder crashes |

Run `Build-DayZeroUSB.cmd /console` or `DayZero.cmd /console` to keep a PowerShell window
open with any error messages.

## 6. Moving to real hardware

Only after a clean VM run:
* Back up everything on the target PC.
* If you can, unplug other drives (data disks, external disks) while installing. Setup
  will still ask you for the disk, but fewer disks means fewer chances to click the wrong one.
* Keep the stick private, or rebuild it with a temporary password. The answer file
  contains your password in base64.
