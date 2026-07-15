#!/usr/bin/env bash
# Guest-side setup: the pinned cross toolchain plus wt itself. Run inside the VM:
#   limactl shell wt -- bash /wt-src/macos/setup-guest.sh
# Idempotent; re-run after bumping the pins.
set -euo pipefail
ZIG_VERSION=${ZIG_VERSION:-0.15.2}
CARGO_ZIGBUILD_VERSION=${CARGO_ZIGBUILD_VERSION:-0.23.0}
WT_SRC=${WT_SRC:-/wt-src}

[ -d "$WT_SRC" ] || { echo "$WT_SRC not mounted — start the VM with macos/setup-host.sh" >&2; exit 1; }

command -v cargo >/dev/null 2>&1 || {
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
}
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
rustup target add aarch64-apple-darwin
pip3 install --user --break-system-packages "ziglang==$ZIG_VERSION"
# cargo install rebuilds from source every time — skip it when the pin is already in place.
command -v cargo-zigbuild >/dev/null 2>&1 && cargo-zigbuild --version 2>/dev/null | grep -qF "$CARGO_ZIGBUILD_VERSION" \
  || cargo install --locked cargo-zigbuild --version "$CARGO_ZIGBUILD_VERSION"

(cd "$WT_SRC" && sudo ./install.sh)
sudo install -D -m 0755 "$WT_SRC/macos/guest/mac-env.sh" /usr/local/share/wt-hooks/mac-env.sh

echo
echo "toolchain ready. Per project, see macos/README.md:"
echo "  clone your repo, point ~/.config/wt/config at it, then run /wt-src/host-zfs-setup.sh"
echo "  (WT_HOOK_ENTER=/usr/local/share/wt-hooks/mac-env.sh)"
