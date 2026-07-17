# Getting work out of the macOS loop VM

**Date:** 2026-07-16
**Status:** design, approved — not yet implemented

## Problem

Work accumulates inside the `wt` Lima VM with no way to get it out. The guest has no
git credentials, so commits sit on guest-local disk until someone extracts them by hand.

On 2026-07-16 one commit (`boxddd f741b63`) was stranded this way and had to be rescued
manually: `git bundle` in the guest → copy to `/export` → `git fetch` on the host → push.
That worked, but it is ten minutes of hand-typed git plumbing, it is not incremental, and
nothing tells you a commit is stranded in the first place. The same session found that
voxfall's four "at risk" commits were already on GitHub — the uncertainty was the real cost,
not the extraction.

## Constraint that shapes everything

**Lima mounts are host→guest only.** virtiofs shares a *host* directory into the guest;
there is no reverse direction. Guest-local files cannot be exposed to the host by adding a
mount — not with a restart, not ever.

This matters because the work lives on guest-local ZFS datasets on the additional disk:

```
wt/proj/voxfall-src  zfs  /home/wolf.guest/dev/voxfall
wt/proj/app-wt/t2    zfs  legacy          # wt's clone-based worktrees
```

Those datasets are load-bearing: wt's worktrees are ZFS clones. Relocating `~/dev` onto a
host-backed mount would break that mechanism and move Cargo build output onto virtiofs.

So the design space is ssh-based access, not mounts.

## Approach

The host reaches the guest over the ssh endpoint Lima already provides. Verified working
against a running, busy VM with no restart:

```
$ git ls-remote lima-wt:/home/wolf.guest/dev/voxfall
0c7efdd  refs/heads/mac-loop
```

Credentials stay on the Mac. The guest never holds a key. The host pulls; the host pushes.

### Why the port problem solves itself

`~/.lima/<vm>/ssh.config` defines a stable `Host lima-<vm>` alias but a **dynamically
assigned port**, and Lima regenerates the file on every start with this warning:

> Modifications to this file will be lost on restarting the Lima instance.

The design never writes that file — it only ever passes it to `ssh -F`. Remote URLs use the
stable `lima-<vm>` alias, so the volatile port is resolved fresh on each invocation and VM
restarts are absorbed for free. Never hardcode the port; never edit the config.

## Phase 1 — `macos/host/vm-git.sh` (no restart; safe while the VM is busy)

Two commands, because friction is the thing being designed away:

```
vm-git.sh                  # status — the default; run from anywhere
vm-git.sh fetch [project]  # self-configuring; run inside a host repo
```

### `vm-git.sh` (default: status)

The "is anything stranded?" report, across every guest repo, from any directory, with no
arguments and no setup.

**Stranded means: commits reachable from a local branch but from no remote-tracking ref.**
The primitive is one command per branch:

```
git rev-list --count <branch> --not --remotes
```

This definition matters. The obvious alternative — "a branch with no upstream is stranded" —
is wrong and actively harmful. voxfall's `wt/gameplay` has no upstream, yet its commits are
all on `origin/mac-loop`; wt creates such branches constantly, so that rule cries wolf on the
common case, and a report that is usually noise gets ignored precisely when it is right.
`--not --remotes` yields voxfall→0 and boxddd→1, which is the truth.

It also sidesteps a trap that bit the 2026-07-16 session: `git log @{u}..` **fails** when a
branch has no upstream, and in a pipeline the exit status is the last command's — so
`git log @{u}.. | head` prints nothing and looks like "all clear" for exactly the local-only
branches most likely to hold stranded work. Never resolve `@{u}` for this; `--not --remotes`
needs no upstream at all.

**Staleness cross-check (not optional).** `--remotes` reads remote-tracking refs, which are a
local cache and can lie. So for each repo the host — which has the credentials and the network
— runs `git ls-remote <origin-url>` and compares the real ref shas against the guest's cached
ones, flagging any repo whose cache disagrees as "counts may be wrong". The 2026-07-16 session
only established voxfall was safe by querying GitHub directly; a report trusting the cache
would have been confidently wrong.

Discovery scans `$WT_MAC_GUEST_DEV` (default `~/dev`) for `*/.git`, cross-checked against
`zfs list` rather than trusting the path blindly.

Output ends with a **copy-pasteable recipe** per stranded repo (fetch → merge → push), so the
report is the fix, not homework.

### `vm-git.sh fetch [project]`

Run from inside a host repo; operates on cwd the way `git` does. **Self-configuring** — it
adds the remote when missing, so the first run and the thousandth are the same command. There
is no separate `add` step to remember:

```
git remote add vm lima-<vm>:<guest-dev>/<project>
git config --local core.sshCommand 'ssh -F ~/.lima/<vm>/ssh.config'
git config --local remote.vm.fetch '+refs/heads/*:refs/vm/<project>/*'
```

Project inference, in order: match the guest repo's `origin` URL against the host repo's
`origin` URL; else directory basename; else require an explicit argument. URL matching beats
a path convention — it pairs correctly even when the two directories are named differently.

**No host path convention exists anywhere in this design.** There is no registry, no state
file, and no assumed projects directory. Configuration lives in the host repo's own
`.git/config`, so after the first `fetch` the script is out of the loop entirely: plain
`git fetch vm` works forever without it.

Status is not folded into `fetch`: it costs a network round-trip to the origin per repo, and
`fetch` should stay cheap enough to run in a loop.

### Safety properties

- Writes only `refs/vm/*`. Never checks out, never merges, never force-updates a branch.
- Strictly read-only against the guest — safe to run mid-build.
- Namespaced refs cannot collide with `origin/*`. Merging stays deliberate and manual.

## Phase 2 — `/host-ssh` (deferred; requires a VM restart)

Lets the guest push directly. Independent of Phase 1 and strictly a convenience — Phase 1
already gets work out.

Gap to close: `setup-host.sh` injects the ssh mount only on a **fresh** start (`--set
.mounts +=`); for an existing VM it merely prints a `limactl edit` hint, because Lima cannot
add a mount to a live instance. Add an explicit opt-in flag performing
`stop → limactl edit --set → start`, gated behind that flag precisely because it restarts
the VM and interrupts work.

Guest side needs a **plain key file** — ssh agent sockets do not cross virtiofs. Document
that the key is readable by any code in the guest; that is the tradeoff Phase 1 avoids.

## Testing

Extend `test/test-macos-host-unit.sh` using its existing stub pattern (`limactl`, `git`,
`ssh` on PATH), keeping it hermetic on ubuntu CI. Cover:

- port changes between invocations are absorbed (regenerate stub ssh.config, re-fetch)
- a branch with no upstream is reported stranded, not silently skipped (the `@{u}` trap)
- a stale remote-tracking ref is caught by the `ls-remote` cross-check
- `add` infers by origin URL when basenames differ
- `add` is idempotent and rewrites an existing `vm` remote rather than failing

## Docs

New `macos/README.md` section, "Getting work out of the VM": the `status` → `add` →
`git fetch vm` → merge → push flow, and the Phase 2 tradeoff.

## Rejected alternatives

- **sshfs / FUSE mount of `~/dev`** — macFUSE is a kext requiring reduced security and a
  reboot on Apple Silicon, is a brew cask rather than a nixpkg (this host uses nix, no brew),
  and performs poorly. Scope is extraction, not browsing, so it buys nothing.
- **Relocating `~/dev` onto a host virtiofs mount** — breaks wt's ZFS clone worktrees and
  puts build output on virtiofs.
- **`git bundle` via `/export` as the primary path** — manual and non-incremental. Retain as
  the documented fallback for when guest networking is wedged but the mount still works.
