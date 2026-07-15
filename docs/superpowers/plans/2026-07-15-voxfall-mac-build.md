# voxfall on the wt macOS loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and run voxfall (Bevy 0.19 macOS app + native Linux tests) as a second wt project inside the existing `wt` Lima VM, cloned over ssh via a read-only bind mount of the host's `~/.ssh`.

**Architecture:** wt's `macos/setup-host.sh` gains an opt-in `WT_MAC_SSH_DIR` knob that injects a read-only virtiofs mount at `/host-ssh` (retrofit onto the live VM via `limactl edit`). voxfall commits its own `.config/wt.conf` (minimal — datasets derived at runtime per upstream f38db30), a `ship-mac.sh` that bundles Bevy assets beside the binary, and `packaging/Info.plist`. Guest one-time setup follows the existing documented flow; datasets are named exactly once, as env on the `host-zfs-setup.sh` call, because the guest home is ext4.

**Tech Stack:** bash, Lima 2.x (vz/virtiofs), ZFS, cargo-zigbuild, Bevy 0.19.

**Spec:** `docs/superpowers/specs/2026-07-15-voxfall-mac-build-design.md` (approved 2026-07-15).

## Global Constraints

- The `/host-ssh` mount is **always read-only** (`"writable": false`); never copy the private key into the VM image.
- voxfall's committed `.config/wt.conf` **never names `WT_DS_SRC`/`WT_DS_PARENT`** — runtime derivation reads them off the ZFS mounts.
- Dataset names (used exactly once, on the one-shot setup call): `wt/proj/voxfall-src` and `wt/proj/voxfall-wt`.
- `SHIP_APP=Voxfall`, `SHIP_BIN=app` (the `[[bin]]` in `crates/app/Cargo.toml`), bundle identifier `dev.wolfd.voxfall`.
- The host checkout `~/projects/voxfall` is in active use: **never modify its working tree or switch its branch.** All voxfall file changes happen in the guest clone `~/dev/voxfall` on branch `mac-loop`.
- Never publish or share the VM image (it contains this machine's SDK copy — license).
- wt repo work happens on branch `macos`; pushes go to remote `fork` (`git@github.com:wolfd/wt.git`).

---

### Task 1: `WT_MAC_SSH_DIR` knob in `macos/setup-host.sh`

**Files:**
- Modify: `macos/setup-host.sh`
- Test: `test/test-macos-host-unit.sh` (append a section; the suite is hermetic — limactl is an argv-recording stub)

**Interfaces:**
- Produces: env knob `WT_MAC_SSH_DIR` (default empty = off). When set on a **fresh** `limactl start`, injects `{"location": <dir>, "mountPoint": "/host-ssh", "writable": false}` into the `--set .mounts` expression. When set but the VM already exists, prints a note containing the exact `limactl edit` retrofit command (Task 3 runs it). When set to a non-directory, exits non-zero naming `WT_MAC_SSH_DIR`.

- [ ] **Step 1: Write the failing tests**

In `test/test-macos-host-unit.sh`, insert this block after the "failure modes name their remedy" section (after the `missing SDK` assertion, before the `# ---- host agent ----` divider):

```bash
echo "== setup-host.sh: WT_MAC_SSH_DIR =="
rm -f "$STATE/vm" "$STATE/disk"; : > "$LIMACTL_LOG"
mkdir -p "$T/sshdir"
run_setup WT_MAC_SDKS="$T/sdks" WT_MAC_SSH_DIR="$T/sshdir" >"$T/out3" 2>&1; rc=$?
start=$(grep -m1 '^start ' "$LIMACTL_LOG" || true)
[ "$rc" -eq 0 ] && grep -qF "\"location\": \"$T/sshdir\", \"mountPoint\": \"/host-ssh\", \"writable\": false" <<<"$start" \
  && ok "WT_MAC_SSH_DIR injects a read-only /host-ssh mount on first start" \
  || no "ssh mount missing or not read-only: $start"

rm -f "$STATE/vm" "$STATE/disk"; : > "$LIMACTL_LOG"
run_setup WT_MAC_SDKS="$T/sdks" >"$T/out4" 2>&1
grep -q '/host-ssh' "$LIMACTL_LOG" \
  && no "unset WT_MAC_SSH_DIR still injected /host-ssh" \
  || ok "no knob, no /host-ssh mount"

out=$(run_setup WT_MAC_SDKS="$T/sdks" WT_MAC_SSH_DIR="$T/sshdir" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'limactl edit' <<<"$out" && grep -qF "$T/sshdir" <<<"$out" \
  && ok "existing VM + knob: succeeds and prints the limactl edit retrofit" \
  || no "no retrofit hint for an existing VM: rc=$rc out=$out"

out=$(run_setup WT_MAC_SDKS="$T/sdks" WT_MAC_SSH_DIR="$T/nope" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'WT_MAC_SSH_DIR' <<<"$out" \
  && ok "a non-directory WT_MAC_SSH_DIR fails and names the knob" \
  || no "bad ssh dir: rc=$rc out=$out"
```

- [ ] **Step 2: Run the suite to verify the new cases fail**

Run: `bash test/test-macos-host-unit.sh` (host bash is fine for this suite — it is hermetic).
Expected: the four new cases FAIL (`ssh mount missing`, existing-VM hint missing, bad-dir accepted); all pre-existing cases still PASS.

- [ ] **Step 3: Implement the knob**

In `macos/setup-host.sh`: after line 14 (`DISK_SIZE=...`) add:

```bash
SSH_DIR=${WT_MAC_SSH_DIR:-}
```

After the SDK existence check (`[ -d "$SDKS/MacOSX.sdk" ] || ...`) add:

```bash
if [ -n "$SSH_DIR" ]; then
  [ -d "$SSH_DIR" ] \
    || { echo "WT_MAC_SSH_DIR is set but not a directory: $SSH_DIR" >&2; exit 1; }
fi
```

Replace the `if limactl list ... else ... fi` block (currently `limactl start "$VM"` / the one-line `limactl start --name ...`) with:

```bash
# The ssh mount object, reused by both the fresh-start injection and the retrofit hint.
SSH_MOUNT="{\"location\": \"$SSH_DIR\", \"mountPoint\": \"/host-ssh\", \"writable\": false}"

if limactl list -q 2>/dev/null | grep -qx "$VM"; then
  if [ -n "$SSH_DIR" ]; then
    echo "note: VM '$VM' already exists — WT_MAC_SSH_DIR cannot retrofit a mount. Apply it with:"
    echo "  limactl stop $VM && limactl edit $VM --set '.mounts += [$SSH_MOUNT]' && limactl start $VM"
  fi
  limactl start "$VM"
else
  MOUNTS="{\"location\": \"$REPO\", \"mountPoint\": \"/wt-src\", \"writable\": false}, {\"location\": \"$SDKS\", \"mountPoint\": \"/host-sdks\", \"writable\": false}"
  [ -n "$SSH_DIR" ] && MOUNTS="$MOUNTS, $SSH_MOUNT"
  # One line on purpose: the argv is asserted line-wise by the unit suite, and yq is
  # indifferent to the whitespace anyway.
  limactl start --name "$VM" --tty=false \
    --set ".mounts += [$MOUNTS]" \
    "$SELF/lima.yaml"
fi
```

- [ ] **Step 4: Run the suite to verify everything passes**

Run: `bash test/test-macos-host-unit.sh`
Expected: `== results: N passed, 0 failed ==` (N = 23 pre-existing + 4 new = 27).
Also run: `bash -n macos/setup-host.sh` and, if installed, `shellcheck macos/setup-host.sh` (CI enforces both).

- [ ] **Step 5: Commit**

```bash
cd ~/projects/wt
git add macos/setup-host.sh test/test-macos-host-unit.sh
git commit -m "macos: WT_MAC_SSH_DIR mounts the host's ssh dir read-only at /host-ssh"
```

---

### Task 2: macos/README.md — private repos, second projects, minimal config

**Files:**
- Modify: `macos/README.md`

**Interfaces:**
- Consumes: the `WT_MAC_SSH_DIR` knob and retrofit command from Task 1.
- Produces: the documented recipes Tasks 3–5 execute verbatim.

- [ ] **Step 1: Update the knobs paragraph**

In the `## Setup` section, extend the knobs sentence ("`setup-host.sh` knobs (env): ...") to include:

```
`WT_MAC_SSH_DIR` (host directory with ssh keys, e.g. `~/.ssh`, mounted read-only at
`/host-ssh` for cloning private repos; default off — for an existing VM, setup-host.sh
prints the `limactl edit` retrofit command instead).
```

- [ ] **Step 2: Rewrite the per-project section**

Replace the `## Per project (inside the VM)` section's config example and add two subsections. The section becomes:

````markdown
## Per project (inside the VM)

```sh
limactl shell wt
git clone <your-app> ~/dev/app && cd ~/dev/app
mkdir -p ~/.config/wt
cat > ~/.config/wt/config <<EOF
WT_CANONICAL=$HOME/dev/app
WT_HOME=$HOME/dev/app-wt
WT_HOOK_ENTER=/usr/local/share/wt-hooks/mac-env.sh
EOF
sudo WT_DS_SRC=wt/proj/app-src WT_DS_PARENT=wt/proj/app-wt \
     /wt-src/host-zfs-setup.sh          # migrate the checkout into a dataset; see -h
```

`WT_DS_SRC`/`WT_DS_PARENT` appear only on the setup call: the guest home is ext4, so
host-zfs-setup.sh's own derivation has nothing to read there — but after migration both
paths are ZFS mounts and `wt` derives the datasets at runtime, so the config file never
names them.

Copy `/wt-src/macos/example/ship-mac.sh` into your repo (edit the `SHIP_*` defaults) and
`/wt-src/macos/example/Info.plist` to `packaging/Info.plist` (edit names/identifier). Then:

```sh
wt new t1 && wt enter t1
./scripts/ship-mac.sh --dev        # build → bundle → rename into /export → agent relaunches
tail -F /export/logs/stdout.log    # the app's stdout, live from the Mac
ls /export/logs/crashes/           # .ips crash reports swept back per app
```

The enter hook feeds every sandbox session `SDKROOT=/opt/MacOSX.sdk` and
`MACOSX_DEPLOYMENT_TARGET=13.0`; `cargo zigbuild --target aarch64-apple-darwin` does the rest.

### Private repos

Run `WT_MAC_SSH_DIR=~/.ssh macos/setup-host.sh` so the guest sees your keys read-only at
`/host-ssh` (for an existing VM it prints the `limactl edit` retrofit instead). Then:

```sh
GIT_SSH_COMMAND='ssh -i /host-ssh/id_ed25519 -o IdentitiesOnly=yes' \
  git clone git@github.com:you/private-repo.git ~/dev/private-repo
cd ~/dev/private-repo
git config core.sshCommand 'ssh -i /host-ssh/id_ed25519 -o IdentitiesOnly=yes'
```

The second line makes plain `git fetch`/`pull`/`push` work from then on. Point at a plain
file key: agent sockets don't cross virtiofs, and hardware-backed agents (Secretive) hang
non-interactive git anyway.

### A second project in the same guest

`~/.config/wt/config` belongs to the first project. Each additional repo commits its own
`.config/wt.conf` (same minimal three lines as above) and every wt command for it runs
with the config named explicitly:

```sh
export WT_CONFIG=$HOME/dev/other/.config/wt.conf   # per shell, or use a direnv/alias
wt new t1 && wt enter t1
```

Forgetting the export makes wt silently operate on the first project — check `wt status`
when in doubt. wt's sudo re-exec preserves `WT_CONFIG` (explicit `--preserve-env` list).
````

- [ ] **Step 3: Proofread the rendered section**

Run: `sed -n '/## Per project/,/## Gotchas/p' macos/README.md`
Expected: the text above, with all three code fences balanced (` ```sh ` opened and closed).

- [ ] **Step 4: Run the full unit suite (docs must not break scripts)**

Run: `for t in test/test-*.sh; do bash "$t" >/dev/null 2>&1 || echo "FAIL $t"; done`
Expected: only the known BSD-tooling failures on macOS (`test-ssh-unit`, `wc`-padding cases); `test-macos-host-unit.sh` and `test-macos-guest-unit.sh` pass. (Definitive run is in the guest: `limactl shell wt -- bash -c 'cd /wt-src && bash test/test-macos-host-unit.sh'`.)

- [ ] **Step 5: Commit and push the wt branch**

```bash
cd ~/projects/wt
git add macos/README.md
git commit -m "macos: document private-repo clones via /host-ssh and the second-project pattern"
git push --force-with-lease fork macos
```

---

### Task 3: Retrofit the mount onto the live VM and clone voxfall

**Files:** none (live VM state). All commands run on the Mac host unless prefixed `guest$`.

**Interfaces:**
- Consumes: the retrofit command shape from Task 1.
- Produces: `/host-ssh` visible in the guest; clone at `~/dev/voxfall` (guest) with working `git fetch`.

- [ ] **Step 1: Apply the mount** (VM edits need the instance stopped)

```bash
limactl stop wt
limactl edit wt --set ".mounts += [{\"location\": \"$HOME/.ssh\", \"mountPoint\": \"/host-ssh\", \"writable\": false}]"
limactl start wt
```

Expected: `limactl start wt` reports Ready. (`setup-host.sh` re-run also works and re-probes the zpool.)

- [ ] **Step 2: Verify the mount and key permissions**

```bash
limactl shell wt -- ls -l /host-ssh
limactl shell wt -- stat -c '%a %U' /host-ssh/id_ed25519
```

Expected: `id_ed25519` and `id_ed25519.pub` listed; stat shows `600 wolf` (uid 501 maps through vz virtiofs). **Fallback if ssh later refuses the key** ("bad permissions"): per session, `install -m 600 /host-ssh/id_ed25519 /dev/shm/id_ed25519` and point `core.sshCommand` there instead; do not weaken the design to a persistent copy.

- [ ] **Step 3: Prove auth without cloning**

```bash
limactl shell wt -- env GIT_SSH_COMMAND='ssh -i /host-ssh/id_ed25519 -o IdentitiesOnly=yes' \
  git ls-remote git@github.com:wolfd/voxfall.git HEAD
```

Expected: one line, `<sha>\tHEAD`. (First contact may print the github.com host-key confirmation; accept it.)

- [ ] **Step 4: Clone and persist the key choice**

```bash
limactl shell wt -- bash -c "
  GIT_SSH_COMMAND='ssh -i /host-ssh/id_ed25519 -o IdentitiesOnly=yes' \
    git clone git@github.com:wolfd/voxfall.git ~/dev/voxfall &&
  cd ~/dev/voxfall &&
  git config core.sshCommand 'ssh -i /host-ssh/id_ed25519 -o IdentitiesOnly=yes' &&
  git fetch --dry-run && echo CLONE-OK"
```

Expected: clone output then `CLONE-OK`. If `~/dev` is root-owned (known gotcha: ZFS auto-mount creates parents as root), fix first: `limactl shell wt -- sudo chown wolf:wolf ~/dev`.

- [ ] **Step 5: Record progress** — no commit (no repo files changed); tick this task's boxes.

---

### Task 4: voxfall's committed pieces (branch `mac-loop` in the guest clone)

**Files** (all inside the guest at `~/dev/voxfall`):
- Create: `.config/wt.conf`
- Create: `packaging/Info.plist`
- Create: `scripts/ship-mac.sh` (mode 0755)
- Create: `docs/mac-vm.md`

**Interfaces:**
- Consumes: `/host-ssh` clone from Task 3; wt README conventions from Task 2.
- Produces: `SHIP_APP=Voxfall`, `SHIP_BIN=app`; the exact conf Task 5's migration and all later `wt` commands read.

- [ ] **Step 1: Branch**

```bash
limactl shell wt -- git -C ~/dev/voxfall switch -c mac-loop
```

- [ ] **Step 2: Write `.config/wt.conf`**

```sh
# wt config for the macOS VM guest — see wt's macos/README.md ("A second project").
# WT_DS_SRC / WT_DS_PARENT are intentionally absent: wt derives them from the ZFS
# mounts at runtime. They were named exactly once, on the host-zfs-setup.sh call
# (wt/proj/voxfall-src, wt/proj/voxfall-wt).
WT_CANONICAL=$HOME/dev/voxfall
WT_HOME=$HOME/dev/voxfall-wt
WT_HOOK_ENTER=/usr/local/share/wt-hooks/mac-env.sh
```

- [ ] **Step 3: Write `packaging/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Voxfall</string>
  <key>CFBundleIdentifier</key><string>dev.wolfd.voxfall</string>
  <key>CFBundleName</key><string>Voxfall</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
```

- [ ] **Step 4: Write `scripts/ship-mac.sh`** (then `chmod +x scripts/ship-mac.sh`)

```bash
#!/usr/bin/env bash
# Ship Voxfall.app into the wt macOS loop (see wt's macos/README.md). Builds the `app`
# crate for aarch64-apple-darwin, assembles the bundle in a hidden staging dir, and
# RENAMES it into incoming/ — the rename is the publish — then touches run.trigger.
set -euo pipefail
APP=${SHIP_APP:-Voxfall}        # bundle name: <APP>.app
BIN=${SHIP_BIN:-app}            # cargo binary name (crates/app [[bin]])
EXPORT=${SHIP_EXPORT:-/export}  # the virtiofs handoff mount

PROFILE=${1:---release}
case "$PROFILE" in
  --dev)
    cargo zigbuild -p app --target aarch64-apple-darwin
    OUT=target/aarch64-apple-darwin/debug/$BIN ;;
  --release)
    cargo zigbuild -p app --release --target aarch64-apple-darwin
    OUT=target/aarch64-apple-darwin/release/$BIN ;;
  *)
    echo "usage: ship-mac.sh [--dev|--release]" >&2; exit 2 ;;
esac

STAGE="$EXPORT/incoming/.stage.$$"
rm -rf "$STAGE"
mkdir -p "$STAGE/$APP.app/Contents/MacOS"
cp "$OUT" "$STAGE/$APP.app/Contents/MacOS/$APP"
# Bevy's default asset root is the executable's directory — bundle assets beside the binary.
cp -R crates/app/assets "$STAGE/$APP.app/Contents/MacOS/assets"
cp packaging/Info.plist "$STAGE/$APP.app/Contents/Info.plist"
rm -rf "${EXPORT:?}/incoming/$APP.app"
mv "$STAGE/$APP.app" "$EXPORT/incoming/$APP.app"
rm -rf "$STAGE"
date +%s%N > "$EXPORT/incoming/run.trigger"
echo "shipped $APP.app — the host agent relaunches it now" >&2
```

- [ ] **Step 5: Write `docs/mac-vm.md`**

```markdown
# Building voxfall in the wt macOS VM

One-time host setup lives in the wt repo: `macos/README.md` (VM, SDK injection, host
agent, and the `WT_MAC_SSH_DIR=~/.ssh` mount this clone was made through).

## One-time guest setup

```sh
limactl shell wt
sudo apt-get install -y libasound2-dev libudev-dev   # bevy's native Linux build deps
sudo WT_CONFIG=$HOME/dev/voxfall/.config/wt.conf \
     WT_DS_SRC=wt/proj/voxfall-src WT_DS_PARENT=wt/proj/voxfall-wt \
     /wt-src/host-zfs-setup.sh -y   # datasets named here once; see .config/wt.conf
```

## Daily loop

```sh
limactl shell wt
export WT_CONFIG=$HOME/dev/voxfall/.config/wt.conf   # REQUIRED — else wt targets the other project
wt new v1 && wt enter v1
cargo test --workspace                 # native Linux tests, warm caches
./scripts/ship-mac.sh --dev            # cross-build → Voxfall.app → Mac relaunches it
tail -F /export/logs/stdout.log        # the app's stdout, live from the Mac
ls /export/logs/crashes/               # .ips crash reports, swept back per app
```
```

- [ ] **Step 6: Verify syntax, commit, push**

```bash
limactl shell wt -- bash -c "cd ~/dev/voxfall &&
  bash -n scripts/ship-mac.sh &&
  git add .config/wt.conf packaging/Info.plist scripts/ship-mac.sh docs/mac-vm.md &&
  git commit -m 'Add the wt macOS VM loop: wt.conf, ship script with asset bundling, bundle plist' &&
  git push -u origin mac-loop"
```

Expected: commit created; push accepted (the key from Task 3 authenticates it).

---

### Task 5: Guest deps, ZFS migration, first sandbox

**Files:** none (live guest state).

**Interfaces:**
- Consumes: `.config/wt.conf` from Task 4.
- Produces: datasets `wt/proj/voxfall-src` (mounted at `~/dev/voxfall`) and `wt/proj/voxfall-wt` (at `~/dev/voxfall-wt`); sandbox `v1`.

- [ ] **Step 1: Install Bevy's Linux build deps**

```bash
limactl shell wt -- sudo apt-get install -y libasound2-dev libudev-dev
```

- [ ] **Step 2: Migrate the checkout into ZFS**

```bash
limactl shell wt -- bash -c "sudo WT_CONFIG=\$HOME/dev/voxfall/.config/wt.conf \
  WT_DS_SRC=wt/proj/voxfall-src WT_DS_PARENT=wt/proj/voxfall-wt \
  /wt-src/host-zfs-setup.sh -y"
```

Expected: script reports the migration (checkout moved aside, dataset created and mounted, files copied back, `.aside` removed or kept per its own output).

- [ ] **Step 3: Verify datasets, mounts, and runtime derivation**

```bash
limactl shell wt -- zfs list -o name,mountpoint | grep voxfall
limactl shell wt -- bash -c "export WT_CONFIG=\$HOME/dev/voxfall/.config/wt.conf && wt status"
```

Expected: `wt/proj/voxfall-src  /home/wolf.guest/dev/voxfall` and `wt/proj/voxfall-wt  /home/wolf.guest/dev/voxfall-wt`; `wt status` names both datasets **without** them appearing in the conf file — that is the implicit derivation working.

- [ ] **Step 4: First sandbox**

```bash
limactl shell wt -- bash -c "export WT_CONFIG=\$HOME/dev/voxfall/.config/wt.conf && \
  wt new v1 && wt enter v1 <<< 'echo SDKROOT=\$SDKROOT; exit'"
```

Expected: sandbox created from a snapshot clone; the session echoes `SDKROOT=/opt/MacOSX.sdk` (the enter hook ran).

- [ ] **Step 5: Confirm the other project is untouched**

```bash
limactl shell wt -- bash -c "wt status"   # NO WT_CONFIG: the global config, i.e. the app project
```

Expected: still reports the `app` project's canonical/datasets exactly as before this plan.

---

### Task 6: Native Linux tests in a sandbox

**Files:** none.

**Interfaces:**
- Consumes: sandbox `v1` from Task 5.
- Produces: a green native `cargo test --workspace` (or a recorded, explained subset).

- [ ] **Step 1: Run the suite in the sandbox**

```bash
limactl shell wt -- bash -c "export WT_CONFIG=\$HOME/dev/voxfall/.config/wt.conf && \
  wt enter v1 <<< 'cargo test --workspace 2>&1 | tail -20; exit'"
```

Expected: compiles (cold: minutes — the canonical build warms every later clone) and tests pass. Known allowances: anything needing a display/GPU may be skipped or fail — voxfall's sim/voxelcore suites are headless and MUST pass; if an `app`-crate test needs winit/a display, record it as expected-fail in the task notes rather than chasing it in the VM.
If the **build** fails on a missing system lib (`alsa-sys`, `libudev-sys`, or similar `pkg-config` errors): `sudo apt-get install -y <the -dev package named>` and append it to `docs/mac-vm.md`'s apt line (amend Task 4's commit or add a fixup commit on `mac-loop`).

- [ ] **Step 2: Warm the canonical too** (so future `wt new` clones inherit hot caches)

```bash
limactl shell wt -- bash -c "cd ~/dev/voxfall && cargo build --workspace 2>&1 | tail -3"
```

Expected: `Finished` line.

---

### Task 7: Milestone 1 — bare cross-compile to aarch64-apple-darwin

**Files:** none (or a fixup commit on `mac-loop` if a contingency lands).

**Interfaces:**
- Consumes: sandbox `v1`; the enter hook's `SDKROOT=/opt/MacOSX.sdk`.
- Produces: `target/aarch64-apple-darwin/debug/app` — the go/no-go for the whole ship loop.

- [ ] **Step 1: Build**

```bash
limactl shell wt -- bash -c "export WT_CONFIG=\$HOME/dev/voxfall/.config/wt.conf && \
  wt enter v1 <<< 'cargo zigbuild -p app --target aarch64-apple-darwin 2>&1 | tail -15; exit'"
```

Expected: `Finished` and `file target/aarch64-apple-darwin/debug/app` → `Mach-O 64-bit executable arm64`.

- [ ] **Step 2: Contingencies, in order of likelihood** (apply only what the error names)

1. **`coreaudio-sys`/bindgen cannot find headers** (the spec's named risk):
   `sudo apt-get install -y clang libclang-dev` in the guest, and export
   `BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_darwin="--sysroot=/opt/MacOSX.sdk -F /opt/MacOSX.sdk/System/Library/Frameworks"`
   in the build environment (if it proves necessary permanently, add the export to voxfall's `docs/mac-vm.md` and a fixup commit).
2. **A crate hard-fails for the target** (walls of undefined objc/AppKit symbols, unsupported target): FIRST rule out the known SDK-tbd gotcha — `grep -m1 targets: /opt/MacOSX.sdk/usr/lib/libobjc.tbd` must show `arm64-macos`; if it doesn't, the VM was provisioned from the wrong SDK and the fix is re-provisioning, not feature surgery. Only if the SDK checks out and the failing crate is feature-gated (e.g. `bevy_audio`) do feature surgery: in voxfall's `crates/app/Cargo.toml`, wrap the failing capability behind a cargo feature that is on by default and disabled for the mac build (ship-mac.sh then passes `--no-default-features --features <the-kept-set>`). That change is a real code change: it gets its own commit on `mac-loop` with the full linker/bindgen error text in the message, and the exact feature list is decided from the error, not guessed here.
3. **zig missing in the sandbox PATH**: the toolchain came from `setup-guest.sh` into the guest home — confirm `wt enter v1 <<< 'command -v cargo-zigbuild zig'` and re-run `bash /wt-src/macos/setup-guest.sh` if absent.

- [ ] **Step 3: Record the cold cross-build time** in the task notes (the spec's measured baselines: app cold 59 s, sandbox incremental 1.8 s — voxfall is bigger; knowing its numbers calibrates the loop).

---

### Task 8: Full ship — end to end

**Files:** none.

**Interfaces:**
- Consumes: `scripts/ship-mac.sh` (Task 4), milestone-1 binary (Task 7), the host agent (already installed, label `dev.wt.mac-runner`).
- Produces: Voxfall running on the Mac with live logs — the plan's exit criterion.

- [ ] **Step 1: Ship from the sandbox**

```bash
limactl shell wt -- bash -c "export WT_CONFIG=\$HOME/dev/voxfall/.config/wt.conf && \
  wt enter v1 <<< './scripts/ship-mac.sh --dev; exit'"
```

Expected: `shipped Voxfall.app — the host agent relaunches it now`.

- [ ] **Step 2: Verify on the Mac (host)**

```bash
ls ~/wt-export/incoming/Voxfall.app/Contents/MacOS/   # Voxfall + assets/
tail -5 ~/wt-export/logs/agent.log                    # signed + opened
tail -f ~/wt-export/logs/stdout.log                   # Bevy startup logs, live
```

Expected: the Voxfall window is on screen; stdout.log shows Bevy/wgpu init lines. If the window opens then dies: `ls ~/wt-export/logs/crashes/` — an `.ips` there is the debugging entry point, and a missing-assets panic in stdout.log means the `cp -R crates/app/assets` line (Task 4) didn't land in the bundle.

- [ ] **Step 3: Prove the incremental loop** (the point of all this)

In the guest sandbox (a `wt enter v1` session starts at the canonical path, so plain relative paths work): add any visible log line to `crates/app/src/main.rs`, re-run `./scripts/ship-mac.sh --dev`, and time it.
Expected: seconds-scale rebuild; the Mac window relaunches with the change. Revert afterwards, inside the same sandbox session: `git checkout -- crates/app/src/main.rs`.

- [ ] **Step 4: Wrap up**

- Guest: `git push` any fixup commits on `mac-loop`.
- Host wt repo: `git push --force-with-lease fork macos` if Tasks 1–2 landed after the last push.
- Report the measured numbers (cold cross-build, incremental ship) and any contingencies that fired.
- Integration decision (voxfall `mac-loop` → main PR; wt `macos` branch PR) is the user's call — surface it, don't make it.
