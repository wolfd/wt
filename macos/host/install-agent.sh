#!/usr/bin/env bash
# Render and load the launchd agent that runs run-latest.sh on every guest ship. A LaunchAgent,
# not a Daemon: `open` needs the Aqua session, which only gui/<uid> has.
set -euo pipefail
SELF=$(cd "$(dirname "$0")" && pwd)
EXPORT=${WT_MAC_EXPORT:-$HOME/wt-export}
LABEL=dev.wt.mac-runner
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$HOME/Library/LaunchAgents" "$EXPORT/incoming" "$EXPORT/logs"
touch "$EXPORT/incoming/run.trigger"

sed -e "s|@RUN_LATEST@|$SELF/run-latest.sh|g" \
    -e "s|@EXPORT@|$EXPORT|g" \
    -e "s|@TRIGGER@|$EXPORT/incoming/run.trigger|g" \
    -e "s|@LOG@|$EXPORT/logs/agent-launchd.log|g" \
    "$SELF/wt-runner.plist.in" > "$PLIST"

# Reload if already present; bootout of a not-loaded label is the expected no-op.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL — every guest ship now relaunches the app (uninstall: launchctl bootout gui/$(id -u)/$LABEL)"
