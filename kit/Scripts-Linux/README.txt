Your own Linux scripts
======================

Put *.sh files here before you make a Linux stick. On the new PC DayZero runs them once, as
root, with bash, in name order (01-..., 02-...), after the apps. Their output goes to
/var/log/dayzero/setup.log. A script that fails is tried again at the next start, up to 3 times.

These scripts are yours: DayZero does not check what they do. Do not put anything here that
turns off updates or the firewall.
