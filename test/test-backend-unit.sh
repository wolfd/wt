#!/usr/bin/env bash
# Fast, hermetic unit tests for the btrfs storage backend (no btrfs/root/distrobox needed).
#
# The btrfs backend reaches real host root through WT_BTRFS_ESC (default `distrobox-host-exec
# sudo`) for exactly `btrfs subvolume snapshot|delete`. These tests stub `btrfs` and point
# WT_BTRFS_ESC at a recorder, so the dispatch, the disjointness guard, the gc orphan filter, and
# the escalation hop are all exercised for real — the parts that DON'T need a live filesystem.
# (The privileged mount overlay and a real snapshot cycle are covered by the spikes, not here.)
#
# Nothing here can touch real state: btrfs is a stub, `stat` is stubbed so the inode-256 subvolume
# test always says "subvolume", every path is overridden, and WT_CONFIG= skips any installed file.
set -uo pipefail
# Same sharp edge as the other suites: env > file > default, and every `wt enter` exports a WT_*
# bundle — scrub it so a suite run inside a sandbox can't feed the code under test a real config.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^WT_' || true)

DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
WT="$DIR/../wt"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS  $*"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/trees" "$T/home/active" "$T/canonical" "$T/parent"

SNAP_LOG="$T/snap.log"; DELETE_LOG="$T/delete.log"; ESC_LOG="$T/esc.log"
: > "$SNAP_LOG"; : > "$DELETE_LOG"; : > "$ESC_LOG"

# Fake btrfs. Simulates just enough filesystem: a snapshot creates the destination directory, a
# delete removes it; both are logged. `subvolume show` succeeds iff the path exists.
cat > "$T/bin/btrfs" <<EOF
#!/usr/bin/env bash
if [ "\$1" = subvolume ]; then
  case "\$2" in
    snapshot) src=\${3:?}; dst=\${4:?}; printf '%s -> %s\n' "\$src" "\$dst" >> "$SNAP_LOG"; mkdir -p "\$dst" ;;
    delete)   tgt=\${3:?}; printf '%s\n' "\$tgt" >> "$DELETE_LOG"; rm -rf "\$tgt" ;;
    show)     [ -e "\${3:-}" ] || exit 1 ;;
  esac
fi
exit 0
EOF
chmod +x "$T/bin/btrfs"

# Fake stat: the inode-256 subvolume test (`stat -c %i`) always reports a subvolume root, so
# be_require/be_status accept our plain-dir canonical without a real btrfs filesystem.
cat > "$T/bin/stat" <<'EOF'
#!/usr/bin/env bash
echo 256
EOF
chmod +x "$T/bin/stat"

# Escalation recorder standing in for `distrobox-host-exec sudo`: log the wrapped command, then run
# it. Proves btrfs create/delete actually go through WT_BTRFS_ESC rather than being run bare.
cat > "$T/bin/escrec" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ESC_LOG"
exec "\$@"
EOF
chmod +x "$T/bin/escrec"

wt() {
  env PATH="$T/bin:$PATH" WT_CONFIG= WT_HOOK_TEARDOWN= \
      WT_BACKEND=btrfs WT_HOME="$T/home" WT_CANONICAL="$T/canonical" \
      WT_BTRFS_PARENT="$T/parent" WT_BTRFS_ESC="escrec" \
      bash "$WT" "$@"
}

resolved=$(env PATH="$T/bin:$PATH" bash -c 'command -v btrfs')
[ "$resolved" = "$T/bin/btrfs" ] && ok "the fake btrfs is first on PATH" || no "btrfs resolved to $resolved"

echo "== configuration guards =="
if env PATH="$T/bin:$PATH" WT_CONFIG= WT_BACKEND=bogus bash "$WT" help >/dev/null 2>"$T/bad.err"; then
  no "an unknown WT_BACKEND was accepted"
else
  grep -qF "unknown WT_BACKEND 'bogus'" "$T/bad.err" \
    && ok "an unknown WT_BACKEND is rejected with a clear message" \
    || no "unknown WT_BACKEND died without the expected message"
fi

# WT_BTRFS_PARENT must be disjoint from WT_CANONICAL — nesting would let gc walk into live data.
if env PATH="$T/bin:$PATH" WT_CONFIG= WT_BACKEND=btrfs WT_HOME="$T/home" \
     WT_CANONICAL="$T/canonical" WT_BTRFS_PARENT="$T/canonical/wt" \
     bash "$WT" gc >/dev/null 2>"$T/nest.err"; then
  no "a WT_BTRFS_PARENT nested under WT_CANONICAL was accepted"
else
  grep -qF "must not be, or live under, WT_CANONICAL" "$T/nest.err" \
    && ok "WT_BTRFS_PARENT nested under WT_CANONICAL is refused" \
    || no "nested parent died without the expected message"
fi

echo "== wt gc reaps only orphan sandbox subvolumes, through the escalation hop =="
# 'live' has a tree (an active sandbox); 'orphan' does not (its tree was removed).
mkdir -p "$T/parent/live" "$T/parent/orphan" "$T/home/trees/live"
wt gc >"$T/gc.out" 2>"$T/gc.err"
grep -qF "$T/parent/orphan" "$DELETE_LOG" \
  && ok "destroys the orphan subvolume (no tree)" || no "did NOT destroy the orphan subvolume"
grep -qF "$T/parent/live" "$DELETE_LOG" \
  && no "destroyed a live subvolume (tree still present)" \
  || ok "spares the live subvolume"
grep -qF "btrfs subvolume delete $T/parent/orphan" "$ESC_LOG" \
  && ok "the delete goes through WT_BTRFS_ESC (real host root would be reached here)" \
  || no "the delete bypassed WT_BTRFS_ESC"
[ ! -e "$T/parent/orphan" ] && ok "the orphan subvolume is gone afterwards" || no "orphan subvolume still present"

echo "== wt list surfaces orphan subvolumes =="
mkdir -p "$T/parent/orphan2"          # another orphan, no tree
wt list >"$T/list.out" 2>"$T/list.err"
awk '/orphan subvolumes \(run/,0' "$T/list.out" | grep -qF "$T/parent/orphan2" \
  && ok "an orphan subvolume is listed under 'orphan subvolumes'" \
  || no "orphan subvolume missing from the list report"

echo "== wt status reports the btrfs backend =="
wt status >"$T/status.out" 2>"$T/status.err"
grep -qE "^backend       : btrfs" "$T/status.out" \
  && ok "status names the btrfs backend" || no "status did not name the btrfs backend"
grep -qE "^src subvol    :" "$T/status.out" \
  && ok "status shows the btrfs source subvolume line" || no "status missing the src subvol line"

echo
echo "wt-backend-unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
