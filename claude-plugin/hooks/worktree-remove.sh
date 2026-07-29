#!/usr/bin/env bash
# WorktreeRemove hook: tear down whichever kind of worktree worktree-create.sh handed back.
#
# stdin: {"hook_event_name":"WorktreeRemove","worktree_path":"<abs path>",...}
#
# Both teardowns are destructive, so each is guarded on the path actually living where this hook
# puts things. Anything else is someone else's worktree and is left alone. Exits 0 throughout: a
# teardown that fails must not make a worktree unremovable.
set -euo pipefail

log() { printf '[worktree-remove] %s\n' "$*" >&2; }

worktree_path="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("worktree_path",""))')"
[ -n "$worktree_path" ] || { log "no worktree_path on stdin"; exit 0; }

name=$(basename "$worktree_path")

# ---- wt sandbox ---------------------------------------------------------------------------
# `wt rm` archives the branch to wt-archive/<name>, so committed work survives; uncommitted work
# in the clone does not.
if command -v wt >/dev/null 2>&1; then
  parent=$(wt status 2>/dev/null | sed -n 's/^wt parent *: *//p' | head -1)
  if [ -n "$parent" ] && [ "$worktree_path" = "$parent/$name" ]; then
    log "removing wt sandbox $name"
    wt rm "$name" >&2 || log "wt rm '$name' failed; sandbox may need manual cleanup"
    exit 0
  fi
fi

# ---- plain git worktree -------------------------------------------------------------------
base="${XDG_DATA_HOME:-$HOME/.local/share}/claude-code-worktrees"
case "$worktree_path" in
  "$base"/*/"$name")
    log "removing git worktree $name"
    # --force because the agent's uncommitted edits would otherwise block removal, and Claude
    # Code only asks for teardown once it has decided the worktree is finished with.
    git -C "$worktree_path" worktree remove --force "$worktree_path" >&2 2>/dev/null \
      || git worktree remove --force "$worktree_path" >&2 \
      || log "git worktree remove failed; $worktree_path may need manual cleanup"
    ;;
  *)
    log "not a worktree this hook created, leaving alone: $worktree_path"
    ;;
esac
exit 0
