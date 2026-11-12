# Testing DayZero safely

**Always test in a virtual machine before using a DayZero stick on real hardware.** A VM
costs nothing to break, and you can roll it back with a snapshot in seconds.

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
- [ ] Mode picker: arrow keys and 1 / 2 / 3 switch modes, Enter continues, the mouse works too.
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
