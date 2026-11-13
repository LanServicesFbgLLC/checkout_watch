# lockwatch

Records what is stopping your screen from locking on macOS, Windows, and Linux.
It's a single Python 3.8+ file that uses only the standard library.

Apps keep the screen awake by asking the OS to (macOS "power assertions",
Windows "power requests", Linux logind/GNOME/KDE "inhibitors"). Common
offenders include video players, browsers playing media, Zoom/Teams calls,
remote-desktop clients, and audio interfaces. lockwatch checks these every
15 seconds, tracks how long you've been idle, and logs:

| event     | meaning |
|-----------|---------|
| `start`   | an app began keeping the display awake |
| `flagged` | that app was still holding it after you'd been idle longer than the lock timeout, so **it's the likely reason your screen didn't lock** |
| `threshold` | the lock timeout lockwatch is using, and where it came from |
| `end`     | the app let go (with duration and the longest idle time seen). `still_active: true` means lockwatch was stopped while the app was still holding it |

## Usage

```bash
python3 lockwatch.py snapshot     # what's blocking right now, and your lock timeout
python3 lockwatch.py              # watch (Ctrl+C to stop)
python3 lockwatch.py report       # summary: which apps, how often, how long
```

lockwatch reads the machine's lock timeout itself and re-checks it every 10
minutes:
- macOS: screen saver start time or display sleep, plus the "require password" delay
- Windows: screen saver timeout, the `InactivityTimeoutSecs` policy, or the display-off timeout
- Linux: GNOME/Cinnamon idle delay, the KDE screen locker, or the X11 screensaver

Use `--idle-threshold SECONDS` to set the timeout yourself.

Options: `--interval N` (seconds between checks), `--all` (also log things that
only stop *system* sleep, not the display), `--log PATH`, `--quiet`.

Default log location:
- macOS: `~/Library/Logs/lockwatch/lockwatch.jsonl`
- Windows: `%LOCALAPPDATA%\lockwatch\lockwatch.jsonl`
- Linux: `~/.local/state/lockwatch/lockwatch.jsonl`

## Platform notes

**macOS**: uses `pmset -g assertions` and `ioreg` (idle time). No special
permissions needed. If `coreaudiod` holds an assertion, the report names the app
it's holding it for, such as `coreaudiod (for firefox)`.

**Windows**: uses `powercfg /requests`, which **requires an elevated prompt**
(Run as Administrator). Idle time comes from `GetLastInputInfo`. The `DISPLAY`
category is the one that blocks locking.

**Linux**: queries systemd-logind (`idle` inhibitors), the GNOME Session
Manager, and KDE PowerDevil over D-Bus via `busctl`. It also detects X11
`xset -dpms` / `xset s off`. Idle time comes from GNOME Mutter or `xprintidle`.
Run it inside your desktop session so it can reach the user D-Bus.

## What it can't see

Something that fakes input (a mouse jiggler, a twitchy mouse, a game controller,
or a remote-control tool moving the cursor) resets the idle timer instead of
holding a power request. If your screen isn't locking and lockwatch shows no
blockers, check the idle time in `snapshot`. If it never climbs while you're
away, the problem is input, not an app. Also check that the OS lock timeout or
screen-saver policy is actually set.

## Run it in the background

Each OS has an installer, plus launch files under `deploy/` that are **identical
on every machine**. They use fixed install paths and auto-detect the lock
timeout, so you can push the same files with an MDM, RMM, Ansible or group
policy instead of running an installer on each machine.

Each installer:
- installs for just the current user by default, or for every user on the
  machine with `--system` / admin rights
- takes `--idle-threshold N` to override the detected timeout
- removes lockwatch with `--uninstall` (logs are kept)

### macOS

```bash
./install-macos.sh                 # just you, no sudo
sudo ./install-macos.sh --system   # every user on this Mac
```

| File | All-users location |
|---|---|
| `lockwatch.py`, `deploy/macos/run.sh` | `/Library/Application Support/lockwatch/` |
| `deploy/macos/com.lanservicesfbg.lockwatch.plist` | `/Library/LaunchAgents/` (root:wheel, 644) |

`run.sh` looks for Python 3 in Homebrew, then python.org, then the Xcode
Command Line Tools. **New Macs don't include Python**, so install it first
(`xcode-select --install`, `brew install python`, or the python.org
installer). If `run.sh` can't find Python, it writes a note to
`~/Library/Logs/lockwatch/stderr.log` and exits without retrying.

### Linux

```bash
./install-linux.sh                 # just you
sudo ./install-linux.sh --system   # every user on this machine
```

| File | All-users location |
|---|---|
| `lockwatch.py` | `/usr/local/lib/lockwatch/` |
| `deploy/linux/lockwatch.desktop` | `/etc/xdg/autostart/` (works on any desktop) |
| or `deploy/linux/lockwatch.service` | `/etc/systemd/user/`, then `systemctl --global enable lockwatch.service` |

The installer uses the systemd user service when the desktop supports it
(GNOME, KDE Plasma 5.25+), because it restarts on failure. Otherwise it uses
the XDG autostart entry. Use `--method systemd|autostart` to choose. If Python 3
is missing, it offers to install it with the system package manager.

### Windows

Copy `lockwatch.py`, `install-windows.ps1` and `install-windows.cmd` to the PC
and double-click `install-windows.cmd`, or run it from PowerShell:

```powershell
.\install-windows.ps1
.\install-windows.ps1 -IdleThreshold 600
.\install-windows.ps1 -Uninstall
```

The installer asks for admin rights. It finds Python, offering to install it
with winget if it's missing. It installs `lockwatch.py` to
`C:\Program Files\lockwatch`, which only admins can write to, since the task
runs elevated. It then registers a `lockwatch` scheduled task that runs at
logon for the signed-in user. If you install it from a different admin account,
it still monitors the user at the console. Use `-User DOMAIN\name` to choose a
different user.
