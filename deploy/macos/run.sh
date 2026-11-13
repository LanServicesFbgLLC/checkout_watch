#!/bin/sh
# Starts lockwatch with whichever Python 3 this Mac has. Any arguments are
# passed through to lockwatch.py (e.g. --idle-threshold 600).
DIR=$(cd "$(dirname "$0")" && pwd)
LOGDIR="$HOME/Library/Logs/lockwatch"
mkdir -p "$LOGDIR"
exec 2>>"$LOGDIR/stderr.log"

for py in /opt/homebrew/bin/python3 /usr/local/bin/python3 \
          /Library/Frameworks/Python.framework/Versions/Current/bin/python3; do
  [ -x "$py" ] && exec "$py" "$DIR/lockwatch.py" --quiet "$@"
done
# /usr/bin/python3 is only a stub that pops an installer unless the Xcode
# Command Line Tools are installed, so only use it when they are.
if xcode-select -p >/dev/null 2>&1 && [ -x /usr/bin/python3 ]; then
  exec /usr/bin/python3 "$DIR/lockwatch.py" --quiet "$@"
fi
echo "$(date '+%F %T') lockwatch: no Python 3 found; install it (brew install python, python.org, or xcode-select --install)." >&2
exit 0
