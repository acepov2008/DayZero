#!/usr/bin/env python3
"""DayZero for Linux - the first-boot setup on the new PC.

Installed to /opt/dayzero by install-kit.sh (an autoinstall late-command). Python 3 standard
library only, because that is all a fresh Ubuntu has.

  dayzero.py run       as root, from dayzero-setup.service at every boot until it is done:
                       updates, graphics drivers, Flathub, the apps of the mode, your scripts.
                       Finished steps are remembered (state.json), so a restart resumes.
  dayzero.py retry     as root: run the failed steps again.
  dayzero.py progress  as the signed-in user (autostart): a window with the live log.
  dayzero.py watch     the live log in a terminal.
  dayzero.py status    one line about where the setup is.

Rules kept from the Windows side: updates are never turned off, nothing is guessed (apps are
Flathub ids from apps.json, checked when the catalog is made), config files hold no commands,
and logs stay in English. Texts shown to the user go through T() (kit/lang/ru.json).
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request

KIT = os.environ.get("DAYZERO_KIT", os.path.dirname(os.path.abspath(__file__)))
VAR = os.environ.get("DAYZERO_VAR", "/var/lib/dayzero")
LOG_DIR = os.environ.get("DAYZERO_LOG_DIR", "/var/log/dayzero")
STATE_FILE = os.path.join(VAR, "state.json")
DONE_FILE = os.path.join(VAR, "done")
SUMMARY_FILE = os.path.join(VAR, "summary.txt")
LOG_FILE = os.path.join(LOG_DIR, "setup.log")
SERVICE = "dayzero-setup.service"
FLATHUB_REPO = "https://dl.flathub.org/repo/flathub.flatpakrepo"
MAX_ATTEMPTS = 3
FLATPAK_ID = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$")
APT_NAME = re.compile(r"^[a-z0-9][a-z0-9+.-]+$")
APT_ENV = {"DEBIAN_FRONTEND": "noninteractive", "NEEDRESTART_MODE": "a"}
APT_OPTS = ["-y", "-o", "DPkg::Lock::Timeout=900", "-o", "Dpkg::Options::=--force-confdef", "-o", "Dpkg::Options::=--force-confold"]

_strings = {}


# --------------------------------------------------------------------------------------
# Texts
# --------------------------------------------------------------------------------------

def load_language(code, kit=None):
    """Loads kit/lang/<code>.json pairs; English needs nothing."""
    _strings.clear()
    if not code or code == "en":
        return
    path = os.path.join(kit or KIT, "lang", code + ".json")
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        for pair in data.get("strings", []):
            if isinstance(pair, list) and len(pair) == 2:
                _strings[pair[0]] = pair[1]
    except (OSError, ValueError):
        pass


def T(text, *args):
    """Shown text in the chosen language; {0} {1} are filled after translating."""
    out = _strings.get(text, text)
    if args:
        out = out.format(*args)
    return out


# --------------------------------------------------------------------------------------
# Files
# --------------------------------------------------------------------------------------

def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def log(message):
    line = time.strftime("%Y-%m-%d %H:%M:%S") + "  " + message
    print(line, flush=True)
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
        os.chmod(LOG_FILE, 0o644)
    except OSError:
        pass


# --------------------------------------------------------------------------------------
# The plan: a list of steps, each {id, title, kind, ...}. Built from settings + apps.json only.
# --------------------------------------------------------------------------------------

def pick_apps(settings, catalog):
    """Apps to install: exactly the builder's list when appsExact is set, else the mode's apps
    plus whatever was picked."""
    mode = str(settings.get("defaultMode") or "custom")
    picked = set(settings.get("apps") or [])
    exact = bool(settings.get("appsExact"))
    out = []
    for app in catalog.get("apps", []):
        if app.get("id") in picked or (not exact and (mode == "everything" or mode in (app.get("modes") or []))):
            out.append(app)
    return out


def list_scripts(scripts_dir):
    if not os.path.isdir(scripts_dir):
        return []
    return sorted(n for n in os.listdir(scripts_dir) if n.endswith(".sh") and os.path.isfile(os.path.join(scripts_dir, n)))


def build_plan(settings, catalog, scripts_dir):
    steps = [
        {"id": "network", "title": "Waiting for the internet", "kind": "network"},
        {"id": "apt-update", "title": "Reading the package lists", "kind": "cmd",
         "cmd": ["apt-get", "update"], "env": APT_ENV},
        {"id": "apt-upgrade", "title": "Installing updates", "kind": "cmd",
         "cmd": ["apt-get"] + APT_OPTS + ["full-upgrade"], "env": APT_ENV},
    ]
    if settings.get("installDrivers", True):
        steps.append({"id": "drivers", "title": "Installing graphics and other drivers", "kind": "cmd",
                      "cmd": ["ubuntu-drivers", "install"], "optionalTool": "ubuntu-drivers"})
    apps = pick_apps(settings, catalog)
    flat = [a for a in apps if a.get("flatpak")]
    debs = [a for a in apps if a.get("apt")]
    if flat:
        steps.append({"id": "flatpak", "title": "Setting up Flathub (the app store for Linux apps)", "kind": "cmd",
                      "cmd": ["apt-get"] + APT_OPTS + ["install", "flatpak", "gnome-software-plugin-flatpak"], "env": APT_ENV})
        steps.append({"id": "flathub", "title": "Adding Flathub", "kind": "cmd",
                      "cmd": ["flatpak", "remote-add", "--system", "--if-not-exists", "flathub", FLATHUB_REPO]})
    for a in flat:
        ref = a["flatpak"]
        if not FLATPAK_ID.match(ref):
            raise ValueError("Bad Flathub id in apps.json: %r" % ref)
        steps.append({"id": "app-" + a["id"], "title": "Installing {0}", "args": [a["name"]], "kind": "cmd",
                      "cmd": ["flatpak", "install", "--system", "--noninteractive", "-y", "flathub", ref]})
    for a in debs:
        pkg = a["apt"]
        if not APT_NAME.match(pkg):
            raise ValueError("Bad package name in apps.json: %r" % pkg)
        steps.append({"id": "app-" + a["id"], "title": "Installing {0}", "args": [a["name"]], "kind": "cmd",
                      "cmd": ["apt-get"] + APT_OPTS + ["install", pkg], "env": APT_ENV})
    for name in list_scripts(scripts_dir):
        steps.append({"id": "script-" + name, "title": "Running your script {0}", "args": [name], "kind": "cmd",
                      "cmd": ["bash", os.path.join(scripts_dir, name)], "cwd": scripts_dir})
    return steps


# --------------------------------------------------------------------------------------
# Running
# --------------------------------------------------------------------------------------

def wait_for_network(timeout=900, probe=None):
    probe = probe or (lambda: urllib.request.urlopen("https://dl.flathub.org/", timeout=15).close())
    end = time.time() + timeout
    while True:
        try:
            probe()
            return True
        except Exception as e:  # noqa: BLE001 - any failure means "not yet"
            if time.time() >= end:
                log("No internet after %d s: %s" % (timeout, e))
                return False
            time.sleep(10)


def run_command(step, dry_run=False):
    cmd = step["cmd"]
    tool = step.get("optionalTool")
    if tool and not shutil.which(tool):
        log("  %s is not installed here; skipped." % tool)
        return 0
    if dry_run:
        log("  DRY RUN: would run: " + " ".join(cmd))
        return 0
    env = dict(os.environ)
    env.update(step.get("env") or {})
    log("  $ " + " ".join(cmd))
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
                             cwd=step.get("cwd") or "/", text=True, errors="replace")
    except OSError as e:
        log("  could not start: %s" % e)
        return 127
    for line in p.stdout:
        line = line.rstrip()
        if line:
            log("  | " + line[-300:])
    return p.wait()


def english(step):
    """A step's title for the log (always English)."""
    return step["title"].format(*(step.get("args") or []))


def shown(step):
    """A step's title for the user (translated)."""
    return T(step["title"], *(step.get("args") or []))


def run_plan(steps, state, dry_run=False, runner=run_command, network=wait_for_network, save=None):
    """Runs every step that is not done yet. Returns the state dict."""
    results = state.setdefault("steps", {})
    for step in steps:
        r = results.setdefault(step["id"], {"status": "pending", "attempts": 0})
        if r["status"] == "done":
            continue
        if r["status"] == "failed" and r["attempts"] >= MAX_ATTEMPTS:
            continue
        log("== " + english(step))
        r["attempts"] += 1
        if step["kind"] == "network":
            ok = dry_run or network()
            code = 0 if ok else 1
        else:
            code = runner(step, dry_run)
        r["status"] = "done" if code == 0 else "failed"
        r["exitCode"] = code
        r["title"] = english(step)
        if code != 0:
            log("   failed (exit code %d)" % code)
        if save:
            save(state)
        if step["kind"] == "network" and code != 0:
            log("Stopping here: nothing else works without the internet. DayZero tries again at the next start.")
            break
    return state


def is_finished(steps, state):
    results = state.get("steps", {})
    for s in steps:
        r = results.get(s["id"])
        if not r:
            return False
        if r["status"] == "done":
            continue
        if r["status"] == "failed" and r["attempts"] >= MAX_ATTEMPTS:
            continue
        return False
    return True


def summary_lines(steps, state):
    results = state.get("steps", {})
    ok = [s for s in steps if results.get(s["id"], {}).get("status") == "done"]
    bad = [s for s in steps if results.get(s["id"], {}).get("status") == "failed"]
    lines = [T("DayZero finished: {0} of {1} steps worked.", len(ok), len(steps))]
    if bad:
        lines.append(T("These did not work:"))
        lines += ["  - " + shown(s) for s in bad]
        lines.append(T("To try them again, run: sudo python3 /opt/dayzero/dayzero.py retry"))
    if os.path.exists("/var/run/reboot-required"):
        lines.append(T("Restart the PC to finish the updates."))
    lines.append(T("The full log is in {0}", LOG_FILE))
    return lines


def load_context(kit=None):
    kit = kit or KIT
    settings = read_json(os.path.join(kit, "settings.json"), {}) or {}
    catalog = read_json(os.path.join(kit, "apps.json"), {}) or {}
    load_language(str(settings.get("appLanguage") or "en"), kit)
    steps = build_plan(settings, catalog, os.path.join(kit, "scripts"))
    return settings, steps


def finish(steps, state):
    lines = summary_lines(steps, state)
    for line in lines:
        log(line)
    os.makedirs(VAR, exist_ok=True)
    with open(SUMMARY_FILE, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    with open(DONE_FILE, "w", encoding="utf-8") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S") + "\n")
    if shutil.which("systemctl"):
        subprocess.call(["systemctl", "disable", SERVICE], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def cmd_run(retry=False):
    if os.geteuid() != 0:
        print(T("Run this as root: sudo python3 /opt/dayzero/dayzero.py run"))
        return 1
    settings, steps = load_context()
    state = read_json(STATE_FILE, {}) or {}
    if retry:
        for r in state.get("steps", {}).values():
            if r.get("status") == "failed":
                r["status"] = "pending"
                r["attempts"] = 0
        if os.path.exists(DONE_FILE):
            os.remove(DONE_FILE)
    state["buildId"] = settings.get("buildId")
    log("DayZero for Linux, build %s, mode %s%s" % (settings.get("buildId"), settings.get("defaultMode"),
                                                   " (DRY RUN)" if settings.get("dryRun") else ""))
    run_plan(steps, state, dry_run=bool(settings.get("dryRun")), save=lambda s: write_json(STATE_FILE, s))
    write_json(STATE_FILE, state)
    if is_finished(steps, state):
        finish(steps, state)
    else:
        log("Not finished yet; DayZero continues at the next start.")
    return 0


# --------------------------------------------------------------------------------------
# Showing progress to the signed-in user
# --------------------------------------------------------------------------------------

def status_line():
    if os.path.exists(DONE_FILE):
        return T("DayZero is done.")
    if os.path.exists(LOG_FILE):
        return T("DayZero is setting up this PC. You can keep using it.")
    return T("DayZero has not started yet.")


def follow_log(out, stop_when_done=True, poll=1.0):
    """Copies the log to `out` as it grows; returns when the setup is done."""
    pos = 0
    while True:
        try:
            with open(LOG_FILE, encoding="utf-8", errors="replace") as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
            if chunk:
                out.write(chunk)
                out.flush()
        except OSError:
            pass
        if stop_when_done and os.path.exists(DONE_FILE):
            return
        time.sleep(poll)


def cmd_watch():
    print(T("DayZero is setting up this PC. You can keep using it.") + "\n", flush=True)
    try:
        follow_log(sys.stdout)
        print()
        try:
            with open(SUMMARY_FILE, encoding="utf-8") as f:
                print(f.read())
        except OSError:
            pass
        input(T("Press Enter to close this window."))
    except (KeyboardInterrupt, EOFError):
        pass
    return 0


def shown_marker():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "dayzero", "summary-shown")


def notify(title, body):
    if shutil.which("notify-send"):
        subprocess.call(["notify-send", "-a", "DayZero", title, body])


def cmd_progress():
    marker = shown_marker()
    if os.path.exists(DONE_FILE) and os.path.exists(marker):
        return 0
    settings = read_json(os.path.join(KIT, "settings.json"), {}) or {}
    load_language(str(settings.get("appLanguage") or "en"))
    title = T("DayZero setup")
    me = [sys.executable, os.path.abspath(__file__), "watch"]
    if shutil.which("zenity"):
        p = subprocess.Popen(["zenity", "--text-info", "--title", title, "--auto-scroll", "--width", "820",
                              "--height", "560", "--font", "monospace 10"], stdin=subprocess.PIPE, text=True)
        try:
            p.stdin.write(status_line() + "\n\n")
            follow_log(p.stdin)
            try:
                with open(SUMMARY_FILE, encoding="utf-8") as f:
                    p.stdin.write("\n" + f.read())
            except OSError:
                pass
            p.stdin.close()
        except BrokenPipeError:
            return 0
        p.wait()
    else:
        terminals = [["ptyxis", "--"], ["gnome-terminal", "--"], ["konsole", "-e"], ["xfce4-terminal", "-x"],
                     ["mate-terminal", "-x"], ["x-terminal-emulator", "-e"]]
        for t in terminals:
            if shutil.which(t[0]):
                subprocess.call(t + me)
                break
        else:
            notify(title, status_line())
            while not os.path.exists(DONE_FILE):
                time.sleep(30)
            try:
                with open(SUMMARY_FILE, encoding="utf-8") as f:
                    notify(title, f.read())
            except OSError:
                pass
    if os.path.exists(DONE_FILE):
        os.makedirs(os.path.dirname(marker), exist_ok=True)
        with open(marker, "w", encoding="utf-8") as f:
            f.write("shown\n")
    return 0


def main(argv):
    what = argv[1] if len(argv) > 1 else "status"
    if what == "run":
        return cmd_run()
    if what == "retry":
        return cmd_run(retry=True)
    if what == "progress":
        return cmd_progress()
    if what == "watch":
        return cmd_watch()
    if what == "status":
        settings = read_json(os.path.join(KIT, "settings.json"), {}) or {}
        load_language(str(settings.get("appLanguage") or "en"))
        print(status_line())
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
