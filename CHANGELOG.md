# Changelog

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
