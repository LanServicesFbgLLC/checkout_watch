#!/bin/bash
# Install lockwatch on macOS as a LaunchAgent that starts at login.
#
#   ./install-macos.sh                       # just you (no sudo)
#   sudo ./install-macos.sh --system         # every user on this Mac
#   ./install-macos.sh --idle-threshold 600  # override the detected lock timeout
#   ./install-macos.sh --uninstall           # (sudo ... --system --uninstall for all users)
#
# Uses the portable files in deploy/macos/. --system installs them unchanged:
#   /Library/Application Support/lockwatch/{lockwatch.py,run.sh}
#   /Library/LaunchAgents/com.lanservicesfbg.lockwatch.plist
# which is the same layout you'd push with an MDM. The default (per-user)
# install puts the same files under ~/Library instead.
#
# Logs: ~/Library/Logs/lockwatch/lockwatch.jsonl for each user.

set -euo pipefail

LABEL=com.lanservicesfbg.lockwatch
SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SYS_DIR="/Library/Application Support/lockwatch"

MODE=user
THRESHOLD=""
UNINSTALL=0

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die()   { echo "error: $*" >&2; exit 1; }
info()  { echo "==> $*"; }
warn()  { echo "warning: $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --system)         MODE=system ;;
    --user)           MODE=user ;;
    --idle-threshold) THRESHOLD=${2:?}; shift ;;
    --uninstall)      UNINSTALL=1 ;;
    -h|--help)        usage 0 ;;
    *)                echo "unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

[[ "$(uname -s)" == Darwin ]] || die "this installer is for macOS."
[[ -z $THRESHOLD || $THRESHOLD =~ ^[0-9]+$ ]] || die "--idle-threshold must be a number of seconds"

# The user whose GUI session we load the agent into right now.
CONSOLE_UID=$(stat -f %u /dev/console)
CONSOLE_USER=$(stat -f %Su /dev/console)

if [[ $MODE == system ]]; then
  [[ $EUID -eq 0 ]] || die "--system needs root: sudo $0 --system"
  DIR=$SYS_DIR
  PLIST=/Library/LaunchAgents/$LABEL.plist
  TARGET_UID=$CONSOLE_UID
else
  [[ $EUID -ne 0 ]] || die "run without sudo to install for yourself, or add --system for all users."
  DIR="$HOME/Library/Application Support/lockwatch"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  TARGET_UID=$(id -u)
fi

# launchctl in the target user's GUI session (root must use asuser for bootstrap).
lctl() {
  if [[ $EUID -eq 0 ]]; then launchctl asuser "$TARGET_UID" launchctl "$@"; else launchctl "$@"; fi
}
unload() {  # $1 = plist path
  [[ $TARGET_UID -ne 0 ]] || return 0
  lctl bootout "gui/$TARGET_UID/$LABEL" 2>/dev/null || true
}
load() {
  if [[ $TARGET_UID -eq 0 ]]; then
    echo "No one is logged in at the console; it will start at the next login."
    return
  fi
  lctl bootstrap "gui/$TARGET_UID" "$PLIST"
  sleep 3
  if lctl print "gui/$TARGET_UID/$LABEL" 2>/dev/null | grep -q 'state = running'; then
    info "running for $( [[ $MODE == system ]] && echo "$CONSOLE_USER" || id -un )"
  else
    warn "loaded but not running yet; see ~/Library/Logs/lockwatch/stderr.log"
  fi
}

# --------------------------------------------------------------------------- #
# Uninstall
# --------------------------------------------------------------------------- #
if [[ $UNINSTALL -eq 1 ]]; then
  unload
  [[ -f $PLIST ]] && rm -f "$PLIST" && info "removed $PLIST"
  [[ -d $DIR ]] && rm -rf "$DIR" && info "removed $DIR"
  [[ $MODE == system ]] && echo "Other logged-in users stop at their next logout."
  echo "lockwatch uninstalled. Logs in ~/Library/Logs/lockwatch were kept."
  exit 0
fi

for f in lockwatch.py deploy/macos/run.sh deploy/macos/$LABEL.plist; do
  [[ -f $SRC_DIR/$f ]] || die "missing $f (run this from the lockwatch folder)."
done

# A per-user and an all-users copy would share the same label and clash.
if [[ $MODE == user && -f /Library/LaunchAgents/$LABEL.plist ]]; then
  die "lockwatch is already installed for all users; remove that first (sudo $0 --system --uninstall)."
fi
if [[ $MODE == system ]]; then
  for home in /Users/*; do
    old="$home/Library/LaunchAgents/$LABEL.plist"
    if [[ -f $old ]]; then
      owner_uid=$(stat -f %u "$old")
      launchctl asuser "$owner_uid" launchctl bootout "gui/$owner_uid/$LABEL" 2>/dev/null || true
      rm -f "$old"
      rm -rf "$home/Library/Application Support/lockwatch"
      info "removed per-user install for $(basename "$home") (replaced by the all-users install)"
    fi
  done
fi

# --------------------------------------------------------------------------- #
# Python check (same search order as run.sh)
# --------------------------------------------------------------------------- #
PY=""
for p in /opt/homebrew/bin/python3 /usr/local/bin/python3 \
         /Library/Frameworks/Python.framework/Versions/Current/bin/python3; do
  [[ -x $p ]] && PY=$p && break
done
if [[ -z $PY ]] && xcode-select -p >/dev/null 2>&1 && [[ -x /usr/bin/python3 ]]; then
  PY=/usr/bin/python3
fi
if [[ -n $PY ]]; then
  info "using $($PY --version 2>&1) at $PY"
else
  warn "no Python 3 found. lockwatch is installed but won't run until you install one of:"
  warn "  xcode-select --install   |   brew install python   |   https://www.python.org/downloads/macos/"
  warn "then log out and back in (or run this installer again)."
fi

# --------------------------------------------------------------------------- #
# Install
# --------------------------------------------------------------------------- #
unload
mkdir -p "$DIR" "$(dirname "$PLIST")"
install -m 755 "$SRC_DIR/lockwatch.py" "$DIR/lockwatch.py"
install -m 755 "$SRC_DIR/deploy/macos/run.sh" "$DIR/run.sh"
[[ -f $SRC_DIR/README.md ]] && install -m 644 "$SRC_DIR/README.md" "$DIR/README.md"
xattr -cr "$DIR" 2>/dev/null || true   # drop download quarantine flags
info "installed to $DIR"

if [[ $MODE == system ]]; then
  install -m 644 "$SRC_DIR/deploy/macos/$LABEL.plist" "$PLIST"
  chown -R root:wheel "$DIR" "$PLIST"
else
  # Same file, pointed at the per-user folder.
  sed "s|$SYS_DIR|$DIR|g" "$SRC_DIR/deploy/macos/$LABEL.plist" > "$PLIST"
  chmod 644 "$PLIST"
fi
if [[ -n $THRESHOLD ]]; then
  plutil -insert ProgramArguments.2 -string --idle-threshold "$PLIST"
  plutil -insert ProgramArguments.3 -string "$THRESHOLD" "$PLIST"
  info "idle threshold: $THRESHOLD seconds"
else
  info "idle threshold: auto (read from each Mac's screen saver / display sleep settings)"
fi
plutil -lint "$PLIST" >/dev/null
info "installed $PLIST"

load

echo
echo "Done. Log:    ~/Library/Logs/lockwatch/lockwatch.jsonl"
echo "      Report: python3 \"$DIR/lockwatch.py\" report"
if [[ $MODE == system ]]; then
  echo "      Remove: sudo $0 --system --uninstall"
else
  echo "      Remove: $0 --uninstall"
fi
