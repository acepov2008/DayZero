DAYZERO - OPTIONAL DRIVERS FOLDER
=================================

Put extra drivers here that Windows Update might not find, for example the
network (Wi-Fi / Ethernet) driver for a PC that has no internet without it.

  * Use extracted driver folders that contain .inf files (not .exe installers).
    Many vendors offer an "INF" or "SCCM driver pack" download.
  * Subfolders are fine, e.g. Drivers\Intel-WiFi\...\*.inf
  * DayZero installs them with Windows' own tool:  pnputil /add-driver *.inf /subdirs /install
  * They are installed first, before anything that needs the internet.

This folder is never deleted or overwritten when you rebuild the USB stick.
