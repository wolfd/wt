# voxfall on the wt macOS loop — design

**Date:** 2026-07-15 · **Approved:** owner, all sections
**Scope decision:** full edit→ship loop **plus** running voxfall's native Linux test suite
in wt sandboxes. **Auth decision:** read-only bind mount of the host's `~/.ssh` into the
guest (no key copies, no agent forwarding — the host agent is Secretive, which hangs
non-interactive git). **Shape decision:** approach A — productize in both repos.

## Goal

Use the existing `macos/` loop (VM `wt`, zpool `wt`, host agent `dev.wt.mac-runner`) to
build and run voxfall — a Bevy 0.19 Rust workspace at `git@github.com:wolfd/voxfall.git`,
in active use at `~/projects/voxfall` on the host — as a second wt project in the guest,
re-cloned fresh inside the VM. The host checkout is never touched.

## 1. wt repo changes (branch `macos`)

- **`setup-host.sh`: new knob `WT_MAC_SSH_DIR`** (default empty = feature off). When set
  (e.g. `~/.ssh`), inject a **read-only** virtiofs mount of that directory at `/host-ssh`,
  using the same `--set` injection as `/wt-src` and `/host-sdks`. Never writable.
- **Existing instance:** apply the mount to the already-running `wt` VM via
  `limactl edit` + restart — documented; no rebuild, the zpool disk is untouched.
- **`macos/README.md`, per-project section:**
  - Private-repo clone recipe:
    `GIT_SSH_COMMAND='ssh -i /host-ssh/id_ed25519 -o IdentitiesOnly=yes' git clone <url>`,
    then persist with `git config core.sshCommand 'ssh -i /host-ssh/id_ed25519 -o IdentitiesOnly=yes'`
    so plain `git fetch/pull` works forever after (same pattern the wt fork remote uses on
    the host, for the same Secretive reason).
  - Second-project pattern: the guest's global `~/.config/wt/config` stays owned by the
    first project; each additional repo commits `.config/wt.conf` and every wt command for
    it runs with `WT_CONFIG=<checkout>/.config/wt.conf` (wt's re-exec already preserves it
    through sudo-rs via the explicit `--preserve-env` list).

## 2. voxfall repo changes

- **`.config/wt.conf`** (committed):
  ```sh
  WT_CANONICAL=$HOME/dev/voxfall
  WT_DS_SRC=wt/proj/voxfall
  WT_DS_PARENT=wt/proj/voxfall-clones
  WT_HOME=$HOME/dev/voxfall-wt
  WT_HOOK_ENTER=/usr/local/share/wt-hooks/mac-env.sh
  ```
- **`scripts/ship-mac.sh`**: copy of `macos/example/ship-mac.sh` with voxfall defaults
  (`SHIP_APP=Voxfall`, `SHIP_BIN=app` — the `[[bin]]` in `crates/app/Cargo.toml`) and one
  real extension: rsync `crates/app/assets/` into `Voxfall.app/Contents/MacOS/assets`.
  Bevy's default asset root is the executable's directory, so bundling assets next to the
  binary needs no code change.
- **`packaging/Info.plist`**: copy of `macos/example/Info.plist` with name `Voxfall` and
  identifier `dev.wolfd.voxfall`.
- **Guest-deps note** (short doc in voxfall, e.g. `docs/mac-vm.md`): the apt packages the
  native Linux test build needs (Bevy on Linux: `libasound2-dev`, `libudev-dev`, plus
  whatever the first `cargo build` proves missing). These are project-specific, so they
  live in voxfall, not in wt's `setup-guest.sh`.

## 3. Guest one-time setup (existing flow, no new tooling)

```sh
limactl shell wt
GIT_SSH_COMMAND='ssh -i /host-ssh/id_ed25519 -o IdentitiesOnly=yes' \
  git clone git@github.com:wolfd/voxfall.git ~/dev/voxfall
cd ~/dev/voxfall && git config core.sshCommand 'ssh -i /host-ssh/id_ed25519 -o IdentitiesOnly=yes'
sudo apt-get install -y libasound2-dev libudev-dev   # + anything the first build proves
sudo WT_CONFIG=$HOME/dev/voxfall/.config/wt.conf /wt-src/host-zfs-setup.sh -y
export WT_CONFIG=$HOME/dev/voxfall/.config/wt.conf
wt new v1 && wt enter v1
```

Inside a sandbox, both loops:
- **Linux tests:** `cargo test --workspace` (native target, warm caches from the canonical
  dataset).
- **Mac app:** `./scripts/ship-mac.sh --dev` → cargo-zigbuild `aarch64-apple-darwin` →
  `Voxfall.app` (binary + assets + Info.plist) → renamed into `/export/incoming` → the
  existing host agent signs and `open`s it; `tail -F /export/logs/stdout.log`, crash
  reports in `/export/logs/crashes/`.

## 4. Risks and mitigations

- **Cross-compile blockers (main risk):** a transitive crate failing under cargo-zigbuild —
  most likely `coreaudio-sys`/`cpal` via `bevy_audio` (bindgen against SDK frameworks).
  Mitigation: milestone 1 is a bare
  `cargo zigbuild --target aarch64-apple-darwin` of the workspace, before any bundling
  work; if a crate blocks, gate audio (or the offending feature) off for mac dev builds.
- **ssh key permission check across virtiofs:** uid 501 maps through and the host file is
  0600, so it should pass; fallback is catting the key into a per-session tmpfs file.
- **WT_CONFIG footgun:** forgetting the export makes wt silently operate on the `app`
  project. Called out in both READMEs; acceptable for now (a shell alias is an easy
  personal fix).
- **Existing-VM drift:** the mount knob must land in the committed `lima.yaml`/
  `setup-host.sh` path so a VM rebuild reproduces it — no hand-edits that evaporate.

## Verification

1. wt unit suite stays green (`test/*.sh`).
2. Live end-to-end in order: mount visible at `/host-ssh` → clone works → zfs migration →
   `wt new v1` → `cargo test -p sim` green in the sandbox → milestone-1 zigbuild → full
   `ship-mac.sh --dev` → app window on the Mac, live stdout in `/export/logs`.
