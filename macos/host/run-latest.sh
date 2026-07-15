#!/usr/bin/env bash
# Sign and (re)launch the newest .app the guest shipped into incoming/. Invoked by watch.sh or
# the launchd agent whenever the guest touches incoming/run.trigger; also safe to run by hand.
set -euo pipefail
EXPORT=${WT_MAC_EXPORT:-$HOME/wt-export}
INCOMING="$EXPORT/incoming"; LOGS="$EXPORT/logs"
mkdir -p "$LOGS/crashes"

# Newest bundle wins. The ship script stages then renames, so any bundle visible here is whole.
BUNDLE=$(ls -td "$INCOMING"/*.app 2>/dev/null | head -1 || true)
[ -n "$BUNDLE" ] || exit 0
APP=$(basename "$BUNDLE" .app)

# Belt and braces, both verified 2026-07: virtiofs writes carry no quarantine xattr, and zig's
# embedded ad-hoc signature already verifies — but those are observed behaviors, not contracts.
xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true
if ! codesign --force -s - "$BUNDLE"; then
  echo "$(date) codesign FAILED for $APP" >> "$LOGS/agent.log"
  exit 1
fi

# Replace, don't stack: kill the previous instance of exactly this bundle's binary.
pkill -f "$BUNDLE/Contents/MacOS/" 2>/dev/null && sleep 0.4 || true

: > "$LOGS/stdout.log"; : > "$LOGS/stderr.log"
open -n "$BUNDLE" --stdout "$LOGS/stdout.log" --stderr "$LOGS/stderr.log"
echo "$(date) launched $APP" >> "$LOGS/agent.log"

# This app's crash reports, where the guest can read them.
rsync -a --include="$APP-*.ips" --exclude='*' \
  "$HOME/Library/Logs/DiagnosticReports/" "$LOGS/crashes/" 2>/dev/null || true
