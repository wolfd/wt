# wt on macOS: warm cross-builds for Mac apps

wt itself needs Linux and ZFS. This directory runs it in a lightweight Linux VM on your Mac
and turns it into a fast edit→run loop for **macOS GUI apps**:

- sandboxes come from wt as usual (ZFS clone, same canonical path, warm cargo caches);
- inside each sandbox, [cargo-zigbuild](https://github.com/rust-cross/cargo-zigbuild) cross-
  compiles `aarch64-apple-darwin` against **your own Mac's SDK**, injected into the VM at boot;
- a ship script assembles the `.app` and renames it into a shared virtiofs directory;
- a tiny host agent ad-hoc-signs it and `open`s it, wiring stdout/stderr and crash reports
  back into the shared directory where the guest can read them.

Measured on an M-series Mac (2026-07): cold canonical build 59 s, incremental build in a fresh
sandbox 1.8 s, full edit→ship 1.7 s, and the app window repaints on the Mac about a second later.

```
Mac (host)                                 │  Linux VM (Lima, vz+virtiofs)
                                           │
 ~/wt-export  ◄────── virtiofs ──────────► │  /export
   incoming/App.app   ◄─ ship-mac.sh renames bundle, touches run.trigger
   logs/{stdout,stderr}.log  ─►  guest tails them live
 run-latest.sh (launchd/fswatch):          │  wt sandboxes on zpool `wt` (Lima disk)
   codesign --force -s -  →  open -n       │  cargo-zigbuild + SDKROOT=/opt/MacOSX.sdk
 CLT SDKs  ────── read-only mount ───────► │  /host-sdks ─(rsync at boot)→ /opt/MacOSX.sdk
```

## SDK licensing — read this first

The VM copies the SDK from **your** Command Line Tools install at provision time
(`/host-sdks/MacOSX.sdk` → `/opt/MacOSX.sdk`). Apple's license ties the SDK to your Xcode/CLT
install: **never publish or hand out a VM image with the SDK inside.** The image stays private
to the machine that built it; anyone else runs `setup-host.sh` against their own CLT.

## Prerequisites

- macOS on Apple silicon, with the Command Line Tools (`xcode-select --install`).
- Lima ≥ 2.0 and (for the foreground watcher) fswatch:
  `nix profile install nixpkgs#lima nixpkgs#fswatch`

## Setup

```sh
macos/setup-host.sh                     # export dir, wtpool disk, VM up (instance: wt)
limactl shell wt -- bash /wt-src/macos/setup-guest.sh   # rust + zig + cargo-zigbuild + wt
macos/host/install-agent.sh             # launchd agent: relaunch on every ship
```

`setup-host.sh` knobs (env): `WT_MAC_VM` (instance name, default `wt`), `WT_MAC_SDKS` (SDK dir,
default the CLT path), `WT_MAC_DISK_SIZE` (zpool disk, default `80GiB`). The agent scripts take
`WT_MAC_EXPORT` (default `~/wt-export`). Prefer a visible terminal tab over launchd?
`macos/host/watch.sh` is the same loop in the foreground.

## Per project (inside the VM)

```sh
limactl shell wt
git clone <your-app> ~/dev/app && cd ~/dev/app
sudo /usr/local/bin/host-zfs-setup.sh          # migrate the checkout into a dataset; see -h
mkdir -p ~/.config/wt
cat > ~/.config/wt/config <<EOF
WT_CANONICAL=$HOME/dev/app
WT_DS_SRC=wt/proj/canonical
WT_DS_PARENT=wt/proj/clones
WT_HOME=$HOME/dev/app-wt
WT_HOOK_ENTER=/usr/local/share/wt-hooks/mac-env.sh
EOF
```

Copy `macos/example/ship-mac.sh` into your repo (edit the `SHIP_*` defaults) and
`macos/example/Info.plist` to `packaging/Info.plist` (edit names/identifier). Then:

```sh
wt new t1 && wt enter t1
./scripts/ship-mac.sh --dev        # build → bundle → rename into /export → agent relaunches
tail -F /export/logs/stdout.log    # the app's stdout, live from the Mac
ls /export/logs/crashes/           # .ips crash reports swept back per app
```

The enter hook feeds every sandbox session `SDKROOT=/opt/MacOSX.sdk` and
`MACOSX_DEPLOYMENT_TARGET=13.0`; `cargo zigbuild --target aarch64-apple-darwin` does the rest.

## Gotchas we already paid for

- **Do not point the VM at Xcode's macOS 26.x SDK.** Its `.tbd` stubs list only `x86_64-*` and
  `arm64e-*` — plain `arm64-macos` is gone — and zig's linker fails with walls of undefined
  objc/AppKit symbols. The Command Line Tools SDK still carries `arm64-macos`; that is why
  `/host-sdks` defaults to the CLT dir. Check a candidate SDK with:
  `grep -m1 targets: /path/to/SDK/usr/lib/libobjc.tbd` — you want to see `arm64-macos`.
- **sudo-rs** (default `sudo` since Ubuntu 25.10) ignores `-E`. wt ≥ this branch passes an
  explicit `--preserve-env` list and is fine; if you install an older wt in the VM, switch the
  guest back to sudo.ws: `sudo update-alternatives --set sudo /usr/bin/sudo.ws`.
- The SDK rsync must keep `--exclude=Ruby.framework`: with `-L`, its self-referential symlinks
  recurse forever.
- `additionalDisks.format: false` in lima.yaml is what keeps Lima from putting ext4 on the
  zpool disk. The disk shows up as `/dev/vdb` in the guest; there is no `/dev/disk/by-id`.
- zig's embedded ad-hoc signature already verifies on macOS, and virtiofs writes carry no
  quarantine xattr — the host agent re-signs and strips quarantine anyway, as insurance against
  either behavior changing.
- `open -n --stdout <file> --stderr <file>` works with files on virtiofs, and the guest sees
  the output live. That is the entire log-feedback mechanism; there is no daemon.

## Uninstall / teardown

```sh
launchctl bootout gui/$(id -u)/dev.wt.mac-runner   # remove the agent
limactl stop wt && limactl delete wt               # the VM (zpool disk survives)
limactl disk delete wtpool                         # ...and the sandboxes' pool
rm -rf ~/wt-export
```
