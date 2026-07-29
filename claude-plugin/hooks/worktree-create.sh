#!/usr/bin/env bash
# WorktreeCreate hook: back Claude Code worktree isolation with `wt` CoW sandboxes.
#
# stdin : {"hook_event_name":"WorktreeCreate","name":"<sandbox>","cwd":"<abs path>",...}
# stdout: the absolute path of the created directory (THE return channel — nothing else)
# stderr: diagnostics
#
# For the wt-managed checkout this returns the host-visible clone, so the agent gets native file
# tools on a real CoW clone with a warm build tree. Builds and git inside it must still go through
# `wt enter -- ...`, which sees the same bytes at the canonical path — see the `wt` skill.
#
# Everywhere else it falls back to a plain `git worktree`. That fallback is not a nicety: this
# plugin is enabled per MACHINE, wt is configured for exactly one canonical checkout, and Claude
# Code hard-fails worktree creation when a configured hook errors. Without the fallback, enabling
# this plugin would break `isolation: "worktree"` in every other repo on the box.
set -euo pipefail

log() { printf '[worktree-create] %s\n' "$*" >&2; }

input=$(cat)
read_field() { printf '%s' "$input" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))"; }

name=$(read_field name)
cwd=$(read_field cwd)
[ -n "$name" ] || { log "no worktree name on stdin"; exit 1; }
[ -n "$cwd" ] || cwd=$PWD

# The name becomes a directory and a git branch either way, so screen it before it reaches
# either. wt is stricter than this (no dots); it will say so itself if it disagrees.
case "$name" in
  ''|.|..|-*|*[!A-Za-z0-9._-]*) log "refusing unsafe worktree name: $name"; exit 1 ;;
esac

repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$repo_root" ] || { log "not a git repository: $cwd"; exit 1; }

# Same directory, whatever it is spelled as. String comparison is not enough and `pwd -P` does
# not rescue it: on ostree-style systems /home is a BIND MOUNT of /var/home, not a symlink, so
# both spellings are already physical and resolve to themselves. wt reports one, git reports the
# other, and comparing the strings silently fell through to the fallback for the very checkout wt
# manages — losing the warm build tree that is the whole point. Device+inode is the real identity.
same_dir() {
  local a b
  a=$(stat -c '%d:%i' "$1" 2>/dev/null) || return 1
  b=$(stat -c '%d:%i' "$2" 2>/dev/null) || return 1
  [ "$a" = "$b" ]
}

# ---- wt path ------------------------------------------------------------------------------
# Only for the one checkout wt is configured against.
canonical=""; parent=""
if command -v wt >/dev/null 2>&1; then
  status=$(wt status 2>/dev/null || true)
  canonical=$(printf '%s\n' "$status" | sed -n 's/^canonical *: *//p' | head -1)
  parent=$(printf '%s\n' "$status" | sed -n 's/^wt parent *: *//p' | head -1)
fi

if [ -n "$canonical" ] && [ -n "$parent" ] && same_dir "$repo_root" "$canonical"; then
  path="$parent/$name"
  if [ -d "$path" ]; then
    log "reusing existing sandbox $name"
  else
    log "creating sandbox $name"
    wt new "$name" >&2
  fi

  # A wt new predating the fix that installs the gitdir pointer at creation leaves the snapshot's
  # copy of main's .git in the clone: a live repo on the wrong branch whose commits the first
  # `wt enter` destroys. Force the swap, then assert it, rather than hand back a path where
  # committing looks like it works.
  if [ -d "$path/.git" ]; then
    log "normalizing snapshot .git into wt's worktree pointer"
    wt enter "$name" -- true >&2
  fi
  if [ -d "$path/.git" ]; then
    log "sandbox .git is still a directory — refusing to hand back a path where host-side"
    log "commits would be silently lost by the next 'wt enter'"
    exit 1
  fi

  [ -d "$path" ] || { log "wt new '$name' produced no directory at $path"; exit 1; }
  log "ready (wt sandbox): $path"
  printf '%s\n' "$path"
  exit 0
fi

# ---- plain git worktree fallback ----------------------------------------------------------
# Kept outside the repo by choice, not by requirement — Claude Code's own default lives at
# <repo>/.claude/worktrees/<name>, so inside would be accepted too. Out-of-tree keeps an agent's
# worktree from ever surfacing in the project's own git status. Keyed by repo, so two repos can
# both hold a worktree of the same name.
if [ -n "$canonical" ]; then
  log "$repo_root is not wt's canonical checkout ($canonical) — using a plain git worktree"
else
  log "wt unavailable or unconfigured — using a plain git worktree"
fi

base="${XDG_DATA_HOME:-$HOME/.local/share}/claude-code-worktrees/$(basename "$repo_root")"
path="$base/$name"
mkdir -p "$base"

if [ -d "$path" ]; then
  log "reusing existing worktree $name"
else
  # Reuse the branch if it survived an earlier worktree, so a retry after cleanup is not fatal.
  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$name"; then
    git -C "$repo_root" worktree add "$path" "$name" >&2
  else
    git -C "$repo_root" worktree add -b "$name" "$path" >&2
  fi
fi

[ -d "$path" ] || { log "git worktree add did not produce a directory at $path"; exit 1; }
log "ready (git worktree): $path"
printf '%s\n' "$path"
