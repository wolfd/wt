# vm-git.sh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `macos/host/vm-git.sh` so work stranded in the Lima guest is visible in one zero-argument command and retrievable in one more — without credentials in the VM and without restarting it.

**Architecture:** The host reaches the guest over the ssh endpoint Lima already provides (`Host lima-<vm>` in `~/.lima/<vm>/ssh.config`). `status` batches a survey of every guest repo into a **single** ssh round-trip that emits TSV, which the host parses. `fetch` runs from inside a host repo, self-configures a `vm` remote on first use, and lands guest branches under `refs/vm/<project>/*`.

**Tech Stack:** bash, git, ssh, Lima 2.x. Tests are hermetic bash with argv-recording stubs on PATH.

**Spec:** `docs/superpowers/specs/2026-07-16-vm-file-access-design.md`

## Global Constraints

- Phase 1 only. `/host-ssh` (Phase 2) needs a VM restart, cannot be tested while the VM is working, and gets its own plan.
- **Never hardcode the ssh port.** It is dynamic. Always `ssh -F "$HOME/.lima/$VM/ssh.config"` + the `lima-$VM` alias.
- **Never write to `~/.lima/<vm>/ssh.config`.** Lima regenerates it on every start; edits are lost.
- Strictly read-only against the guest. No `git fetch`, no writes, no state changes in the VM.
- Host-side writes are confined to `refs/vm/*` and the host repo's own `.git/config`.
- **No host path convention.** No registry, no state file, no assumed projects directory.
- VM name is `${WT_MAC_VM:-wt}`; guest project dir is `${WT_MAC_GUEST_DEV:-$HOME/dev}` (evaluated in the guest).
- Every failure names its remedy (existing convention, asserted by the unit suite).
- `set -euo pipefail` in the script; match the terse commented style of `macos/host/run-latest.sh`.
- Tests append to `test/test-macos-host-unit.sh`, reusing its `ok`/`no` helpers and `$T` tempdir.

## The two rules that are easy to get wrong

1. **Stranded = `git rev-list --count <branch> --not --remotes`.** Do *not* define it as "branch has no upstream" — voxfall's `wt/gameplay` has no upstream but is fully on `origin/mac-loop`; wt makes such branches constantly, so that rule reports false positives on the common case.
2. **Never use `git log @{u}..` here.** It *fails* when a branch has no upstream, and in a pipeline the exit status comes from the last command, so it silently prints "all clear" for exactly the branches most likely to hold stranded work.

---

## File Structure

- **Create** `macos/host/vm-git.sh` — the whole tool. One file, ~120 lines: preflight, guest survey, status, fetch. Matches the flat `macos/host/` layout (`run-latest.sh`, `watch.sh` are each single-purpose scripts).
- **Modify** `macos/setup-host.sh:57-59` — add a discoverability line to the closing hint.
- **Modify** `macos/README.md` — new "Getting work out of the VM" section.
- **Modify** `test/test-macos-host-unit.sh` — append a `vm-git.sh` block after the `install-agent.sh` block (currently ends line 208).

### The test's key trick: a local-exec `ssh` stub

Rather than mocking git, the suite stubs **ssh** so it strips `-F <cfg>` and the `lima-*` host and runs the remaining command locally. Real git then runs against real temp repos, so `--not --remotes` is exercised for real — and `git fetch` over `lima-wt:/path` genuinely works end-to-end.

---

### Task 1: Preflight and the batched guest survey

**Files:**
- Create: `macos/host/vm-git.sh`
- Test: `test/test-macos-host-unit.sh` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `guest_survey()` printing TSV to stdout. Row types, tab-separated:
  - `U <repo> <origin-url>` — one per repo (`-` when no origin)
  - `B <repo> <branch> <stranded-count> <short-sha>` — one per local branch
  - `R <repo> <remote-ref> <sha>` — one per remote-tracking ref (for Task 2's staleness check)

- [ ] **Step 1: Write the failing test**

Append to `test/test-macos-host-unit.sh`:

```bash
# ---- vm-git.sh ----------------------------------------------------------------------------
VMGIT="$DIR/../macos/host/vm-git.sh"

# ssh stub: drop "-F <cfg>" and the lima-* host, run the rest locally. Lets the real git run
# against real temp repos, so the stranded-detection logic is genuinely exercised.
cat > "$T/bin/ssh" <<'STUB'
#!/usr/bin/env bash
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -F) shift 2 ;;
    lima-*) shift; args=("$@"); break ;;
    *) shift ;;
  esac
done
exec bash -c "${args[*]}"
STUB
chmod +x "$T/bin/ssh"

# A guest that mirrors the real 2026-07-16 state: one repo with a stranded commit, one whose
# branches all live on a remote-tracking ref despite having no upstream (the false-positive trap).
GD="$T/guest-dev"; mkdir -p "$GD"
gitq() { git -C "$1" -c user.email=t@t -c user.name=t -c init.defaultBranch=main "${@:2}"; }
mkdir -p "$GD/stranded"; git init -q "$GD/stranded"
gitq "$GD/stranded" commit -q --allow-empty -m base
gitq "$GD/stranded" update-ref refs/remotes/origin/main HEAD
gitq "$GD/stranded" commit -q --allow-empty -m "vendor bump"
gitq "$GD/stranded" remote add origin https://example.invalid/stranded

mkdir -p "$GD/safe"; git init -q "$GD/safe"
gitq "$GD/safe" commit -q --allow-empty -m base
gitq "$GD/safe" update-ref refs/remotes/origin/mac-loop HEAD
gitq "$GD/safe" branch wt/gameplay          # no upstream, but fully on origin/mac-loop
gitq "$GD/safe" remote add origin https://example.invalid/safe

run_vmgit() { env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
                  WT_MAC_GUEST_DEV="$GD" LIMACTL_LOG="$LIMACTL_LOG" STATE="$STATE" \
                  "$@" bash "$VMGIT"; }

echo "== vm-git.sh: preflight names its remedy =="
mkdir -p "$T/home/.lima/wt"; : > "$T/home/.lima/wt/ssh.config"
out=$(env -i PATH="/usr/bin:/bin" HOME="$T/home" bash "$VMGIT" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -qi 'nix profile install' <<<"$out" \
  && ok "vm-git: missing limactl fails and points at nix" \
  || no "vm-git: missing limactl: rc=$rc out=$out"

rm -f "$T/home/.lima/wt/ssh.config"
out=$(run_vmgit 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'limactl start wt' <<<"$out" \
  && ok "vm-git: no ssh.config fails and points at 'limactl start wt'" \
  || no "vm-git: missing ssh.config: rc=$rc out=$out"
: > "$T/home/.lima/wt/ssh.config"

echo "== vm-git.sh: the survey is one round-trip of TSV =="
: > "$T/ssh.count"
out=$(run_vmgit --survey 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "vm-git: --survey exits 0" || no "vm-git: --survey rc=$rc: $out"
grep -qP '^B\tstranded\tmain\t1\t' <<<"$out" \
  && ok "vm-git: the stranded repo reports 1 commit off all remotes" \
  || no "vm-git: expected 'B stranded main 1': $out"
grep -qP '^B\tsafe\twt/gameplay\t0\t' <<<"$out" \
  && ok "vm-git: an upstream-less branch already on a remote ref counts 0 (no false positive)" \
  || no "vm-git: wt/gameplay must be 0, got: $out"
grep -qP '^U\tsafe\thttps://example.invalid/safe' <<<"$out" \
  && ok "vm-git: the survey reports each repo's origin URL" \
  || no "vm-git: missing U row: $out"
grep -qP '^R\tsafe\torigin/mac-loop\t' <<<"$out" \
  && ok "vm-git: the survey reports remote-tracking refs for the staleness check" \
  || no "vm-git: missing R row: $out"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test-macos-host-unit.sh 2>&1 | tail -20`
Expected: FAIL lines for the vm-git block ("No such file or directory" for `vm-git.sh`).

- [ ] **Step 3: Write minimal implementation**

Create `macos/host/vm-git.sh`:

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/test-macos-host-unit.sh 2>&1 | tail -20`
Expected: all vm-git PASS lines; `results: N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
chmod +x macos/host/vm-git.sh
git add macos/host/vm-git.sh test/test-macos-host-unit.sh
git commit -m "macos: vm-git.sh surveys guest repos for stranded commits in one ssh round-trip"
```

---

### Task 2: The status report — quiet when clean, actionable when not

**Files:**
- Modify: `macos/host/vm-git.sh`
- Test: `test/test-macos-host-unit.sh` (append)

**Interfaces:**
- Consumes: `guest_survey()` TSV from Task 1.
- Produces: `cmd_status()`, the default when no subcommand is given. Exit 0 whether or not anything is stranded (stranded work is a finding, not a script error).

- [ ] **Step 1: Write the failing test**

Append to `test/test-macos-host-unit.sh`:

```bash
echo "== vm-git.sh: status =="
# git ls-remote stub, so the staleness cross-check has a controllable "real" remote.
cat > "$T/bin/git" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = ls-remote ] && [ -n "${LSREMOTE_OUT:-}" ]; then cat "$LSREMOTE_OUT"; exit 0; fi
exec /usr/bin/git "$@"
STUB
chmod +x "$T/bin/git"

safe_sha=$(gitq "$GD/safe" rev-parse HEAD)
printf '%s\trefs/heads/mac-loop\n' "$safe_sha" > "$T/lsremote.ok"

out=$(run_vmgit LSREMOTE_OUT="$T/lsremote.ok" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "vm-git: status exits 0 even with stranded work" \
                || no "vm-git: status rc=$rc: $out"
grep -q 'stranded' <<<"$out" && grep -q '1 commit' <<<"$out" \
  && ok "vm-git: status names the stranded repo and its commit count" \
  || no "vm-git: status missed the stranded repo: $out"
grep -q 'safe' <<<"$out" \
  && no "vm-git: status listed a clean repo (must be quiet when clean)" \
  || ok "vm-git: status stays quiet about clean repos"
grep -q 'vm-git.sh fetch' <<<"$out" && grep -q 'refs/vm/stranded/main' <<<"$out" \
  && ok "vm-git: status prints a copy-pasteable fetch/merge recipe" \
  || no "vm-git: no actionable recipe: $out"

echo "== vm-git.sh: status flags a stale remote-tracking cache =="
printf '%s\trefs/heads/mac-loop\n' 0000000000000000000000000000000000000000 > "$T/lsremote.stale"
out=$(run_vmgit LSREMOTE_OUT="$T/lsremote.stale" 2>&1)
grep -qi 'stale' <<<"$out" \
  && ok "vm-git: a remote whose sha differs from the cache is flagged stale" \
  || no "vm-git: stale cache not flagged: $out"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test-macos-host-unit.sh 2>&1 | tail -12`
Expected: FAIL — status prints nothing; no recipe, no stale warning.

- [ ] **Step 3: Write minimal implementation**

In `macos/host/vm-git.sh`, replace the trailing `guest_survey >/dev/null` with:

```bash
# The cache `--not --remotes` reads is local and can lie, so ask the real remote (we have the
# credentials here, the guest does not) and say so when they disagree.
stale_check() {
  local repo=$1 url=$2 survey=$3
  [ "$url" = "-" ] && return 0
  local real; real=$(git ls-remote "$url" 2>/dev/null) || { echo "  (could not reach $url)"; return 0; }
  awk -v r="$repo" '$1=="R" && $2==r {print $3"\t"$4}' "$survey" | while IFS=$'\t' read -r ref sha; do
    local want; want=$(awk -v b="refs/heads/${ref#origin/}" '$2==b {print $1}' <<<"$real")
    [ -n "$want" ] && [ "$want" != "$sha" ] \
      && echo "  warning: $ref is stale (guest cache $sha, remote $want) — counts may be wrong"
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/test-macos-host-unit.sh 2>&1 | tail -12`
Expected: all vm-git status PASS lines.

- [ ] **Step 5: Commit**

```bash
git add macos/host/vm-git.sh test/test-macos-host-unit.sh
git commit -m "macos: vm-git.sh status — quiet when clean, copy-pasteable recipe when not"
```

---

### Task 3: `fetch` — self-configuring, namespaced, cwd-based

**Files:**
- Modify: `macos/host/vm-git.sh`
- Test: `test/test-macos-host-unit.sh` (append)

**Interfaces:**
- Consumes: `guest()`, `guest_survey()` from Task 1.
- Produces: `cmd_fetch [project]`. Operates on `$PWD`'s repo. Adds remote `vm` → `lima-$VM:<guest-dev>/<project>`, sets `core.sshCommand` and `remote.vm.fetch = +refs/heads/*:refs/vm/<project>/*`, then runs `git fetch vm`. Idempotent: rewrites an existing `vm` remote rather than failing.

- [ ] **Step 1: Write the failing test**

Append to `test/test-macos-host-unit.sh`:

```bash
echo "== vm-git.sh: fetch =="
HOSTREPO="$T/host-side/boxddd-checkout"   # deliberately NOT named like the guest repo
mkdir -p "$HOSTREPO"; git init -q "$HOSTREPO"
gitq "$HOSTREPO" remote add origin https://example.invalid/stranded   # matches guest 'stranded'

run_fetch() { env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" WT_MAC_GUEST_DEV="$GD" \
                  bash -c "cd '$HOSTREPO' && bash '$VMGIT' fetch $*"; }

out=$(run_fetch 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "vm-git: fetch exits 0" || no "vm-git: fetch rc=$rc: $out"
[ "$(gitq "$HOSTREPO" config --get remote.vm.url)" = "lima-wt:$GD/stranded" ] \
  && ok "vm-git: fetch infers the guest repo from the origin URL, not the directory name" \
  || no "vm-git: wrong vm url: $(gitq "$HOSTREPO" config --get remote.vm.url)"
[ "$(gitq "$HOSTREPO" config --get remote.vm.fetch)" = "+refs/heads/*:refs/vm/stranded/*" ] \
  && ok "vm-git: guest branches land under refs/vm/<project>/* and cannot collide with origin/*" \
  || no "vm-git: wrong refspec: $(gitq "$HOSTREPO" config --get remote.vm.fetch)"
grep -q 'ssh.config' <<<"$(gitq "$HOSTREPO" config --get core.sshCommand)" \
  && ok "vm-git: core.sshCommand is pinned to lima's regenerated config (survives port changes)" \
  || no "vm-git: core.sshCommand not set: $(gitq "$HOSTREPO" config --get core.sshCommand)"
gitq "$HOSTREPO" rev-parse --verify refs/vm/stranded/main >/dev/null 2>&1 \
  && ok "vm-git: the stranded commit actually landed on the host" \
  || no "vm-git: refs/vm/stranded/main missing after fetch"
gitq "$HOSTREPO" rev-parse --verify refs/heads/main >/dev/null 2>&1 \
  && no "vm-git: fetch created a local branch (must only write refs/vm/*)" \
  || ok "vm-git: fetch wrote no local branches"

out=$(run_fetch 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "vm-git: fetch is idempotent (a second run re-uses the vm remote)" \
                || no "vm-git: second fetch failed: $out"

out=$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" WT_MAC_GUEST_DEV="$GD" \
      bash -c "cd '$T' && bash '$VMGIT' fetch" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -qi 'not a git repo' <<<"$out" \
  && ok "vm-git: fetch outside a git repo fails and says so" \
  || no "vm-git: fetch outside a repo: rc=$rc out=$out"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test-macos-host-unit.sh 2>&1 | tail -12`
Expected: FAIL — `usage:` from the `*)` case, exit 2.

- [ ] **Step 3: Write minimal implementation**

In `macos/host/vm-git.sh`, add before the `case`:

```bash
# Which guest repo pairs with the host repo we are standing in? Origin URL first — it pairs
# correctly even when the two directories are named differently — then basename, then ask.
infer_project() {
  local survey=$1 origin
  origin=$(git config --get remote.origin.url 2>/dev/null || true)
  if [ -n "$origin" ]; then
    local m; m=$(awk -v u="$origin" '$1=="U" && $3==u {print $2; exit}' "$survey")
    [ -n "$m" ] && { echo "$m"; return 0; }
  fi
  local base; base=$(basename "$PWD")
  awk -v r="$base" '$1=="U" && $2==r {print $2; exit}' "$survey"
}

cmd_fetch() {
  git rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "not a git repo: $PWD — run this from the host checkout you want the work in" >&2; exit 1; }
  local survey="$TMP/survey"
  guest_survey > "$survey"

  local project=${1:-}
  [ -n "$project" ] || project=$(infer_project "$survey")
  [ -n "$project" ] || { echo "cannot tell which guest repo this is — name it: $(basename "$0") fetch <project>" >&2
                         awk '$1=="U" {print "  " $2}' "$survey" >&2; exit 1; }
  awk -v r="$project" '$1=="U" && $2==r {f=1} END {exit !f}' "$survey" \
    || { echo "no guest repo '$project' under the guest's dev dir" >&2; exit 1; }

  # Self-configuring: first run and every run are the same command. The URL uses the stable
  # lima-<vm> alias and the port is resolved from lima's file each time, so restarts are free.
  # GUEST_DEV may be "$HOME/dev" for the guest to expand, so ask the guest what it means.
  local dev; dev=$(guest "echo $GUEST_DEV")
  git remote remove vm 2>/dev/null || true
  git remote add vm "lima-$VM:$dev/$project"
  git config --local core.sshCommand "ssh -F $SSH_CONFIG"
  git config --local remote.vm.fetch "+refs/heads/*:refs/vm/$project/*"
  git fetch vm
  echo "guest branches are under refs/vm/$project/* — merge with: git merge --ff-only refs/vm/$project/<branch>"
}
```

Extend the `case`:

```bash
  fetch)    shift; cmd_fetch "${1:-}" ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/test-macos-host-unit.sh 2>&1 | tail -12`
Expected: all vm-git fetch PASS lines; `results: N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add macos/host/vm-git.sh test/test-macos-host-unit.sh
git commit -m "macos: vm-git.sh fetch — self-configuring vm remote, refs/vm/* namespace"
```

---

### Task 4: Make it discoverable (the last UX gap)

A tool nobody can remember the path to is a tool nobody runs.

**Files:**
- Modify: `macos/setup-host.sh:57-59`
- Modify: `macos/README.md`
- Test: `test/test-macos-host-unit.sh` (append)

**Interfaces:**
- Consumes: `macos/host/vm-git.sh` from Tasks 1–3.
- Produces: no new interfaces.

- [ ] **Step 1: Write the failing test**

Append to `test/test-macos-host-unit.sh`:

```bash
echo "== setup-host.sh points at vm-git.sh =="
out=$(run_setup WT_MAC_SDKS="$T/sdks" 2>&1)
grep -q 'vm-git.sh' <<<"$out" \
  && ok "setup-host closes by naming vm-git.sh (how work gets back out)" \
  || no "setup-host never mentions vm-git.sh: $out"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test-macos-host-unit.sh 2>&1 | grep vm-git.sh`
Expected: FAIL — setup-host never mentions vm-git.sh.

- [ ] **Step 3: Write minimal implementation**

Replace `macos/setup-host.sh` lines 57-59 with:

```bash
echo
echo "VM '$VM' is up. Next:"
echo "  limactl shell $VM -- bash /wt-src/macos/setup-guest.sh"
echo
echo "To get work back out (the guest holds no git credentials):"
echo "  $SELF/host/vm-git.sh          # what's stranded in the VM?"
echo "  alias wt-vm='$SELF/host/vm-git.sh'   # worth putting in your shell rc"
```

Add to `macos/README.md`:

````markdown
## Getting work out of the VM

The guest has no git credentials by design — the host pulls instead. Lima mounts are
host→guest only, so the guest's ZFS-backed `~/dev` can never be exposed as a mount; ssh is
the path, and it needs no VM restart.

```
macos/host/vm-git.sh                 # what's stranded? (safe to run mid-build)
cd ~/wherever/boxddd && macos/host/vm-git.sh fetch
git merge --ff-only refs/vm/boxddd/voxfall-patches
git push origin voxfall-patches
```

`fetch` self-configures a `vm` remote in the repo you run it from, so afterwards plain
`git fetch vm` works without the script. Guest branches land under `refs/vm/<project>/*` and
never collide with `origin/*`; nothing is merged for you.

*Stranded* means reachable from no remote-tracking ref — not "has no upstream", since wt's
`wt/*` branches have no upstream yet are usually fully pushed.

**Fallback** when the guest's network is wedged but `/export` still mounts: bundle it out.

```
# guest
git bundle create /export/outbox/repo.bundle origin/<branch>..<branch>
# host
git fetch ~/wt-export/outbox/repo.bundle '<branch>:refs/vm-rescue/<branch>'
```

**Pushing from inside the guest** (`/host-ssh`) is deliberately not set up: it needs a VM
restart and puts a plain key file where guest code can read it — agent sockets don't cross
virtiofs.
````

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/test-macos-host-unit.sh 2>&1 | tail -6`
Expected: `results: N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add macos/setup-host.sh macos/README.md test/test-macos-host-unit.sh
git commit -m "macos: point setup-host and the README at vm-git.sh"
```

---

## Manual verification (after Task 3, against the real VM)

The unit suite stubs ssh, so exercise the real thing once. All read-only; safe while the VM works.

```bash
macos/host/vm-git.sh                 # expect: boxddd clean now (f741b63 was pushed 2026-07-16)
cd ~/projects/voxfall && ~/projects/wt/macos/host/vm-git.sh fetch
git rev-parse refs/vm/voxfall/mac-loop   # expect 0c7efdd
```

Then confirm the port claim, which is the design's main load-bearing bet: `limactl stop wt && limactl start wt`, check the port in `~/.lima/wt/ssh.config` changed, and re-run `git fetch vm` with no reconfiguration. **Requires a restart — do this only when the VM is idle.**
