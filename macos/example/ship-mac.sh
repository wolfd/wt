#!/usr/bin/env bash
# Ship-script template — copy into your project (e.g. scripts/ship-mac.sh) and set the SHIP_*
# defaults for your app. Builds for aarch64-apple-darwin, assembles the bundle in a hidden
# staging dir, and RENAMES it into incoming/ — the rename is the publish, so the host agent
# can never see a half-written bundle — then touches run.trigger to wake the agent.
set -euo pipefail
APP=${SHIP_APP:-Hello}          # bundle name: <APP>.app
BIN=${SHIP_BIN:-hello-mac}      # cargo binary name
EXPORT=${SHIP_EXPORT:-/export}  # the virtiofs handoff mount

PROFILE=${1:---release}
case "$PROFILE" in
  --dev)
    cargo zigbuild --target aarch64-apple-darwin
    OUT=target/aarch64-apple-darwin/debug/$BIN ;;
  --release)
    cargo zigbuild --release --target aarch64-apple-darwin
    OUT=target/aarch64-apple-darwin/release/$BIN ;;
  *)
    echo "usage: ship-mac.sh [--dev|--release]" >&2; exit 2 ;;
esac

STAGE="$EXPORT/incoming/.stage.$$"
rm -rf "$STAGE"
mkdir -p "$STAGE/$APP.app/Contents/MacOS"
cp "$OUT" "$STAGE/$APP.app/Contents/MacOS/$APP"
cp packaging/Info.plist "$STAGE/$APP.app/Contents/Info.plist"
rm -rf "${EXPORT:?}/incoming/$APP.app"
mv "$STAGE/$APP.app" "$EXPORT/incoming/$APP.app"
rm -rf "$STAGE"
date +%s%N > "$EXPORT/incoming/run.trigger"
echo "shipped $APP.app — the host agent relaunches it now" >&2
