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

command -v limactl >/dev/null 2>&1 \
  || { echo "limactl not found — install Lima first: nix profile install nixpkgs#lima" >&2; exit 1; }
[ -d "$SDKS/MacOSX.sdk" ] \
  || { echo "no MacOSX.sdk under $SDKS — install the Command Line Tools: xcode-select --install" >&2; exit 1; }

mkdir -p "$EXPORT/incoming" "$EXPORT/logs/crashes"
touch "$EXPORT/incoming/run.trigger"

limactl disk list 2>/dev/null | grep -qw wtpool \
  || limactl disk create wtpool --size "$DISK_SIZE"

if limactl list -q 2>/dev/null | grep -qx "$VM"; then
  limactl start "$VM"
else
  # One line on purpose: the argv is asserted line-wise by the unit suite, and yq is
  # indifferent to the whitespace anyway.
  limactl start --name "$VM" --tty=false \
    --set ".mounts += [{\"location\": \"$REPO\", \"mountPoint\": \"/wt-src\", \"writable\": false}, {\"location\": \"$SDKS\", \"mountPoint\": \"/host-sdks\", \"writable\": false}]" \
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
