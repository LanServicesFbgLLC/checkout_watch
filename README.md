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
| `flagged` | that app was still holding it after you'd been idle longer than `--idle-threshold`, so **it's the likely reason your screen didn't lock** |
| `end`     | the app let go (with duration and the longest idle time seen). `still_active: true` means lockwatch was stopped while the app was still holding it |

## Usage

```bash
python3 lockwatch.py snapshot                 # what's blocking right now
python3 lockwatch.py --idle-threshold 300     # watch; set threshold = your lock timeout in seconds
python3 lockwatch.py report                   # summary: which apps, how often, how long
```

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

- **macOS**: create a LaunchAgent that runs `python3 /path/lockwatch.py --quiet`
  with `RunAtLoad`.
- **Windows**: copy `lockwatch.py`, `install-windows.ps1`, and
  `install-windows.cmd` to the PC and double-click `install-windows.cmd`.
  You can also run it from PowerShell:

  ```powershell
  .\install-windows.ps1                      # auto-detects the lock timeout
  .\install-windows.ps1 -IdleThreshold 600   # or set it yourself
  .\install-windows.ps1 -Uninstall
  ```

  The installer asks for admin rights. It finds Python, offering to install it
  with winget if it's missing, and detects the user's lock timeout from the
  screen saver, the inactivity policy, and the display-off setting. It installs
  `lockwatch.py` to `C:\Program Files\lockwatch`, which only admins can write
  to, since the task runs elevated. It then registers a `lockwatch` scheduled
  task that runs at logon for the signed-in user. If you install it from a
  different admin account, it still monitors the user at the console. Use
  `-User DOMAIN\name` to choose a different user.
- **Linux**: create a systemd user unit
  (`~/.config/systemd/user/lockwatch.service`) with
  `ExecStart=/usr/bin/python3 /path/lockwatch.py --quiet`, then run
  `systemctl --user enable --now lockwatch`.
