#!/usr/bin/env bash
# Foreground watcher: relaunch on every guest ship. The launchd agent (install-agent.sh) is the
# hands-off alternative; this one is for a visible terminal tab you can ctrl-C.
set -euo pipefail
SELF=$(cd "$(dirname "$0")" && pwd)
EXPORT=${WT_MAC_EXPORT:-$HOME/wt-export}
command -v fswatch >/dev/null 2>&1 \
  || { echo "fswatch not found — nix profile install nixpkgs#fswatch" >&2; exit 1; }
mkdir -p "$EXPORT/incoming"
touch "$EXPORT/incoming/run.trigger"
echo "watching $EXPORT/incoming/run.trigger" >&2
fswatch -o "$EXPORT/incoming/run.trigger" | while read -r _; do "$SELF/run-latest.sh"; done
