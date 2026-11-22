DayZero for Linux
=================

This folder is copied to /opt/dayzero on the new PC by install-kit.sh (an Ubuntu autoinstall
late-command). At every start until it is done, dayzero-setup.service runs

    /usr/bin/python3 /opt/dayzero/dayzero.py run

which installs updates, drivers, Flathub and the apps of your mode (apps.json), then runs your
own scripts from scripts/*.sh as root, in name order. Finished steps are remembered in
/var/lib/dayzero/state.json; when everything is done the service turns itself off.

  Log:            /var/log/dayzero/setup.log
  Try again:      sudo python3 /opt/dayzero/dayzero.py retry
  Where is it:    python3 /opt/dayzero/dayzero.py status
  Live log:       python3 /opt/dayzero/dayzero.py watch
