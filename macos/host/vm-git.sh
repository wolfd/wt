#!/usr/bin/env bash
# Find and retrieve work stranded in the Lima guest. The guest holds no git credentials, so
# the host pulls: it reads guest repos over the ssh endpoint Lima already publishes.
#   vm-git.sh                  report what is stranded (default)
#   vm-git.sh fetch [project]  fetch a guest repo into the host repo you are standing in
set -euo pipefail
VM=${WT_MAC_VM:-wt}
SSH_CONFIG="$HOME/.lima/$VM/ssh.config"
GUEST_DEV=${WT_MAC_GUEST_DEV:-\$HOME/dev}   # expanded in the guest, not here

command -v limactl >/dev/null 2>&1 \
  || { echo "limactl not found — install Lima first: nix profile install nixpkgs#lima" >&2; exit 1; }
# The port in this file is assigned per start, so we always read it fresh and never write it.
[ -e "$SSH_CONFIG" ] \
  || { echo "no ssh config for VM '$VM' — start it: limactl start $VM" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

guest() { ssh -F "$SSH_CONFIG" "lima-$VM" "$@"; }

# One round-trip: every repo, every branch, every remote-tracking ref, as TSV.
# Stranded is "reachable from no remote-tracking ref" — NOT "has no upstream" (wt's wt/*
# branches have no upstream yet are fully pushed), and never `git log @{u}..`, which fails
# on upstream-less branches and looks like all-clear inside a pipeline.
guest_survey() {
  guest "GUEST_DEV=$GUEST_DEV bash -s" <<'REMOTE'
for d in "$GUEST_DEV"/*/; do
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
  repo=$(basename "$d")
  printf 'U\t%s\t%s\n' "$repo" "$(git -C "$d" config --get remote.origin.url || echo -)"
  git -C "$d" for-each-ref --format='%(refname:short)' refs/heads | while read -r b; do
    printf 'B\t%s\t%s\t%s\t%s\n' "$repo" "$b" \
      "$(git -C "$d" rev-list --count "$b" --not --remotes)" \
      "$(git -C "$d" rev-parse --short "$b")"
  done
  git -C "$d" for-each-ref --format="R	$repo	%(refname:short)	%(objectname)" refs/remotes
done
REMOTE
}

if [ "${1:-}" = "--survey" ]; then guest_survey; exit 0; fi
guest_survey >/dev/null
