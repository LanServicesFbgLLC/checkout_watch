#!/usr/bin/env python3
"""
lockwatch - record what is stopping your screen from locking.

Works on macOS, Windows and Linux with only the Python standard library.

It polls the operating system's list of "power assertions" / "power requests" /
"inhibitors" (the mechanism apps use to say "don't sleep / don't blank the
screen"), along with how long you've been idle, and writes a JSON-lines log:

  start    - an app began blocking display sleep / idle lock
  flagged  - an app was blocking while you'd been idle past the threshold
             (i.e. this is very likely why your screen didn't lock)
  end      - the app released its block (includes how long it lasted)

Usage:
  python3 lockwatch.py                 # watch (Ctrl+C to stop)
  python3 lockwatch.py snapshot        # show what is blocking right now
  python3 lockwatch.py report          # summarize the log
  python3 lockwatch.py --help
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field, asdict
from datetime import datetime
from pathlib import Path

SYSTEM = platform.system()  # "Darwin", "Windows", "Linux"


# --------------------------------------------------------------------------- #
# Data model
# --------------------------------------------------------------------------- #

@dataclass
class Blocker:
    source: str            # which OS mechanism reported it
    process: str           # process / app name
    pid: int | None
    kind: str              # assertion / request / inhibitor type
    reason: str            # free-text reason the app gave
    blocks_display: bool   # True = keeps the display awake -> prevents lock
    extra: dict = field(default_factory=dict)

    @property
    def key(self) -> str:
        return f"{self.source}|{self.process}|{self.pid}|{self.kind}|{self.reason}"


def _run(cmd: list[str], timeout: float = 10, stderr: bool = False) -> str:
    """Run a command and return stdout (plus stderr if asked); '' on failure."""
    if not shutil.which(cmd[0]):
        return ""
    try:
        kwargs = {}
        if SYSTEM == "Windows":
            kwargs["creationflags"] = 0x08000000  # CREATE_NO_WINDOW
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           errors="replace", **kwargs)
        return p.stdout + (p.stderr if stderr else "")
    except (OSError, subprocess.SubprocessError):
        return ""


# --------------------------------------------------------------------------- #
# macOS
# --------------------------------------------------------------------------- #

# Assertion types that keep the display on (and so stop the screen saver / lock).
MAC_DISPLAY_TYPES = {"PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"}
# Assertion types that only keep the machine awake (display can still sleep/lock).
MAC_SYSTEM_TYPES = {"PreventUserIdleSystemSleep", "NoIdleSleepAssertion",
                    "PreventSystemSleep", "PreventDiskIdle"}

_MAC_LINE = re.compile(
    r"^\s*pid (?P<pid>\d+)\((?P<proc>[^)]*)\):\s*\[[^\]]*\]\s*"
    r"(?P<age>[\d:]+)\s+(?P<type>\S+)\s+named:\s*\"(?P<name>.*)\"\s*$"
)
_MAC_CREATED_FOR = re.compile(r"Created for PID:\s*(\d+)")


def mac_blockers() -> list[Blocker]:
    out = _run(["pmset", "-g", "assertions"])
    blockers: list[Blocker] = []
    last: Blocker | None = None
    for line in out.splitlines():
        m = _MAC_LINE.match(line)
        if m:
            last = None
            kind = m["type"]
            if kind not in MAC_DISPLAY_TYPES | MAC_SYSTEM_TYPES:
                continue
            proc, pid, name = m["proc"], int(m["pid"]), m["name"]
            # powerd's own "prevent sleep while display is on" is a consequence,
            # not a cause.
            if proc == "powerd" and "while display is on" in name:
                continue
            last = Blocker("pmset", proc, pid, kind, name,
                           kind in MAC_DISPLAY_TYPES, {"age": m["age"]})
            blockers.append(last)
            continue
        if last is not None:
            c = _MAC_CREATED_FOR.search(line)
            if c:
                # e.g. coreaudiod holds an assertion on behalf of another app
                cpid = int(c.group(1))
                last.extra["on_behalf_of_pid"] = cpid
                last.extra["on_behalf_of"] = _mac_proc_name(cpid)
    return blockers


def _mac_proc_name(pid: int) -> str:
    out = _run(["ps", "-p", str(pid), "-o", "comm="]).strip()
    return os.path.basename(out) if out else ""


def mac_idle_seconds() -> float | None:
    out = _run(["ioreg", "-c", "IOHIDSystem", "-d", "4"])
    m = re.search(r'"HIDIdleTime"\s*=\s*(\d+)', out)
    return int(m.group(1)) / 1e9 if m else None


# --------------------------------------------------------------------------- #
# Windows
# --------------------------------------------------------------------------- #

WIN_DISPLAY_SECTIONS = {"DISPLAY"}
WIN_SECTIONS = {"DISPLAY", "SYSTEM", "AWAYMODE", "EXECUTION", "PERFBOOST",
                "ACTIVELOCKSCREEN"}


def win_blockers() -> list[Blocker]:
    out = _run(["powercfg", "/requests"])
    if not out:
        return []
    if "DISPLAY:" not in out:
        _warn_once("powercfg /requests failed - run lockwatch from an elevated "
                   "(Run as Administrator) prompt. Output: " + out.strip()[:200])
        return []
    blockers: list[Blocker] = []
    section = None
    pending: tuple[str, str] | None = None  # (type, path)

    def flush(reason: str = ""):
        nonlocal pending
        if pending and section:
            typ, path = pending
            proc = re.split(r"[\\/]", path)[-1] if typ == "PROCESS" else path
            blockers.append(Blocker("powercfg", proc, None, f"{section}/{typ}",
                                    reason, section in WIN_DISPLAY_SECTIONS,
                                    {"path": path}))
        pending = None

    for raw in out.splitlines():
        line = raw.strip()
        if line.rstrip(":") in WIN_SECTIONS and line.endswith(":"):
            flush()
            section = line.rstrip(":")
            continue
        m = re.match(r"^\[(PROCESS|SERVICE|DRIVER)\]\s*(.*)$", line)
        if m:
            flush()
            pending = (m.group(1), m.group(2).strip())
            continue
        if pending:
            flush(line)  # the line after an entry is its reason (may be blank)
    flush()
    return blockers


def win_idle_seconds() -> float | None:
    try:
        import ctypes
        from ctypes import wintypes

        class LASTINPUTINFO(ctypes.Structure):
            _fields_ = [("cbSize", wintypes.UINT), ("dwTime", wintypes.DWORD)]

        lii = LASTINPUTINFO()
        lii.cbSize = ctypes.sizeof(LASTINPUTINFO)
        if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(lii)):
            return None
        now = ctypes.windll.kernel32.GetTickCount() & 0xFFFFFFFF
        return ((now - lii.dwTime) & 0xFFFFFFFF) / 1000.0
    except Exception:
        return None


# --------------------------------------------------------------------------- #
# Linux
# --------------------------------------------------------------------------- #

def _busctl_json(args: list[str]):
    out = _run(["busctl", "--json=short", *args])
    if not out:
        return None
    try:
        return json.loads(out).get("data")
    except ValueError:
        return None


def _proc_comm(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/comm").read_text().strip()
    except OSError:
        return ""


def linux_blockers() -> list[Blocker]:
    blockers: list[Blocker] = []

    # 1. systemd-logind inhibitors (system-wide; "idle" blocks idle lock)
    data = _busctl_json(["call", "org.freedesktop.login1", "/org/freedesktop/login1",
                         "org.freedesktop.login1.Manager", "ListInhibitors"])
    if data:
        for what, who, why, mode, _uid, pid in data[0]:
            if "idle" not in what and "sleep" not in what:
                continue
            blockers.append(Blocker("logind", _proc_comm(pid) or who, pid,
                                    f"{what}/{mode}", f"{who}: {why}",
                                    "idle" in what))

    # 2. GNOME session manager inhibitors (flag 8 = inhibit idle)
    paths = _busctl_json(["--user", "call", "org.gnome.SessionManager",
                          "/org/gnome/SessionManager", "org.gnome.SessionManager",
                          "GetInhibitors"])
    if paths:
        for path in paths[0]:
            def get(method):
                d = _busctl_json(["--user", "call", "org.gnome.SessionManager", path,
                                  "org.gnome.SessionManager.Inhibitor", method])
                return d[0] if d else None
            flags = get("GetFlags") or 0
            if not flags & (8 | 4):  # 8 = idle, 4 = suspend
                continue
            app = get("GetAppId") or "?"
            blockers.append(Blocker("gnome-session", app, None,
                                    f"flags={flags}", get("GetReason") or "",
                                    bool(flags & 8)))

    # 3. KDE Plasma PowerDevil inhibitions
    data = _busctl_json(["--user", "call", "org.kde.Solid.PowerManagement",
                         "/org/kde/Solid/PowerManagement/PolicyAgent",
                         "org.kde.Solid.PowerManagement.PolicyAgent",
                         "ListInhibitions"])
    if data:
        for app, reason in data[0]:
            blockers.append(Blocker("kde-powerdevil", app, None, "inhibit",
                                    reason, True))

    # 4. X11 screensaver/DPMS disabled outright (xset -dpms / s off)
    xset = _run(["xset", "q"]) if os.environ.get("DISPLAY") else ""
    if xset:
        if "DPMS is Disabled" in xset:
            blockers.append(Blocker("xset", "X server", None, "dpms-disabled",
                                    "DPMS is disabled (xset -dpms)", True))
        m = re.search(r"timeout:\s*(\d+)", xset)
        if m and m.group(1) == "0" and "XScreenSaver" not in xset:
            blockers.append(Blocker("xset", "X server", None, "screensaver-off",
                                    "X screensaver timeout is 0 (xset s off)", True))
    return blockers


def linux_idle_seconds() -> float | None:
    d = _busctl_json(["--user", "call", "org.gnome.Mutter.IdleMonitor",
                      "/org/gnome/Mutter/IdleMonitor/Core",
                      "org.gnome.Mutter.IdleMonitor", "GetIdletime"])
    if d:
        return d[0] / 1000.0
    out = _run(["xprintidle"]).strip()
    if out.isdigit():
        return int(out) / 1000.0
    return None


# --------------------------------------------------------------------------- #
# Dispatch
# --------------------------------------------------------------------------- #

_warned: set[str] = set()


def _warn_once(msg: str):
    if msg not in _warned:
        _warned.add(msg)
        print(f"[lockwatch] warning: {msg}", file=sys.stderr)


def get_blockers() -> list[Blocker]:
    if SYSTEM == "Darwin":
        return mac_blockers()
    if SYSTEM == "Windows":
        return win_blockers()
    if SYSTEM == "Linux":
        return linux_blockers()
    _warn_once(f"unsupported platform {SYSTEM}")
    return []


def get_idle_seconds() -> float | None:
    return {"Darwin": mac_idle_seconds, "Windows": win_idle_seconds,
            "Linux": linux_idle_seconds}.get(SYSTEM, lambda: None)()


# --------------------------------------------------------------------------- #
# Lock timeout auto-detection
# --------------------------------------------------------------------------- #

DEFAULT_THRESHOLD = 300.0


def _int(s) -> int | None:
    try:
        return int(str(s).strip())
    except (TypeError, ValueError):
        return None


def mac_lock_timeout() -> tuple[float | None, str]:
    cands = []
    ss = _int(_run(["defaults", "-currentHost", "read", "com.apple.screensaver",
                    "idleTime"]))
    if ss is None:  # never set -> macOS default is 20 min
        ss = 1200
    if ss > 0:
        cands.append((ss, "screen saver"))
    m = re.search(r"^\s*displaysleep\s+(\d+)", _run(["pmset", "-g"]), re.M)
    if m and int(m.group(1)) > 0:
        cands.append((int(m.group(1)) * 60, "display sleep"))
    if not cands:
        return None, "screen saver and display sleep are both off"
    secs, what = min(cands)
    lock = _run(["sysadminctl", "-screenLock", "status"], stderr=True)
    if "is off" in lock:
        _warn_once("macOS 'require password after screen saver' is off; the screen never locks.")
    m = re.search(r"delay is (\d+) seconds", lock)
    if m:
        secs += int(m.group(1))
        what += f" + {m.group(1)}s lock delay"
    return float(secs), what


def win_lock_timeout() -> tuple[float | None, str]:
    cands = []
    try:
        import winreg
        for root, path in ((winreg.HKEY_CURRENT_USER,
                            r"Software\Policies\Microsoft\Windows\Control Panel\Desktop"),
                           (winreg.HKEY_CURRENT_USER, r"Control Panel\Desktop")):
            try:
                with winreg.OpenKey(root, path) as k:
                    def val(name):
                        try:
                            return winreg.QueryValueEx(k, name)[0]
                        except OSError:
                            return None
                    t = _int(val("ScreenSaveTimeOut"))
                    if str(val("ScreenSaveActive")) != "0" and t:
                        cands.append((t, "screen saver"))
                        break
            except OSError:
                continue
        try:
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                                r"SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System") as k:
                t = _int(winreg.QueryValueEx(k, "InactivityTimeoutSecs")[0])
                if t:
                    cands.append((t, "inactivity policy"))
        except OSError:
            pass
    except ImportError:
        pass
    # Display-off timeout; the last two hex values are the AC and DC settings.
    vals = re.findall(r":\s*0x([0-9a-fA-F]{8})\s*$",
                      _run(["powercfg", "/q", "SCHEME_CURRENT", "SUB_VIDEO", "VIDEOIDLE"]),
                      re.M)[-2:]
    for v in vals:
        if int(v, 16) > 0:
            cands.append((int(v, 16), "display off"))
    if not cands:
        return None, "no screen saver, inactivity policy or display-off timeout"
    secs, what = min(cands)
    return float(secs), what


def _gs(schema: str, key: str) -> str:
    """gsettings value without its type prefix/quotes ('uint32 300' -> '300')."""
    parts = _run(["gsettings", "get", schema, key]).split()
    return parts[-1].strip("'") if parts else ""


def linux_lock_timeout() -> tuple[float | None, str]:
    idle = _int(_gs("org.gnome.desktop.session", "idle-delay"))
    if idle:
        if _gs("org.gnome.desktop.screensaver", "lock-enabled") == "false":
            _warn_once("GNOME screen lock is turned off (Settings > Privacy > Screen Lock).")
        delay = _int(_gs("org.gnome.desktop.screensaver", "lock-delay")) or 0
        return float(idle + delay), "GNOME idle delay" + (f" + {delay}s lock delay" if delay else "")
    idle = _int(_gs("org.cinnamon.desktop.session", "idle-delay"))
    if idle:
        return float(idle), "Cinnamon idle delay"
    for tool in ("kreadconfig6", "kreadconfig5"):
        if shutil.which(tool):
            args = [tool, "--file", "kscreenlockerrc", "--group", "Daemon", "--key"]
            if _run(args + ["Autolock"]).strip() == "false":
                _warn_once("KDE automatic screen locking is turned off.")
            mins = _int(_run(args + ["Timeout"])) or 5  # Plasma default
            return float(mins * 60), "KDE screen locker"
    if os.environ.get("DISPLAY"):
        m = re.search(r"timeout:\s*(\d+)", _run(["xset", "q"]))
        if m and int(m.group(1)) > 0:
            return float(m.group(1)), "X11 screensaver"
    return None, "could not read desktop lock settings"


def detect_lock_timeout() -> tuple[float, str]:
    """Return (seconds idle before the screen should lock, where it came from)."""
    fn = {"Darwin": mac_lock_timeout, "Windows": win_lock_timeout,
          "Linux": linux_lock_timeout}.get(SYSTEM)
    secs, what = fn() if fn else (None, "unsupported OS")
    if secs is None:
        _warn_once(f"lock timeout not detected ({what}); using {int(DEFAULT_THRESHOLD)}s. "
                   "Pass --idle-threshold to set it.")
        return DEFAULT_THRESHOLD, f"default ({what})"
    return secs, what


def default_log_path() -> Path:
    home = Path.home()
    if SYSTEM == "Darwin":
        base = home / "Library" / "Logs" / "lockwatch"
    elif SYSTEM == "Windows":
        base = Path(os.environ.get("LOCALAPPDATA", home)) / "lockwatch"
    else:
        base = Path(os.environ.get("XDG_STATE_HOME", home / ".local" / "state")) / "lockwatch"
    return base / "lockwatch.jsonl"


# --------------------------------------------------------------------------- #
# Watch loop
# --------------------------------------------------------------------------- #

def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _fmt_dur(sec: float) -> str:
    sec = int(sec)
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    return f"{h}h{m:02d}m{s:02d}s" if h else f"{m}m{s:02d}s"


def _label(b: Blocker) -> str:
    who = b.process
    if b.extra.get("on_behalf_of"):
        who += f" (for {b.extra['on_behalf_of']})"
    pid = f" pid {b.pid}" if b.pid else ""
    return f"{who}{pid} [{b.kind}] {b.reason}"


class Watcher:
    def __init__(self, log_path: Path, interval: float, idle_threshold: float,
                 include_system: bool, quiet: bool):
        self.log_path = log_path
        self.interval = interval
        self.auto_threshold = idle_threshold is None
        self.threshold_checked = 0.0
        self.idle_threshold = DEFAULT_THRESHOLD if idle_threshold is None else idle_threshold
        self.threshold_source = "auto" if self.auto_threshold else "--idle-threshold"
        self.include_system = include_system
        self.quiet = quiet
        self.active: dict[str, dict] = {}  # key -> state
        log_path.parent.mkdir(parents=True, exist_ok=True)

    def write(self, event: str, b: Blocker | None = None, **fields):
        rec = {"time": _now(), "event": event, "host": platform.node(), **fields}
        if b is not None:
            rec["blocker"] = asdict(b)
        with self.log_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")
        if not self.quiet:
            desc = _label(b) if b else ""
            extra = " ".join(f"{k}={v}" for k, v in fields.items())
            print(f"{rec['time']}  {event.upper():8} {desc}  {extra}".rstrip(), flush=True)

    def poll(self):
        idle = get_idle_seconds()
        blockers = [b for b in get_blockers() if b.blocks_display or self.include_system]
        now = time.time()
        self._refresh_threshold(now)
        seen = set()
        for b in blockers:
            seen.add(b.key)
            st = self.active.get(b.key)
            if st is None:
                st = self.active[b.key] = {"blocker": b, "start": now,
                                           "max_idle": 0.0, "flagged": False}
                self.write("start", b)
            st["blocker"] = b
            if idle is not None:
                st["max_idle"] = max(st["max_idle"], idle)
                if (b.blocks_display and not st["flagged"]
                        and idle >= self.idle_threshold):
                    st["flagged"] = True
                    self.write("flagged", b, idle_seconds=round(idle))
        for key in list(self.active):
            if key not in seen:
                self._end(key, now)

    def _refresh_threshold(self, now: float):
        """Re-read the OS lock timeout every 10 minutes (settings can change)."""
        if not self.auto_threshold or now - self.threshold_checked < 600:
            return
        first = self.threshold_checked == 0
        self.threshold_checked = now
        secs, src = detect_lock_timeout()
        if first or secs != self.idle_threshold:
            self.idle_threshold, self.threshold_source = secs, src
            self.write("threshold", idle_threshold=round(secs), source=src)

    def _end(self, key: str, now: float, still_active: bool = False):
        st = self.active.pop(key)
        extra = {"still_active": True} if still_active else {}
        self.write("end", st["blocker"],
                   duration_seconds=round(now - st["start"]),
                   max_idle_seconds=round(st["max_idle"]),
                   flagged=st["flagged"], **extra)

    def stop(self):
        now = time.time()
        for key in list(self.active):
            self._end(key, now, still_active=True)
        self.write("stopped")

    def run(self):
        self.write("started", os=SYSTEM, interval=self.interval,
                   idle_threshold="auto" if self.auto_threshold else self.idle_threshold)
        if get_idle_seconds() is None:
            _warn_once("could not read idle time; 'flagged' events will not be recorded.")
        try:
            while True:
                self.poll()
                time.sleep(self.interval)
        except KeyboardInterrupt:
            pass
        finally:
            self.stop()


# --------------------------------------------------------------------------- #
# Report
# --------------------------------------------------------------------------- #

def report(log_path: Path):
    if not log_path.exists():
        print(f"No log at {log_path}")
        return
    stats: dict[str, dict] = {}
    open_since: dict[str, tuple[str, datetime]] = {}  # blocker key -> (name, start)
    carried: set[str] = set()  # still active when lockwatch stopped/restarted
    first = last = None
    for line in log_path.open(encoding="utf-8"):
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        first = first or rec["time"]
        last = rec["time"]
        b = rec.get("blocker")
        if not b:
            continue
        name = b["process"]
        if b.get("extra", {}).get("on_behalf_of"):
            name += f" (for {b['extra']['on_behalf_of']})"
        s = stats.setdefault(name, {"sessions": 0, "seconds": 0, "flagged": 0,
                                    "display": False, "reasons": set(),
                                    "active": False})
        key = f"{b['source']}|{b['process']}|{b['pid']}|{b['kind']}|{b['reason']}"
        s["display"] |= b["blocks_display"]
        if b["reason"]:
            s["reasons"].add(b["reason"][:80])
        if rec["event"] == "start":
            # A blocker that was still active when lockwatch restarted is the
            # same occurrence, not a new one.
            if key in carried:
                carried.discard(key)
            else:
                s["sessions"] += 1
            open_since[key] = (name, datetime.fromisoformat(rec["time"]))
        elif rec["event"] == "end":
            s["seconds"] += rec.get("duration_seconds", 0)
            open_since.pop(key, None)
            if rec.get("still_active"):
                carried.add(key)
        elif rec["event"] == "flagged":
            s["flagged"] += 1

    # Blockers still active at the end of the log count up to the last entry.
    if last:
        end = datetime.fromisoformat(last)
        for name, start in open_since.values():
            stats[name]["seconds"] += max(0, (end - start).total_seconds())
            stats[name]["active"] = True

    print(f"Log: {log_path}\nPeriod: {first}  ->  {last}\n")
    if not stats:
        print("Nothing has blocked the screen from locking.")
        return
    rows = sorted(stats.items(), key=lambda kv: (-kv[1]["flagged"], -kv[1]["seconds"]))
    print(f"{'PROCESS':40} {'BLOCKS LOCK':11} {'FLAGGED':>7} {'TIMES':>5} {'TOTAL TIME':>11}")
    print("-" * 78)
    for name, s in rows:
        print(f"{name[:40]:40} {'yes' if s['display'] else 'no (sleep)':11} "
              f"{s['flagged']:>7} {s['sessions']:>5} {_fmt_dur(s['seconds']):>11}"
              f"{'  (active now)' if s['active'] else ''}")
    print("\nFLAGGED = times it was holding the screen awake after you'd been idle "
          "past the threshold.\nReasons given:")
    for name, s in rows:
        for r in sorted(s["reasons"]):
            print(f"  {name[:30]}: {r}")


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def snapshot(include_system: bool):
    idle = get_idle_seconds()
    lock, src = detect_lock_timeout()
    print(f"OS: {SYSTEM}   idle: {_fmt_dur(idle) if idle is not None else 'unknown'}"
          f"   screen should lock after: {_fmt_dur(lock)} ({src})\n")
    bl = get_blockers()
    shown = [b for b in bl if b.blocks_display or include_system]
    if not shown:
        print("Nothing is currently preventing the screen from locking.")
    for b in shown:
        tag = "BLOCKS LOCK " if b.blocks_display else "keeps awake "
        print(f"  {tag} {_label(b)}")
    hidden = len(bl) - len(shown)
    if hidden:
        print(f"\n({hidden} system-sleep-only assertion(s) hidden; use --all to show)")


def main(argv=None):
    p = argparse.ArgumentParser(description="Record what stops the screen from locking.")
    p.add_argument("command", nargs="?", default="watch",
                   choices=["watch", "snapshot", "report"])
    p.add_argument("--log", type=Path, default=default_log_path(),
                   help="log file (default: %(default)s)")
    p.add_argument("--interval", type=float, default=15,
                   help="seconds between checks (default: 15)")
    p.add_argument("--idle-threshold", default="auto",
                   help="seconds idle after which your screen should have locked, or "
                        "'auto' to read this machine's lock settings (default: auto)")
    p.add_argument("--all", action="store_true",
                   help="also record things that only prevent system sleep "
                        "(not the display/lock)")
    p.add_argument("--quiet", action="store_true", help="don't print events to stdout")
    a = p.parse_args(argv)
    if str(a.idle_threshold).lower() == "auto":
        a.idle_threshold = None
    else:
        try:
            a.idle_threshold = float(a.idle_threshold)
        except ValueError:
            p.error("--idle-threshold must be a number of seconds or 'auto'")

    # Under pythonw.exe (Windows, no console) stdout/stderr are None; send
    # anything printed to a file next to the log instead of crashing.
    if sys.stdout is None or sys.stderr is None:
        a.log.parent.mkdir(parents=True, exist_ok=True)
        sink = open(a.log.parent / "stderr.log", "a", encoding="utf-8", buffering=1)
        sys.stdout = sys.stdout or sink
        sys.stderr = sys.stderr or sink

    if a.command == "snapshot":
        snapshot(a.all)
    elif a.command == "report":
        report(a.log)
    else:
        if SYSTEM != "Windows":
            def _on_term(*_):
                raise KeyboardInterrupt
            signal.signal(signal.SIGTERM, _on_term)
        if not a.quiet:
            print(f"lockwatch: logging to {a.log}  (Ctrl+C to stop)", flush=True)
        Watcher(a.log, a.interval, a.idle_threshold, a.all, a.quiet).run()


if __name__ == "__main__":
    main()
