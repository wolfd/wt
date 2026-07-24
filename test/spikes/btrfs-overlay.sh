#!/usr/bin/env bash
# Spike: prove the three load-bearing assumptions of the btrfs backend on real hardware, BEFORE
# host-btrfs-setup.sh's NOPASSWD rule exists. Run it from INSIDE your build container (distrobox):
#
#   distrobox enter dev -- bash /path/to/wt/test/spikes/btrfs-overlay.sh
#
# There is NO NOPASSWD rule yet (installing one is host-btrfs-setup.sh's job), so the host-root work
# is batched into exactly TWO `distrobox-host-exec sudo` calls — setup and cleanup — so you type your
# password twice, not a dozen times. If your host uses a GUI sudo askpass that misbehaves, prime the
# cache first in a host terminal: `sudo -v`. Throwaway subvolumes live under ~/.wt-spike (cleaned up).
#
# The three assumptions:
#   1. A nested subvolume snapshots as an EMPTY STUB (so WT_SNAPSHOT_EXCLUDE works and the sandbox
#      subvol has no nested subvols → single-step delete).
#   2. Box-root can `unshare --mount` + `mount --bind` a subvol over a path (the enter overlay).
#   3. `distrobox-host-exec sudo btrfs subvolume snapshot|delete` works and returns real exit codes.
set -uo pipefail

ESC=${WT_BTRFS_ESC:-distrobox-host-exec sudo}
BASE=${WT_SPIKE_BASE:-$HOME/.wt-spike}
SRC="$BASE/src"                 # stands in for WT_CANONICAL (the source subvolume)
PARENT="$BASE/parent"           # stands in for WT_BTRFS_PARENT
SANDBOX="$PARENT/s1"            # the per-sandbox subvolume (kept, for inspection)
MNT="$BASE/mnt"                # a plain dir to overlay onto in assumption 2
U=$(id -u); G=$(id -g)         # in the box these map to the host uid/gid (home bind)

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS  $*"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
is_subvol() { [ "$(stat -c %i "$1" 2>/dev/null)" = 256 ]; }

cleanup() {
  echo "== cleanup (one host-root call) =="
  $ESC bash -s <<CLEAN >/dev/null 2>&1 || true
btrfs subvolume delete "$SANDBOX"      2>/dev/null || true
btrfs subvolume delete "$SANDBOX-del"  2>/dev/null || true
btrfs subvolume delete "$SRC/logs"     2>/dev/null || true
btrfs subvolume delete "$SRC"          2>/dev/null || true
rm -rf "$BASE"                         2>/dev/null || true
CLEAN
  rm -rf "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

echo "== preflight =="
[ -e /run/.containerenv ] && ok "running inside a container (as intended)" \
  || no "NOT in a container — run this inside 'distrobox enter dev'"
command -v distrobox-host-exec >/dev/null 2>&1 && ok "distrobox-host-exec present" || no "distrobox-host-exec missing"

echo "== host-root setup + assumption 3 (one sudo call; enter your password once) =="
# Everything that needs host root, batched. Outcomes are written to $BASE/out.* (chowned back to the
# caller) for the box side to read. `set +e` semantics: each check records a flag rather than aborting.
$ESC bash -s <<HOST
umask 022
mkdir -p "$BASE" "$PARENT"
# Clear any subvols a previous interrupted run left behind, so the snapshots below start clean.
btrfs subvolume delete "$SANDBOX" "$SANDBOX-del" >/dev/null 2>&1 || true
btrfs subvolume show "$SRC" >/dev/null 2>&1 || btrfs subvolume create "$SRC" >/dev/null
btrfs subvolume show "$SRC/logs" >/dev/null 2>&1 || btrfs subvolume create "$SRC/logs" >/dev/null
printf spam  > "$SRC/logs/keep.txt"
printf hello > "$SRC/code.txt"
printf box   > "$SRC/overlaytest"

# assumption 3a: a valid snapshot returns 0
if btrfs subvolume snapshot "$SRC" "$SANDBOX" >/dev/null 2>&1; then echo 1 > "$BASE/out.snap"; else echo 0 > "$BASE/out.snap"; fi
# assumption 3b: a snapshot into a missing parent returns non-zero (exit codes are honored)
if btrfs subvolume snapshot "$SRC" "$PARENT/definitely/missing/parent" >/dev/null 2>&1; then echo 0 > "$BASE/out.neg"; else echo 1 > "$BASE/out.neg"; fi
# assumption 1b: a sandbox snapshot (nested subvol became a stub) deletes in ONE step
btrfs subvolume snapshot "$SRC" "$SANDBOX-del" >/dev/null 2>&1
if btrfs subvolume delete "$SANDBOX-del" >/dev/null 2>&1; then echo 1 > "$BASE/out.del"; else echo 0 > "$BASE/out.del"; fi

chown -R $U:$G "$BASE"
HOST

rc=$?
[ "$rc" -eq 0 ] && ok "the host-root batch (distrobox-host-exec sudo btrfs …) ran and returned 0" \
  || no "the host-root batch failed (rc=$rc) — sudo/askpass problem? try 'sudo -v' in a host terminal first"

[ "$(cat "$BASE/out.snap" 2>/dev/null)" = 1 ] && ok "3a: a valid snapshot via host-exec returned success" || no "3a: snapshot via host-exec did not succeed"
[ "$(cat "$BASE/out.neg"  2>/dev/null)" = 1 ] && ok "3b: a failing snapshot returns non-zero through host-exec (exit codes honored)" || no "3b: a failing snapshot did NOT report non-zero"
[ "$(cat "$BASE/out.del"  2>/dev/null)" = 1 ] && ok "1b: sandbox subvol deleted in one step (no nested subvols)" || no "1b: single-step delete failed"

echo "== assumption 1: nested subvol became an empty stub in the snapshot =="
[ -f "$SANDBOX/code.txt" ] && ok "source file carried into the snapshot" || no "source file missing from snapshot"
if [ -d "$SANDBOX/logs" ] && ! is_subvol "$SANDBOX/logs" && [ ! -e "$SANDBOX/logs/keep.txt" ]; then
  ok "nested subvol is an EMPTY, non-subvol stub in the snapshot (exclude mechanism holds)"
else
  no "nested subvol did NOT become an empty stub (is_subvol=$(is_subvol "$SANDBOX/logs" && echo yes || echo no), keep.txt=$([ -e "$SANDBOX/logs/keep.txt" ] && echo present || echo absent))"
fi

echo "== assumption 2: box-root unshare --mount + bind overlay (box sudo is NOPASSWD; no prompt) =="
mkdir -p "$MNT"
if sudo -n unshare --mount --propagation private -- \
     bash -c "mount --bind '$SANDBOX' '$MNT' && test -f '$MNT/overlaytest'" 2>"$BASE/ov.err"; then
  ok "box-root bind-mounted a subvol over a path inside a private mount ns"
else
  no "in-box bind overlay failed: $(head -1 "$BASE/ov.err" 2>/dev/null)"
fi
[ -f "$MNT/overlaytest" ] && no "the overlay leaked OUT of the namespace (should be private)" \
  || ok "the overlay stayed private to the namespace (host view of $MNT is clean)"

echo
echo "btrfs-overlay spike: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
