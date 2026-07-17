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

# The cache `--not --remotes` reads is local and can lie, so ask the real remote (we have the
# credentials here, the guest does not) and say so when they disagree.
stale_check() {
  local repo=$1 url=$2 survey=$3
  [ "$url" = "-" ] && return 0
  local real; real=$(git ls-remote "$url" 2>/dev/null) || { echo "  (could not reach $url)"; return 0; }
  awk -v r="$repo" '$1=="R" && $2==r {print $3"\t"$4}' "$survey" | while IFS=$'\t' read -r ref sha; do
    local want; want=$(awk -v b="refs/heads/${ref#origin/}" '$2==b {print $1}' <<<"$real")
    # An `if`, not an && chain: a ref the remote doesn't have leaves $want empty, and a
    # trailing false && chain would fail the while, fail the pipeline, and `set -e` would
    # kill the report before the return below could save it.
    if [ -n "$want" ] && [ "$want" != "$sha" ]; then
      echo "  warning: $ref is stale (guest cache $sha, remote $want) — counts may be wrong"
    fi
  done
  return 0
}

cmd_status() {
  local survey="$TMP/survey"
  guest_survey > "$survey"
  local found=0
  while IFS=$'\t' read -r _ repo url; do
    local rows; rows=$(awk -v r="$repo" '$1=="B" && $2==r && $4>0' "$survey")
    [ -n "$rows" ] || continue
    found=1
    echo "$repo — not on any remote:"
    while IFS=$'\t' read -r _ _ branch n sha; do
      echo "  $branch  $n commit$([ "$n" -eq 1 ] || echo s)  (tip $sha)"
    done <<<"$rows"
    stale_check "$repo" "$url" "$survey"
    echo "  cd <your $repo checkout> && $0 fetch $repo"
    while IFS=$'\t' read -r _ _ branch _ _; do
      echo "    git merge --ff-only refs/vm/$repo/$branch && git push origin $branch"
    done <<<"$rows"
    echo
  done < <(awk '$1=="U"' "$survey")
  [ "$found" -eq 1 ] || echo "nothing stranded — every guest commit is on a remote."
}

case "${1:-status}" in
  --survey) guest_survey ;;
  status)   cmd_status ;;
  *) echo "usage: $(basename "$0") [status|fetch [project]]" >&2; exit 2 ;;
esac
