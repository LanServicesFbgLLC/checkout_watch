#!/usr/bin/env bash
# Install lockwatch on Linux so it starts with your desktop session.
#
#   ./install-linux.sh                     # current user (no root needed)
#   ./install-linux.sh --idle-threshold 600
#   sudo ./install-linux.sh --system       # every user on this machine
#   ./install-linux.sh --uninstall         # (sudo ... --system --uninstall for system-wide)
#
# Uses the portable files in deploy/linux/. --system installs them unchanged:
#   /usr/local/lib/lockwatch/lockwatch.py
#   /etc/xdg/autostart/lockwatch.desktop   (or /etc/systemd/user/lockwatch.service)
# which is the same layout you'd push with Ansible/RMM. The default
# (per-user) install puts the same files under ~/.local and ~/.config.
#
# How it starts (--method):
#   systemd   - systemd *user* service tied to graphical-session.target,
#               restarts on failure (GNOME, KDE Plasma 5.25+, ...).
#   autostart - XDG autostart entry; works on any desktop (XFCE, MATE, ...).
#   auto      - (default) systemd for a per-user install when the graphical
#               session target is active, otherwise autostart.
#
# The lock timeout is read from each user's desktop settings at runtime;
# --idle-threshold overrides it. Logs: ~/.local/state/lockwatch/lockwatch.jsonl

set -euo pipefail

NAME=lockwatch
SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC="$SRC_DIR/lockwatch.py"
SYS_PREFIX=/usr/local/lib/$NAME

MODE=user
METHOD=auto
THRESHOLD=""
UNINSTALL=0
YES=0

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die()   { echo "error: $*" >&2; exit 1; }
info()  { echo "==> $*"; }
warn()  { echo "warning: $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --system)          MODE=system ;;
    --user)            MODE=user ;;
    --method)          METHOD=${2:?}; shift ;;
    --idle-threshold)  THRESHOLD=${2:?}; shift ;;
    --uninstall)       UNINSTALL=1 ;;
    -y|--yes)          YES=1 ;;
    -h|--help)         usage 0 ;;
    *)                 echo "unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

[[ "$(uname -s)" == Linux ]] || die "this installer is for Linux."
case "$METHOD" in auto|systemd|autostart) ;; *) die "--method must be auto, systemd or autostart" ;; esac
[[ -z "$THRESHOLD" || "$THRESHOLD" =~ ^[0-9]+$ ]] || die "--idle-threshold must be a number of seconds"

if [[ $MODE == system ]]; then
  [[ $EUID -eq 0 ]] || die "--system needs root: sudo $0 --system $*"
  PREFIX=$SYS_PREFIX
  UNIT_DIR=/etc/systemd/user
  AUTOSTART_DIR=/etc/xdg/autostart
else
  [[ $EUID -ne 0 ]] || die "run without sudo to install for yourself, or add --system for all users."
  PREFIX=${XDG_DATA_HOME:-$HOME/.local/share}/$NAME
  UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
  AUTOSTART_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/autostart
fi
UNIT="$UNIT_DIR/$NAME.service"
DESKTOP="$AUTOSTART_DIR/$NAME.desktop"
SCRIPT="$PREFIX/lockwatch.py"

have() { command -v "$1" >/dev/null 2>&1; }
user_systemd_ok() { have systemctl && systemctl --user show-environment >/dev/null 2>&1; }

stop_running() {
  pkill -u "$(id -u)" -f "$NAME/lockwatch.py" 2>/dev/null || true
}

# --------------------------------------------------------------------------- #
# Uninstall
# --------------------------------------------------------------------------- #
if [[ $UNINSTALL -eq 1 ]]; then
  if [[ -f $UNIT ]]; then
    if [[ $MODE == system ]]; then
      systemctl --global disable "$NAME.service" 2>/dev/null || true
    elif user_systemd_ok; then
      systemctl --user disable --now "$NAME.service" 2>/dev/null || true
    fi
    rm -f "$UNIT"
    [[ $MODE == user ]] && user_systemd_ok && systemctl --user daemon-reload
    info "removed $UNIT"
  fi
  [[ -f $DESKTOP ]] && rm -f "$DESKTOP" && info "removed $DESKTOP"
  [[ $MODE == user ]] && stop_running
  [[ -d $PREFIX ]] && rm -rf "$PREFIX" && info "removed $PREFIX"
  [[ $MODE == system ]] && echo "Running copies stop at each user's next logout."
  echo "lockwatch uninstalled. Logs in ~/.local/state/lockwatch were kept."
  exit 0
fi

for f in "$SRC" "$SRC_DIR/deploy/linux/$NAME.service" "$SRC_DIR/deploy/linux/$NAME.desktop"; do
  [[ -f $f ]] || die "missing $f (run this from the lockwatch folder)."
done

# --------------------------------------------------------------------------- #
# Python
# --------------------------------------------------------------------------- #
python_ok() { have python3 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null; }

if ! python_ok; then
  warn "Python 3.8+ was not found."
  cmd=""
  if   have apt-get; then cmd="apt-get install -y python3"
  elif have dnf;     then cmd="dnf install -y python3"
  elif have yum;     then cmd="yum install -y python3"
  elif have pacman;  then cmd="pacman -S --noconfirm python"
  elif have zypper;  then cmd="zypper --non-interactive install python3"
  elif have apk;     then cmd="apk add python3"
  fi
  [[ -n $cmd ]] || die "install Python 3 with your package manager, then run this again."
  if [[ $YES -eq 0 ]]; then
    read -r -p "Install it now with 'sudo $cmd'? [y/N] " ans
    [[ $ans =~ ^[Yy] ]] || die "install Python 3, then run this again."
  fi
  if [[ $EUID -eq 0 ]]; then $cmd; else sudo $cmd; fi
  python_ok || die "Python 3 still not found."
fi
info "using $(python3 --version) at $(command -v python3)"
have busctl || warn "busctl not found; lockwatch needs it to read inhibitors (it ships with systemd)."

# --------------------------------------------------------------------------- #
# Pick start method
# --------------------------------------------------------------------------- #
if [[ $METHOD == auto ]]; then
  if [[ $MODE == user ]] && user_systemd_ok &&
     systemctl --user is-active --quiet graphical-session.target; then
    METHOD=systemd
  else
    METHOD=autostart
  fi
fi
if [[ $METHOD == systemd && $MODE == user ]] && ! user_systemd_ok; then
  die "systemd user services aren't available in this session; use --method autostart."
fi
info "start method: $METHOD"

# --------------------------------------------------------------------------- #
# Install
# --------------------------------------------------------------------------- #
install -d -m 755 "$PREFIX"
install -m 755 "$SRC" "$SCRIPT"
[[ -f $SRC_DIR/README.md ]] && install -m 644 "$SRC_DIR/README.md" "$PREFIX/README.md"
info "installed $SCRIPT"

# Render a deploy/linux template: point it at $PREFIX, add --idle-threshold if given.
render() {
  local extra=""
  [[ -n $THRESHOLD ]] && extra=" --idle-threshold $THRESHOLD"
  sed -e "s|$SYS_PREFIX|$PREFIX|g" -e "s|lockwatch.py --quiet\$|lockwatch.py --quiet$extra|" "$1"
}
EXEC="/usr/bin/env python3 $SCRIPT --quiet${THRESHOLD:+ --idle-threshold $THRESHOLD}"
if [[ -n $THRESHOLD ]]; then info "idle threshold: $THRESHOLD seconds"
else info "idle threshold: auto (read from each user's desktop lock settings)"; fi

# Remove whichever method we're *not* using, so it never runs twice.
if [[ $METHOD == systemd ]]; then
  rm -f "$DESKTOP"
  install -d "$UNIT_DIR"
  render "$SRC_DIR/deploy/linux/$NAME.service" > "$UNIT"
  chmod 644 "$UNIT"
  info "wrote $UNIT"
  if [[ $MODE == system ]]; then
    systemctl --global enable "$NAME.service"
    echo "Enabled for all users; it starts at each user's next login."
  else
    stop_running
    systemctl --user daemon-reload
    systemctl --user enable --now "$NAME.service"
    sleep 2
    systemctl --user --no-pager --lines=0 status "$NAME.service" || true
  fi
else
  if [[ -f $UNIT ]]; then
    if [[ $MODE == system ]]; then systemctl --global disable "$NAME.service" 2>/dev/null || true
    elif user_systemd_ok; then systemctl --user disable --now "$NAME.service" 2>/dev/null || true; fi
    rm -f "$UNIT"
  fi
  install -d "$AUTOSTART_DIR"
  render "$SRC_DIR/deploy/linux/$NAME.desktop" > "$DESKTOP"
  chmod 644 "$DESKTOP"
  info "wrote $DESKTOP"
  if [[ $MODE == system ]]; then
    echo "Installed for all users; it starts at each user's next login."
  elif [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
    stop_running
    # shellcheck disable=SC2086
    nohup $EXEC >/dev/null 2>&1 &
    disown
    info "started now (pid $!)"
  else
    echo "No desktop session detected; it will start at your next desktop login."
  fi
fi

echo
echo "Done. Log:    ~/.local/state/lockwatch/lockwatch.jsonl"
echo "      Report: python3 $SCRIPT report"
if [[ $MODE == system ]]; then echo "      Remove: sudo $0 --system --uninstall"
else echo "      Remove: $0 --uninstall"; fi
