---
name: wt
description: Work correctly inside a wt sandbox - host-side git fails by design, edits use native tools, builds and git go through `wt enter`. Read before running git or cargo in a worktree under wt-subvols, or when git reports "not a git repository" in a tree whose files are clearly there.
---

# Working in a wt sandbox

`wt` gives each sandbox a CoW clone of the canonical checkout, build outputs included, so a
sandbox starts with a warm `target/` instead of a cold one. The clone is visible from two paths,
and which one you are standing in determines what works:

| Path | What it is | Files | git |
|---|---|---|---|
| `<wt parent>/<name>` (e.g. `~/.local/share/wt-subvols/foo`) | the clone, on the host | yes | **no** |
| `<canonical>` inside `wt enter` (e.g. `~/Documents/voxfall`) | the same clone, bind-mounted in a namespace | yes | yes |

Same bytes, two spellings. An edit made at either path is immediately visible at the other.

## The rule

**Edit with native tools where you are. Run git and builds through `wt enter`.**

```bash
wt enter -- git status          # no name needed: the sandbox is inferred from cwd
wt enter -- cargo build
wt enter -- git commit -am "..."
```

`wt enter` with no name resolves the sandbox from `WT_SANDBOX` or from your cwd. Prefer that form.
Do not write `wt enter "$(basename $PWD)" -- ...`: a worktree-isolated agent's bash guard refuses
command substitution it cannot statically prove stays inside the worktree, so that spelling fails
where the no-arg form succeeds.

## Do not repair host-side git

Inside the clone on the host, git fails:

```
fatal: not a git repository: (null)
```

**This is deliberate. Do not fix it.** The clone's `.git` is a pointer to a path that only
resolves inside the namespace. It reads as broken from the host precisely so that git refuses to
run there.

The alternative is worse than an error. That file used to be a full copy of the source repo's
`.git`, sitting on the wrong branch — `git commit` against it appeared to succeed and the first
`wt enter` then destroyed the commit, keeping the edited files as an uncommitted diff and
discarding the history. Anything that restores a working `.git` at the host path — `git init`,
rewriting the gitdir, copying `.git` in — rebuilds that trap.

If you need git, you are one `wt enter --` away from the real thing.

## Other things worth knowing

- **Builds must go through `wt enter`.** Cargo's fingerprints and the absolute paths baked into
  `target/` were produced at the canonical path. Building at the host clone path instead changes
  the workspace root and throws away the warm tree — the entire reason wt exists.
- **`wt new` refuses to run from inside a sandbox.** The snapshot is taken host-side, where the
  canonical path is the source checkout rather than the sandbox you are standing in, so it would
  clone the wrong tree. Run it from outside. (Forking a sandbox is a TODO on `wt_new`.)
- **Isolated agents get a fresh sandbox branched from the canonical checkout's HEAD**, not from
  any existing sandbox. An agent under `isolation: "worktree"` does not see another sandbox's
  work, and lands on its own `wt/<name>` branch.
- **`wt rm` archives the branch** to `wt-archive/<name>`, so committed work survives removal.
  Uncommitted work in the clone does not.

## Quick orientation

```bash
wt list                  # sandboxes, and what each clone is holding down
wt status                # config: canonical path, wt parent, backend
wt enter <name>          # interactive shell in a sandbox
```
