#!/bin/bash
# UxPlay.app main executable (CFBundleExecutable).
#
# UxPlay prints a one-time PIN and status messages to its terminal, so the
# app must run inside a terminal window.  When launched from Finder (no TTY)
# this opens Terminal.app running Contents/Resources/run-uxplay.sh; when run
# from a shell it just execs the runner directly so arguments pass through.

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$(cd "$HERE/../Resources" && pwd)/run-uxplay.sh"

if [ -t 1 ]; then
    exec "$RUNNER" "$@"
fi

if ! open -a Terminal "$RUNNER"; then
    # Fallback if `open` refuses (e.g. Terminal not the default handler).
    exec osascript \
        -e "tell application \"Terminal\" to do script \"'$RUNNER'\"" \
        -e 'tell application "Terminal" to activate'
fi
