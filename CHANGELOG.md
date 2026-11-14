# Changelog

## 0.13.0 - tiny11 option
- New tick box under "Where Windows comes from": **Make it tiny11**. The builder turns the
  Windows 11 it downloaded (or your ISO) into tiny11 with ntdevlabs' tiny11builder and writes
  that to the stick, with your DayZero settings on top.
- tiny11builder is not part of DayZero and is not stored here. Its script is downloaded from
  GitHub at one fixed commit and only run when its SHA-256 matches the reviewed file. It runs
  unchanged in its own window.
- Needs Windows 11 with the edition set to Home or Pro. The finished tiny11 is kept and reused,
  and listed in **Downloaded Windows...**.
- Only the standard tiny11 is offered. "tiny11 core" switches off Windows Update and Defender,
  which DayZero's rules do not allow.

## 0.12.0 - Russian, stick check, downloaded-Windows manager
- **English or Russian**, for the builder and the wizard. A **Language** button in each header
  switches at once and is remembered; the builder's choice travels to the new PC. The first
  start follows the language Windows is shown in. Logs stay English.
- Translations live in `kit\lang\ru.json` (English text and its translation, about 600
  entries); a test fails when a text shown in a window or config has no translation.
- **Verify a stick** button: checks the Windows Setup and boot files, the split Windows image,
  the answer file (well-formed, no disk settings, points at this stick's toolkit) and the
  toolkit. It also runs by itself after every write. It changes nothing.
- **Downloaded Windows...** button: shows what the builder keeps in
  `%LOCALAPPDATA%\DayZero\media` with sizes, and deletes what you tick. Unfinished downloads
  and unpacks are listed and pre-ticked.
- A `state.json`, `backup\` or language choice left in the repo's `kit\` folder by trying the
  wizard on your own PC is no longer copied to the stick.

## 0.11.0 - the builder makes the Windows stick
- New default: **Make a new Windows USB stick**. Pick the stick and Windows 10 or 11, press
  **CREATE WINDOWS USB**: the builder gets Windows, erases the stick, makes it bootable (UEFI
  and legacy BIOS) and adds the answer file and toolkit. No Media Creation Tool or Rufus needed.
- Windows is downloaded from Microsoft through the Media Creation Tool's own catalogue, checked
  against Microsoft's size and SHA-1, unpacked with DISM and kept in
  `%LOCALAPPDATA%\DayZero\media` for the next stick. Or pick a Windows ISO file you have.
- Only USB drives of 7.5 to 300 GB that Windows is not running from can be erased; the stick is
  re-checked right before erasing. Sticks you already made still work as before.

## 0.10.0 - your own scripts
- `kit\Scripts\` / `DayZero\Scripts\`: your .cmd, .bat and .ps1 files run on the new PC after
  the apps, as administrator, in name order. Review switch, **Run my scripts** button on the
  summary, `C:\DayZero\RunScripts.cmd`.
- Builder: **Open the Scripts folder** button with a count of the scripts that go on the stick.
- Rebuilding the stick keeps scripts that are already on it.

## 0.9.0 - monochrome redesign
- Sleek, professional look: charcoal, gray and white instead of neon synthwave. Solid white
  primary buttons, thin borders, soft shadows, no glows, no animated sun or grid.
- Monochrome Segoe icons on the mode cards and single-colour step symbols instead of emoji.
- Thin progress bar. Resource names unchanged, so custom XAML keeps working.

## 0.8.0 - clean-up levels from WinUtil
- New **clean-up level** choice in the builder, separate from the mode: **Clear**, **Minimal**,
  **Standard** (default) and **Advanced**, modelled on Chris Titus Tech's WinUtil presets.
  On the new PC the level is pre-selected and works like WinUtil's preset buttons.
- New tweaks from WinUtil's presets: telemetry off, trimmed services, WPBT off, activity
  history, location and Delivery Optimization sharing off, 'End task' on the taskbar, generic
  folder views, temp and component clean-up, Recall/Notepad AI off, classic right-click menu.
- New reversible action types: service start type, registry key, machine environment
  variable; temp and DISM component clean-up. Windows Update, Defender, firewall and Store
  services are refused in code.
- App removal lists per level (WinUtil's default AppX selection at Standard); Teams is kept
  when you install it. Calculator, Clock, Sticky Notes, Sound Recorder and Quick Assist stay.
- Privacy tweaks moved from the modes into the levels. Old level names (none/light/full) and
  Custom picks from 0.7 builders still work.

## 0.7.0 - Custom mode and the full app catalog
- New **Custom** mode: pick every app, Microsoft 365, clean-up and tweaks in the builder
  (**CHOOSE APPS...**); the picks arrive pre-ticked on the new PC and can still be changed.
- Catalog grouped by category, now with Firefox, Opera, Brave, Edge, Telegram, WhatsApp
  (Microsoft Store), Viber, Teams, WinRAR, Claude and ChatGPT. Compression is pick-one
  (7-Zip, WinRAR or none). Every winget id checked against winget-pkgs.
- Review screen shows the whole catalog in every mode, with the mode's apps ticked; clean-up
  level and every tweak can be changed there.
- Builder: clicking a mode card shows what the mode includes.

## 0.6.0 - design polish
- Animated synthwave header in the builder and the wizard: striped sun, scrolling neon floor
  grid, pulsing title glow.
- Mode cards: the selected card's glow ring breathes; hover grows the card.
- Progress bar shine; pages fade and slide in; screen-reader names on mode cards.
- New static checks: animation targets exist; Theme.xaml defines resources before use.

## 0.5.0 - drivers and Windows Update
- Windows Update via the built-in Windows Update Agent API, software + drivers, restart and
  continue; final check only recommends a restart.
- `Drivers\` folder via pnputil; GPU vendor app and PC-brand tool from drivers.json
  (links for NVIDIA/AMD, which are not in winget).
- End-to-end dry-run tests for every mode (they found and fixed two bugs).

## 0.4.0 - tweaks, debloat, restore point, activation, undo
- 14 documented, reversible tweaks; full/light debloat with an enforced keep-list;
  restore point gate; legitimate activation only; `DayZero.cmd -Undo`.

## 0.3.0 - apps
- winget readiness chain with offline fallback, id checks + search fallback, non-elevated
  installs (Spotify, Discord); Microsoft 365 through the Office Deployment Tool.
- Builder: offline installers on the stick, Microsoft 365 plan, "Check the app list".

## 0.2.0 - wizard
- Mode picker, review, progress with live log, summary with retry, restarts and resume,
  background engine, state.json, Windows 10 ESU reminder.

## 0.1.0 - USB builder and answer file
- Builder GUI, autounattend.xml generator (no disk settings), install-time bootstrap.
