#!/usr/bin/env bash
# Mac-side bootstrap for the cross-build loop. Idempotent; re-run freely.
#   - verifies limactl and the Command Line Tools SDK exist
#   - lays out ~/wt-export (the virtiofs handoff dir) and the wtpool Lima disk
#   - starts the VM from lima.yaml, injecting this repo (/wt-src) and the SDK dir
#     (/host-sdks) as read-only mounts — they are host-specific, so they don't live
#     in the template
set -euo pipefail
SELF=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF/.." && pwd)
VM=${WT_MAC_VM:-wt}
EXPORT="$HOME/wt-export"
SDKS=${WT_MAC_SDKS:-/Library/Developer/CommandLineTools/SDKs}
DISK_SIZE=${WT_MAC_DISK_SIZE:-80GiB}
SSH_DIR=${WT_MAC_SSH_DIR:-}

command -v limactl >/dev/null 2>&1 \
  || { echo "limactl not found — install Lima first: nix profile install nixpkgs#lima" >&2; exit 1; }
[ -d "$SDKS/MacOSX.sdk" ] \
  || { echo "no MacOSX.sdk under $SDKS — install the Command Line Tools: xcode-select --install" >&2; exit 1; }
if [ -n "$SSH_DIR" ]; then
  [ -d "$SSH_DIR" ] \
    || { echo "WT_MAC_SSH_DIR is set but not a directory: $SSH_DIR" >&2; exit 1; }
fi

mkdir -p "$EXPORT/incoming" "$EXPORT/logs/crashes"
touch "$EXPORT/incoming/run.trigger"

limactl disk list 2>/dev/null | grep -qw wtpool \
  || limactl disk create wtpool --size "$DISK_SIZE"

# The ssh mount object, reused by both the fresh-start injection and the retrofit hint.
SSH_MOUNT="{\"location\": \"$SSH_DIR\", \"mountPoint\": \"/host-ssh\", \"writable\": false}"

if limactl list -q 2>/dev/null | grep -qx "$VM"; then
  if [ -n "$SSH_DIR" ]; then
    echo "note: VM '$VM' already exists — WT_MAC_SSH_DIR cannot retrofit a mount. Apply it with:"
    echo "  limactl stop $VM && limactl edit $VM --set '.mounts += [$SSH_MOUNT]' && limactl start $VM"
  fi
  limactl start "$VM"
else
  MOUNTS="{\"location\": \"$REPO\", \"mountPoint\": \"/wt-src\", \"writable\": false}, {\"location\": \"$SDKS\", \"mountPoint\": \"/host-sdks\", \"writable\": false}"
  [ -n "$SSH_DIR" ] && MOUNTS="$MOUNTS, $SSH_MOUNT"
  # One line on purpose: the argv is asserted line-wise by the unit suite, and yq is
  # indifferent to the whitespace anyway.
  limactl start --name "$VM" --tty=false \
    --set ".mounts += [$MOUNTS]" \
    "$SELF/lima.yaml"
fi

# Lima downgrades a failed provision script to a warning and reports the boot as READY, so a
# broken zpool would sail through silently. Probe the one thing everything downstream needs.
limactl shell "$VM" -- zpool list wt >/dev/null 2>&1 \
  || { echo "VM is up but zpool 'wt' is missing — the provision failed; inspect it with:" >&2
       echo "  limactl shell $VM -- sudo cat /var/log/cloud-init-output.log" >&2; exit 1; }

echo
echo "VM '$VM' is up. Next:"
echo "  limactl shell $VM -- bash /wt-src/macos/setup-guest.sh"
