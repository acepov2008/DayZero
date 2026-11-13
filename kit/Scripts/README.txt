DAYZERO - YOUR OWN SCRIPTS
==========================

Put your own .cmd, .bat or .ps1 files here. On the new PC, DayZero runs them
automatically after Windows Update, drivers and the apps are done (you can untick
"Run your own scripts" on the review screen), one after another in name order:

  01-settings.cmd
  02-copy-files.ps1
  ...

  * They run as administrator, each in its own window, so you can see them.
  * A script that ends with an error code other than 0 is shown as a warning on the
    summary screen; the others still run.
  * Don't end a script with "pause" unless you want to press a key there.
  * .ps1 files run with: powershell -NoProfile -ExecutionPolicy Bypass -File <script>
  * The working folder is C:\DayZero\Scripts, so a script can use files next to it.
  * If the PC restarts in the middle, the scripts run again from the first one at the
    next sign-in, so write them so that running twice is harmless.
  * The summary screen has a "Run my scripts" button to run them again any time, and
    C:\DayZero\RunScripts.cmd does the same.

Where to put them:
  * in the DayZero project: kit\Scripts\ (the builder copies them to the stick), or
  * on the USB stick: DayZero\Scripts\
Files here are never deleted when you rebuild the stick; files from kit\Scripts with the
same name replace the stick's copy.
