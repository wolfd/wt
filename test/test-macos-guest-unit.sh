#!/usr/bin/env bash
# Hermetic unit tests for the guest-side macos/ pieces. The enter hook is tested against
# wt-setup.sh's REAL apply_hook_env (sourcing the file defines the helpers and runs nothing),
# because "the hook's stdout is well-formed env" only matters as "wt actually exports it".
# cargo is a stub that fabricates the target binary; everything else is real.
set -uo pipefail
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^WT_' || true)

DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
HOOK="$DIR/../macos/guest/mac-env.sh"
SHIP="$DIR/../macos/example/ship-mac.sh"
SETUP_GUEST="$DIR/../macos/setup-guest.sh"
WT_SETUP="$DIR/../wt-setup.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS  $*"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

echo "== mac-env.sh speaks wt's env channel =="
out=$(bash "$HOOK"); rc=$?
[ "$rc" -eq 0 ] && ok "the hook exits 0 (non-zero would abort every session)" \
  || no "hook rc=$rc"
bad=$(grep -Evc '^[A-Za-z_][A-Za-z0-9_]*=' <<<"$out" || true)
[ "${bad:-0}" -eq 0 ] \
  && ok "every stdout line is KEY=VALUE (chatter would be silently dropped)" \
  || no "$bad non-env line(s) on stdout: $out"
got=$(bash -c 'source "$1"; apply_hook_env <<<"$2"; echo "$SDKROOT|$MACOSX_DEPLOYMENT_TARGET"' \
        _ "$WT_SETUP" "$out")
[ "$got" = "/opt/MacOSX.sdk|13.0" ] \
  && ok "through the real apply_hook_env, the session gets SDKROOT and the 13.0 target" \
  || no "apply_hook_env produced: $got"

echo "== ship-mac.sh stages, renames, then triggers =="
# cargo stub: fabricate the binaries ship-mac.sh expects, for both profiles.
cat > "$T/bin/cargo" <<'STUB'
#!/usr/bin/env bash
mkdir -p target/aarch64-apple-darwin/release target/aarch64-apple-darwin/debug
printf 'MACHO' > target/aarch64-apple-darwin/release/hello-mac
printf 'MACHO' > target/aarch64-apple-darwin/debug/hello-mac
chmod +x target/aarch64-apple-darwin/release/hello-mac target/aarch64-apple-darwin/debug/hello-mac
STUB
chmod +x "$T/bin/cargo"

PROJ="$T/proj"; EXP="$T/export"
mkdir -p "$PROJ/packaging" "$EXP/incoming"
printf '<plist/>' > "$PROJ/packaging/Info.plist"
ship() { (cd "$PROJ" && env PATH="$T/bin:$PATH" SHIP_EXPORT="$EXP" bash "$SHIP" "$@"); }

ship >/dev/null 2>"$T/ship.err"; rc=$?
[ "$rc" -eq 0 ] && ok "a default (--release) ship exits 0" \
  || no "ship failed (rc=$rc): $(cat "$T/ship.err")"
[ -x "$EXP/incoming/Hello.app/Contents/MacOS/Hello" ] \
  && ok "the binary lands executable at Contents/MacOS/<APP>" \
  || no "bundle binary missing or not executable"
[ -e "$EXP/incoming/Hello.app/Contents/Info.plist" ] \
  && ok "packaging/Info.plist is copied into the bundle" \
  || no "Info.plist missing from the bundle"
[ -e "$EXP/incoming/run.trigger" ] \
  && ok "run.trigger is written (the host agent's wake-up)" \
  || no "run.trigger missing"
find "$EXP/incoming" -maxdepth 1 -name '.stage.*' | grep -q . \
  && no "a .stage.* leftover remains in incoming/" \
  || ok "no staging leftovers (the rename is the publish)"

ship --dev >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "--dev ships the debug binary" || no "--dev failed (rc=$rc)"
ship --wat >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "an unknown profile is usage error 2" || no "--wat gave rc=$rc, want 2"

echo "== setup-guest.sh pins the toolchain =="
export CALL_LOG="$T/calls.log"; : > "$CALL_LOG"
for b in rustup pip3 sudo curl; do
  cat > "$T/bin/$b" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$b" "\$*" >> "\$CALL_LOG"
exit 0
STUB
  chmod +x "$T/bin/$b"
done
# cargo already stubbed above; extend it to record too (setup-guest runs `cargo install`).
cat > "$T/bin/cargo" <<'STUB'
#!/usr/bin/env bash
printf 'cargo %s\n' "$*" >> "$CALL_LOG"
exit 0
STUB
chmod +x "$T/bin/cargo"

WTSRC="$T/wt-src"; mkdir -p "$WTSRC/macos/guest"
printf '#!/bin/bash\n' > "$WTSRC/macos/guest/mac-env.sh"
env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" CALL_LOG="$CALL_LOG" WT_SRC="$WTSRC" \
    bash "$SETUP_GUEST" >"$T/sg.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "setup-guest.sh runs clean against stubs" \
  || no "setup-guest rc=$rc: $(cat "$T/sg.out")"
grep -q '^pip3 install --user --break-system-packages ziglang==0.15.2$' "$CALL_LOG" \
  && ok "zig is pinned: ziglang==0.15.2" \
  || no "zig pin lost: $(grep '^pip3' "$CALL_LOG" || echo '<no pip3 call>')"
grep -q '^cargo install --locked cargo-zigbuild --version 0.23.0$' "$CALL_LOG" \
  && ok "cargo-zigbuild is pinned: 0.23.0" \
  || no "cargo-zigbuild pin lost: $(grep '^cargo install' "$CALL_LOG" || echo '<no install>')"
grep -q '^rustup target add aarch64-apple-darwin$' "$CALL_LOG" \
  && ok "the darwin target is added" \
  || no "no rustup target add: $(grep '^rustup' "$CALL_LOG" || echo '<none>')"
grep -q '^sudo ./install.sh' "$CALL_LOG" \
  && ok "wt itself is installed from /wt-src" \
  || no "wt install missing: $(grep '^sudo' "$CALL_LOG" || echo '<none>')"
grep -Eq '^sudo install .*mac-env\.sh /usr/local/share/wt-hooks/mac-env\.sh$' "$CALL_LOG" \
  && ok "the enter hook is installed to /usr/local/share/wt-hooks/" \
  || no "hook install missing: $(grep 'mac-env' "$CALL_LOG" || echo '<none>')"

echo
echo "== results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
